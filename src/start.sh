#!/usr/bin/env bash

###############################################################################
# PREREQUISITES — REQUIRED TOKENS
###############################################################################
: "${HF_TOKEN:?⛔  HF_TOKEN unset}"
: "${CIVI_TOKEN:?⛔  CIVI_TOKEN unset}"

###############################################################################
# Signal handling for graceful shutdown
###############################################################################
trap 'kill $(jobs -p) 2>/dev/null' EXIT

###############################################################################
# 0)  RUNPOD VOLUME → COMFYUI
###############################################################################
RUNPOD_VOL="/runpod-volume"
mkdir -p "$RUNPOD_VOL/models"
ln -sf "$RUNPOD_VOL/models" /comfyui/models   # ComfyUI sees all models here

###############################################################################
# 1)  FILES TO DOWNLOAD
###############################################################################

declare -A DOWNLOADS
DOWNLOADS=(
  # RedDream model from Civitai
  ["diffusion_models/redreamfp16.safetensors"]="https://civitai.com/api/download/models/1719149?type=Model&format=SafeTensor&size=pruned&fp=16"
  
  # Text encoders from HuggingFace
  ["text_encoders/clip_l_hidream.safetensors"]="https://huggingface.co/Comfy-Org/HiDream-I1_ComfyUI/resolve/main/split_files/text_encoders/clip_l_hidream.safetensors"
  ["text_encoders/clip_g_hidream.safetensors"]="https://huggingface.co/Comfy-Org/HiDream-I1_ComfyUI/resolve/main/split_files/text_encoders/clip_g_hidream.safetensors"
  ["text_encoders/t5xxl_fp8_e4m3fn_scaled.safetensors"]="https://huggingface.co/Comfy-Org/HiDream-I1_ComfyUI/resolve/main/split_files/text_encoders/t5xxl_fp8_e4m3fn_scaled.safetensors"
  ["text_encoders/llama_3.1_8b_instruct_fp8_scaled.safetensors"]="https://huggingface.co/Comfy-Org/HiDream-I1_ComfyUI/resolve/main/split_files/text_encoders/llama_3.1_8b_instruct_fp8_scaled.safetensors"
  
  # VAE from HuggingFace
  ["vae/ae.safetensors"]="https://huggingface.co/Comfy-Org/HiDream-I1_ComfyUI/resolve/main/split_files/vae/ae.safetensors"
)

###############################################################################
# 2)  DOWNLOAD FUNCTION
###############################################################################
download_all() {
  local missing=false
  for REL_PATH in "${!DOWNLOADS[@]}"; do
    local TARGET="$RUNPOD_VOL/models/$REL_PATH"
    local URL="${DOWNLOADS[$REL_PATH]}"

    if [[ -f "$TARGET" ]]; then
      echo "✅  $REL_PATH already exists"
      continue
    fi

    echo "⏬  Downloading $REL_PATH ..."
    mkdir -p "$(dirname "$TARGET")"

    if [[ "$URL" == *"civitai.com"* ]]; then
      curl -L --fail --retry 5 --retry-delay 5 \
           -H "Authorization: Bearer ${CIVI_TOKEN}" \
           -o "$TARGET" "$URL" || rm -f "$TARGET"
    else
      wget -c --retry-connrefused --waitretry=5 -t 5 \
           --header="Authorization: Bearer ${HF_TOKEN}" \
           -O "$TARGET" "$URL" || rm -f "$TARGET"
    fi

    if [[ -f "$TARGET" ]]; then
      echo "✅  Finished $REL_PATH"
    else
      echo "❌  Failed $REL_PATH"
      missing=true
    fi
  done
  $missing && return 1 || return 0
}

# Run the download process
download_all

# Use libtcmalloc for better memory management
TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
export LD_PRELOAD="${TCMALLOC}"

# Process monitoring function
monitor_processes() {
  local pid=$1
  local name=$2
  while true; do
    if ! kill -0 $pid 2>/dev/null; then
      echo "⚠️ $name process (PID: $pid) has died. Restarting..."
      return 1
    fi
    sleep 10
  done
}

# Serve the API and don't shutdown the container
if [ "$SERVE_API_LOCALLY" == "true" ]; then
    echo "runpod-worker-comfy: Starting ComfyUI"
    python3 /comfyui/main.py --disable-auto-launch --disable-metadata --listen &
    COMFY_PID=$!
    
    echo "runpod-worker-comfy: Starting RunPod Handler"
    python3 -u /rp_handler.py --rp_serve_api --rp_api_host=0.0.0.0 &
    HANDLER_PID=$!
    
    # Monitor processes
    monitor_processes $COMFY_PID "ComfyUI" &
    monitor_processes $HANDLER_PID "RunPod Handler" &
else
    echo "runpod-worker-comfy: Starting ComfyUI"
    python3 /comfyui/main.py --disable-auto-launch --disable-metadata &
    COMFY_PID=$!
    
    echo "runpod-worker-comfy: Starting RunPod Handler"
    python3 -u /rp_handler.py &
    HANDLER_PID=$!
    
    # Monitor processes
    monitor_processes $COMFY_PID "ComfyUI" &
    monitor_processes $HANDLER_PID "RunPod Handler" &
fi

echo "Container is running with ComfyUI (PID: $COMFY_PID) and RunPod Handler (PID: $HANDLER_PID)"

# Keep the container running with a simple wait loop
# This is critical to prevent container restarts
while true; do
    # Check if either process has died
    if ! kill -0 $COMFY_PID 2>/dev/null; then
        echo "⚠️ ComfyUI process died. Restarting..."
        python3 /comfyui/main.py --disable-auto-launch --disable-metadata --listen &
        COMFY_PID=$!
    fi
    
    if ! kill -0 $HANDLER_PID 2>/dev/null; then
        echo "⚠️ RunPod Handler process died. Restarting..."
        if [ "$SERVE_API_LOCALLY" == "true" ]; then
            python3 -u /rp_handler.py --rp_serve_api --rp_api_host=0.0.0.0 &
        else
            python3 -u /rp_handler.py &
        fi
        HANDLER_PID=$!
    fi
    
    sleep 30
done