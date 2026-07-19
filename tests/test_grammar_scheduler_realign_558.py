# SPDX-License-Identifier: Apache-2.0
"""Scheduler grammar/penalty processor↔uid realignment (#558 PR-3, codex).

mlx-lm's ``GenerationBatch`` stores ``logits_processors`` as a positional
per-uid list. When a NO-processor request finishes while a grammar request is
mid-flight, a stale entry can survive the filter and DESYNC that list from
``uids`` — mlx-lm's ``_step`` then iterates ``range(len(uids))`` and applies
the wrong (or no) processor, silently leaving an explicit ``required``/named
call unconstrained (observed live on qwen3.5-4b: the first tool request after
the boot warmup fell back to free-form).

``Scheduler._realign_grammar_logits_processors`` rebuilds the positional list
from AUTHORITATIVE per-uid state: ``uid_to_request_processors`` holds the FULL
processor list (grammar + penalties) for EVERY live uid that carries any
processor — grammar AND penalty-only — so a bystander's penalties survive a
length-desync rebuild (codex #3). A ``_known_grammar_processors`` identity set
(with tombstones for finished-but-still-leaked grammars) scrubs leaked grammars
from untracked slots. These tests drive that method against a stand-in
generation batch reproducing the desync shapes — no model needed.
"""

from types import SimpleNamespace

import pytest


class _FakeBatchGen:
    """Minimal stand-in for mlx-lm's BatchGenerator + its _generation_batch."""

    def __init__(self, uids, logits_processors):
        self._generation_batch = SimpleNamespace(
            uids=list(uids),
            logits_processors=[list(x) for x in logits_processors],
        )


def _make_scheduler_stub():
    """Bind the realign + forget methods onto a bare state object (no model)."""
    from vllm_mlx.scheduler import Scheduler

    stub = SimpleNamespace(
        uid_to_request_processors={},
        _uids_with_grammar=set(),
        _known_grammar_processors=set(),
        _grammar_processor_objs={},
        _grammar_tombstones=set(),
        batch_generator=None,
    )
    stub._realign_grammar_logits_processors = (
        Scheduler._realign_grammar_logits_processors.__get__(stub, type(stub))
    )
    stub._flush_grammar_tombstones = Scheduler._flush_grammar_tombstones.__get__(
        stub, type(stub)
    )
    stub._forget_uid_grammar = Scheduler._forget_uid_grammar.__get__(stub, type(stub))
    return stub


def _register(stub, uid, processors, grammar=None):
    """Mirror the scheduler's insert-time bookkeeping.

    ``grammar=None`` registers a penalty-only uid (tracked for desync repair but
    not a grammar). A non-None ``grammar`` also registers its identity + arms
    the guard, exactly like the scheduler insert site.
    """
    if processors:
        stub.uid_to_request_processors[uid] = list(processors)
    if grammar is not None:
        stub._uids_with_grammar.add(uid)
        stub._known_grammar_processors.add(id(grammar))
        stub._grammar_processor_objs[id(grammar)] = grammar


def test_realign_repairs_stale_leading_entry():
    # The live-repro shape: a finished no-processor uid left a stale empty
    # entry at index 0; the grammar uid sits at index 1 but is the ONLY live
    # uid. Realign must place the grammar processor at the grammar uid's real
    # position.
    glp = object()
    stub = _make_scheduler_stub()
    _register(stub, 42, [glp], glp)
    stub.batch_generator = _FakeBatchGen(uids=[42], logits_processors=[[], [glp]])

    stub._realign_grammar_logits_processors()

    lp = stub.batch_generator._generation_batch.logits_processors
    assert len(lp) == 1, "logits_processors must be realigned to len(uids)"
    assert lp[0] == [glp], "the grammar processor must land at its uid's index"


def test_realign_two_uids_grammar_not_leaked():
    # A grammar request (uid 7) batched alongside a plain request (uid 9).
    # uid 7 -> [glp]; uid 9 -> [] (no grammar leaked onto it) even when the
    # desynced list wrongly had glp on both slots.
    glp = object()
    stub = _make_scheduler_stub()
    _register(stub, 7, [glp], glp)
    stub.batch_generator = _FakeBatchGen(uids=[7, 9], logits_processors=[[glp], [glp]])

    stub._realign_grammar_logits_processors()

    lp = stub.batch_generator._generation_batch.logits_processors
    assert lp[0] == [glp], "uid 7 must keep its grammar processor"
    assert lp[1] == [], "uid 9 must NOT carry another uid's grammar processor"


def test_realign_preserves_penalties_on_grammar_uid():
    # A grammar uid's penalty processors must be PRESERVED — the authoritative
    # per-uid list carries grammar + penalties in insert order.
    glp = object()
    penalty = object()
    stub = _make_scheduler_stub()
    _register(stub, 5, [penalty, glp], glp)
    # Desynced batch (length mismatch) — a naive rebuild would drop penalty.
    stub.batch_generator = _FakeBatchGen(
        uids=[5], logits_processors=[[], [penalty, glp]]
    )

    stub._realign_grammar_logits_processors()

    lp = stub.batch_generator._generation_batch.logits_processors
    assert lp[0] == [penalty, glp], "grammar uid must keep penalty + grammar in order"


def test_realign_preserves_untracked_penalty_when_aligned():
    # A penalty-only uid keeps its penalties when the list is length-aligned.
    glp = object()
    penalty = object()
    stub = _make_scheduler_stub()
    _register(stub, 7, [glp], glp)  # a grammar uid must exist to trigger realign
    _register(stub, 9, [penalty])  # penalty-only uid, now TRACKED
    stub.batch_generator = _FakeBatchGen(
        uids=[7, 9], logits_processors=[[glp], [penalty]]
    )

    stub._realign_grammar_logits_processors()

    lp = stub.batch_generator._generation_batch.logits_processors
    assert lp[0] == [glp]
    assert lp[1] == [penalty], "tracked penalty-only uid's penalty must be preserved"


def test_realign_preserves_penalty_only_uid_on_desync():
    # codex #3 (the load-bearing regression): when the positional list is
    # LENGTH-DESYNCED, a penalty-only bystander must NOT lose its penalties.
    # Before the fix, an untracked uid got [] on a desync, permanently deleting
    # its repetition/frequency/presence processors (running requests are never
    # re-inserted). Now every processor-carrying uid is tracked, so its slot is
    # reconstructed verbatim from uid-keyed state.
    glp = object()
    penalty = object()
    stub = _make_scheduler_stub()
    _register(stub, 7, [glp], glp)
    _register(stub, 9, [penalty])  # penalty-only, tracked
    # Desync: a stale entry makes the positional list longer than uids.
    stub.batch_generator = _FakeBatchGen(
        uids=[7, 9], logits_processors=[[], [glp], [penalty]]
    )

    stub._realign_grammar_logits_processors()

    lp = stub.batch_generator._generation_batch.logits_processors
    assert len(lp) == 2, "realigned to len(uids)"
    assert lp[0] == [glp]
    assert lp[1] == [penalty], (
        "penalty-only uid must keep its penalties across a length-desync — "
        "not be zeroed (codex #3)"
    )


def test_realign_untracked_uid_with_no_processors_gets_empty_slot():
    # A truly processor-free uid (never registered) gets an empty slot, and any
    # grammar that leaked into it is scrubbed.
    glp = object()
    stub = _make_scheduler_stub()
    _register(stub, 7, [glp], glp)
    # uid 9 was never registered (no processors) but a desync leaked glp in.
    stub.batch_generator = _FakeBatchGen(uids=[7, 9], logits_processors=[[glp], [glp]])

    stub._realign_grammar_logits_processors()

    lp = stub.batch_generator._generation_batch.logits_processors
    assert lp[0] == [glp]
    assert lp[1] == [], "processor-free uid must get an empty, grammar-scrubbed slot"


def test_realign_scrubs_finished_grammar_via_tombstone():
    # codex #1: a grammar whose owning uid already FINISHED can still linger in
    # another slot. _forget_uid_grammar TOMBSTONES it (keeps it in
    # _known_grammar_processors) so realign still scrubs it; only once it's
    # absent from every live slot is it fully forgotten.
    glp_live = object()
    glp_dead = object()  # finished owner, but leaked into uid 9's slot
    stub = _make_scheduler_stub()
    _register(stub, 7, [glp_live], glp_live)
    _register(stub, 8, [glp_dead], glp_dead)
    # uid 8 finishes: forget tombstones glp_dead (still known + scrubbable).
    stub._forget_uid_grammar(8)
    assert id(glp_dead) in stub._known_grammar_processors, (
        "must be tombstoned, not gone"
    )
    assert id(glp_dead) in stub._grammar_tombstones
    # A leaked slot still carries glp_dead at uid 9's (untracked) position.
    stub.batch_generator = _FakeBatchGen(
        uids=[7, 9], logits_processors=[[glp_live], [glp_dead]]
    )

    stub._realign_grammar_logits_processors()

    lp = stub.batch_generator._generation_batch.logits_processors
    assert lp[0] == [glp_live]
    assert lp[1] == [], "a finished (tombstoned) grammar must be scrubbed"
    # Now that it's absent from every slot, the tombstone is flushed.
    assert id(glp_dead) not in stub._known_grammar_processors
    assert id(glp_dead) not in stub._grammar_tombstones
    assert id(glp_dead) not in stub._grammar_processor_objs


def test_tombstone_survives_until_absent_then_flushes():
    # A tombstoned grammar that is STILL present in a leaked slot is NOT
    # forgotten on this tick — it stays known so the NEXT tick can still scrub
    # it. Only when absent from every slot does the flush drop it. This closes
    # the cleanup-ordering gap where the last grammar finishing would disarm the
    # guard before its leaked slot was cleaned.
    glp_dead = object()
    stub = _make_scheduler_stub()
    _register(stub, 8, [glp_dead], glp_dead)
    stub._forget_uid_grammar(8)  # tombstoned; uid_to_request_processors now empty
    # A stale slot still holds glp_dead at an untracked position. The guard is
    # armed by the tombstone even though uid_to_request_processors is empty.
    assert stub._grammar_tombstones, "tombstone must arm the realign guard"
    stub.batch_generator = _FakeBatchGen(uids=[9], logits_processors=[[glp_dead]])

    stub._realign_grammar_logits_processors()

    lp = stub.batch_generator._generation_batch.logits_processors
    assert lp[0] == [], "the tombstoned grammar is scrubbed from the leaked slot"
    # Scrubbed this tick -> now absent -> flushed.
    assert id(glp_dead) not in stub._known_grammar_processors


def test_realign_noop_when_already_correct():
    glp = object()
    stub = _make_scheduler_stub()
    _register(stub, 1, [glp], glp)
    stub.batch_generator = _FakeBatchGen(uids=[1], logits_processors=[[glp]])

    stub._realign_grammar_logits_processors()

    lp = stub.batch_generator._generation_batch.logits_processors
    assert lp == [[glp]]


def test_penalty_only_uid_does_not_arm_the_guard():
    # codex #558-PR3 (perf): a penalty-only request is tracked in
    # uid_to_request_processors for desync repair, but MUST NOT be in
    # _uids_with_grammar — the realign guard arms on _uids_with_grammar (not the
    # broader processor map), so plain penalty traffic never triggers an
    # O(batch) rebuild every token.
    penalty = object()
    stub = _make_scheduler_stub()
    _register(stub, 9, [penalty])  # penalty-only, grammar=None

    assert 9 in stub.uid_to_request_processors, "tracked for desync repair"
    assert 9 not in stub._uids_with_grammar, "penalty-only must NOT arm the guard"
    assert not stub._known_grammar_processors
    assert not stub._grammar_tombstones


def test_forget_penalty_only_uid_creates_no_tombstone():
    penalty = object()
    stub = _make_scheduler_stub()
    _register(stub, 9, [penalty])  # penalty-only

    stub._forget_uid_grammar(9)

    assert 9 not in stub.uid_to_request_processors
    assert not stub._grammar_tombstones, "a penalty-only uid must not tombstone"
    assert not stub._known_grammar_processors


def test_forget_uid_grammar_tombstones_then_flush_drops_state():
    glp = object()
    stub = _make_scheduler_stub()
    _register(stub, 1, [glp], glp)
    assert id(glp) in stub._known_grammar_processors

    stub._forget_uid_grammar(1)

    # uid-keyed state is gone immediately; the grammar identity is TOMBSTONED
    # (still known so a leaked slot can be scrubbed) until a flush confirms it's
    # absent from every slot.
    assert 1 not in stub.uid_to_request_processors
    assert 1 not in stub._uids_with_grammar
    assert id(glp) in stub._known_grammar_processors, "tombstoned, not yet dropped"
    assert id(glp) in stub._grammar_tombstones

    # No slot holds it -> flush drops it entirely.
    stub._flush_grammar_tombstones(present=set())
    assert id(glp) not in stub._known_grammar_processors
    assert id(glp) not in stub._grammar_processor_objs
    assert id(glp) not in stub._grammar_tombstones


def test_realign_handles_missing_generation_batch():
    stub = _make_scheduler_stub()
    _register(stub, 1, [object()], object())
    stub.batch_generator = SimpleNamespace(_generation_batch=None)
    stub._realign_grammar_logits_processors()  # no raise


def test_realign_handles_empty_uids_flushes_tombstones():
    glp_dead = object()
    stub = _make_scheduler_stub()
    _register(stub, 1, [glp_dead], glp_dead)
    stub._forget_uid_grammar(1)  # tombstoned
    stub.batch_generator = _FakeBatchGen(uids=[], logits_processors=[])
    stub._realign_grammar_logits_processors()  # no raise
    # No live slots -> tombstone is trivially absent everywhere -> flushed.
    assert id(glp_dead) not in stub._known_grammar_processors


def test_realign_empty_uids_scrubs_stale_processor_list():
    # codex #558-PR3 blocking: the LAST grammar request finished and the batch
    # emptied its ``uids`` WITHOUT the parallel positional ``logits_processors``
    # list being cleared (mlx-lm keys the two separately). If realign only
    # flushed the tombstone and returned, the leaked ``[glp_dead]`` at index 0
    # would be inherited by the NEXT admitted plain request and silently
    # constrain it. The no-live-slots branch must scrub the stale list to ``[]``
    # while the grammar identity is still known.
    glp_dead = object()
    stub = _make_scheduler_stub()
    _register(stub, 1, [glp_dead], glp_dead)
    stub._forget_uid_grammar(1)  # tombstoned (uid gone, processor may linger)
    # uids empty, but a stale processor slot survived the filter.
    stub.batch_generator = _FakeBatchGen(uids=[], logits_processors=[[glp_dead]])

    stub._realign_grammar_logits_processors()

    lp = stub.batch_generator._generation_batch.logits_processors
    assert lp == [], (
        "a batch with zero uids must carry zero processors — the leaked grammar "
        "slot must be scrubbed so the next plain request cannot inherit it"
    )
    # And the tombstone is flushed now that the grammar is absent everywhere.
    assert id(glp_dead) not in stub._known_grammar_processors
    assert id(glp_dead) not in stub._grammar_tombstones


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
