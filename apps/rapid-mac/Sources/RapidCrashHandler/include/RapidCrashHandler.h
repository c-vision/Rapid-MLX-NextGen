// SPDX-License-Identifier: MIT
//
// Pure-C signal handler + arena owned by rapid-desktop's CrashReporter
// surface. Issue #24: the previous Swift implementation kept the arena
// as ``nonisolated(unsafe) static var`` storage, but Swift static-var
// reads compile down to ``_swift_beginAccess`` exclusivity-tracking
// runtime calls — re-entering the Swift runtime from an interrupted
// signal context is exactly the deadlock class signal handlers must
// avoid. This C target gives us truly signal-safe reads: plain extern
// struct fields, no Swift accessor machinery on the read path.
//
// Swift owns the lifecycle (alloc/install/free) and writes pointers
// INTO the arena at install time via the ``rapid_crash_arena_install``
// helper. The signal handler ONLY reads.

#ifndef RAPID_CRASH_HANDLER_H
#define RAPID_CRASH_HANDLER_H

#include <signal.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// One per-signal envelope: pre-built JSON payload in the
// ``CrashMarker`` decode shape that ``flushPendingCrashReports``
// expects (session_id + version + error_type + error_message).
typedef struct {
    const char *buf;    // owned by Swift, NUL-free, ``write(2)``-ready
    size_t len;         // bytes to ``write(2)``
} rapid_crash_envelope_t;

// Arena read by the signal handler. All fields are populated by Swift
// at install time via ``rapid_crash_arena_install``; the handler only
// reads them. Declared ``volatile`` so the compiler doesn't hoist or
// re-order loads relative to ``raise`` / ``write``.
//
// ``detailed_flag`` is the F7 race guard. NSException hook sets it to
// 1 BEFORE the runtime fires SIGABRT via ``objc_terminate``; signal
// handler reads it and bails out without ``O_TRUNC`` over the rich
// payload. ``sig_atomic_t`` is the only type the C standard pins as
// race-safe across the writer/handler boundary.
typedef struct {
    const char *marker_path;            // NUL-terminated, for open(2)
    volatile sig_atomic_t detailed_flag;
    rapid_crash_envelope_t sigabrt;
    rapid_crash_envelope_t sigsegv;
    rapid_crash_envelope_t sigbus;
    rapid_crash_envelope_t sigill;
    rapid_crash_envelope_t sigfpe;
} rapid_crash_arena_t;

// Test-only readback. Returns a by-value snapshot of the arena's
// observable state — the field-by-field layout matches
// ``rapid_crash_arena_t`` so the Swift regression suite can pin
// it without importing the live extern (which Swift 6 strict-
// concurrency rejects as non-Sendable shared mutable state).
typedef struct {
    const char *marker_path;
    sig_atomic_t detailed_flag;
    const char *sigabrt_buf;
    size_t sigabrt_len;
    const char *sigsegv_buf;
    size_t sigsegv_len;
    const char *sigbus_buf;
    size_t sigbus_len;
    const char *sigill_buf;
    size_t sigill_len;
    const char *sigfpe_buf;
    size_t sigfpe_len;
} rapid_crash_arena_snapshot_t;

rapid_crash_arena_snapshot_t rapid_crash_arena_snapshot(void);

// Populate the arena. All pointer arguments must outlive the arena
// (i.e. the process); Swift ``malloc``'s them at install time and
// never frees in production. Test helpers call ``..._free`` to drop
// them between regression runs.
void rapid_crash_arena_install(
    const char *marker_path,
    const char *sigabrt_buf, size_t sigabrt_len,
    const char *sigsegv_buf, size_t sigsegv_len,
    const char *sigbus_buf,  size_t sigbus_len,
    const char *sigill_buf,  size_t sigill_len,
    const char *sigfpe_buf,  size_t sigfpe_len);

// Test-only: zero the arena fields so a follow-up install rebuilds
// from scratch. Does NOT free the underlying buffers — Swift owns
// those and frees them via ``UnsafeMutablePointer.deallocate``.
void rapid_crash_arena_reset(void);

// F7 setter. NSException hook calls this BEFORE the runtime fires
// ``objc_terminate`` -> SIGABRT, so the signal handler leaves the
// rich payload on disk instead of truncating it with the generic
// envelope. ``volatile sig_atomic_t`` store is async-signal-safe.
void rapid_crash_mark_detailed_written(void);

// The C signal handler. Passed to ``sigaction(2)`` from Swift. Only
// reads ``rapid_crash_arena``; the only runtime calls it makes are
// ``open``, ``write``, ``close``, ``signal``, ``raise`` — all on the
// async-signal-safe whitelist.
void rapid_crash_signal_handler(int sig);

#ifdef __cplusplus
}
#endif

#endif // RAPID_CRASH_HANDLER_H
