# Wan 2.2 ComfyUI — our own image. Current ComfyUI + Wan node stack baked in.
# Single Python env (the base conda python ComfyUI runs on) => no venv mismatch.
FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

# Pin ComfyUI here for reproducibility; bump when you choose to.
ARG COMFYUI_REF=master

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    COMFY_DIR=/workspace/ComfyUI \
    BAKED_COMFY=/opt/ComfyUI

# System deps: git (clones), aria2 (parallel model downloads), ffmpeg+libgl (video/image),
# openssh-server (so we can actually SSH in to debug), rsync (first-boot copy).
RUN apt-get update && apt-get install -y --no-install-recommends \
        git aria2 ffmpeg libgl1 libglib2.0-0 wget curl ca-certificates openssh-server rsync && \
    rm -rf /var/lib/apt/lists/*

# --- ComfyUI baked to /opt (safe from the /workspace volume mount) ---
RUN git clone https://github.com/comfyanonymous/ComfyUI.git "$BAKED_COMFY" && \
    cd "$BAKED_COMFY" && git checkout "$COMFYUI_REF" && \
    python -m pip install -r requirements.txt

# --- Custom nodes (baked) ---
WORKDIR ${BAKED_COMFY}/custom_nodes
RUN git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager.git && \
    git clone --depth 1 https://github.com/kijai/ComfyUI-WanVideoWrapper.git && \
    git clone --depth 1 https://github.com/kijai/ComfyUI-KJNodes.git && \
    git clone --depth 1 https://github.com/yolain/ComfyUI-Easy-Use.git && \
    git clone --depth 1 https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git && \
    git clone --depth 1 https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git

# --- Node Python deps (same interpreter ComfyUI uses) ---
RUN set -e; \
    for d in */ ; do \
        if [ -f "${d}requirements.txt" ]; then \
            echo "[deps] $d"; python -m pip install -r "${d}requirements.txt" || echo "WARN deps failed: $d"; \
        fi; \
    done; \
    if [ -f ComfyUI-Frame-Interpolation/requirements-no-cupy.txt ]; then \
        python -m pip install -r ComfyUI-Frame-Interpolation/requirements-no-cupy.txt || true; \
    fi; \
    python -m pip install sageattention || echo "WARN sageattention skipped (use attention_mode=sdpa)"

EXPOSE 8188 22
WORKDIR ${BAKED_COMFY}
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
