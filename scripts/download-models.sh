#!/usr/bin/env bash
# 下载生图权重（清单来自 config/models.json，可重复执行；断了重跑会从分片断点续传）
#
#   ./scripts/download-models.sh                    # 全部（按目录里的 download 字段）
#   MODEL=real ./scripts/download-models.sh         # 只下某个 id
#   MODEL=real,anime ./scripts/download-models.sh   # 多个 id
#   HF_ENDPOINT=https://huggingface.co ./scripts/download-models.sh
#
# 单连接在 HF 上只有 1.5 MB/s 左右，这里用分片并行下载（scripts/dl-parallel.py），
# 实测能到 11~20 MB/s，7 GB 约 6~10 分钟。
set -euo pipefail

MODEL="${MODEL:-all}"
CONNS="${CONNS:-8}"
HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PLAN="$(python3 "$ROOT/scripts/catalog.py" download-plan "$MODEL")" || {
  echo "config/models.json 里没有匹配 $MODEL 的可下载条目" >&2
  exit 1
}

echo "下载选择: $MODEL"
echo "下载源  : $HF_ENDPOINT"
echo

while IFS='|' read -r rel repo path want; do
  [[ -z "$rel" ]] && continue
  out="$ROOT/models/$rel"
  url="$HF_ENDPOINT/$repo/resolve/main/$path"
  if [[ -f "$out" ]] && [[ "$(stat -c%s "$out")" == "$want" ]]; then
    echo "  [跳过] $rel 已完整"
    continue
  fi
  python3 "$ROOT/scripts/dl-parallel.py" "$url" "$out" "$want" "$CONNS"
done <<< "$PLAN"

echo
echo "权重就绪："
find models -maxdepth 2 -type f -printf '%10s  %p\n' 2>/dev/null | sort -k2
echo
echo "切换生效的模型：./scripts/use-model.sh list"
