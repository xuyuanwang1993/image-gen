#!/usr/bin/env bash
# 切换生图模型。模型清单来自 config/models.json（由 scripts/catalog.py 读取），
# 本脚本不含任何写死的模型名 / 文件名。
#
#   ./scripts/use-model.sh              # 看当前用的是哪个 + 模型目录
#   ./scripts/use-model.sh list         # 只列目录和磁盘状态
#   ./scripts/use-model.sh real         # 按 id 切（id 定义在 config/models.json）
#   ./scripts/use-model.sh <文件名>     # 切到任意本地 checkpoint（不在目录里也行）
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"
WEB_DIR="$ROOT/web"
CKPT_DIR="$ROOT/models/checkpoints"
CATALOG="$ROOT/scripts/catalog.py"
[[ -f "$ENV_FILE" ]] || { echo "找不到 $ENV_FILE（先跑 ./scripts/prepare.sh 或 cp .env.example .env）" >&2; exit 1; }

# 只按需读 .env 的值，绝不 source 进环境：
# 否则这些变量会残留在进程环境里，docker compose 会优先用环境值而不是文件里的新值，
# 导致"改了 .env 却没换模型"。
envval() { grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- | sed 's/^"\(.*\)"$/\1/'; }

list_models() {
  python3 "$CATALOG" list
  local extra
  extra="$(cd "$CKPT_DIR" 2>/dev/null && ls -1 *.safetensors 2>/dev/null || true)"
  if [[ -n "$extra" ]]; then
    echo
    echo "models/checkpoints/ 里的全部权重："
    while IFS= read -r f; do
      [[ -n "$f" ]] && printf "  %-56s %s\n" "$f" "$(du -h "$CKPT_DIR/$f" | cut -f1)"
    done <<< "$extra"
  fi
}

show() {
  local clip; clip="$(envval SD_CLIP_SKIP)"
  printf "当前风格 : %s\n" "$(envval SD_STYLE)"
  printf "当前模型 : %s\n" "$(envval SD_MODEL_NAME)"
  printf "权重文件 : models/%s/%s\n" "$(envval SD_MODEL_DIR)" "$(envval SD_MODEL_FILE)"
  printf "采样参数 : %s 步 · CFG %s · %s · clip skip %s\n" \
         "$(envval SD_STEPS)" "$(envval SD_CFG_SCALE)" "$(envval SD_SAMPLER)" "${clip:-默认}"
  printf "默认尺寸 : %sx%s\n" "$(envval SD_WIDTH)" "$(envval SD_HEIGHT)"
  printf "API      : http://%s:%s\n" "$(envval SDCPP_HOST)" "$(envval SDCPP_PORT)"
  echo
  list_models
}

# 把一组键值写回 .env（保留原有顺序和注释，缺的键追加到末尾）
write_env() {
  python3 - "$ENV_FILE" "$1" <<'PY'
import json, re, sys
path, payload = sys.argv[1], json.loads(sys.argv[2])
text = open(path, encoding="utf-8").read()
for key, value in payload.items():
    line = f"{key}={value}"
    if re.search(rf"^{re.escape(key)}=.*$", text, re.M):
        text = re.sub(rf"^{re.escape(key)}=.*$", lambda m: line, text, flags=re.M)
    else:
        text = text.rstrip("\n") + "\n" + line + "\n"
open(path, "w", encoding="utf-8").write(text)
PY
}

# web/model.json：网页据此显示模型名，并填好默认步数 / CFG / 负面提示词
write_model_json() {
  python3 - "$WEB_DIR/model.json" "$@" <<'PY'
import json, sys
path = sys.argv[1]
style, name, checkpoint, steps, cfg, sampler, clip, neg = sys.argv[2:10]
data = {
    "style": style,            # real | anime | custom
    "name": name,
    "checkpoint": checkpoint,
    "steps": int(float(steps)),
    "cfg": float(cfg),
    "sampler": sampler,
    "clip_skip": int(clip) if clip else None,
    "negative": neg,
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
print(f"  web/model.json 已更新（{style}）")
PY
}

apply_entry() {
  local resolved="$1"
  eval "$resolved"          # 载入 MODEL_* 变量（由 catalog.py 输出，已做 shell 转义）

  if [[ ! -f "$CKPT_DIR/$MODEL_FILE" ]]; then
    echo "缺少权重：models/checkpoints/$MODEL_FILE" >&2
    echo "下载：MODEL=$MODEL_ID ./scripts/download-models.sh（或直接 ./scripts/prepare.sh）" >&2
    exit 1
  fi

  write_env "$(python3 -c '
import json, sys
name, style, file, steps, cfg, sampler, clip, width, height = sys.argv[1:10]
print(json.dumps({
    "SD_MODEL_NAME": f"\"{name}\"",
    "SD_STYLE": style,
    "SD_MODEL_DIR": "checkpoints",
    "SD_MODEL_FILE": file,
    "SD_STEPS": steps,
    "SD_CFG_SCALE": cfg,
    "SD_SAMPLER": sampler,
    "SD_CLIP_SKIP": clip,
    "SD_WIDTH": width,
    "SD_HEIGHT": height,
}, ensure_ascii=False))' \
    "$MODEL_NAME" "$MODEL_STYLE" "$MODEL_FILE" "$MODEL_STEPS" "$MODEL_CFG" \
    "$MODEL_SAMPLER" "$MODEL_CLIP" "$MODEL_WIDTH" "$MODEL_HEIGHT")"
  write_model_json "$MODEL_STYLE" "$MODEL_NAME" "$MODEL_FILE" "$MODEL_STEPS" \
                   "$MODEL_CFG" "$MODEL_SAMPLER" "$MODEL_CLIP" "$MODEL_NEG"

  # 清掉可能残留的 SD_* 变量，保证 compose 读的是刚写好的 .env
  unset SD_MODEL_NAME SD_MODEL_DIR SD_MODEL_FILE SD_STEPS SD_CFG_SCALE SD_SAMPLER \
        SD_CLIP_SKIP SD_WIDTH SD_HEIGHT SD_STYLE 2>/dev/null || true

  # 从 manager 容器里调用时是 root，写出来的文件要还给宿主机用户
  if [[ -n "${OWNER_UID:-}" && -n "${OWNER_GID:-}" ]]; then
    chown "$OWNER_UID:$OWNER_GID" "$ENV_FILE" "$WEB_DIR/model.json" 2>/dev/null || true
  fi

  echo "切换到 $MODEL_NAME（${MODEL_STEPS} 步 / CFG ${MODEL_CFG} / ${MODEL_SAMPLER}${MODEL_CLIP:+ / clip skip $MODEL_CLIP}）…"
  cd "$ROOT"
  docker compose up -d --force-recreate sd-server >/dev/null

  local PORT; PORT="$(envval SDCPP_PORT)"; PORT="${PORT:-18234}"
  # 默认走本机端口；从 manager 容器里调用时 sd-server 在 compose 网络里，要换服务名
  local WAIT_BASE="${WAIT_BASE:-http://127.0.0.1:$PORT}"
  echo -n "等待模型加载"
  for _ in $(seq 1 100); do
    if curl -fsS --max-time 3 "$WAIT_BASE/v1/models" >/dev/null 2>&1; then
      echo " 就绪"
      echo
      show
      docker compose exec -T sd-server nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null || true
      exit 0
    fi
    echo -n "."
    sleep 3
  done
  echo
  echo "等待超时，看日志：docker compose logs -f sd-server" >&2
  exit 1
}

case "${1:-show}" in
  show|status|"")
    show
    ;;
  list)
    list_models
    ;;
  *)
    resolved="$(python3 "$CATALOG" resolve "$1")" || {
      echo "无法解析模型：$1" >&2
      list_models >&2
      exit 1
    }
    apply_entry "$resolved"
    ;;
esac
