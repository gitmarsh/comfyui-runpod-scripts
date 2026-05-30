#!/usr/bin/env bash
# Build and push the Wan2.2 ComfyUI image.
#
#   1. docker login                       # one-time, into Docker Hub
#   2. DOCKERHUB_USER=youruser bash build_and_push.sh
#
# Override the ComfyUI version by passing COMFYUI_REF (default: master):
#   COMFYUI_REF=v0.3.40 DOCKERHUB_USER=youruser bash build_and_push.sh
set -euo pipefail

USER_NS="${DOCKERHUB_USER:?Set DOCKERHUB_USER=your_dockerhub_username}"
IMAGE="${IMAGE:-docker.io/${USER_NS}/wan22-comfyui:latest}"
COMFYUI_REF="${COMFYUI_REF:-master}"

cd "$(dirname "$0")"
echo "[build] $IMAGE  (ComfyUI ref: $COMFYUI_REF)"
docker build --build-arg COMFYUI_REF="$COMFYUI_REF" -t "$IMAGE" .

echo "[push] $IMAGE"
docker push "$IMAGE"

echo "[done] $IMAGE"
echo "Now deploy with: IMAGE=\"$IMAGE\" CONFIRM=1 bash /home/marhearn/deploy_runpod.sh"
