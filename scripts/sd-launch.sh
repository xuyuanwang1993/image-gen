#!/usr/bin/env bash
# 容器入口：按 .env 拼出 /sd-server 的启动参数。
#
# 只跑「单文件 checkpoint」这一种架构（SDXL / SD1.5 / Pony 等 A1111 格式的 .safetensors）：
#   -m /models/<SD_MODEL_DIR>/<SD_MODEL_FILE>
# 单文件里已烘进 VAE 和两个 text encoder；需要覆盖时给 SD_CKPT_VAE。
set -euo pipefail

MODEL_DIR="${SD_MODEL_DIR:-checkpoints}"
MODEL_FILE="${SD_MODEL_FILE:?SD_MODEL_FILE 未设置}"

args=(
  -m "/models/${MODEL_DIR}/${MODEL_FILE}"
  --listen-ip 0.0.0.0
  --listen-port 1234
  --cfg-scale "${SD_CFG_SCALE:-6.0}"
  --sampling-method "${SD_SAMPLER:-euler_a}"
  --steps "${SD_STEPS:-28}"
  --width "${SD_WIDTH:-1024}"
  --height "${SD_HEIGHT:-1024}"
  --seed "${SD_SEED:--1}"
  --lora-model-dir /models/loras
)

# CLIP skip（Illustrious / NoobAI 这类动漫底模一般用 2；写实底模用 1 或留空）
if [[ -n "${SD_CLIP_SKIP:-}" ]]; then
  args+=(--clip-skip "${SD_CLIP_SKIP}")
fi

# 显式指定 VAE（可选）。某些 SDXL 微调自带的 VAE 有瑕疵，这时换一个修好的：
#   SD_CKPT_VAE=sdxl-vae-fp16-fix.safetensors
if [[ -n "${SD_CKPT_VAE:-}" ]]; then
  args+=(--vae "/models/${MODEL_DIR}/${SD_CKPT_VAE}")
fi

# 额外参数（空格分隔），例如 SDCPP_EXTRA_ARGS="--vae-tiling --diffusion-fa"
if [[ -n "${SDCPP_EXTRA_ARGS:-}" ]]; then
  read -r -a extra <<< "${SDCPP_EXTRA_ARGS}"
  args+=("${extra[@]}")
fi

echo "[sd-launch] model=${MODEL_FILE} steps=${SD_STEPS:-28} cfg=${SD_CFG_SCALE:-6.0} sampler=${SD_SAMPLER:-euler_a} size=${SD_WIDTH:-1024}x${SD_HEIGHT:-1024} clip_skip=${SD_CLIP_SKIP:-default}"
exec /sd-server "${args[@]}"
