# Assistant replacement and dictation coexistence

## Status

Accepted for the 0.13.1 implementation track. Desktop wiring is separate.

## User contract

Changing the Desktop assistant model does not restart the server. The caller
chooses one explicit policy for work already owned by the current assistant:

- `reject` (default) leaves the current assistant untouched when it is busy;
- `wait` closes new assistant admission, drains admitted/running/queued work,
  and then replaces it;
- `abort` closes admission, terminates admitted/running/queued work, and then
  replaces it. Streaming and non-streaming callers both receive a terminal
  cancellation signal.

Speech-to-text and text-to-speech are auxiliary audio lanes. They do not join
the `assistant` replacement group. A completed assistant replacement changes
the model worker through the existing audio-worker handoff transaction while
preserving the audio lane's loaded model and lifecycle state. If audio work is
active, the handoff fails closed: the assistant remains available, the audio
request reaches its original terminal result, and no worker is stopped.

## Ownership and state

The inference engine owns assistant admission and scheduler state. Its
lifecycle snapshot exposes `paused`, `pause_mode`, and admitted, queued,
running, and total active request counts. The residency manager serializes the
replacement transaction and publishes that engine-owned truth through
`GET /v1/models/residency`.

The audio-worker dispatcher remains the single source of truth for auxiliary
lane residency and active work. The residency response appends its
`audio_lanes` snapshot without folding audio activity into assistant counters.
This keeps replacement policy scoped to the selected lifecycle group.

## Transaction boundary

1. Materialize the replacement through the existing runtime serving-lane
   resolver, but do not publish it.
2. Close admission on every old assistant engine and reach the selected
   reject/drain/abort boundary.
3. Acquire the existing primary/audio-worker handoff lease.
4. Publish the replacement as primary, retire old assistant engines, and
   commit the worker handoff.
5. On cancellation or failure, discard the unpublished replacement, reopen
   old assistant admission, and roll back the audio-worker lease.

No capacity, idle-TTL, audio-lane, scheduler, or Desktop policy is introduced
by this decision.

## Verification

Contract tests cover admission races, queued/running truth, wait/abort terminal
behavior for streaming and non-streaming callers, replacement rollback, audio
work blocking a worker handoff under every assistant replacement policy, and
speech-to-text serving before and after a successful assistant replacement.
