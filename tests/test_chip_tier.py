# SPDX-License-Identifier: Apache-2.0
"""Hermetic tests for the structured chip-tier classifier (absorb #5).

Table-driven over the real chip strings the engine's existing detectors emit
(``machdep.cpu.brand_string`` form + ``HARDWARE_PROFILES`` keys) plus the
fallback / non-Apple shapes. Pure string parsing — no system calls.
"""

from __future__ import annotations

import pytest

from vllm_mlx.chip_tier import (
    VARIANT_BASE,
    VARIANT_MAX,
    VARIANT_PRO,
    VARIANT_ULTRA,
    VARIANT_UNKNOWN,
    ChipTier,
    classify_chip_tier,
    detect_chip_tier,
)

# (raw, is_apple, generation, variant, is_m3_or_newer)
_CASES = [
    # machdep.cpu.brand_string form
    ("Apple M1", True, 1, VARIANT_BASE, False),
    ("Apple M2 Pro", True, 2, VARIANT_PRO, False),
    ("Apple M2 Max", True, 2, VARIANT_MAX, False),
    ("Apple M2 Ultra", True, 2, VARIANT_ULTRA, False),
    ("Apple M3", True, 3, VARIANT_BASE, True),
    ("Apple M3 Pro", True, 3, VARIANT_PRO, True),
    ("Apple M3 Max", True, 3, VARIANT_MAX, True),
    ("Apple M3 Ultra", True, 3, VARIANT_ULTRA, True),
    ("Apple M4", True, 4, VARIANT_BASE, True),
    ("Apple M4 Max", True, 4, VARIANT_MAX, True),
    # HARDWARE_PROFILES key form (no "Apple" prefix)
    ("M1", True, 1, VARIANT_BASE, False),
    ("M1 Ultra", True, 1, VARIANT_ULTRA, False),
    ("M4 Pro", True, 4, VARIANT_PRO, True),
    # Case-insensitivity
    ("apple m3 ultra", True, 3, VARIANT_ULTRA, True),
    ("APPLE M2 PRO", True, 2, VARIANT_PRO, False),
    # Future generation — must not crash or clamp
    ("Apple M13 Ultra", True, 13, VARIANT_ULTRA, True),
    # Fallback / non-Apple / degenerate
    ("Apple Silicon", False, None, VARIANT_UNKNOWN, False),
    ("Unknown", False, None, VARIANT_UNKNOWN, False),
    ("", False, None, VARIANT_UNKNOWN, False),
    (None, False, None, VARIANT_UNKNOWN, False),
    ("Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz", False, None, VARIANT_UNKNOWN, False),
    # Incidental M<n> in an unrelated (non-Apple, not-leading) string -> unknown.
    ("BMW M3", False, None, VARIANT_UNKNOWN, False),
    ("BMW M3 Competition", False, None, VARIANT_UNKNOWN, False),
]


@pytest.mark.parametrize(
    "raw,is_apple,generation,variant,is_m3", _CASES, ids=[repr(c[0]) for c in _CASES]
)
def test_classify_chip_tier_table(raw, is_apple, generation, variant, is_m3):
    tier = classify_chip_tier(raw)
    assert isinstance(tier, ChipTier)
    assert tier.raw == (raw or "")
    assert tier.is_apple_silicon is is_apple
    assert tier.generation == generation
    assert tier.variant == variant
    assert tier.is_m3_or_newer is is_m3


def test_substring_variant_does_not_false_trigger():
    """A word merely CONTAINING a variant token must not set the variant."""
    tier = classify_chip_tier("Apple M3 Maximum")
    assert tier.generation == 3
    # "Maximum" is not the exact token "Max" -> stays base, never VARIANT_MAX.
    assert tier.variant == VARIANT_BASE


def test_first_m_token_wins():
    """Only the first M<n> token drives the generation."""
    tier = classify_chip_tier("Apple M3 something M9")
    assert tier.generation == 3


def test_is_m3_or_newer_boundary():
    assert classify_chip_tier("Apple M2 Ultra").is_m3_or_newer is False
    assert classify_chip_tier("Apple M3").is_m3_or_newer is True


def test_unknown_tier_never_raises_and_is_explicit():
    for junk in ["", "   ", "banana", "M", "MX", "Mmm", "3M company"]:
        tier = classify_chip_tier(junk)
        assert tier.is_apple_silicon is False
        assert tier.generation is None
        assert tier.variant == VARIANT_UNKNOWN


def test_detect_chip_tier_returns_valid_tier():
    """detect_chip_tier must return a ChipTier on any host without raising."""
    tier = detect_chip_tier()
    assert isinstance(tier, ChipTier)
    # Consistency invariants regardless of the host chip.
    if tier.is_apple_silicon:
        assert isinstance(tier.generation, int)
        assert tier.is_m3_or_newer == (tier.generation >= 3)
    else:
        assert tier.generation is None
        assert tier.variant == VARIANT_UNKNOWN
