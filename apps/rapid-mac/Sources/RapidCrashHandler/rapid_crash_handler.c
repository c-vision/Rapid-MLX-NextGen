// SPDX-License-Identifier: MIT
//
// Pure-C signal handler + arena. See ``RapidCrashHandler.h`` for the
// rationale; the short version: Swift static-var reads invoke
// ``_swift_beginAccess`` which re-enters the runtime — async-signal-
// unsafe. This file gives the handler raw extern-struct reads.

#include "RapidCrashHandler.h"

#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>

// The arena lives in BSS; ``rapid_crash_arena_install`` populates
// it at install time. Zero-initialized at process start so a signal
// firing before install (vanishingly unlikely) just no-ops out via
// the NULL ``marker_path`` guard.
//
// ``static`` (file-private) so Swift's strict concurrency checker
// can't see it as a non-Sendable extern global. The signal handler
// in this same TU reads it directly; Swift accesses go through
// the ``rapid_crash_arena_snapshot`` helper which returns a by-value
// copy.
static rapid_crash_arena_t rapid_crash_arena;

void rapid_crash_arena_install(
    const char *marker_path,
    const char *sigabrt_buf, size_t sigabrt_len,
    const char *sigsegv_buf, size_t sigsegv_len,
    const char *sigbus_buf,  size_t sigbus_len,
    const char *sigill_buf,  size_t sigill_len,
    const char *sigfpe_buf,  size_t sigfpe_len)
{
    // Populate scalar fields in dependency order: pointers + lens
    // first, then expose marker_path LAST so the signal handler
    // sees an arena that's either entirely empty (marker_path
    // NULL, bail out via the NULL guard) or entirely populated.
    // Avoids a partial-init torn read if a signal lands mid-install
    // — pathological today (install runs on the main thread before
    // anything can crash) but trivial to guarantee.
    rapid_crash_arena.sigabrt.buf = sigabrt_buf;
    rapid_crash_arena.sigabrt.len = sigabrt_len;
    rapid_crash_arena.sigsegv.buf = sigsegv_buf;
    rapid_crash_arena.sigsegv.len = sigsegv_len;
    rapid_crash_arena.sigbus.buf  = sigbus_buf;
    rapid_crash_arena.sigbus.len  = sigbus_len;
    rapid_crash_arena.sigill.buf  = sigill_buf;
    rapid_crash_arena.sigill.len  = sigill_len;
    rapid_crash_arena.sigfpe.buf  = sigfpe_buf;
    rapid_crash_arena.sigfpe.len  = sigfpe_len;
    rapid_crash_arena.detailed_flag = 0;
    rapid_crash_arena.marker_path = marker_path;
}

void rapid_crash_arena_reset(void)
{
    // Zero the entire arena. Buffer ownership stays with Swift —
    // the caller is responsible for ``UnsafeMutablePointer.deallocate``
    // on the originals BEFORE calling reset (otherwise the arena
    // forgets them and they leak).
    memset(&rapid_crash_arena, 0, sizeof(rapid_crash_arena));
}

void rapid_crash_mark_detailed_written(void)
{
    // ``volatile sig_atomic_t`` store. ``sig_atomic_t`` is the only
    // type the C standard requires the implementation to be able to
    // load/store atomically with respect to signal delivery, and
    // ``volatile`` keeps the compiler from hoisting the store out
    // of the function or eliding it after subsequent reads.
    rapid_crash_arena.detailed_flag = 1;
}

rapid_crash_arena_snapshot_t rapid_crash_arena_snapshot(void)
{
    rapid_crash_arena_snapshot_t snap;
    snap.marker_path  = rapid_crash_arena.marker_path;
    snap.detailed_flag = rapid_crash_arena.detailed_flag;
    snap.sigabrt_buf  = rapid_crash_arena.sigabrt.buf;
    snap.sigabrt_len  = rapid_crash_arena.sigabrt.len;
    snap.sigsegv_buf  = rapid_crash_arena.sigsegv.buf;
    snap.sigsegv_len  = rapid_crash_arena.sigsegv.len;
    snap.sigbus_buf   = rapid_crash_arena.sigbus.buf;
    snap.sigbus_len   = rapid_crash_arena.sigbus.len;
    snap.sigill_buf   = rapid_crash_arena.sigill.buf;
    snap.sigill_len   = rapid_crash_arena.sigill.len;
    snap.sigfpe_buf   = rapid_crash_arena.sigfpe.buf;
    snap.sigfpe_len   = rapid_crash_arena.sigfpe.len;
    return snap;
}

void rapid_crash_signal_handler(int sig)
{
    // Read the F7 race guard. If the NSException hook already wrote
    // the rich uncaught_exception payload, leave it alone — re-raise
    // and let the OS default disposition produce the crash report.
    if (rapid_crash_arena.detailed_flag != 0) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    // Guard against the (pathological) "signal fires before install"
    // case. If install ran, marker_path is non-NULL.
    const char *path = rapid_crash_arena.marker_path;
    if (path == NULL) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }

    // F9 0o600: the marker body may carry an active context label
    // that leaks workflow state, so other local users on a shared
    // Mac account must not be able to read the file. ``umask`` may
    // further tighten this but cannot loosen it.
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) {
        const char *buf = NULL;
        size_t len = 0;
        switch (sig) {
            case SIGABRT:
                buf = rapid_crash_arena.sigabrt.buf;
                len = rapid_crash_arena.sigabrt.len;
                break;
            case SIGSEGV:
                buf = rapid_crash_arena.sigsegv.buf;
                len = rapid_crash_arena.sigsegv.len;
                break;
            case SIGBUS:
                buf = rapid_crash_arena.sigbus.buf;
                len = rapid_crash_arena.sigbus.len;
                break;
            case SIGILL:
                buf = rapid_crash_arena.sigill.buf;
                len = rapid_crash_arena.sigill.len;
                break;
            case SIGFPE:
                buf = rapid_crash_arena.sigfpe.buf;
                len = rapid_crash_arena.sigfpe.len;
                break;
            default:
                // Defensive: only 5 signals are wired via sigaction.
                // If a stray lands here, fall back to SIGABRT shape
                // so the next launch still records "something".
                buf = rapid_crash_arena.sigabrt.buf;
                len = rapid_crash_arena.sigabrt.len;
                break;
        }
        if (buf != NULL && len > 0) {
            // EINTR/EAGAIN ignored: we're about to die and have no
            // way to recover. write(2) returning short is fine —
            // the next launch decodes what's there or treats it as
            // garbage and discards.
            (void)write(fd, buf, len);
        }
        (void)close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}
