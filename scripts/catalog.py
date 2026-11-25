#!/usr/bin/env python3
"""模型目录（config/models.json）的读写工具。

所有需要「模型清单」的地方都走这里，避免脚本里各写一份文件名：

    scripts/catalog.py list                 # 人看的表格（含磁盘状态）
    scripts/catalog.py ids                  # 空格分隔的 id
    scripts/catalog.py resolve <id|file>    # 解析成 shell 变量（供 use-model.sh eval）
    scripts/catalog.py field <id> <key>     # 取单个字段
    scripts/catalog.py download-plan [all|id,id]   # 下载清单：rel|repo|path|size

设计约定：
* 条目按 id 唯一；style 用于前端分组（real / anime / custom）。
* 只有 file 字段是必须的；其余缺省时回落到 defaults。
* 不在目录里的本地权重也能用：resolve 会按文件名合成一个 custom 条目。
"""
import json
import os
import re
import shlex
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "config", "models.json")
CKPT_DIR = os.path.join(ROOT, "models", "checkpoints")


def load():
    with open(CATALOG, encoding="utf-8") as fh:
        data = json.load(fh)
    models = data.get("models") or []
    defaults = data.get("defaults") or {}
    out = []
    for raw in models:
        entry = dict(defaults)
        entry.update(raw)
        out.append(entry)
    return defaults, out


def find(arg):
    """按 id / style / 文件名找条目；找不到但磁盘上有同名文件则合成 custom。"""
    _, models = load()
    needle = os.path.basename(arg)
    for entry in models:
        if arg in (entry.get("id"), entry.get("style")) or needle == entry.get("file"):
            return entry, False
    matches = [e for e in models if e.get("file") == needle]
    if matches:
        return matches[0], False

    path = os.path.join(CKPT_DIR, needle)
    if not os.path.exists(path):
        return None, True

    defaults, _ = load()
    style = "anime" if re.search(r"illustrious|noob|pony|anime|cartoon", needle, re.I) else "custom"
    entry = dict(defaults)
    entry.update({
        "id": re.sub(r"[^a-z0-9]+", "-", needle.rsplit(".", 1)[0].lower()).strip("-")[:40],
        "style": style,
        "label": "自定义",
        "name": needle,
        "file": needle,
        "clip_skip": 2 if style == "anime" else None,
        "negative": defaults.get("negative", ""),
    })
    return entry, False


def as_shell(entry):
    keys = {
        "MODEL_ID": entry.get("id", ""),
        "MODEL_STYLE": entry.get("style", "custom"),
        "MODEL_LABEL": entry.get("label", "自定义"),
        "MODEL_NAME": entry.get("name", entry.get("file", "")),
        "MODEL_FILE": entry.get("file", ""),
        "MODEL_STEPS": entry.get("steps", 28),
        "MODEL_CFG": entry.get("cfg", 6.0),
        "MODEL_SAMPLER": entry.get("sampler", "euler_a"),
        "MODEL_CLIP": entry.get("clip_skip") or "",
        "MODEL_WIDTH": entry.get("width", 1024),
        "MODEL_HEIGHT": entry.get("height", 1024),
        "MODEL_NEG": entry.get("negative", ""),
    }
    for key, value in keys.items():
        print(f"{key}={shlex.quote(str(value))}")


def download_plan(selector):
    _, models = load()
    wanted = None if selector in ("", "all") else {s.strip() for s in selector.split(",")}
    rows = []
    for entry in models:
        if wanted and entry.get("id") not in wanted and entry.get("style") not in wanted:
            continue
        info = entry.get("download") or {}
        if not info.get("repo") or not info.get("path"):
            continue
        rows.append("|".join([
            os.path.join("checkpoints", entry["file"]),
            info["repo"],
            info["path"],
            str(info.get("size", 0)),
        ]))
    print("\n".join(rows))
    return 0 if rows else 1


def cmd_list():
    _, models = load()
    print(f"{'id':<10} {'风格':<8} {'名称':<24} {'大小':>8}  磁盘")
    for entry in models:
        size = (entry.get("download") or {}).get("size", 0)
        path = os.path.join(CKPT_DIR, entry.get("file", ""))
        state = f"✓ {os.path.getsize(path) / 1e9:.1f} GB" if os.path.exists(path) else "✗ 未下载"
        print(f"{entry.get('id', ''):<10} {entry.get('style', ''):<8} "
              f"{entry.get('name', ''):<24} {size / 1e9:>6.1f} GB  {state}")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd = argv[0]
    if cmd == "list":
        cmd_list()
        return 0
    if cmd == "ids":
        _, models = load()
        print(" ".join(e.get("id", "") for e in models))
        return 0
    if cmd == "resolve":
        if len(argv) < 2:
            print("用法: catalog.py resolve <id|文件名>", file=sys.stderr)
            return 2
        entry, missing = find(argv[1])
        if missing:
            print(f"找不到模型 {argv[1]!r}（config/models.json 和 models/checkpoints/ 都没有）",
                  file=sys.stderr)
            return 2
        as_shell(entry)
        return 0
    if cmd == "field":
        if len(argv) < 3:
            print("用法: catalog.py field <id> <key>", file=sys.stderr)
            return 2
        entry, missing = find(argv[1])
        if missing:
            return 2
        value = entry.get(argv[2], "")
        print("" if value is None else value)
        return 0
    if cmd == "download-plan":
        return download_plan(argv[1] if len(argv) > 1 else "all")
    print(f"未知命令 {cmd!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
