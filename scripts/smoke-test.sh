#!/usr/bin/env bash
# 冒烟测试：探活 + 生成一张小图，确认「服务 + GPU + 模型」整链路可用
#
#   ./scripts/smoke-test.sh
#
set -euo pipefail

# 读取仓库根目录的 .env，端口等配置以它为准
_ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
if [[ -f "$_ENV_FILE" ]]; then set -a; . "$_ENV_FILE"; set +a; fi

API="${API:-http://127.0.0.1:${SDCPP_PORT:-18234}}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/outputs/smoke_$(date +%Y%m%d_%H%M%S).png"
mkdir -p "$ROOT/outputs"

echo "==> 1/2 探活 $API/v1/models"
for i in $(seq 1 120); do          # 首次启动要把 10GB 权重读进显存，耐心等
  if curl -fsS --max-time 5 "$API/v1/models" >/dev/null 2>&1; then
    echo "    服务已就绪"
    break
  fi
  [[ $i == 120 ]] && { echo "    ✗ 服务在 10 分钟内没有起来，看日志: docker compose logs -f sd-server" >&2; exit 1; }
  sleep 5
done

echo "==> 2/2 生成测试图（768x768 / 8 步，只为验证链路，不求画质）"
t0=$(date +%s)
curl -fsS --max-time 600 "$API/sdapi/v1/txt2img" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"photorealistic close-up of a red apple on a wooden table, soft window light","negative_prompt":"lowres, blurry, watermark","width":768,"height":768,"steps":8,"seed":42,"cfg_scale":5.0,"sampler_name":"euler_a"}' \
  | python3 -c '
import base64, json, sys
d = json.load(sys.stdin)
imgs = d.get("images") or []
if not imgs:
    sys.exit("服务没有返回图片: " + json.dumps(d)[:400])
open(sys.argv[1], "wb").write(base64.b64decode(imgs[0]))
info = json.loads(d.get("info") or "{}")
print("    seed:", info.get("seed"), " steps:", info.get("steps"), " size:", info.get("width"), "x", info.get("height"))
' "$OUT"
echo "    耗时 $(( $(date +%s) - t0 ))s"
echo "    ✓ 图片已保存: $OUT"
