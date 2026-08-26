from __future__ import annotations

import asyncio
import threading
from types import SimpleNamespace

import pytest

from vllm_mlx.engine.batched import BatchedEngine, _admission_token_context
from vllm_mlx.engine_core import EngineCore
from vllm_mlx.mllm_scheduler import MLLMScheduler
from vllm_mlx.output_collector import RequestOutputCollector
from vllm_mlx.scheduler import BackpressureError, Scheduler


def _engine(*, reservations: int = 0, running: dict | None = None):
    engine = BatchedEngine.__new__(BatchedEngine)
    engine._is_mllm = False
    engine._mllm_scheduler = None
    engine._admission_lock = threading.Lock()
    engine._admission_reservations = reservations
    engine._admission_tokens = {f"reserved-{index}" for index in range(reservations)}
    engine._admission_tasks = {}
    engine._lifecycle_aborted_tasks = set()
    _admission_token_context.set(
        (id(engine), ("reserved-0",)) if reservations else None
    )
    engine._generation_paused = False
    engine._generation_pause_mode = None
    scheduler = SimpleNamespace(
        requests=running or {},
        running=running or {},
        waiting=[],
        config=SimpleNamespace(max_concurrent_requests=8),
    )

    def set_generation_paused(paused, *, add_allowance=0):
        scheduler.generation_paused = paused
        scheduler.add_allowance = add_allowance if paused else 0

    def pause_generation_admission(tokens, mode):
        scheduler.generation_paused = True
        owned = {
            getattr(request, "lifecycle_admission_token", None)
            for request in scheduler.requests.values()
        }
        pending = set(tokens) - owned
        scheduler._paused_admission_tokens = pending if mode == "wait" else set()
        scheduler.add_allowance = len(scheduler._paused_admission_tokens)

    scheduler.set_generation_paused = set_generation_paused
    scheduler.pause_generation_admission = pause_generation_admission
    engine._engine = SimpleNamespace(engine=SimpleNamespace(scheduler=scheduler))
    engine.get_stats = lambda: {
        "num_running": len(scheduler.running),
        "num_waiting": len(scheduler.waiting),
    }
    return engine, scheduler


@pytest.mark.asyncio
async def test_wait_pause_closes_admission_then_drains_existing_request():
    engine, _ = _engine(reservations=1)

    pause = asyncio.create_task(engine.pause_generation("wait"))
    await asyncio.sleep(0)

    with pytest.raises(BackpressureError, match="paused"):
        engine.check_admission()
    assert not pause.done()

    engine.release_admission_reservation()
    status = await asyncio.wait_for(pause, timeout=1)
    assert status["paused"] is True
    assert status["admitted_requests"] == 0

    await engine.resume_generation()
    engine.check_admission()
    engine.release_admission_reservation()


@pytest.mark.asyncio
async def test_abort_pause_rechecks_requests_that_arrive_after_pause_edge():
    engine, scheduler = _engine(reservations=1)
    aborted = []

    async def abort_request(request_id, *, error_kind=None):
        assert error_kind == "lifecycle"
        aborted.append(request_id)
        scheduler.requests.pop(request_id, None)
        scheduler.running.pop(request_id, None)
        engine.release_admission_reservation()
        return True

    engine.abort_request = abort_request
    pause = asyncio.create_task(engine.pause_generation("abort"))
    await asyncio.sleep(0)

    # Simulate a route that reserved just before pause and reached the
    # scheduler just after it. Abort mode must discover it on a later scan.
    request = SimpleNamespace(request_id="late")
    scheduler.requests["late"] = request
    scheduler.running["late"] = request

    status = await asyncio.wait_for(pause, timeout=1)
    assert aborted == ["late"]
    assert status["running_requests"] == 0
    assert status["admitted_requests"] == 0


@pytest.mark.asyncio
async def test_abort_pause_cancels_request_stalled_before_scheduler_commit():
    engine, scheduler = _engine()
    admitted = asyncio.Event()

    async def stalled_request():
        engine.check_admission()
        admitted.set()
        try:
            await asyncio.Event().wait()
        finally:
            engine.release_admission_reservation()

    request = asyncio.create_task(stalled_request())
    await admitted.wait()

    status = await asyncio.wait_for(engine.pause_generation("abort"), timeout=1)

    with pytest.raises(asyncio.CancelledError):
        await request
    assert scheduler._paused_admission_tokens == set()
    assert status["admitted_requests"] == 0


@pytest.mark.asyncio
async def test_pre_scheduler_abort_returns_terminal_non_streaming_503():
    from fastapi import HTTPException

    from vllm_mlx.service.helpers import _wait_with_disconnect

    engine, _ = _engine()
    preprocessing = asyncio.Event()

    class RawRequest:
        async def is_disconnected(self):
            return False

    async def stalled_generation():
        preprocessing.set()
        await asyncio.Event().wait()

    async def request():
        engine.check_admission()
        try:
            return await _wait_with_disconnect(
                stalled_generation(),
                RawRequest(),
                timeout=5,
                poll_interval=0.01,
            )
        finally:
            engine.release_admission_reservation()

    response = asyncio.create_task(request())
    await preprocessing.wait()
    status = await asyncio.wait_for(engine.pause_generation("abort"), timeout=1)

    with pytest.raises(HTTPException) as exc_info:
        await response
    assert exc_info.value.status_code == 503
    assert exc_info.value.detail == "Request cancelled by model replacement"
    assert status["admitted_requests"] == 0


@pytest.mark.asyncio
async def test_route_boundary_translates_lifecycle_abort_before_helper_binding():
    from fastapi import HTTPException

    from vllm_mlx.service.helpers import _raise_lifecycle_cancel_or_reraise

    engine, _ = _engine()
    adapting = asyncio.Event()

    async def route_boundary():
        engine.check_admission()
        try:
            adapting.set()
            await asyncio.Event().wait()
        except asyncio.CancelledError as exc:
            _raise_lifecycle_cancel_or_reraise(engine, exc)
        finally:
            engine.release_admission_reservation()

    response = asyncio.create_task(route_boundary())
    await adapting.wait()
    status = await asyncio.wait_for(engine.pause_generation("abort"), timeout=1)

    with pytest.raises(HTTPException) as exc_info:
        await response
    assert exc_info.value.status_code == 503
    assert exc_info.value.detail == "Request cancelled by model replacement"
    assert status["admitted_requests"] == 0


@pytest.mark.asyncio
async def test_route_boundary_preserves_unowned_cancellation():
    from vllm_mlx.service.helpers import _raise_lifecycle_cancel_or_reraise

    engine, _ = _engine()
    error = asyncio.CancelledError("client disconnected")

    with pytest.raises(asyncio.CancelledError) as exc_info:
        _raise_lifecycle_cancel_or_reraise(engine, error)
    assert exc_info.value is error


@pytest.mark.asyncio
async def test_pre_scheduler_abort_emits_terminal_streaming_error():
    import json

    from vllm_mlx.service.helpers import _disconnect_guard

    engine, _ = _engine()
    preprocessing = asyncio.Event()

    class RawRequest:
        async def is_disconnected(self):
            return False

    async def stalled_stream():
        preprocessing.set()
        await asyncio.Event().wait()
        yield "unreachable"

    async def request():
        engine.check_admission()
        try:
            return [
                chunk
                async for chunk in _disconnect_guard(
                    stalled_stream(),
                    RawRequest(),
                    poll_interval=0.01,
                    engine=engine,
                    keepalive_seconds=0,
                )
            ]
        finally:
            engine.release_admission_reservation()

    response = asyncio.create_task(request())
    await preprocessing.wait()
    status = await asyncio.wait_for(engine.pause_generation("abort"), timeout=1)
    chunks = await response

    payload = json.loads(chunks[0].removeprefix("data: "))
    assert payload["error"]["code"] == "model_replacement"
    assert chunks[-1] == "data: [DONE]\n\n"
    assert status["admitted_requests"] == 0


@pytest.mark.asyncio
async def test_text_core_reports_scheduler_commit_before_waiting_for_output():
    from vllm_mlx.request import SamplingParams

    core = EngineCore.__new__(EngineCore)
    committed = []

    class SchedulerStub:
        def __init__(self):
            self.requests = {}

        def add_request(self, request):
            self.requests[request.request_id] = request

    core.scheduler = SchedulerStub()
    core._hybrid_throttle = False
    core._output_collectors = {}
    core._stream_states = {}
    core._finished_events = {}
    core._mlx_executor = None
    core._idle_event = asyncio.Event()
    core.config = SimpleNamespace(stream_interval=1)

    request_id = await core.add_request(
        "prompt",
        SamplingParams(max_tokens=1),
        request_id="committed",
        on_request_committed=lambda: committed.append(
            "committed" if "committed" in core.scheduler.requests else "too-early"
        ),
    )

    assert request_id == "committed"
    assert committed == ["committed"]


@pytest.mark.asyncio
async def test_mllm_reports_commit_after_output_queue_is_ready():
    scheduler = MLLMScheduler.__new__(MLLMScheduler)
    scheduler.output_queues = {}
    scheduler.add_request = lambda **_kwargs: "committed"
    committed = []

    request_id = await scheduler.add_request_async(
        "prompt",
        on_request_committed=lambda: committed.append(
            "committed" if "committed" in scheduler.output_queues else "too-early"
        ),
    )

    assert request_id == "committed"
    assert committed == ["committed"]


@pytest.mark.asyncio
async def test_direct_non_stream_generation_transfers_admission_at_commit():
    engine, scheduler = _engine()
    committed = asyncio.Event()

    class AsyncCoreStub:
        def __init__(self):
            self.engine = SimpleNamespace(scheduler=scheduler)

        async def generate(self, **kwargs):
            kwargs["on_request_committed"]()
            committed.set()
            await asyncio.Event().wait()

    engine._engine = AsyncCoreStub()
    engine._loaded = True

    generation = asyncio.create_task(engine.generate("prompt", max_tokens=1))
    await committed.wait()

    assert engine._admission_reservations == 0
    assert engine._admission_tokens == set()
    assert engine._current_admission_token() is None

    generation.cancel()
    with pytest.raises(asyncio.CancelledError):
        await generation


@pytest.mark.asyncio
async def test_direct_stream_generation_reserves_until_scheduler_commit():
    engine, scheduler = _engine()
    committed = asyncio.Event()

    class AsyncCoreStub:
        def __init__(self):
            self.engine = SimpleNamespace(scheduler=scheduler)

        async def add_request(self, **kwargs):
            assert engine._admission_reservations == 1
            kwargs["on_request_committed"]()
            committed.set()
            return "streaming"

        async def stream_outputs(self, _request_id):
            await asyncio.Event().wait()
            yield  # pragma: no cover - keeps this an async generator

    engine._engine = AsyncCoreStub()
    engine._loaded = True

    stream = engine.stream_generate("prompt", max_tokens=1)
    consumer = asyncio.create_task(anext(stream))
    await committed.wait()

    assert engine._admission_reservations == 0
    assert engine._admission_tokens == set()
    assert engine._current_admission_token() is None

    consumer.cancel()
    with pytest.raises(asyncio.CancelledError):
        await consumer
    await stream.aclose()


@pytest.mark.asyncio
async def test_direct_stream_precommit_failure_releases_admission():
    engine, scheduler = _engine()

    class FailingCoreStub:
        def __init__(self):
            self.engine = SimpleNamespace(scheduler=scheduler)

        async def add_request(self, **_kwargs):
            raise RuntimeError("precommit failed")

    engine._engine = FailingCoreStub()
    engine._loaded = True

    with pytest.raises(RuntimeError, match="precommit failed"):
        await anext(engine.stream_generate("prompt", max_tokens=1))

    assert engine._admission_reservations == 0
    assert engine._admission_tokens == set()


@pytest.mark.asyncio
async def test_engine_precommit_cleanup_preserves_lifecycle_route_translation():
    from fastapi import HTTPException

    from vllm_mlx.service.helpers import _raise_lifecycle_cancel_or_reraise

    engine, scheduler = _engine()
    entered_precommit = asyncio.Event()

    class StalledCoreStub:
        def __init__(self):
            self.engine = SimpleNamespace(scheduler=scheduler)

        async def generate(self, **_kwargs):
            entered_precommit.set()
            await asyncio.Event().wait()

    engine._engine = StalledCoreStub()
    engine._loaded = True

    async def route_boundary():
        try:
            await engine.generate("prompt", max_tokens=1)
        except asyncio.CancelledError as exc:
            _raise_lifecycle_cancel_or_reraise(engine, exc)

    response = asyncio.create_task(route_boundary())
    await entered_precommit.wait()
    status = await asyncio.wait_for(engine.pause_generation("abort"), timeout=1)

    with pytest.raises(HTTPException) as exc_info:
        await response
    assert exc_info.value.status_code == 503
    assert exc_info.value.detail == "Request cancelled by model replacement"
    assert status["admitted_requests"] == 0
    assert not engine._lifecycle_aborted_tasks


@pytest.mark.asyncio
async def test_direct_mllm_stream_transfers_admission_at_queue_commit():
    engine, _ = _engine()
    committed = asyncio.Event()

    class MLLMSchedulerStub:
        config = SimpleNamespace(max_concurrent_requests=8)

        async def add_request_async(self, **kwargs):
            assert engine._admission_reservations == 1
            kwargs["on_request_committed"]()
            committed.set()
            return "mllm-streaming"

        async def stream_outputs(self, _request_id):
            await asyncio.Event().wait()
            yield  # pragma: no cover - keeps this an async generator

    engine._is_mllm = True
    engine._mllm_scheduler = MLLMSchedulerStub()
    engine._engine = None
    engine._loaded = True

    stream = engine.stream_generate("prompt", max_tokens=1)
    consumer = asyncio.create_task(anext(stream))
    await committed.wait()

    assert engine._admission_reservations == 0
    assert engine._admission_tokens == set()
    assert engine._current_admission_token() is None

    consumer.cancel()
    with pytest.raises(asyncio.CancelledError):
        await consumer
    await stream.aclose()


@pytest.mark.asyncio
async def test_wait_pause_allows_request_reserved_before_pause_to_enter_scheduler():
    engine, scheduler = _engine(reservations=1)

    pause = asyncio.create_task(engine.pause_generation("wait"))
    await asyncio.sleep(0)

    assert scheduler.generation_paused is True
    assert scheduler.add_allowance == 1

    # This request owns the one reservation captured at the pause edge.
    scheduler.add_allowance -= 1
    request = SimpleNamespace(request_id="reserved-before-pause")
    scheduler.requests[request.request_id] = request
    scheduler.running[request.request_id] = request
    await asyncio.sleep(0)
    assert not pause.done()

    scheduler.requests.clear()
    scheduler.running.clear()
    engine.release_admission_reservation()
    await asyncio.wait_for(pause, timeout=1)


@pytest.mark.asyncio
async def test_zero_timeout_atomically_pauses_an_idle_engine():
    engine, _ = _engine()

    status = await engine.pause_generation("wait", timeout=0)

    assert status["paused"] is True
    with pytest.raises(BackpressureError, match="paused"):
        engine.check_admission()


def test_text_scheduler_rejects_direct_add_while_paused():
    scheduler = Scheduler.__new__(Scheduler)
    scheduler._generation_paused = True

    with pytest.raises(BackpressureError, match="paused"):
        scheduler.add_request(SimpleNamespace(request_id="direct"))


def test_mllm_scheduler_rejects_direct_add_while_paused():
    scheduler = MLLMScheduler.__new__(MLLMScheduler)
    scheduler._generation_paused = True

    with pytest.raises(BackpressureError, match="paused"):
        scheduler.add_request("prompt", request_id="direct")


def test_paused_engine_rejects_even_when_concurrency_cap_is_unlimited():
    engine, scheduler = _engine()
    scheduler.config.max_concurrent_requests = None
    engine._generation_paused = True

    with pytest.raises(BackpressureError, match="paused"):
        engine.check_admission()


def test_unlimited_cap_still_tracks_lifecycle_reservation():
    engine, scheduler = _engine()
    scheduler.config.max_concurrent_requests = None

    engine.check_admission()

    assert engine._admission_reservations == 1
    engine.release_admission_reservation()
    assert engine._admission_reservations == 0


def test_lifecycle_status_reports_each_owned_stage_and_total():
    running = {"one": object(), "two": object()}
    engine, scheduler = _engine(reservations=1, running=running)
    scheduler.waiting.append(object())

    status = engine.lifecycle_status()

    assert status["admitted_requests"] == 1
    assert status["running_requests"] == 2
    assert status["queued_requests"] == 1
    assert status["active_requests"] == 4


def test_scheduler_transfer_releases_route_owned_reservation():
    engine, _ = _engine()
    engine.check_admission()
    token = engine._current_admission_token()

    engine._transfer_admission_to_scheduler(token)

    assert engine._admission_reservations == 0
    assert engine._admission_tokens == set()


@pytest.mark.asyncio
async def test_stream_terminal_release_cannot_consume_concurrent_admission():
    engine, scheduler = _engine()
    scheduler.config.max_concurrent_requests = None
    stream_transferred = asyncio.Event()
    concurrent_reserved = asyncio.Event()
    release_concurrent = asyncio.Event()
    concurrent_token = None

    async def streaming_request():
        engine.check_admission()
        token = engine._current_admission_token()
        engine._transfer_admission_to_scheduler(token)
        stream_transferred.set()
        await concurrent_reserved.wait()
        engine.release_admission_reservation()

    async def concurrent_request():
        nonlocal concurrent_token
        await stream_transferred.wait()
        engine.check_admission()
        concurrent_token = engine._current_admission_token()
        concurrent_reserved.set()
        await release_concurrent.wait()
        engine.release_admission_reservation()

    stream = asyncio.create_task(streaming_request())
    concurrent = asyncio.create_task(concurrent_request())
    await stream

    assert concurrent_token is not None
    assert engine._admission_reservations == 1
    assert engine._admission_tokens == {concurrent_token}

    release_concurrent.set()
    await concurrent
    assert engine._admission_reservations == 0


@pytest.mark.parametrize("scheduler_type", [Scheduler, MLLMScheduler])
@pytest.mark.parametrize("mode", ["wait", "abort"])
def test_scheduler_pause_accepts_only_uncommitted_pre_pause_token(scheduler_type, mode):
    scheduler = scheduler_type.__new__(scheduler_type)
    scheduler._cancel_counter_lock = threading.Lock()
    scheduler.requests = {
        "already-owned": SimpleNamespace(lifecycle_admission_token="owned")
    }

    scheduler.pause_generation_admission({"owned", "pending"}, mode)

    assert scheduler._generation_paused is True
    expected = {"pending"} if mode == "wait" else set()
    assert scheduler._paused_add_allowance == len(expected)
    assert scheduler._paused_admission_tokens == expected

    scheduler.set_generation_paused(False)
    assert scheduler._generation_paused is False
    assert scheduler._paused_add_allowance == 0


def test_same_context_admissions_release_as_a_token_stack():
    engine, scheduler = _engine()
    scheduler.config.max_concurrent_requests = None

    engine.check_admission()
    engine.check_admission()
    assert engine._admission_reservations == 2

    engine.release_admission_reservation()
    assert engine._admission_reservations == 1
    engine.release_admission_reservation()
    assert engine._admission_reservations == 0


def test_cross_context_release_preserves_legacy_release_contract():
    engine, _ = _engine()
    engine.check_admission()
    _admission_token_context.set(None)

    engine.release_admission_reservation()

    assert engine._admission_reservations == 0
    assert engine._admission_tokens == set()


@pytest.mark.parametrize("scheduler_type", [Scheduler, MLLMScheduler])
def test_request_id_snapshot_is_safe_during_concurrent_mutation(scheduler_type):
    scheduler = scheduler_type.__new__(scheduler_type)
    scheduler._cancel_counter_lock = threading.Lock()
    scheduler.requests = {}
    start = threading.Event()

    def mutate():
        start.wait()
        for index in range(2_000):
            with scheduler._cancel_counter_lock:
                scheduler.requests[str(index)] = index
                if index:
                    scheduler.requests.pop(str(index - 1), None)

    writer = threading.Thread(target=mutate)
    writer.start()
    start.set()
    for _ in range(2_000):
        assert isinstance(scheduler.request_ids_snapshot(), tuple)
    writer.join()


@pytest.mark.parametrize("scheduler_type", [Scheduler, MLLMScheduler])
def test_request_publication_is_atomic_with_wait_queue(scheduler_type):
    class TracedLock:
        def __init__(self):
            self._lock = threading.Lock()
            self.contended = threading.Event()

        def __enter__(self):
            if self._lock.locked():
                self.contended.set()
            self._lock.acquire()
            return self

        def __exit__(self, *_args):
            self._lock.release()

    entered_append = threading.Event()
    release_append = threading.Event()

    class BlockingWaiting(list):
        def append(self, request):
            entered_append.set()
            assert release_append.wait(timeout=1)
            super().append(request)

    scheduler = scheduler_type.__new__(scheduler_type)
    scheduler._cancel_counter_lock = TracedLock()
    scheduler._generation_paused = False
    scheduler._paused_admission_tokens = set()
    scheduler._paused_add_allowance = 0
    scheduler.requests = {}
    scheduler.waiting = BlockingWaiting()
    scheduler._cancelled_request_ids = set()
    scheduler._disconnect_abort_ids = set()
    scheduler._orphaned_running_candidates = {}
    request = SimpleNamespace(request_id="publishing", lifecycle_admission_token=None)
    errors = []

    def publish():
        try:
            scheduler._commit_request(request)
        except BaseException as exc:
            errors.append(exc)

    publisher = threading.Thread(target=publish)

    def pause():
        try:
            scheduler.pause_generation_admission(set(), "wait")
        except BaseException as exc:
            errors.append(exc)

    publisher.start()
    assert entered_append.wait(timeout=1)
    pauser = threading.Thread(target=pause)
    pauser.start()

    assert scheduler._cancel_counter_lock.contended.wait(timeout=1)
    assert pauser.is_alive()
    release_append.set()
    publisher.join(timeout=1)
    pauser.join(timeout=1)

    assert errors == []
    assert scheduler.requests == {"publishing": request}
    assert scheduler.waiting == [request]
    assert scheduler._generation_paused is True


@pytest.mark.asyncio
async def test_text_abort_wakes_non_streaming_consumer_with_terminal_error():
    engine = EngineCore.__new__(EngineCore)
    engine.scheduler = SimpleNamespace(abort_request=lambda _request_id: True)
    engine._output_collectors = {
        "active": RequestOutputCollector(aggregate=True),
    }
    engine._finished_events = {"active": asyncio.Event()}
    engine._idle_event = asyncio.Event()

    assert await engine.abort_request("active", error_kind="lifecycle") is True
    await asyncio.wait_for(engine._finished_events["active"].wait(), timeout=0.1)

    terminal = engine._output_collectors["active"].get_nowait()
    assert terminal is not None
    assert terminal.finished is True
    assert terminal.error_kind == "lifecycle"
    assert "cancellation" in terminal.error
    # The waiting stream/generate coroutine owns cleanup after consuming the
    # terminal signal. Removing these here recreates the hung HTTP request.
    assert "active" in engine._output_collectors
    assert "active" in engine._finished_events


@pytest.mark.asyncio
async def test_text_ordinary_abort_preserves_non_lifecycle_cleanup():
    engine = EngineCore.__new__(EngineCore)
    engine.scheduler = SimpleNamespace(
        abort_request=lambda _request_id: True,
        remove_finished_request=lambda _request_id: None,
    )
    engine._output_collectors = {
        "active": RequestOutputCollector(aggregate=True),
    }
    engine._stream_states = {"active": object()}
    engine._stream_buffers = {"active": object()}
    engine._finished_events = {"active": asyncio.Event()}
    engine._idle_event = asyncio.Event()

    assert await engine.abort_request("active") is True

    await asyncio.wait_for(engine._finished_events["active"].wait(), timeout=0.1)
    terminal = engine._output_collectors["active"].get_nowait()
    assert terminal is not None
    assert terminal.finished is True
    assert terminal.error is None
    assert terminal.error_kind is None
    # The consumer still owns cleanup after receiving the ordinary terminal.
    assert "active" in engine._output_collectors
    assert "active" in engine._finished_events


def test_mllm_abort_delivers_terminal_error_instead_of_empty_success():
    scheduler = MLLMScheduler.__new__(MLLMScheduler)
    scheduler.output_queues = {"active": asyncio.Queue()}
    scheduler._aborted_queue_ids = {"active"}
    scheduler._abort_error_kinds = {"active": "lifecycle"}

    scheduler._distribute_outputs(SimpleNamespace(outputs=[]))

    terminal = scheduler.output_queues["active"].get_nowait()
    assert terminal.finished is True
    assert terminal.error_kind == "lifecycle"
    assert "cancellation" in terminal.error


def test_mllm_ordinary_abort_preserves_non_lifecycle_queue_close():
    scheduler = MLLMScheduler.__new__(MLLMScheduler)
    scheduler.output_queues = {"active": asyncio.Queue()}
    scheduler._aborted_queue_ids = {"active"}
    scheduler._abort_error_kinds = {}

    scheduler._distribute_outputs(SimpleNamespace(outputs=[]))

    assert scheduler.output_queues["active"].get_nowait() is None


def test_mllm_lifecycle_abort_records_reason_until_terminal_delivery():
    scheduler = MLLMScheduler.__new__(MLLMScheduler)
    scheduler._cancel_counter_lock = threading.Lock()
    scheduler.requests = {"active": object()}
    scheduler.request_id_to_uid = {}
    scheduler.running = {}
    scheduler._pending_abort_ids = set()
    scheduler._cancelled_request_ids = set()
    scheduler._abort_error_kinds = {}
    scheduler.num_requests_cancelled = 0

    assert scheduler.abort_request("active", error_kind="lifecycle") is True

    assert scheduler._abort_error_kinds == {"active": "lifecycle"}


def test_mllm_abort_remains_queued_until_terminal_delivery():
    scheduler = MLLMScheduler.__new__(MLLMScheduler)
    scheduler.waiting = []
    scheduler.running = {}
    scheduler.finished_req_ids = set()
    scheduler._aborted_queue_ids = {"active"}
    scheduler.num_requests_processed = 0
    scheduler.total_prompt_tokens = 0
    scheduler.total_completion_tokens = 0
    scheduler.num_requests_cancelled = 0
    scheduler.num_requests_cancelled_via_disconnect = 0
    scheduler.batch_generator = None
    scheduler.vision_cache = None

    assert scheduler.get_stats()["num_waiting"] == 1


def test_mllm_terminal_delivery_is_counted_by_engine_lifecycle():
    engine, _ = _engine()
    scheduler = MLLMScheduler.__new__(MLLMScheduler)
    scheduler.waiting = []
    scheduler.running = {}
    scheduler.finished_req_ids = set()
    scheduler._aborted_queue_ids = {"active"}
    scheduler.num_requests_processed = 0
    scheduler.total_prompt_tokens = 0
    scheduler.total_completion_tokens = 0
    scheduler.num_requests_cancelled = 0
    scheduler.num_requests_cancelled_via_disconnect = 0
    scheduler.batch_generator = None
    scheduler.vision_cache = None
    engine._is_mllm = True
    engine._mllm_scheduler = scheduler
    engine._engine = None
    engine.get_stats = scheduler.get_stats

    status = engine.lifecycle_status()

    assert status["queued_requests"] == 1
    assert status["active_requests"] == 1


@pytest.mark.asyncio
async def test_mllm_abort_unblocks_consumer_as_inference_error():
    from vllm_mlx.request import InferenceAbortedError, RequestOutput

    scheduler = MLLMScheduler.__new__(MLLMScheduler)
    scheduler.output_queues = {"active": asyncio.Queue()}
    scheduler.output_queues["active"].put_nowait(
        RequestOutput(
            request_id="active",
            finished=True,
            finish_reason="length",
            error="Inference aborted by a cancellation request",
            error_kind="lifecycle",
        )
    )

    with pytest.raises(InferenceAbortedError, match="cancellation") as exc_info:
        await anext(scheduler.stream_outputs("active"))
    assert exc_info.value.error_kind == "lifecycle"
    assert "active" not in scheduler.output_queues


@pytest.mark.asyncio
async def test_text_abort_preserves_lifecycle_reason_through_stream_consumer():
    from vllm_mlx.request import InferenceAbortedError

    engine = EngineCore.__new__(EngineCore)
    engine.scheduler = SimpleNamespace(abort_request=lambda _request_id: True)
    engine._output_collectors = {
        "active": RequestOutputCollector(aggregate=True),
    }
    engine._finished_events = {"active": asyncio.Event()}
    engine._idle_event = asyncio.Event()
    engine._cleanup_request = lambda _request_id: None

    assert await engine.abort_request("active", error_kind="lifecycle") is True

    with pytest.raises(InferenceAbortedError, match="cancellation") as exc_info:
        await anext(engine.stream_outputs("active"))
    assert exc_info.value.error_kind == "lifecycle"


@pytest.mark.asyncio
async def test_post_commit_lifecycle_abort_emits_model_replacement_sse():
    import json

    from vllm_mlx.request import InferenceAbortedError
    from vllm_mlx.service.helpers import _disconnect_guard

    engine, _ = _engine()

    class RawRequest:
        async def is_disconnected(self):
            return False

    async def aborted_stream():
        raise InferenceAbortedError(
            "Inference aborted by a cancellation request",
            error_kind="lifecycle",
        )
        yield "unreachable"  # pragma: no cover

    chunks = [
        chunk
        async for chunk in _disconnect_guard(
            aborted_stream(),
            RawRequest(),
            poll_interval=0.01,
            engine=engine,
            keepalive_seconds=0,
        )
    ]

    payload = json.loads(chunks[0].removeprefix("data: "))
    assert payload["error"] == {
        "message": "Request cancelled by model replacement",
        "type": "server_error",
        "code": "model_replacement",
    }
    assert chunks[-1] == "data: [DONE]\n\n"
