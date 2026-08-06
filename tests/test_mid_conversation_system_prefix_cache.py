# SPDX-License-Identifier: Apache-2.0
"""Mid-conversation system messages must not move to the front.

Claude Code injects a ``role: "system"`` message into ``messages``
routinely — the "task tools haven't been used recently" nudge, the "date
has changed" notice, and entering or leaving plan mode — always at the
END of the array, right before the new user turn.

Hoisting those into the leading system block grows the FRONT of the
prompt, shifts everything behind it, and invalidates the prefix cache at
the system/first-user boundary. Measured on qwen3.6-35b before the fix:

    A  no nudge                  input_tokens = 775
    B  nudge mid-array           input_tokens = 803
    C  nudge appended to system  input_tokens = 803   <- B == C, hoisted

    warm-up          input=775  cached=None
    identical resend input=15   cached=760
    + one nudge      input=803  cached=None   <- whole warm prefix gone

After the fix, ``+ one nudge`` reports ``input=55 cached=760`` and a
five-turn conversation hits the cache on every turn instead of never.

The relocation target is the FOLLOWING user turn, wrapped in
``<system-reminder>`` — the tag Claude Code itself uses for reminders it
injects into user turns upstream, so models already read it as an
instruction rather than something the human typed. That turn is new on
this request anyway, so nothing previously cacheable is disturbed.
"""

from vllm_mlx.api.models import Message
from vllm_mlx.api.responses_adapter import _merge_system_messages

NUDGE = (
    "The task tools haven't been used recently. If you're working on tasks "
    "that would benefit from tracking progress, consider using TaskCreate."
)
DATE = "The date has changed. Today's date is now 2026-08-05."


def roles(msgs):
    return [m.role for m in msgs]


def text(msg):
    return msg.content if isinstance(msg.content, str) else str(msg.content)


class TestLeadingSystemUnchanged:
    """The historical contract for LEADING system messages still holds."""

    def test_single_leading_system_stays_at_index_0(self):
        out = _merge_system_messages(
            [
                Message(role="system", content="base prompt"),
                Message(role="user", content="hi"),
            ]
        )
        assert roles(out) == ["system", "user"]
        assert text(out[0]) == "base prompt"

    def test_multiple_leading_systems_merge_in_order(self):
        out = _merge_system_messages(
            [
                Message(role="system", content="first"),
                Message(role="system", content="second"),
                Message(role="user", content="hi"),
            ]
        )
        assert roles(out) == ["system", "user"]
        assert text(out[0]) == "first\n\nsecond"

    def test_no_system_is_a_passthrough(self):
        msgs = [
            Message(role="user", content="hi"),
            Message(role="assistant", content="hello"),
        ]
        assert _merge_system_messages(msgs) == msgs


class TestMidConversationSystemStaysInPlace:
    def test_nudge_folds_into_the_following_user_turn(self):
        out = _merge_system_messages(
            [
                Message(role="system", content="base prompt"),
                Message(role="user", content="turn 0"),
                Message(role="assistant", content="ack"),
                Message(role="system", content=NUDGE),
                Message(role="user", content="turn 1"),
            ]
        )
        # Leading block is untouched — this is what keeps the prefix stable.
        assert roles(out) == ["system", "user", "assistant", "user"]
        assert text(out[0]) == "base prompt"
        assert NUDGE not in text(out[0])

        # ...and the nudge landed on the NEW turn, at its true position.
        last = text(out[-1])
        assert NUDGE in last
        assert "<system-reminder>" in last
        assert last.endswith("turn 1")

    def test_earlier_turns_are_byte_identical(self):
        """The property the cache actually depends on."""
        base = [
            Message(role="system", content="base prompt"),
            Message(role="user", content="turn 0"),
            Message(role="assistant", content="ack"),
        ]
        without = _merge_system_messages(base + [Message(role="user", content="t1")])
        with_nudge = _merge_system_messages(
            base
            + [
                Message(role="system", content=NUDGE),
                Message(role="user", content="t1"),
            ]
        )
        assert [text(m) for m in without[:-1]] == [text(m) for m in with_nudge[:-1]]

    def test_several_nudges_before_one_user_turn(self):
        out = _merge_system_messages(
            [
                Message(role="system", content="base"),
                Message(role="user", content="t0"),
                Message(role="assistant", content="ack"),
                Message(role="system", content=NUDGE),
                Message(role="system", content=DATE),
                Message(role="user", content="t1"),
            ]
        )
        assert roles(out) == ["system", "user", "assistant", "user"]
        assert text(out[0]) == "base"
        last = text(out[-1])
        assert NUDGE in last and DATE in last
        assert last.count("<system-reminder>") == 2

    def test_nudge_with_no_following_user_turn_falls_back_to_hoist(self):
        """Never drop an instruction on the floor."""
        out = _merge_system_messages(
            [
                Message(role="system", content="base"),
                Message(role="user", content="t0"),
                Message(role="system", content=NUDGE),
            ]
        )
        assert roles(out) == ["system", "user"]
        assert NUDGE in text(out[0])

    def test_nudge_before_an_assistant_turn_is_not_folded_into_it(self):
        """Only USER turns absorb a reminder; assistant turns are model output."""
        out = _merge_system_messages(
            [
                Message(role="system", content="base"),
                Message(role="user", content="t0"),
                Message(role="system", content=NUDGE),
                Message(role="assistant", content="ack"),
                Message(role="user", content="t1"),
            ]
        )
        assert roles(out) == ["system", "user", "assistant", "user"]
        assert text(out[2]) == "ack"
        assert NUDGE in text(out[-1])

    def test_empty_mid_system_contributes_nothing(self):
        out = _merge_system_messages(
            [
                Message(role="system", content="base"),
                Message(role="user", content="t0"),
                Message(role="system", content=""),
                Message(role="user", content="t1"),
            ]
        )
        assert roles(out) == ["system", "user", "user"]
        assert text(out[-1]) == "t1"
        assert "<system-reminder>" not in text(out[-1])


class TestTemplateContractPreserved:
    """At most ONE system message, at index 0 — the reason this
    function exists (Qwen / Llama / Gemma templates raise otherwise)."""

    def test_no_system_message_survives_past_index_0(self):
        out = _merge_system_messages(
            [
                Message(role="system", content="base"),
                Message(role="user", content="t0"),
                Message(role="system", content=NUDGE),
                Message(role="assistant", content="ack"),
                Message(role="system", content=DATE),
                Message(role="user", content="t1"),
            ]
        )
        assert all(m.role != "system" for m in out[1:])
        assert out[0].role == "system"
