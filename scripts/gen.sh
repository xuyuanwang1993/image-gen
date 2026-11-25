#!/usr/bin/env bash
# 命令行出图：结果直接存到 ./outputs/
#
#   ./scripts/gen.sh "photorealistic portrait of a woman, 85mm lens"
#   ./scripts/gen.sh "prompt" 832 1216 28 2          # 宽 高 步数 张数
#   NEG="lowres, blurry" CFG=7 SAMPLER=euler ./scripts/gen.sh "prompt"
#   SEED=42 ./scripts/gen.sh "prompt"                 # 固定随机种子
#   API=http://127.0.0.1:18080/api ./scripts/gen.sh "prompt"   # 走网页端口
#
# 默认的步数 / CFG / 采样器 / 负面提示词都跟随当前生效的模型（.env + web/model.json）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 读取 .env 拿端口和采样参数（compose 也用这个文件）
if [[ -f "$ROOT/.env" ]]; then set -a; . "$ROOT/.env"; set +a; fi

PROMPT="${1:?用法: gen.sh \"提示词\" [宽] [高] [步数] [张数]}"
WIDTH="${2:-1024}"
HEIGHT="${3:-1024}"
STEPS="${4:-${SD_STEPS:-28}}"
COUNT="${5:-1}"
API="${API:-http://127.0.0.1:${SDCPP_PORT:-18234}}"
SEED="${SEED:--1}"
CFG="${CFG:-${SD_CFG_SCALE:-6}}"
SAMPLER="${SAMPLER:-${SD_SAMPLER:-euler_a}}"

# 负面提示词默认取 model.json 里当前风格那一套（use-model.sh 生成的）
if [[ -z "${NEG:-}" && -f "$ROOT/web/model.json" ]]; then
  NEG="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("negative",""))' "$ROOT/web/model.json" 2>/dev/null || true)"
fi
NEG="${NEG:-}"
PREFIX="$([[ "${SD_STYLE:-real}" == anime ]] && echo anime || echo sdxl)"

mkdir -p "$ROOT/outputs"
STAMP="$(date +%Y%m%d_%H%M%S)"
RESP="$(mktemp)"
trap 'rm -f "$RESP"' EXIT

echo "请求 $API （${WIDTH}x${HEIGHT}, ${STEPS} 步, CFG ${CFG}, ${SAMPLER}, ${COUNT} 张, seed=${SEED}）…"
t0=$(date +%s)

# 注意：用 python3 -c 而不是 heredoc，否则 heredoc 会占掉管道/重定向的 stdin
BODY="$(python3 -c '
import json, sys
prompt, neg, w, h, steps, n, seed, cfg, sampler = sys.argv[1:10]
print(json.dumps({
    "prompt": prompt, "negative_prompt": neg,
    "width": int(w), "height": int(h), "steps": int(steps),
    "batch_size": int(n), "seed": int(seed),
    "cfg_scale": float(cfg), "sampler_name": sampler,
}))
' "$PROMPT" "$NEG" "$WIDTH" "$HEIGHT" "$STEPS" "$COUNT" "$SEED" "$CFG" "$SAMPLER")"

if ! curl -fsS --max-time 1800 -o "$RESP" "$API/sdapi/v1/txt2img" \
        -H 'Content-Type: application/json' -d "$BODY"; then
  echo "请求失败（HTTP 非 2xx）。服务端返回：" >&2
  head -c 500 "$RESP" >&2; echo >&2
  exit 1
fi

python3 -c '
import base64, json, sys
resp, outdir, stamp, prefix = sys.argv[1:5]
d = json.load(open(resp))
imgs = d.get("images") or []
if not imgs:
    sys.exit("服务没有返回图片: " + json.dumps(d)[:300])
info = json.loads(d.get("info") or "{}")
seeds = info.get("all_seeds") or [info.get("seed", "?")]
for i, b64 in enumerate(imgs):
    seed = seeds[i] if i < len(seeds) else "?"
    path = f"{outdir}/{prefix}_{stamp}_{i}_seed{seed}.png"
    open(path, "wb").write(base64.b64decode(b64))
    print("  ->", path)
' "$RESP" "$ROOT/outputs" "$STAMP" "$PREFIX"

echo "耗时 $(( $(date +%s) - t0 ))s"
