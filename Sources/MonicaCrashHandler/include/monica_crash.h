#ifndef MONICA_CRASH_H
#define MONICA_CRASH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Crash capture that runs after the Swift runtime can no longer be trusted.
 *
 * A fatal signal handler may only call async-signal-safe functions: no malloc,
 * no Objective-C, no Swift. So this module does exactly one thing inside the
 * handler: it writes a fixed-format report (signal, the crashing thread's
 * frame-pointer walk, and the loaded image table) to a file with write(2),
 * restores the previous disposition and returns so the OS finishes the crash
 * as it would have without MONICA. Everything else -- symbolication, building
 * the event, sending it -- happens in Swift on the next launch.
 */

#define MONICA_CRASH_MAX_FRAMES 128
#define MONICA_CRASH_MAX_IMAGES 1024
#define MONICA_CRASH_MAX_PATH 256

#define MONICA_CRASH_REPORT_MAGIC 0x4d4e4352u /* "MNCR" */
#define MONICA_CRASH_REPORT_VERSION 1u
#define MONICA_CRASH_KIND_SIGNAL 1u
#define MONICA_CRASH_KIND_EXCEPTION 2u

typedef struct {
  uint64_t load_address;
  uint8_t uuid[16];
  char path[MONICA_CRASH_MAX_PATH];
} monica_crash_image;

/* Installs the signal handlers and starts tracking loaded images. The report
 * is written to report_path (copied; at most MONICA_CRASH_MAX_PATH - 1 bytes).
 * Returns false when the path is too long or handlers could not be installed. */
bool monica_crash_install(const char *report_path);

/* Restores the signal dispositions that were in place before install. */
void monica_crash_uninstall(void);

/* Records an uncaught NSException from its (non-signal) handler. The abort()
 * that follows is then ignored by the signal handler so the report is not
 * overwritten. addresses are the exception's callStackReturnAddresses. */
void monica_crash_record_exception(const char *name, const char *reason,
                                   const uint64_t *addresses, uint32_t count);

/* The images currently known to the handler, in load order. */
uint32_t monica_crash_image_count(void);
bool monica_crash_image_at(uint32_t index, monica_crash_image *out);

/* Reads LC_UUID from a Mach-O header. Returns false when there is none. */
bool monica_crash_uuid_of(const void *mach_header, uint8_t out[16]);

/* Whether a report has been written in this process. Tests use it. */
bool monica_crash_has_reported(void);

/* Clears the "already reported" flag. Only tests need this: in a real process
 * the first report is also the last. */
void monica_crash_reset_for_testing(void);

#ifdef __cplusplus
}
#endif

#endif
