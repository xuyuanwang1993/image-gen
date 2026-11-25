#!/usr/bin/env bash
# 预准备：把「刚 clone 下来」的仓库带到「能出图」。
#
#   ./scripts/prepare.sh                 # 全流程：环境检查 -> .env -> 镜像 -> 权重 -> 启动 -> 冒烟
#   ./scripts/prepare.sh --skip-models   # 权重已就绪时跳过下载
#   ./scripts/prepare.sh --skip-build    # 镜像已构建过时跳过构建
#   ./scripts/prepare.sh --no-smoke      # 不在最后跑冒烟测试
#
# 幂等：重复执行不会重复下载/构建，只补缺的部分。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKIP_MODELS=0
SKIP_BUILD=0
SKIP_SMOKE=0
for arg in "$@"; do
  case "$arg" in
    --skip-models) SKIP_MODELS=1 ;;
    --skip-build)  SKIP_BUILD=1 ;;
    --no-smoke)    SKIP_SMOKE=1 ;;
    -h|--help)     sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$arg（见 --help）" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
step "1/6 检查依赖"
# ---------------------------------------------------------------------------
command -v docker >/dev/null || die "没有 docker，先装 Docker Engine + Compose v2"
docker info >/dev/null 2>&1 || die "docker 守护进程不可用（权限或未启动）"
docker compose version >/dev/null 2>&1 || die "需要 docker compose v2（docker compose version 失败）"
ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') / compose $(docker compose version --short 2>/dev/null || echo '?')"

command -v python3 >/dev/null || die "需要 python3（脚本和 manager 都用它）"
ok "python3 $(python3 -V 2>&1 | cut -d' ' -f2)"

# GPU：能检测到就提示，检测不到只警告（CPU 也能跑，只是慢）
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  ok "GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | head -1)"
elif docker info 2>/dev/null | grep -qi 'nvidia'; then
  ok "GPU: 检测到 nvidia runtime（容器内可见）"
else
  printf '  \033[33m!\033[0m 未检测到可用 GPU，出图会很慢（CPU 也能跑）\n'
fi

# ---------------------------------------------------------------------------
step "2/6 检查 .env"
# ---------------------------------------------------------------------------
if [[ ! -f .env ]]; then
  cp .env.example .env
  ok "已从 .env.example 生成 .env"
else
  ok ".env 已存在"
fi

# PROJECT_DIR 必须等于仓库真实路径：manager 容器要按同路径挂载，才能再调 docker compose
if grep -q '^PROJECT_DIR=' .env; then
  sed -i "s#^PROJECT_DIR=.*#PROJECT_DIR=$ROOT#" .env
else
  printf '\n# 由 scripts/prepare.sh 自动写入（manager 容器同路径挂载用）\nPROJECT_DIR=%s\n' "$ROOT" >> .env
fi
ok "PROJECT_DIR=$ROOT"

# web/ 是只读挂载进 nginx 的：文件必须全局可读，否则页面/静态 JSON 会 403
chmod -R a+rX web config 2>/dev/null || true

# ---------------------------------------------------------------------------
step "3/6 准备镜像"
# ---------------------------------------------------------------------------
if [[ "$SKIP_BUILD" == "1" ]]; then
  ok "已跳过（--skip-build）"
else
  # sd.cpp 镜像通常直接拉取；拉不动就用 scripts/fetch-image.sh（直连镜像源 + docker load）
  if ! docker image inspect "${SDCPP_IMAGE:-ghcr.io/leejet/stable-diffusion.cpp:master-cuda}" >/dev/null 2>&1; then
    echo "  拉取 sd.cpp 镜像（失败可改用 ./scripts/fetch-image.sh）"
    docker compose pull sd-server || die "镜像拉取失败，试 ./scripts/fetch-image.sh"
  fi
  ok "sd.cpp 镜像就绪"

  docker compose build manager
  ok "manager 镜像就绪"

  if ! docker image inspect "${DIAGRAM_IMAGE:-image-gen-diagram:local}" >/dev/null 2>&1; then
    echo "  构建流程图镜像（Mermaid + Graphviz，首次约 2~4 分钟）"
    docker compose build diagram
  fi
  ok "流程图镜像就绪"
fi

# ---------------------------------------------------------------------------
step "4/6 准备模型权重"
# ---------------------------------------------------------------------------
if [[ "$SKIP_MODELS" == "1" ]]; then
  ok "已跳过（--skip-models）"
else
  python3 scripts/catalog.py list
  echo
  ./scripts/download-models.sh
fi

# 首次部署：.env 里没有当前模型时，自动选目录里第一个已下载的条目
current_model="$(grep -E '^SD_MODEL_FILE=' .env | tail -1 | cut -d= -f2- | tr -d '"' || true)"
if [[ -z "$current_model" ]]; then
  first_id=""
  for id in $(python3 scripts/catalog.py ids); do
    f="$(python3 scripts/catalog.py field "$id" file 2>/dev/null || true)"
    if [[ -n "$f" && -f "models/checkpoints/$f" ]]; then first_id="$id"; break; fi
  done
  [[ -n "$first_id" ]] || die "没有任何可用权重（models/checkpoints/ 为空）：先跑 ./scripts/download-models.sh"
  echo "  .env 里还没有当前模型，初始化为 $first_id"
  ./scripts/use-model.sh "$first_id" >/dev/null
  ok "当前模型 = $first_id"
else
  ok "当前模型：$current_model"
fi

# ---------------------------------------------------------------------------
step "5/6 启动服务"
# ---------------------------------------------------------------------------
docker compose up -d
ok "容器已启动"

PORT="$(grep -E '^SDCPP_PORT=' .env | tail -1 | cut -d= -f2- || true)"
PORT="${PORT:-18234}"
echo -n "  等待生图 API 就绪（首次要把权重读进显存）"
for _ in $(seq 1 120); do
  if curl -fsS --max-time 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
    echo " ok"
    break
  fi
  echo -n "."
  sleep 3
done
curl -fsS --max-time 3 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1 \
  || die "生图 API 3 分钟内没起来，看 docker compose logs sd-server"

# ---------------------------------------------------------------------------
step "6/6 冒烟测试"
# ---------------------------------------------------------------------------
if [[ "$SKIP_SMOKE" == "1" ]]; then
  ok "已跳过（--no-smoke）"
else
  ./scripts/smoke-test.sh
fi

echo
echo "======================================================================"
echo " 准备完成。"
echo "   网页   http://127.0.0.1:$(grep -E '^WEB_PORT=' .env | tail -1 | cut -d= -f2- || echo 18080)"
echo "   生图API http://127.0.0.1:$PORT"
echo "   模型   ./scripts/use-model.sh list        切换：./scripts/use-model.sh <id>"
echo "======================================================================"
