/*
 * FlashDB firmware measurement harness -- minimal <time.h> shim.
 *
 * FlashDB's public header includes <time.h> unconditionally, but the library
 * itself never calls the C clock: TSDB timestamps come from the application
 * callback (fdb_get_time), which the harness supplies deterministically.
 */
#ifndef HARNESS_LIBC_SHIM_TIME_H
#define HARNESS_LIBC_SHIM_TIME_H

typedef long time_t;

#endif /* HARNESS_LIBC_SHIM_TIME_H */
