#!/usr/bin/env bash
# Download Wan2.2 Remix NSFW i2v models into a ComfyUI install on RunPod.
# Source: https://www.nextdiffusion.ai/tutorials/creating-uncensored-videos-with-wan22-remix-in-comfyui-i2v
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
#   ./download_wan22_remix.sh                       # everything: required + Lightning + RIFE
#   COMFY_DIR=/workspace/ComfyUI ./download_wan22_remix.sh
#   SKIP_OPTIONAL=1 ./download_wan22_remix.sh       # skip Lightning LoRAs AND RIFE
#   SKIP_RIFE=1 ./download_wan22_remix.sh           # keep Lightning, skip RIFE only
#   HF_TOKEN=hf_xxx ./download_wan22_remix.sh       # if a repo ever gates downloads

set -euo pipefail

COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
SKIP_OPTIONAL="${SKIP_OPTIONAL:-0}"
SKIP_RIFE="${SKIP_RIFE:-0}"
HF_TOKEN="${HF_TOKEN:-}"

DIFFUSION_DIR="$COMFY_DIR/models/diffusion_models"
TEXT_ENC_DIR="$COMFY_DIR/models/text_encoders"
VAE_DIR="$COMFY_DIR/models/vae"
LORA_DIR="$COMFY_DIR/models/loras"
# ComfyUI-Frame-Interpolation (Fannovel16) auto-resolves models from this path:
RIFE_DIR="$COMFY_DIR/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife"

mkdir -p "$DIFFUSION_DIR" "$TEXT_ENC_DIR" "$VAE_DIR" "$LORA_DIR"

# Pick downloader: prefer aria2c (parallel, resumable), fall back to wget then curl.
if command -v aria2c >/dev/null 2>&1; then
    DL="aria2c"
elif command -v wget >/dev/null 2>&1; then
    DL="wget"
else
    DL="curl"
fi
echo "[*] Using downloader: $DL"
echo "[*] ComfyUI dir: $COMFY_DIR"

auth_header=()
if [ -n "$HF_TOKEN" ]; then
    auth_header=(--header "Authorization: Bearer $HF_TOKEN")
fi

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

# Convert /blob/ HF URLs to /resolve/ for raw file downloads.

# ---- Required ----
# Diffusion models (high + low noise experts)
download "https://huggingface.co/FX-FeiHou/wan2.2-Remix/resolve/main/NSFW/Wan2.2_Remix_NSFW_i2v_14b_high_lighting_v2.0.safetensors" "$DIFFUSION_DIR"
download "https://huggingface.co/FX-FeiHou/wan2.2-Remix/resolve/main/NSFW/Wan2.2_Remix_NSFW_i2v_14b_low_lighting_v2.0.safetensors" "$DIFFUSION_DIR"

# Text encoder (UMT5-XXL fp8)
download "https://huggingface.co/NSFW-API/NSFW-Wan-UMT5-XXL/resolve/main/nsfw_wan_umt5-xxl_fp8_scaled.safetensors" "$TEXT_ENC_DIR"

# VAE
download "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" "$VAE_DIR"

# ---- Optional: Lightning 4-step speed-up LoRAs ----
if [ "$SKIP_OPTIONAL" != "1" ]; then
    download "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22-Lightning/old/Wan2.2-Lightning_I2V-A14B-4steps-lora_HIGH_fp16.safetensors" "$LORA_DIR"
    download "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22-Lightning/old/Wan2.2-Lightning_I2V-A14B-4steps-lora_LOW_fp16.safetensors" "$LORA_DIR"
else
    echo "[*] SKIP_OPTIONAL=1, skipping Lightning LoRAs."
fi

# ---- Optional: RIFE VFI checkpoint for frame interpolation ----
# Used by the ComfyUI-Frame-Interpolation node (Fannovel16). The node will
# auto-download on first use if missing, but pre-fetching avoids a stall.
if [ "$SKIP_OPTIONAL" != "1" ] && [ "$SKIP_RIFE" != "1" ]; then
    if [ -d "$COMFY_DIR/custom_nodes/ComfyUI-Frame-Interpolation" ]; then
        mkdir -p "$RIFE_DIR"
        download "https://github.com/styler00dollar/VSGAN-tensorrt-docker/releases/download/models/rife47.pth" "$RIFE_DIR"
    else
        echo "[!] ComfyUI-Frame-Interpolation node not installed; skipping rife47.pth."
        echo "    Install it via ComfyUI-Manager, then re-run with SKIP_OPTIONAL=0."
    fi
else
    echo "[*] Skipping RIFE checkpoint."
fi

echo
echo "[✓] Done. Files installed under $COMFY_DIR"
ls -lh "$DIFFUSION_DIR" "$TEXT_ENC_DIR" "$VAE_DIR" "$LORA_DIR" 2>/dev/null || true
[ -d "$RIFE_DIR" ] && ls -lh "$RIFE_DIR" 2>/dev/null || true
