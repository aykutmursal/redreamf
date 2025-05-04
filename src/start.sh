#!/usr/bin/env bash
set -e

###############################################################################
# 1)   MODELE ÖN-KOŞUL KONTROLÜ
###############################################################################
# Tek desteklenen model → dev_bf16
MODEL_TYPE="${MODEL_TYPE:-dev_bf16}"
MODEL_PATH="/comfyui/models/diffusion_models/redreamfp16.safetensors"

echo "Selected MODEL_TYPE=${MODEL_TYPE}"

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "❌ Model file '$MODEL_PATH' not found! Docker imajına dahil edilmemiş."
  exit 1
fi

###############################################################################
# 2)   BELLEK OPTİMİZASYONU
###############################################################################
TCMALLOC="$(ldconfig -p | grep -Po 'libtcmalloc.so.\d' | head -n 1 || true)"
[[ -n "$TCMALLOC" ]] && export LD_PRELOAD="$TCMALLOC"

###############################################################################
# 3)   COMFYUI + RUNPOD HANDLER BAŞLAT
###############################################################################
python3 /comfyui/main.py --disable-auto-launch --disable-metadata --listen &
echo "✅ ComfyUI running on :8188"

if [[ "$SERVE_API_LOCALLY" == "true" ]]; then
  echo "🔌 Starting RunPod Handler (local API)"
  python3 -u /rp_handler.py --rp_serve_api --rp_api_host=0.0.0.0
else
  python3 -u /rp_handler.py
fi
