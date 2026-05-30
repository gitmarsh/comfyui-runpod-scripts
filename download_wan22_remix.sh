#!/usr/bin/env bash
# Set up the Wan2.2 Remix NSFW i2v workflow in a ComfyUI install on RunPod:
# installs the required custom nodes AND downloads the model weights, in one run.
# Source: https://www.nextdiffusion.ai/tutorials/creating-uncensored-videos-with-wan22-remix-in-comfyui-i2v
#
# ============================================================================
# CUSTOM NODES INSTALLED (into $COMFY_DIR/custom_nodes)
# ----------------------------------------------------------------------------
#   ComfyUI-WanVideoWrapper       kijai          Wan video sampler / wrapper
#   ComfyUI-Custom-Scripts        pythongosssss  UI / quality-of-life nodes
#   ComfyUI-Easy-Use              yolain         workflow convenience nodes
#   ComfyUI-Frame-Interpolation   Fannovel16     RIFE VFI (uses rife47.pth below)
#
# ============================================================================
# WORKFLOW SETTINGS (set these in the ComfyUI graph, not in this script)
# ----------------------------------------------------------------------------
#   VAE                       wan_2.1_vae.safetensors                  REQUIRED
#   UNET High Lighting        Wan2.2_Remix_NSFW_i2v_14b_high_..._v2.0  REQUIRED
#   UNET Low  Lighting        Wan2.2_Remix_NSFW_i2v_14b_low_..._v2.0   REQUIRED
#   CLIP / Text Encoder       nsfw_wan_umt5-xxl_fp8_scaled             REQUIRED
#   Lightning LoRAs           HIGH + LOW fp16                          OPTIONAL
#                             -> speeds up rendering, slight quality drop
#                             -> if enabled: Steps=4, Split_step=2
#
#   Steps                     8        (4 if Lightning LoRAs enabled)
#   Split_step                4        (2 if Lightning LoRAs enabled)
#   Resolution                720      short side; long side scales proportionally
#   Length (frames)           65       4s=65, 5s=81, 6s=97, 7s=113, 8s=129
#   FPS                       32       higher = smoother / faster playback
#   Frame Interpolation       rife47.pth   OPTIONAL (RIFE VFI, smoother motion)
# ============================================================================
#
# Usage:
#   chmod +x download_wan22_remix.sh
#   ./download_wan22_remix.sh                       # nodes + required + Lightning + RIFE
#   COMFY_DIR=/workspace/ComfyUI ./download_wan22_remix.sh   # override the ComfyUI root
#   SKIP_NODES=1 ./download_wan22_remix.sh          # skip custom-node install, models only
#   SKIP_OPTIONAL=1 ./download_wan22_remix.sh       # skip Lightning LoRAs AND RIFE
#   SKIP_RIFE=1 ./download_wan22_remix.sh           # keep Lightning, skip RIFE only
#   SKIP_SAGEATTN=1 ./download_wan22_remix.sh       # don't install sageattention
#   UPDATE=1 ./download_wan22_remix.sh              # git pull custom nodes that already exist
#   USE_CUPY=1 ./download_wan22_remix.sh            # Frame-Interpolation with cupy acceleration
#   PYTHON_BIN=/path/to/python ./download_wan22_remix.sh
#   HF_TOKEN=hf_xxx ./download_wan22_remix.sh       # if a repo ever gates downloads

set -euo pipefail

# Auto-detect the ComfyUI root unless COMFY_DIR is set explicitly.
# Handles AI-Dock (/workspace/ComfyUI or /opt/ComfyUI) and plain installs.
if [ -z "${COMFY_DIR:-}" ]; then
    for _c in /workspace/ComfyUI /opt/ComfyUI /workspace/runpod-slim/ComfyUI; do
        if [ -f "$_c/main.py" ]; then COMFY_DIR="$_c"; break; fi
    done
    if [ -z "${COMFY_DIR:-}" ]; then
        _found="$(find /workspace /opt -maxdepth 3 -name main.py -path '*ComfyUI*' 2>/dev/null | head -n1 || true)"
        [ -n "$_found" ] && COMFY_DIR="$(dirname "$_found")"
    fi
    COMFY_DIR="${COMFY_DIR:-/workspace/runpod-slim/ComfyUI}"
fi
SKIP_NODES="${SKIP_NODES:-0}"
SKIP_OPTIONAL="${SKIP_OPTIONAL:-0}"
SKIP_RIFE="${SKIP_RIFE:-0}"
SKIP_SAGEATTN="${SKIP_SAGEATTN:-0}"
UPDATE="${UPDATE:-0}"
USE_CUPY="${USE_CUPY:-0}"
HF_TOKEN="${HF_TOKEN:-}"

NODES_DIR="$COMFY_DIR/custom_nodes"
DIFFUSION_DIR="$COMFY_DIR/models/diffusion_models"
TEXT_ENC_DIR="$COMFY_DIR/models/text_encoders"
VAE_DIR="$COMFY_DIR/models/vae"
LORA_DIR="$COMFY_DIR/models/loras"
# ComfyUI-Frame-Interpolation (Fannovel16) auto-resolves models from this path:
RIFE_DIR="$COMFY_DIR/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife"

mkdir -p "$DIFFUSION_DIR" "$TEXT_ENC_DIR" "$VAE_DIR" "$LORA_DIR" "$NODES_DIR"

# Pick the Python that ComfyUI runs on, so node deps land in the right environment.
if [ -n "${PYTHON_BIN:-}" ]; then
    :
elif [ -n "${COMFYUI_VENV_PYTHON:-}" ] && [ -x "${COMFYUI_VENV_PYTHON}" ]; then
    PYTHON_BIN="$COMFYUI_VENV_PYTHON"                          # AI-Dock exports this
elif [ -x /opt/environments/python/comfyui/bin/python ]; then
    PYTHON_BIN="/opt/environments/python/comfyui/bin/python"   # AI-Dock comfyui venv
elif [ -x /opt/micromamba/envs/comfyui/bin/python ]; then
    PYTHON_BIN="/opt/micromamba/envs/comfyui/bin/python"      # AI-Dock (mamba variant)
elif [ -x "$COMFY_DIR/venv/bin/python" ]; then
    PYTHON_BIN="$COMFY_DIR/venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
else
    PYTHON_BIN="python"
fi

# Pick downloader: prefer aria2c (parallel, resumable), fall back to wget then curl.
if command -v aria2c >/dev/null 2>&1; then
    DL="aria2c"
elif command -v wget >/dev/null 2>&1; then
    DL="wget"
else
    DL="curl"
fi
echo "[*] Using downloader: $DL"
echo "[*] ComfyUI dir:      $COMFY_DIR"
echo "[*] Python:           $PYTHON_BIN"

auth_header=()
if [ -n "$HF_TOKEN" ]; then
    auth_header=(--header "Authorization: Bearer $HF_TOKEN")
fi

# ---------------------------------------------------------------------------
# Custom-node helpers
# ---------------------------------------------------------------------------
pip_install() {
    "$PYTHON_BIN" -m pip install --no-input "$@"
}

# Clone a node repo (or git pull it when UPDATE=1). Prints the node path on stdout.
clone_node() {
    local url="$1" name dest
    name="$(basename "$url" .git)"
    dest="$NODES_DIR/$name"

    if [ -d "$dest/.git" ]; then
        if [ "$UPDATE" = "1" ]; then
            echo "[~] Updating $name" >&2
            ( cd "$dest" && git pull --ff-only ) >&2
        else
            echo "[=] Skipping (exists): $name" >&2
        fi
    else
        echo "[+] Cloning $name" >&2
        git clone --depth 1 "$url" "$dest" >&2
    fi
    echo "$dest"
}

# ---------------------------------------------------------------------------
# Download helper
# ---------------------------------------------------------------------------
download() {
    local url="$1" dest_dir="$2" filename
    filename="$(basename "$url")"
    local out="$dest_dir/$filename"

    if [ -s "$out" ]; then
        echo "[=] Skipping (exists): $out"
        return 0
    fi

    echo "[+] $filename -> $dest_dir"
    case "$DL" in
        aria2c)
            aria2c -x 16 -s 16 -k 1M --file-allocation=none --console-log-level=warn \
                "${auth_header[@]}" -d "$dest_dir" -o "$filename" "$url"
            ;;
        wget)
            local hdr=()
            [ -n "$HF_TOKEN" ] && hdr=(--header="Authorization: Bearer $HF_TOKEN")
            wget --show-progress -q "${hdr[@]}" -O "$out.part" "$url" && mv "$out.part" "$out"
            ;;
        curl)
            local hdr=()
            [ -n "$HF_TOKEN" ] && hdr=(-H "Authorization: Bearer $HF_TOKEN")
            curl -fL --progress-bar "${hdr[@]}" -o "$out.part" "$url" && mv "$out.part" "$out"
            ;;
    esac
}

# ===========================================================================
# 1) Custom nodes
# ===========================================================================
if [ "$SKIP_NODES" != "1" ]; then
    echo
    echo "[*] Installing custom nodes into $NODES_DIR"

    d="$(clone_node https://github.com/kijai/ComfyUI-WanVideoWrapper.git)"
    [ -f "$d/requirements.txt" ] && pip_install -r "$d/requirements.txt"

    # SageAttention: optional speed-up WanVideoWrapper uses when a node's
    # attention_mode is set to sageattn. Non-fatal: if it won't install,
    # set attention_mode=sdpa on the WanVideo Model Loader node instead.
    if [ "$SKIP_SAGEATTN" != "1" ]; then
        pip_install sageattention || echo "[!] sageattention install failed; set WanVideo attention_mode=sdpa in the graph."
    fi

    clone_node https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git >/dev/null

    d="$(clone_node https://github.com/yolain/ComfyUI-Easy-Use.git)"
    [ -f "$d/requirements.txt" ] && pip_install -r "$d/requirements.txt"

    d="$(clone_node https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git)"
    if [ "$USE_CUPY" = "1" ] && [ -f "$d/requirements-with-cupy.txt" ]; then
        pip_install -r "$d/requirements-with-cupy.txt"
    elif [ -f "$d/requirements-no-cupy.txt" ]; then
        pip_install -r "$d/requirements-no-cupy.txt"
    fi
else
    echo "[*] SKIP_NODES=1, skipping custom-node install."
fi

# ===========================================================================
# 2) Required models
# ===========================================================================
# Diffusion models (high + low noise experts)
download "https://huggingface.co/FX-FeiHou/wan2.2-Remix/resolve/main/NSFW/Wan2.2_Remix_NSFW_i2v_14b_high_lighting_v2.0.safetensors" "$DIFFUSION_DIR"
download "https://huggingface.co/FX-FeiHou/wan2.2-Remix/resolve/main/NSFW/Wan2.2_Remix_NSFW_i2v_14b_low_lighting_v2.0.safetensors" "$DIFFUSION_DIR"

# Text encoder (UMT5-XXL bf16 — fp8_scaled variant unsupported by current WanVideoWrapper)
download "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5-xxl-enc-bf16.safetensors" "$TEXT_ENC_DIR"

# VAE
download "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" "$VAE_DIR"

# ===========================================================================
# 3) Optional: Lightning 4-step speed-up LoRAs
# ===========================================================================
if [ "$SKIP_OPTIONAL" != "1" ]; then
    download "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22-Lightning/old/Wan2.2-Lightning_I2V-A14B-4steps-lora_HIGH_fp16.safetensors" "$LORA_DIR"
    download "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22-Lightning/old/Wan2.2-Lightning_I2V-A14B-4steps-lora_LOW_fp16.safetensors" "$LORA_DIR"
else
    echo "[*] SKIP_OPTIONAL=1, skipping Lightning LoRAs."
fi

# ===========================================================================
# 4) Optional: RIFE VFI checkpoint for frame interpolation
# ===========================================================================
# Used by the ComfyUI-Frame-Interpolation node (Fannovel16). The node will
# auto-download on first use if missing, but pre-fetching avoids a stall.
if [ "$SKIP_OPTIONAL" != "1" ] && [ "$SKIP_RIFE" != "1" ]; then
    if [ -d "$COMFY_DIR/custom_nodes/ComfyUI-Frame-Interpolation" ]; then
        mkdir -p "$RIFE_DIR"
        download "https://github.com/styler00dollar/VSGAN-tensorrt-docker/releases/download/models/rife47.pth" "$RIFE_DIR"
    else
        echo "[!] ComfyUI-Frame-Interpolation node not installed; skipping rife47.pth."
        echo "    Re-run without SKIP_NODES=1 to install it."
    fi
else
    echo "[*] Skipping RIFE checkpoint."
fi

echo
echo "[✓] Done. ComfyUI set up under $COMFY_DIR"
echo "[*] Restart ComfyUI to load the new custom nodes."
ls -lh "$DIFFUSION_DIR" "$TEXT_ENC_DIR" "$VAE_DIR" "$LORA_DIR" 2>/dev/null || true
[ -d "$RIFE_DIR" ] && ls -lh "$RIFE_DIR" 2>/dev/null || true
