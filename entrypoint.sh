#!/usr/bin/env bash
# Runtime: restore ComfyUI from baked copy, enable SSH, download models, start ComfyUI.
set -e
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
BAKED_COMFY="${BAKED_COMFY:-/opt/ComfyUI}"
MODEL_SCRIPT_URL="${MODEL_SCRIPT_URL:-https://raw.githubusercontent.com/gitmarsh/comfyui-runpod-scripts/main/download_wan22_remix.sh}"

# --- SSH (debug access) ---
if [ -n "${PUBLIC_KEY:-}" ]; then
    mkdir -p /root/.ssh
    echo "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
    chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
    mkdir -p /run/sshd
    /usr/sbin/sshd || echo "WARN: sshd failed to start"
fi

# --- First-boot restore: /workspace is a fresh volume that wipes the image layer.
#     Copy ComfyUI code from /opt/ComfyUI (safe, outside the volume mount) into
#     /workspace/ComfyUI, skipping any files already present (models, custom_nodes). ---
if [ ! -f "$COMFY_DIR/main.py" ]; then
    echo "[entrypoint] First boot: restoring ComfyUI from $BAKED_COMFY -> $COMFY_DIR"
    mkdir -p "$COMFY_DIR"
    rsync -a --ignore-existing "$BAKED_COMFY/" "$COMFY_DIR/"
    echo "[entrypoint] ComfyUI restored."
fi

# --- Models (nodes are already baked into the image; SKIP_NODES=1) ---
# download() in the script skips files that already exist, so on a persistent
# volume this is a fast no-op after the first boot.
if [ "${SKIP_MODELS:-0}" != "1" ]; then
    echo "[entrypoint] Fetching model-download script..."
    if curl -fsSL "$MODEL_SCRIPT_URL" -o /tmp/dl.sh; then
        SKIP_NODES=1 COMFY_DIR="$COMFY_DIR" bash /tmp/dl.sh || echo "WARN: model download had issues"
    else
        echo "WARN: could not fetch $MODEL_SCRIPT_URL — starting without models"
    fi
fi

# --- ComfyUI ---
echo "[entrypoint] Starting ComfyUI on :8188"
cd "$COMFY_DIR"
exec python main.py --listen 0.0.0.0 --port 8188 ${COMFY_EXTRA_ARGS:-}
