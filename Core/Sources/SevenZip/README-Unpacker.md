# SevenZip (vendored)

7-Zip 26.05 source (https://github.com/ip7z/7zip, release 26.05), trimmed to the objects of the
`Bundles/Format7zF` build (every archive format 7-Zip reads) plus headers. License: GNU LGPL with the
unRAR restriction, see DOC/License.txt and DOC/unRarLicense.txt (RAR code may only be used to extract).

Unpacker additions: `CPP/7zip/UI/Bridge/uz_bridge.cpp` and `include/uz_bridge.h`, a small C API
(`uz_extract`) used by UnpackCore for everything that isn't a plain zip.

To update: download a new `7zNNNN-src.tar.xz`, regenerate the source list (SOURCES.txt) from
`CPP/7zip/Bundles/Format7zF/Arc_gcc.mak` + `makefile.gcc`, copy those files and all headers, keep the bridge.
