#!/usr/bin/env bash
# 拉取 sd.cpp 官方镜像并导入本机 Docker。
#
# 为什么不用 docker pull：国内直连 ghcr.io 极慢，部分 ghcr 镜像源在 `docker pull`
# 时会在中途停滞（层已下载完却不落地）。这里用 curl 并发直接下载各层 blob
# （实测 30+ MB/s），逐层校验 sha256 后按 docker save 格式打包，再 `docker load`。
#
#   ./scripts/fetch-image.sh
#   GHCR_MIRROR=https://ghcr.io ./scripts/fetch-image.sh      # 直连官方源
#   TAG=master-vulkan ./scripts/fetch-image.sh                # 换后端
#
set -euo pipefail

IMAGE="${IMAGE:-leejet/stable-diffusion.cpp}"
TAG="${TAG:-master-cuda}"
MIRROR="${GHCR_MIRROR:-https://ghcr.nju.edu.cn}"
TARGET="${TARGET:-ghcr.io/leejet/stable-diffusion.cpp:${TAG}}"
JOBS="${JOBS:-4}"

WORK="${WORK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.imgfetch}"
mkdir -p "$WORK"
echo "镜像源 : $MIRROR/$IMAGE:$TAG"
echo "导入为 : $TARGET"
echo "工作目录: $WORK（下载完成可 rm -rf 删除）"

TOKEN="$(curl -fsS "$MIRROR/token?scope=repository:${IMAGE}:pull&service=ghcr.io" 2>/dev/null \
         | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' || true)"
[[ -n "$TOKEN" ]] && echo "已获取匿名 token"

ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
MANIFEST_ACCEPT="application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
export IMAGE MIRROR MANIFEST_ACCEPT TOKEN

curl_ghcr() {  # curl_ghcr <accept> <url> <out>
  curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 20 \
       ${TOKEN:+-H "Authorization: Bearer $TOKEN"} -H "Accept: $1" -o "$3" "$2"
}

echo "==> 1/5 获取 manifest"
curl_ghcr "$ACCEPT" "$MIRROR/v2/$IMAGE/manifests/$TAG" "$WORK/root.json"

python3 - "$WORK" <<'PY'
import hashlib, json, os, subprocess, sys
work = sys.argv[1]
root = json.load(open(f"{work}/root.json"))
if "manifests" in root:                       # 多架构 index -> linux/amd64
    entry = next(m for m in root["manifests"]
                 if m.get("platform", {}).get("architecture") == "amd64"
                 and m.get("platform", {}).get("os") == "linux")
    digest = entry["digest"]
    cmd = ["curl", "-fsSL", "--retry", "5", "--retry-delay", "2", "--retry-all-errors"]
    if os.environ.get("TOKEN"):
        cmd += ["-H", f"Authorization: Bearer {os.environ['TOKEN']}"]
    cmd += ["-H", "Accept: " + os.environ["MANIFEST_ACCEPT"],
            "-o", f"{work}/manifest.json",
            f"{os.environ['MIRROR']}/v2/{os.environ['IMAGE']}/manifests/{digest}"]
    subprocess.run(cmd, check=True)
else:                                          # 单架构，本身就是 manifest
    digest = "sha256:" + hashlib.sha256(open(f"{work}/root.json", "rb").read()).hexdigest()
    os.replace(f"{work}/root.json", f"{work}/manifest.json")
print("    manifest digest:", digest)

m = json.load(open(f"{work}/manifest.json"))
rows = [(m["config"]["digest"], "config.json", m["config"].get("size", 0))]
for i, layer in enumerate(m["layers"]):
    rows.append((layer["digest"], f"layer-{i:02d}.tar.gz", layer.get("size", 0)))
with open(f"{work}/blobs.txt", "w") as fh:
    for digest, name, size in rows:
        fh.write(f"{digest} {name} {size}\n")
mb = sum(s for _, _, s in rows) / 1e6
print(f"    共 {len(rows)} 个 blob，合计 {mb:.0f} MB")
PY
# (环境变量已在前面导出)

fetch_blob() {  # fetch_blob <digest> <basename> <size>
  local digest="$1" name="$2" size="$3" out="$WORK/$name" have t0
  if [[ -f "$out" ]] && [[ "$(stat -c%s "$out")" == "$size" ]]; then
    echo "    [复用] $name（$(numfmt --to=iec "$size")）"; return 0
  fi
  t0=$(date +%s)
  echo "    [开始] $name （$(numfmt --to=iec "$size")）"
  for attempt in $(seq 1 10); do
    if curl -fsL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 20 \
            ${TOKEN:+-H "Authorization: Bearer $TOKEN"} \
            -o "$out" "$MIRROR/v2/$IMAGE/blobs/$digest"; then
      have="$(stat -c%s "$out")"
      if [[ "$have" == "$size" ]]; then
        echo "    [完成] $name 用时 $(( $(date +%s) - t0 ))s"
        return 0
      fi
      echo "    大小不符（$have/$size），重试 $name"
    fi
    echo "    第 $attempt 次失败，重试 $name"
    sleep 2
  done
  echo "    ✗ $name 下载失败"
  return 1
}
export -f fetch_blob
export WORK

echo "==> 2/5 下载层（并发 $JOBS）"
failed=0
running=0
while read -r digest name size; do
  fetch_blob "$digest" "$name" "$size" &
  running=$(( running + 1 ))
  if (( running >= JOBS )); then
    wait -n || failed=1
    running=$(( running - 1 ))
  fi
done < "$WORK/blobs.txt"
wait || failed=1
(( failed == 0 )) || { echo "    ✗ 有 blob 下载失败" >&2; exit 1; }

echo "==> 3/5 校验 sha256"
while read -r digest name _rest; do
  actual="sha256:$(sha256sum "$WORK/$name" | cut -d' ' -f1)"
  [[ "$actual" == "$digest" ]] || { echo "    ✗ $name 校验失败" >&2; exit 1; }
  echo "    ✓ $name"
done < "$WORK/blobs.txt"

echo "==> 4/5 打包 docker save 归档"
python3 - "$WORK" "$TARGET" <<'PY'
import json, sys
work, target = sys.argv[1], sys.argv[2]
rows = [l.split() for l in open(f"{work}/blobs.txt").read().splitlines()]
config = rows[0][1]
layers = [name for _, name, _ in rows[1:]]
# 覆盖掉前面下载的 OCI manifest：docker load 只认根目录这个格式的 manifest.json
json.dump([{"Config": config, "RepoTags": [target], "Layers": layers}],
          open(f"{work}/manifest.json", "w"))
PY
( cd "$WORK" && tar cf image.tar manifest.json config.json layer-*.tar.gz )

echo "==> 5/5 docker load"
docker load -i "$WORK/image.tar"
docker images "$TARGET"
