#!/usr/bin/env python3
"""模型切换控制面（给网页用的小后端）。

只看一个状态：当前加载的是哪套权重。切换动作本身复用 scripts/use-model.sh，
所以命令行和网页走的是同一条路径，不会出现两套逻辑。

接口（经 nginx 反代为 /manager/*）：
    GET  /state   -> 当前模型 + 可选模型 + 是否正在切换 + 上次错误
    POST /switch  -> {"target": "real" | "anime"}，异步执行，立即返回 202
    GET  /health  -> ok

安全：只发布到宿主机 127.0.0.1，不鉴权。容器挂了 docker.sock，等于宿主机 root 权限，
所以这个端口绝对不能暴露到局域网。
"""
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PROJECT = os.environ.get("PROJECT_DIR", "/work")
PORT = int(os.environ.get("MANAGER_PORT", "18235"))
CKPT_DIR = os.path.join(PROJECT, "models", "checkpoints")
MODEL_JSON = os.path.join(PROJECT, "web", "model.json")
SCRIPT = os.path.join(PROJECT, "scripts", "use-model.sh")
PRESETS_FILE = os.path.join(PROJECT, "data", "presets.json")
CATALOG_FILE = os.path.join(PROJECT, "config", "models.json")
MAX_PRESETS = 100

STATE = {"busy": False, "error": None, "target": None, "started_at": None}
LOCK = threading.Lock()
PRESET_LOCK = threading.Lock()


def load_catalog():
    """模型目录：config/models.json（唯一来源，脚本和网页都读它）。"""
    try:
        with open(CATALOG_FILE, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    defaults = data.get("defaults") or {}
    models = []
    for raw in data.get("models") or []:
        entry = dict(defaults)
        entry.update(raw)
        models.append(entry)
    return models


def catalog_config():
    """给前端用的端口等运行参数，全部来自环境变量，不在前端写死。"""
    def as_int(name, fallback):
        try:
            return int(os.environ.get(name, fallback))
        except (TypeError, ValueError):
            return fallback

    return {
        "api_port": as_int("SDCPP_PORT", 18234),
        "web_port": as_int("WEB_PORT", 18080),
        "diagram_port": as_int("DIAGRAM_PORT", 18000),
        "manager_port": as_int("MANAGER_PORT", 18235),
        "host": os.environ.get("SDCPP_HOST", "0.0.0.0"),
    }


def read_presets():
    try:
        with open(PRESETS_FILE, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def write_presets(items):
    """原子写 + 把属主还给宿主机用户（容器里是 root）。"""
    os.makedirs(os.path.dirname(PRESETS_FILE), exist_ok=True)
    tmp = PRESETS_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(items, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.replace(tmp, PRESETS_FILE)
    try:
        st = os.stat(PROJECT)
        os.chown(PRESETS_FILE, st.st_uid, st.st_gid)
        os.chown(os.path.dirname(PRESETS_FILE), st.st_uid, st.st_gid)
    except OSError:
        pass


def clean_params(raw):
    """只收认识的键，顺手把数值夹到合理范围——别让前端塞进来奇怪的东西。"""
    if not isinstance(raw, dict):
        raise ValueError("params 必须是对象")
    out = {}
    for key in ("mode", "sampler"):
        if isinstance(raw.get(key), str):
            out[key] = raw[key][:40]
    for key in ("prompt", "negative"):
        if isinstance(raw.get(key), str):
            out[key] = raw[key][:4000]
    for key, hi in (("width", 4096), ("height", 4096), ("steps", 64), ("batch", 8)):
        if key in raw:
            try:
                out[key] = max(1, min(int(raw[key]), hi))
            except (TypeError, ValueError):
                pass
    for key, lo, hi in (("cfg", 0.1, 30.0), ("denoise", 0.05, 1.0)):
        if key in raw:
            try:
                out[key] = round(max(lo, min(float(raw[key]), hi)), 3)
            except (TypeError, ValueError):
                pass
    return out


def read_current():
    try:
        with open(MODEL_JSON, encoding="utf-8") as fh:
            data = json.load(fh)
        return {
            "style": data.get("style"),
            "name": data.get("name"),
            "file": data.get("checkpoint"),
            "steps": data.get("steps"),
            "cfg": data.get("cfg"),
        }
    except Exception:
        return {"style": None, "name": None, "file": None, "steps": None, "cfg": None}


def options():
    out = []
    for item in load_catalog():
        entry = {
            "id": item.get("id"),
            "style": item.get("style"),
            "label": item.get("label"),
            "name": item.get("name"),
            "file": item.get("file"),
        }
        entry["available"] = os.path.exists(os.path.join(CKPT_DIR, item.get("file", "")))
        out.append(entry)
    return out


def snapshot():
    return {
        "current": read_current(),
        "options": options(),
        "config": catalog_config(),
        "busy": STATE["busy"],
        "error": STATE["error"],
        "target": STATE["target"],
        "elapsed": round(time.time() - STATE["started_at"], 1) if STATE["started_at"] else None,
    }


def run_switch(target: str) -> None:
    try:
        env = dict(os.environ)
        # 容器内没法走 127.0.0.1:18234（sd-server 在 compose 网络里），换成服务名
        env["WAIT_BASE"] = "http://sd-server:1234"
        try:
            st = os.stat(PROJECT)
            env["OWNER_UID"] = str(st.st_uid)
            env["OWNER_GID"] = str(st.st_gid)
        except OSError:
            pass
        # use-model.sh 会写 .env / model.json；继承来的 SD_* 会盖掉 .env，先清掉
        for key in [k for k in env if k.startswith("SD_")]:
            env.pop(key, None)

        proc = subprocess.run(
            [SCRIPT, target],
            cwd=PROJECT, env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=420,
        )
        if proc.returncode != 0:
            raise RuntimeError(proc.stdout.strip()[-1500:] or f"exit {proc.returncode}")
    except Exception as exc:  # noqa: BLE001 - 任何失败都要回显给网页
        STATE["error"] = str(exc)[:2000]
    finally:
        STATE.update(busy=False, target=None, started_at=None)


class Handler(BaseHTTPRequestHandler):
    server_version = "image-gen-manager/1.0"

    def _send(self, code: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        path = self.path.split("?")[0].rstrip("/") or "/"
        if path in ("/state", "/"):
            self._send(200, snapshot())
        elif path == "/presets":
            self._send(200, {"presets": read_presets()})
        elif path == "/health":
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        path = self.path.split("?")[0].rstrip("/")
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            self._send(400, {"error": "body 需要是 JSON"})
            return
        if not isinstance(body, dict):
            self._send(400, {"error": "body 需要是 JSON 对象"})
            return

        if path == "/switch":
            self._do_switch(body)
        elif path == "/presets":
            self._do_save_preset(body)
        elif path == "/presets/delete":
            self._do_delete_preset(body)
        else:
            self._send(404, {"error": "not found"})

    def _do_switch(self, body):
        target = (body.get("target") or "").strip()
        known = {
            item.get("id") for item in load_catalog()
            if os.path.exists(os.path.join(CKPT_DIR, item.get("file", "")))
        }
        if target not in known:
            self._send(400, {"error": f"未知或缺失的 target：{target!r}，可选 {sorted(known)}"})
            return

        with LOCK:
            if STATE["busy"]:
                self._send(409, {"error": "上一次切换还没完成", **snapshot()})
                return
            STATE.update(busy=True, error=None, target=target, started_at=time.time())

        threading.Thread(target=run_switch, args=(target,), daemon=True).start()
        self._send(202, snapshot())

    def _do_save_preset(self, body):
        name = str(body.get("name") or "").strip()[:60]
        if not name:
            self._send(400, {"error": "name 不能为空"})
            return
        try:
            params = clean_params(body.get("params"))
        except ValueError as exc:
            self._send(400, {"error": str(exc)})
            return

        with PRESET_LOCK:
            items = read_presets()
            entry = {"name": name, "params": params, "updated_at": int(time.time())}
            for i, item in enumerate(items):
                if item.get("name") == name:
                    items[i] = entry          # 同名覆盖
                    break
            else:
                if len(items) >= MAX_PRESETS:
                    self._send(400, {"error": f"最多保存 {MAX_PRESETS} 个配置"})
                    return
                items.append(entry)
            write_presets(items)
        self._send(200, {"ok": True, "presets": items})

    def _do_delete_preset(self, body):
        name = str(body.get("name") or "").strip()
        if not name:
            self._send(400, {"error": "name 不能为空"})
            return
        with PRESET_LOCK:
            items = read_presets()
            kept = [item for item in items if item.get("name") != name]
            if len(kept) == len(items):
                self._send(404, {"error": f"没有配置 {name!r}"})
                return
            write_presets(kept)
        self._send(200, {"ok": True, "presets": kept})

    def log_message(self, fmt, *args):  # 静默，避免刷日志
        return


def main():
    if not os.path.exists(os.path.join(PROJECT, "docker-compose.yml")):
        raise SystemExit(f"PROJECT_DIR 不对：{PROJECT} 下没有 docker-compose.yml")
    print(f"[manager] project={PROJECT} port={PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
