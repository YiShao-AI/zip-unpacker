// C interface to 7-Zip's archive handlers (7z, RAR 4/5, tar, gz, bz2, xz, zstd, iso, cab, zip and more).
#ifndef UZ_BRIDGE_H
#define UZ_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    UZ_OK = 0,
    UZ_NOT_ARCHIVE = 1,        // the handler doesn't recognise the data
    UZ_UNKNOWN_FORMAT = 2,     // no handler with that name
    UZ_NEED_PASSWORD = 3,      // encrypted and no password given
    UZ_WRONG_PASSWORD = 4,
    UZ_UNSUPPORTED_METHOD = 5,
    UZ_DATA_ERROR = 6,         // damaged data / CRC error
    UZ_MISSING_VOLUME = 7,     // archive ends early: a part of a multi-part set is missing
    UZ_IO_ERROR = 8,           // couldn't read the input or write the output
    UZ_CANCELLED = 9
} uz_status;

/// Called with bytes processed so far and the total (may be 0 if unknown). Return non-zero to cancel.
typedef int (*uz_progress_fn)(void *ctx, uint64_t done, uint64_t total);

/// Extracts every item of an archive into `dest_dir` (created by the caller).
/// - format: 7-Zip handler name, e.g. "7z", "Rar", "Rar5", "zip", "gzip", "bzip2", "xz", "zstd", "tar", "Iso", "Cab".
/// - parts/nparts: the archive, or the pieces of a byte-split archive (x.7z.001, .002…) read as one.
///   Volumes of a RAR set (x.part2.rar, x.r00) or a spanned zip (x.z01) are found next to parts[0].
/// - default_name: file name for an item without a name (single-file .gz/.xz/.bz2).
/// - password: UTF-8, or NULL. Only used if the archive asks for one.
/// - message: receives a short English description of the first problem (may be NULL).
/// - files_written: receives the number of files written (may be NULL).
uz_status uz_extract(const char *format, const char *const *parts, int nparts, const char *dest_dir,
                     const char *default_name, const char *password, uz_progress_fn progress, void *ctx,
                     char *message, size_t message_len, int *files_written);

/// 1 if a handler with this name exists.
int uz_has_format(const char *format);

#ifdef __cplusplus
}
#endif

#endif
