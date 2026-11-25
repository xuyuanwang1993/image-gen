#!/usr/bin/env bash
# 命令行渲染流程图 / 架构图（走本机 diagram 渲染服务），存成 SVG 或 PNG。
#
#   ./scripts/flowchart.sh docs/flow.mmd              # .mmd/.mermaid -> Mermaid
#   ./scripts/flowchart.sh docs/arch.dot              # .dot/.gv      -> Graphviz
#   ./scripts/flowchart.sh flow.mmd out.png           # 指定输出
#   TYPE=mermaid FMT=png ./scripts/flowchart.sh x.txt out.png
#   DIAGRAM=http://127.0.0.1:18080/diagram ./scripts/flowchart.sh x.mmd # 走网页端口
#
set -euo pipefail

# 读取仓库根目录的 .env，端口等配置以它为准
_ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
if [[ -f "$_ENV_FILE" ]]; then set -a; . "$_ENV_FILE"; set +a; fi

SRC="${1:?用法: flowchart.sh <源文件.mmd|.dot> [输出文件]}"
OUT="${2:-${SRC%.*}.svg}"
DIAGRAM="${DIAGRAM:-http://127.0.0.1:${DIAGRAM_PORT:-18000}}"

case "${SRC##*.}" in
  mmd|mermaid) TYPE="${TYPE:-mermaid}" ;;
  dot|gv|graphviz) TYPE="${TYPE:-graphviz}" ;;
  d2) TYPE="${TYPE:-d2}" ;;
  puml|plantuml|iuml) TYPE="${TYPE:-plantuml}" ;;
  *) TYPE="${TYPE:-mermaid}" ;;
esac

case "${OUT##*.}" in
  png) FMT="${FMT:-png}" ;;
  jpg|jpeg) FMT="${FMT:-jpeg}" ;;
  pdf) FMT="${FMT:-pdf}" ;;
  *) FMT="${FMT:-svg}" ;;
esac

echo "渲染 $SRC（$TYPE -> $FMT）…"
code=$(curl -sS -o "$OUT" -w '%{http_code}' --max-time 120 \
        -H 'Content-Type: text/plain' --data-binary "@$SRC" \
        "$DIAGRAM/$TYPE/$FMT" || true)
if [[ "$code" != "200" ]]; then
  echo "渲染失败（HTTP $code）：" >&2
  head -c 400 "$OUT" >&2; echo >&2
  rm -f "$OUT"
  exit 1
fi
echo "  -> $OUT ($(stat -c%s "$OUT") bytes)"
