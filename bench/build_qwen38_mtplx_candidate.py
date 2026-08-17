#!/usr/bin/env python3
"""Assemble a zero-copy MTPLX experiment view over the mixed Qwen3.8 base.

This does not requantize or rewrite the backbone.  It creates symlinks to the
already-audited mixed-3.5bpw files, adds MTPLX's precision-specific MTP
sidecar, and stamps only the runtime metadata MTPLX needs to load the pair.
The resulting directory is an experiment view, not a publishable artifact;
publishing must materialize the links and record immutable source revisions.
"""

from __future__ import annotations

import argparse
import json
import os
from collections import defaultdict
from pathlib import Path


def _args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--mtplx-reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--promote",
        action="append",
        choices=(
            "linear-out-all",
            "linear-out-last16",
            "last8-mlp",
            "lm-head",
            "embed",
        ),
        default=[],
        help="Copy selected Q8 modules from the MTPLX reference into an overlay",
    )
    parser.add_argument(
        "--materialize-backbone",
        action="store_true",
        help="Rewrite base shards without promoted keys (required by glob loaders)",
    )
    return parser.parse_args()


def _read_json(path: Path) -> dict:
    with path.open() as stream:
        return json.load(stream)


def _write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def _selected_module(key: str, promotions: set[str]) -> str | None:
    suffixes = (".weight", ".scales", ".biases")
    module = next((key.removesuffix(s) for s in suffixes if key.endswith(s)), None)
    if module is None:
        return None
    if "lm-head" in promotions and module == "language_model.lm_head":
        return module
    if "embed" in promotions and module == "language_model.model.embed_tokens":
        return module
    if ".linear_attn.out_proj" in module:
        if "linear-out-all" in promotions:
            return module
        if "linear-out-last16" in promotions:
            layer = int(module.split(".layers.", 1)[1].split(".", 1)[0])
            if layer >= 48:
                return module
    if "last8-mlp" in promotions and ".mlp." in module:
        layer = int(module.split(".layers.", 1)[1].split(".", 1)[0])
        if layer >= 56:
            return module
    return None


def _build_overlay(
    *, base: Path, reference: Path, output: Path, config: dict, promotions: set[str]
) -> set[str]:
    if not promotions:
        return set()
    from safetensors import safe_open
    from safetensors.numpy import save_file

    base_index = _read_json(base / "model.safetensors.index.json")
    ref_index = _read_json(reference / "model.safetensors.index.json")
    ref_quant = _read_json(reference / "config.json")["quantization"]
    selected: dict[str, str] = {}
    modules: set[str] = set()
    for key, shard in ref_index["weight_map"].items():
        module = _selected_module(key, promotions)
        if module is not None and key in base_index["weight_map"]:
            selected[key] = shard
            modules.add(module)
    if not selected:
        raise RuntimeError(f"promotions selected no tensors: {sorted(promotions)}")

    by_shard: dict[str, list[str]] = defaultdict(list)
    for key, shard in selected.items():
        by_shard[shard].append(key)
    tensors = {}
    for shard, keys in by_shard.items():
        with safe_open(reference / shard, framework="numpy") as stream:
            for key in keys:
                tensors[key] = stream.get_tensor(key)
    # mlx-lm discovers checkpoint shards with ``model*.safetensors`` rather
    # than trusting the index alone. Keep the promotion overlay in that glob;
    # a custom name appears in the index but is silently skipped at load time.
    overlay_name = "model-promoted-q8.safetensors"
    save_file(tensors, output / overlay_name)
    for key in selected:
        base_index["weight_map"][key] = overlay_name
    _write_json(output / "model.safetensors.index.json", base_index)

    quant = config["quantization"]
    for module in sorted(modules):
        if module not in ref_quant:
            raise RuntimeError(
                f"reference config has no quantization rule for {module}"
            )
        quant[module] = ref_quant[module]
    return set(selected)


def _materialize_base_shards(
    *, base: Path, output: Path, excluded_keys: set[str]
) -> None:
    import mlx.core as mx

    index = _read_json(base / "model.safetensors.index.json")
    by_shard: dict[str, list[str]] = defaultdict(list)
    for key, shard in index["weight_map"].items():
        if key not in excluded_keys:
            by_shard[shard].append(key)
    for shard, keys in sorted(by_shard.items()):
        source = base / shard
        # ``safe_open(..., framework='mlx')`` currently routes BF16 through
        # NumPy on some safetensors builds and raises "bfloat16 not
        # understood". MLX's native loader preserves BF16 and remains lazy.
        all_tensors = mx.load(str(source))
        tensors = {key: all_tensors[key] for key in keys}
        mx.save_safetensors(str(output / shard), tensors)
        del tensors, all_tensors
        mx.clear_cache()


def main() -> int:
    args = _args()
    base = args.base.resolve(strict=True)
    reference = args.mtplx_reference.resolve(strict=True)
    output = args.output
    if output.exists() and any(output.iterdir()):
        raise SystemExit(f"refusing to overwrite non-empty output: {output}")
    output.mkdir(parents=True, exist_ok=True)

    if args.promote and not args.materialize_backbone:
        raise SystemExit(
            "--promote requires --materialize-backbone for MLX glob loaders"
        )

    for source in base.iterdir():
        if source.name in {"config.json", "model.safetensors.index.json"}:
            continue
        if args.materialize_backbone and source.name.startswith("model-"):
            continue
        (output / source.name).symlink_to(source)

    mtp_source = reference / "mtp.safetensors"
    (output / "mtp.safetensors").symlink_to(mtp_source.resolve(strict=True))

    ref_config = _read_json(reference / "config.json")
    contract = ref_config["mtplx_mtp_contract"]
    config = _read_json(base / "config.json")
    config["mlx_lm_extra_tensors"] = {"mtp_file": "mtp.safetensors"}
    config["mtplx_mtp_contract"] = contract
    promoted_keys = _build_overlay(
        base=base,
        reference=reference,
        output=output,
        config=config,
        promotions=set(args.promote),
    )
    if args.materialize_backbone:
        _materialize_base_shards(
            base=base,
            output=output,
            excluded_keys=promoted_keys,
        )
    _write_json(output / "config.json", config)

    if not (output / "model.safetensors.index.json").exists():
        (output / "model.safetensors.index.json").symlink_to(
            base / "model.safetensors.index.json"
        )

    ref_runtime = _read_json(reference / "mtplx_runtime.json")
    runtime = {
        "arch_id": ref_runtime["arch_id"],
        "artifact_role": "rapid-mlx-experiment-view",
        "base_trunk": os.fspath(base),
        "exactness_baseline": {},
        "mtp_contract": contract,
        "mtp_depth_default": ref_runtime.get("mtp_depth_default", 3),
        "mtp_depth_max": ref_runtime.get("mtp_depth_max", 3),
        "mtp_sidecar": ref_runtime.get("mtp_sidecar", "fp16"),
        "mtplx_version": ref_runtime.get("mtplx_version"),
        "precision_variant": ref_runtime.get("precision_variant", "fp16"),
        "public_model_id": "rapid-qwen38-27b-mixed-3.5bpw-mtplx-experiment",
        "recommended_draft_sampler": ref_runtime.get(
            "recommended_draft_sampler",
            {"temperature": 1.0, "top_p": 0.95, "top_k": 20},
        ),
        "recommended_profile": ref_runtime.get("recommended_profile", "turbo"),
        "verified_on": {
            "status": "unverified",
            "model": "Qwen3.8-27B-mixed-3.5bpw-MTPLX-experiment",
        },
        "rapid_mlx_candidate": {
            "backbone_unchanged": True,
            "base": os.fspath(base),
            "mtp_reference": os.fspath(reference),
            "purpose": "runtime compatibility and speed experiment only",
            "promotions": sorted(set(args.promote)),
        },
    }
    _write_json(output / "mtplx_runtime.json", runtime)
    print(output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
