#!/usr/bin/env python3
"""流程图 / 架构图渲染服务（Kroki 兼容 API 的最小子集，仅用标准库）。

    POST /{type}/{format}      body = 图源码，返回图片
    GET  /{type}/{format}/{encoded}   encoded = deflate+base64url(Kroki 的 GET 形式)
    GET  /health               健康检查
    GET  /                     支持的图类型

type: mermaid | graphviz        format: svg | png | pdf | jpeg
"""
import base64
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

PORT = int(os.environ.get("PORT", "8000"))
MAX_BODY = int(os.environ.get("MAX_BODY", str(1024 * 1024)))
TIMEOUT = int(os.environ.get("RENDER_TIMEOUT", "120"))
CONCURRENCY = int(os.environ.get("MAX_CONCURRENCY", "2"))
PUPPETEER_CFG = os.environ.get("PUPPETEER_CFG", "/etc/mermaid/puppeteer.json")

TYPES = ("mermaid", "graphviz")
FORMATS = ("svg", "png", "pdf", "jpeg", "jpg")
MIME = {
    "svg": "image/svg+xml; charset=utf-8",
    "png": "image/png",
    "pdf": "application/pdf",
    "jpeg": "image/jpeg",
    "jpg": "image/jpeg",
}
# 每个 Chromium 实例约 300MB 内存，限制并发，避免把机器打满
_slots = threading.Semaphore(CONCURRENCY)


class RenderError(Exception):
    pass


def _run(cmd, timeout=TIMEOUT):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RenderError(f"渲染超时（>{timeout}s）")
    except FileNotFoundError as e:
        raise RenderError(f"渲染器不可用: {e}")
    if p.returncode != 0:
        detail = (p.stderr or p.stdout or "").strip()
        raise RenderError(detail[-2000:] or f"渲染失败（exit {p.returncode}）")
    return p


def render(dtype, fmt, source):
    """把源码渲染成图片字节流。"""
    if dtype not in TYPES:
        raise RenderError(f"不支持的图类型 '{dtype}'，可用: {', '.join(TYPES)}")
    if fmt not in FORMATS:
        raise RenderError(f"不支持的输出格式 '{fmt}'，可用: {', '.join(FORMATS)}")
    if not source.strip():
        raise RenderError("图源码为空")

    workdir = tempfile.mkdtemp(prefix="diagram-")
    try:
        if dtype == "mermaid":
            src = os.path.join(workdir, "in.mmd")
            out = os.path.join(workdir, f"out.{fmt}")
            with open(src, "w", encoding="utf-8") as fh:
                fh.write(source)
            # SVG 透明底更适合叠到 PPT 上；位图给白底
            background = "transparent" if fmt == "svg" else "white"
            cmd = ["mmdc", "-i", src, "-o", out, "-p", PUPPETEER_CFG,
                   "-b", background, "-q"]
        else:  # graphviz
            src = os.path.join(workdir, "in.dot")
            out = os.path.join(workdir, f"out.{fmt}")
            with open(src, "w", encoding="utf-8") as fh:
                fh.write(source)
            t = "jpg" if fmt in ("jpg", "jpeg") else fmt
            cmd = ["dot", f"-T{t}", "-o", out, src]

        with _slots:
            _run(cmd)

        if not os.path.exists(out) or os.path.getsize(out) == 0:
            raise RenderError("渲染器没有产出文件")
        with open(out, "rb") as fh:
            return fh.read()
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def decode_kroki_get(encoded):
    """兼容 Kroki 的 GET 编码：deflate 压缩 + URL-safe base64（也容忍纯 base64/明文）。"""
    text = unquote(encoded).replace("-", "+").replace("_", "/")
    text += "=" * (-len(text) % 4)
    try:
        raw = base64.b64decode(text)
    except Exception:
        return unquote(encoded)
    for wbits in (-zlib.MAX_WBITS, zlib.MAX_WBITS, 47):
        try:
            return zlib.decompress(raw, wbits).decode("utf-8")
        except Exception:
            continue
    try:
        return raw.decode("utf-8")
    except Exception:
        return unquote(encoded)


class Handler(BaseHTTPRequestHandler):
    server_version = "diagram/1.0"
    protocol_version = "HTTP/1.1"

    # ---- helpers -----------------------------------------------------------
    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # 允许其它页面直接 fetch 本服务
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _fail(self, code, message):
        self._send(code, message if message.endswith("\n") else message + "\n")

    def _route(self):
        path = self.path.split("?", 1)[0].strip("/")
        parts = [unquote(p) for p in path.split("/")] if path else []
        return parts

    # ---- methods -----------------------------------------------------------
    def do_OPTIONS(self):
        self._send(204, b"")

    def do_GET(self):
        parts = self._route()
        if not parts:
            self._send(200, "diagram service\n\nPOST /{type}/{format}  body=图源码\n"
                            f"type:   {', '.join(TYPES)}\n"
                            f"format: {', '.join(FORMATS)}\n"
                            "GET  /{type}/{format}/{deflate+base64url 的源码}\n")
            return
        if parts[0] == "health":
            self._send(200, "ok\n")
            return
        if len(parts) == 3:
            dtype, fmt, encoded = parts
            try:
                image = render(dtype, fmt, decode_kroki_get(encoded))
            except RenderError as e:
                self._fail(400, str(e))
                return
            self._send(200, image, MIME[fmt])
            return
        self._fail(404, "用法: POST /{type}/{format} 或 GET /{type}/{format}/{encoded}")

    def do_POST(self):
        parts = self._route()
        if len(parts) != 2:
            self._fail(404, "用法: POST /{type}/{format}")
            return
        dtype, fmt = parts
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._fail(400, "Content-Length 无效")
            return
        if length <= 0:
            self._fail(400, "请求体为空")
            return
        if length > MAX_BODY:
            self._fail(413, f"图源码过大（>{MAX_BODY} 字节）")
            return
        source = self.rfile.read(length).decode("utf-8", errors="replace")
        try:
            image = render(dtype, fmt, source)
        except RenderError as e:
            self._fail(400, str(e))
            return
        except Exception as e:  # 兜底，别让服务挂掉
            self._fail(500, f"内部错误: {e}")
            return
        self._send(200, image, MIME[fmt])

    def log_message(self, fmt, *args):  # 打日志到 stderr，docker logs 可见
        sys.stderr.write("[diagram] %s - %s\n" % (self.address_string(), fmt % args))


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    sys.stderr.write(f"[diagram] listening on 0.0.0.0:{PORT} "
                     f"(types={TYPES}, concurrency={CONCURRENCY})\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
