// Bridge between the Unpacker app and 7-Zip's archive handlers. See include/uz_bridge.h.

#include "../../../Common/MyWindows.h"
#include "../../../Common/MyCom.h"
#include "../../../Common/MyString.h"
#include "../../../Common/UTFConvert.h"
#include "../../../Windows/PropVariant.h"
#include "../../Archive/IArchive.h"
#include "../../IPassword.h"
#include "../../PropID.h"

#include "../../../../include/uz_bridge.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <new>
#include <string>
#include <vector>

STDAPI GetNumberOfFormats(UINT32 *numFormats);
STDAPI GetHandlerProperty2(UInt32 formatIndex, PROPID propID, PROPVARIANT *value);
STDAPI CreateArchiver(const GUID *clsid, const GUID *iid, void **outObject);

namespace {

std::string ToUtf8(const UString &u) {
    AString a;
    ConvertUnicodeToUTF8(u, a);
    return std::string(a.Ptr(), a.Len());
}

UString FromUtf8(const char *s) {
    UString u;
    ConvertUTF8ToUnicode(AString(s), u);
    return u;
}

std::string DirName(const std::string &p) {
    size_t i = p.rfind('/');
    return i == std::string::npos ? std::string(".") : p.substr(0, i);
}

std::string BaseName(const std::string &p) {
    size_t i = p.rfind('/');
    return i == std::string::npos ? p : p.substr(i + 1);
}

bool MakeDirs(const std::string &path) {
    std::string cur;
    size_t i = 0;
    while (i <= path.size()) {
        size_t j = path.find('/', i);
        if (j == std::string::npos) j = path.size();
        cur = path.substr(0, j);
        if (!cur.empty() && mkdir(cur.c_str(), 0755) != 0 && errno != EEXIST) return false;
        i = j + 1;
    }
    return true;
}

/// Item path → safe relative path: "\" and "/" both separate, "", "." and ".." parts are dropped.
std::string SafeRelative(const std::string &raw) {
    std::string out, part;
    std::string s = raw;
    for (char &c : s) if (c == '\\') c = '/';
    size_t i = 0;
    while (i <= s.size()) {
        size_t j = s.find('/', i);
        if (j == std::string::npos) j = s.size();
        part = s.substr(i, j - i);
        if (!part.empty() && part != "." && part != "..") {
            if (!out.empty()) out += '/';
            out += part;
        }
        i = j + 1;
    }
    return out;
}

// ---------- Input: one file, or several read back to back ----------

Z7_CLASS_IMP_IInStream(CMultiInStream)
    struct Seg { int fd; UInt64 start; UInt64 size; };
    std::vector<Seg> _segs;
    UInt64 _pos = 0;
    UInt64 _size = 0;
public:
    bool Open(const char *const *paths, int n) {
        for (int i = 0; i < n; i++) {
            int fd = open(paths[i], O_RDONLY);
            if (fd < 0) return false;
            struct stat st;
            if (fstat(fd, &st) != 0) { close(fd); return false; }
            _segs.push_back({fd, _size, (UInt64)st.st_size});
            _size += (UInt64)st.st_size;
        }
        return !_segs.empty();
    }
    ~CMultiInStream() { for (const Seg &s : _segs) close(s.fd); }
};

Z7_COM7F_IMF(CMultiInStream::Read(void *data, UInt32 size, UInt32 *processedSize)) {
    if (processedSize) *processedSize = 0;
    if (size == 0 || _pos >= _size) return S_OK;
    size_t k = _segs.size() - 1;
    while (_segs[k].start > _pos) k--;
    const Seg &s = _segs[k];
    UInt64 left = s.start + s.size - _pos;
    if (left == 0) return S_OK;
    UInt32 n = (UInt32)(size < left ? size : left);
    ssize_t r;
    do { r = pread(s.fd, data, n, (off_t)(_pos - s.start)); } while (r < 0 && errno == EINTR);
    if (r < 0) return E_FAIL;
    _pos += (UInt64)r;
    if (processedSize) *processedSize = (UInt32)r;
    return S_OK;
}

Z7_COM7F_IMF(CMultiInStream::Seek(Int64 offset, UInt32 seekOrigin, UInt64 *newPosition)) {
    Int64 base;
    switch (seekOrigin) {
        case STREAM_SEEK_SET: base = 0; break;
        case STREAM_SEEK_CUR: base = (Int64)_pos; break;
        case STREAM_SEEK_END: base = (Int64)_size; break;
        default: return STG_E_INVALIDFUNCTION;
    }
    Int64 p = base + offset;
    if (p < 0) return HRESULT_WIN32_ERROR_NEGATIVE_SEEK;
    _pos = (UInt64)p;
    if (newPosition) *newPosition = _pos;
    return S_OK;
}

// ---------- Output: a file descriptor ----------

Z7_CLASS_IMP_COM_1(COutFdStream, ISequentialOutStream)
public:
    int fd = -1;
    bool failed = false;
    ~COutFdStream() { if (fd >= 0) close(fd); }
};

Z7_COM7F_IMF(COutFdStream::Write(const void *data, UInt32 size, UInt32 *processedSize)) {
    if (processedSize) *processedSize = 0;
    const char *p = (const char *)data;
    UInt32 done = 0;
    while (done < size) {
        ssize_t w = write(fd, p + done, size - done);
        if (w < 0) {
            if (errno == EINTR) continue;
            failed = true;
            return E_FAIL;
        }
        done += (UInt32)w;
    }
    if (processedSize) *processedSize = done;
    return S_OK;
}

// ---------- Shared state ----------

struct Run {
    const char *password = nullptr;
    bool passwordAsked = false;
    std::string missingVolume;   // a volume 7-Zip asked for that isn't there
    uz_status status = UZ_OK;
    std::string message;
    void Fail(uz_status s, const std::string &m) {
        // Keep the first problem, but a wrong/missing password explains later data errors.
        if (status == UZ_OK || ((s == UZ_WRONG_PASSWORD || s == UZ_NEED_PASSWORD) && status == UZ_DATA_ERROR)) {
            status = s;
            message = m;
        }
    }
    HRESULT Password(BSTR *pw) {
        passwordAsked = true;
        if (!password) return E_ABORT;
        return StringToBstr(FromUtf8(password), pw);
    }
};

// ---------- Open: volumes + password for encrypted headers ----------

class COpenCallback Z7_final:
    public IArchiveOpenCallback,
    public IArchiveOpenVolumeCallback,
    public ICryptoGetTextPassword,
    public CMyUnknownImp
{
    Z7_IFACES_IMP_UNK_3(IArchiveOpenCallback, IArchiveOpenVolumeCallback, ICryptoGetTextPassword)
public:
    Run *run = nullptr;
    std::string dir;
    std::string firstName;
};

Z7_COM7F_IMF(COpenCallback::SetTotal(const UInt64 *, const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(COpenCallback::SetCompleted(const UInt64 *, const UInt64 *)) { return S_OK; }

Z7_COM7F_IMF(COpenCallback::GetProperty(PROPID propID, PROPVARIANT *value)) {
    NWindows::NCOM::CPropVariant prop;
    if (propID == kpidName) prop = FromUtf8(firstName.c_str());
    prop.Detach(value);
    return S_OK;
}

Z7_COM7F_IMF(COpenCallback::GetStream(const wchar_t *name, IInStream **inStream)) {
    *inStream = nullptr;
    std::string n = BaseName(ToUtf8(UString(name)));
    std::string path = dir + "/" + n;
    struct stat st;
    if (stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
        if (run->missingVolume.empty()) run->missingVolume = n;
        return S_FALSE;
    }
    CMultiInStream *spec = new CMultiInStream;
    CMyComPtr<IInStream> s = spec;
    const char *p = path.c_str();
    if (!spec->Open(&p, 1)) return S_FALSE;
    *inStream = s.Detach();
    return S_OK;
}

Z7_COM7F_IMF(COpenCallback::CryptoGetTextPassword(BSTR *password)) { return run->Password(password); }

// ---------- Extract ----------

class CExtractCallback Z7_final:
    public IArchiveExtractCallback,
    public ICryptoGetTextPassword,
    public CMyUnknownImp
{
    Z7_IFACES_IMP_UNK_2(IArchiveExtractCallback, ICryptoGetTextPassword)
    Z7_IFACE_COM7_IMP(IProgress)
public:
    Run *run = nullptr;
    IInArchive *arc = nullptr;
    std::string dest;
    std::string defaultName;
    uz_progress_fn progress = nullptr;
    void *ctx = nullptr;
    UInt64 total = 0;
    bool cancelled = false;
    int files = 0;
    std::string curPath;
    bool curEncrypted = false;
    bool skipping = false;
    CMyComPtr<ISequentialOutStream> cur;
};

Z7_COM7F_IMF(CExtractCallback::SetTotal(UInt64 size)) { total = size; return S_OK; }

Z7_COM7F_IMF(CExtractCallback::SetCompleted(const UInt64 *completeValue)) {
    if (progress && completeValue && progress(ctx, *completeValue, total) != 0) {
        cancelled = true;
        return E_ABORT;
    }
    return S_OK;
}

static bool BoolProp(IInArchive *arc, UInt32 index, PROPID id) {
    NWindows::NCOM::CPropVariant p;
    if (arc->GetProperty(index, id, &p) != S_OK) return false;
    return p.vt == VT_BOOL && p.boolVal != VARIANT_FALSE;
}

Z7_COM7F_IMF(CExtractCallback::GetStream(UInt32 index, ISequentialOutStream **outStream, Int32 askExtractMode)) {
    *outStream = nullptr;
    cur.Release();
    skipping = false;
    curEncrypted = BoolProp(arc, index, kpidEncrypted);
    if (askExtractMode != NArchive::NExtract::NAskMode::kExtract) return S_OK;

    NWindows::NCOM::CPropVariant prop;
    RINOK(arc->GetProperty(index, kpidPath, &prop))
    std::string raw = prop.vt == VT_BSTR ? ToUtf8(UString(prop.bstrVal)) : std::string();
    std::string rel = SafeRelative(raw);
    if (rel.empty()) rel = defaultName.empty() ? std::string("file") : defaultName;
    curPath = rel;
    std::string full = dest + "/" + rel;

    if (BoolProp(arc, index, kpidIsDir)) {
        if (!MakeDirs(full)) run->Fail(UZ_IO_ERROR, "Couldn't create folder " + rel);
        return S_OK;
    }
    // Links (symbolic or hard) are skipped: they point at other items and aren't content.
    NWindows::NCOM::CPropVariant pa;
    if (arc->GetProperty(index, kpidPosixAttrib, &pa) == S_OK && pa.vt == VT_UI4 && S_ISLNK(pa.ulVal)) { skipping = true; return S_OK; }
    for (PROPID id : {(PROPID)kpidSymLink, (PROPID)kpidHardLink}) {
        NWindows::NCOM::CPropVariant lp;
        if (arc->GetProperty(index, id, &lp) == S_OK && lp.vt == VT_BSTR && lp.bstrVal && lp.bstrVal[0]) { skipping = true; return S_OK; }
    }

    if (!MakeDirs(DirName(full))) {
        run->Fail(UZ_IO_ERROR, "Couldn't create folder for " + rel);
        return S_OK;
    }
    int fd = open(full.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        run->Fail(UZ_IO_ERROR, "Couldn't write " + rel + ": " + strerror(errno));
        return S_OK;
    }
    COutFdStream *spec = new COutFdStream;
    spec->fd = fd;
    cur = spec;
    *outStream = cur;
    (*outStream)->AddRef();
    files++;
    return S_OK;
}

Z7_COM7F_IMF(CExtractCallback::PrepareOperation(Int32)) { return S_OK; }

Z7_COM7F_IMF(CExtractCallback::SetOperationResult(Int32 opRes)) {
    cur.Release();
    if (skipping) return S_OK;
    using namespace NArchive::NExtract::NOperationResult;
    switch (opRes) {
        case kOK: break;
        case kUnsupportedMethod: run->Fail(UZ_UNSUPPORTED_METHOD, "Unsupported compression method in " + curPath); break;
        case kWrongPassword: run->Fail(UZ_WRONG_PASSWORD, "Wrong password for " + curPath); break;
        case kDataError:
        case kCRCError:
            if (curEncrypted) run->Fail(UZ_WRONG_PASSWORD, "Wrong password for " + curPath);
            else run->Fail(UZ_DATA_ERROR, (opRes == kCRCError ? "CRC error in " : "Damaged data in ") + curPath);
            break;
        case kUnavailable:
        case kUnexpectedEnd: run->Fail(UZ_MISSING_VOLUME, "The archive ends early at " + curPath + " (a part is missing?)"); break;
        default: run->Fail(UZ_DATA_ERROR, "Damaged archive at " + curPath); break;
    }
    return S_OK;
}

Z7_COM7F_IMF(CExtractCallback::CryptoGetTextPassword(BSTR *password)) { return run->Password(password); }

bool FindFormat(const char *name, GUID &clsid) {
    UInt32 n = 0;
    if (GetNumberOfFormats(&n) != S_OK) return false;
    for (UInt32 i = 0; i < n; i++) {
        NWindows::NCOM::CPropVariant prop;
        if (GetHandlerProperty2(i, NArchive::NHandlerPropID::kName, &prop) != S_OK || prop.vt != VT_BSTR) continue;
        if (strcasecmp(ToUtf8(UString(prop.bstrVal)).c_str(), name) != 0) continue;
        NWindows::NCOM::CPropVariant id;
        if (GetHandlerProperty2(i, NArchive::NHandlerPropID::kClassID, &id) != S_OK || id.vt != VT_BSTR) return false;
        memcpy(&clsid, id.bstrVal, sizeof(GUID));
        return true;
    }
    return false;
}

uz_status Extract(const char *format, const char *const *parts, int nparts, const char *destDir,
                  const char *defaultName, const char *password, uz_progress_fn progress, void *ctx,
                  std::string &message, int &files) {
    GUID clsid;
    if (!FindFormat(format, clsid)) { message = std::string("No handler for ") + format; return UZ_UNKNOWN_FORMAT; }
    CMyComPtr<IInArchive> arc;
    if (CreateArchiver(&clsid, &IID_IInArchive, (void **)&arc) != S_OK || !arc) {
        message = "Couldn't create the archive handler";
        return UZ_UNKNOWN_FORMAT;
    }

    Run run;
    run.password = password;

    CMultiInStream *inSpec = new CMultiInStream;
    CMyComPtr<IInStream> in = inSpec;
    if (!inSpec->Open(parts, nparts)) { message = "Couldn't open the archive file"; return UZ_IO_ERROR; }

    COpenCallback *ocSpec = new COpenCallback;
    CMyComPtr<IArchiveOpenCallback> oc = ocSpec;
    ocSpec->run = &run;
    ocSpec->dir = DirName(parts[0]);
    ocSpec->firstName = BaseName(parts[0]);

    const UInt64 scan = 1 << 16;
    HRESULT hr = arc->Open(in, &scan, oc);
    if (hr != S_OK) {
        if (run.passwordAsked) {
            message = password ? "Wrong password (the file list is encrypted)" : "The file list is encrypted: a password is needed";
            return password ? UZ_WRONG_PASSWORD : UZ_NEED_PASSWORD;
        }
        message = "Not a valid archive of this type";
        return UZ_NOT_ARCHIVE;
    }

    CExtractCallback *ecSpec = new CExtractCallback;
    CMyComPtr<IArchiveExtractCallback> ec = ecSpec;
    ecSpec->run = &run;
    ecSpec->arc = arc;
    ecSpec->dest = destDir;
    ecSpec->defaultName = defaultName ? defaultName : "";
    ecSpec->progress = progress;
    ecSpec->ctx = ctx;

    hr = arc->Extract(nullptr, (UInt32)(Int32)-1, 0, ec);
    files = ecSpec->files;
    arc->Close();

    if (ecSpec->cancelled) { message = "Cancelled"; return UZ_CANCELLED; }
    if (hr == E_ABORT && run.passwordAsked && !password) {
        message = "Encrypted: a password is needed";
        return UZ_NEED_PASSWORD;
    }
    if (hr != S_OK && run.status == UZ_OK) {
        char buf[64];
        snprintf(buf, sizeof buf, "Extraction failed (error 0x%08X)", (unsigned)hr);
        run.Fail(hr == E_OUTOFMEMORY ? UZ_DATA_ERROR : UZ_DATA_ERROR, buf);
    }
    if (!run.missingVolume.empty() && (run.status == UZ_DATA_ERROR || run.status == UZ_MISSING_VOLUME)) {
        message = "Missing part: " + run.missingVolume;
        return UZ_MISSING_VOLUME;
    }
    message = run.message;
    return run.status;
}

} // namespace

extern "C" uz_status uz_extract(const char *format, const char *const *parts, int nparts, const char *dest_dir,
                                const char *default_name, const char *password, uz_progress_fn progress, void *ctx,
                                char *message, size_t message_len, int *files_written) {
    std::string msg;
    int files = 0;
    uz_status s;
    try {
        s = Extract(format, parts, nparts, dest_dir, default_name, password, progress, ctx, msg, files);
    } catch (const std::bad_alloc &) {
        s = UZ_DATA_ERROR; msg = "Out of memory";
    } catch (...) {
        s = UZ_DATA_ERROR; msg = "Internal error in the archive reader";
    }
    if (message && message_len) snprintf(message, message_len, "%s", msg.c_str());
    if (files_written) *files_written = files;
    return s;
}

extern "C" int uz_has_format(const char *format) {
    GUID g;
    try { return FindFormat(format, g) ? 1 : 0; } catch (...) { return 0; }
}
