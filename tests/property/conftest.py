# SPDX-License-Identifier: Apache-2.0
"""Hypothesis configuration for the property-based suite.

Registers and loads a profile tuned for MLX. The first call to a given
MLX op JIT-compiles a Metal kernel — a few hundred ms of one-off cost —
so a per-example wall-clock ``deadline`` would flake on that cold start
alone (and only on the first example). Disabling the deadline is the
right call here: these properties assert *exact* mathematical invariants,
not latency, so a slow example is never a failure signal. ``max_examples``
is kept modest so the whole hermetic suite stays well under a couple of
seconds while still sweeping a wide input space.

pytest imports this dir-level conftest before collecting the property
test modules, so ``load_profile`` is in effect for every ``@given`` here
without any per-test decoration. No other test in the repo uses
Hypothesis, so loading the profile globally is inert elsewhere.
"""

from hypothesis import HealthCheck, settings

PROFILE_NAME = "rapid_mlx_property"

settings.register_profile(
    PROFILE_NAME,
    max_examples=100,
    deadline=None,
    # ``too_slow`` fires on the MLX kernel cold-start described above;
    # ``data_too_large`` can fire on the wide seed/param draws in
    # ``mlx_kv_tensors`` — neither is a correctness signal for these
    # whole-tensor invariants.
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.data_too_large],
)
settings.load_profile(PROFILE_NAME)
