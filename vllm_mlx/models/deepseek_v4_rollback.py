"""Exact short-window rollback for DeepSeek V4 speculative verification.

The target cache is advanced by ``[confirmed, draft...]`` in one verify
forward.  A rejected suffix must be removed without replaying the 304B
backbone.  Rotating caches need an undo record after rotation has started;
pooling caches implement the analogous record in ``deepseek_v4_cache``.
"""

from __future__ import annotations

import copy
import threading
from contextlib import contextmanager

import mlx.core as mx

_STATE = threading.local()


def is_armed() -> bool:
    return bool(getattr(_STATE, "armed", False))


@contextmanager
def armed():
    previous = is_armed()
    _STATE.armed = True
    try:
        yield
    finally:
        _STATE.armed = previous


def install_rotating_undo() -> None:
    """Attach a one-update undo log to mlx-lm's rotating cache once."""
    from mlx_lm.models.cache import BatchRotatingKVCache, RotatingKVCache

    def patch(cls, fields):
        if getattr(cls, "_rapid_dspark_undo", False):
            return
        original_update = cls.update_and_fetch
        original_is_trimmable = cls.is_trimmable
        original_trim = cls.trim

        def update_and_fetch(self, keys, values):
            steps = int(keys.shape[2])
            if is_armed() and 1 <= steps <= 8:
                existing = self._rapid_undo
                if steps == 1 and existing is not None:
                    snapshot, old_keys, old_values = existing
                    self._rapid_undo = (
                        snapshot,
                        mx.concatenate([old_keys, keys], axis=2),
                        mx.concatenate([old_values, values], axis=2),
                    )
                else:
                    snapshot = {}
                    for name in fields:
                        value = getattr(self, name)
                        if isinstance(value, mx.array):
                            value = value + 0
                        elif isinstance(value, (dict, list, set, tuple)):
                            value = copy.deepcopy(value)
                        snapshot[name] = value
                    self._rapid_undo = (snapshot, keys, values)
            else:
                self._rapid_undo = None
            return original_update(self, keys, values)

        def is_trimmable(self):
            return original_is_trimmable(self) or self._rapid_undo is not None

        def trim(self, n):
            if original_is_trimmable(self):
                self._rapid_undo = None
                return original_trim(self, n)
            undo = self._rapid_undo
            self._rapid_undo = None
            if undo is None:
                return 0
            snapshot, keys, values = undo
            keep = int(keys.shape[2]) - int(n)
            if keep < 0:
                return 0
            for name, value in snapshot.items():
                setattr(self, name, value)
            if keep:
                original_update(self, keys[..., :keep, :], values[..., :keep, :])
            return int(n)

        cls.update_and_fetch = update_and_fetch
        cls.is_trimmable = is_trimmable
        cls.trim = trim
        cls._rapid_undo = None
        cls._rapid_dspark_undo = True

    patch(RotatingKVCache, ("keys", "values", "offset", "_idx"))
    patch(
        BatchRotatingKVCache,
        ("keys", "values", "offset", "left_padding", "_idx", "_offset", "rotated"),
    )


def can_trim(cache, n: int) -> bool:
    children = getattr(cache, "caches", None)
    if children is not None:
        return all(can_trim(child, n) for child in children)
    can_undo = getattr(cache, "_can_undo", None)
    if callable(can_undo) and can_undo(n):
        return True
    check = getattr(cache, "is_trimmable", None)
    return bool(callable(check) and check())


def trim_all(caches, n: int) -> bool:
    if n <= 0:
        return True
    if not all(can_trim(cache, n) for cache in caches):
        return False
    return all(cache.trim(n) == n for cache in caches)
