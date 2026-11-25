# 自建「流程图 / 架构图」渲染服务
#
# 为什么不用现成的 Kroki 镜像：本机网络下 Docker Hub 的大层（500MB+）反复超时，
# 而 Debian 源（ustc 实测 40MB/s）、npm 源（npmmirror 8MB/s）都很快，
# 所以直接从 debian:bookworm-slim 自建：Mermaid CLI + Graphviz + 中文字体。
#
# 对外 API 与 Kroki 兼容：POST /{type}/{format}，body 就是图源码。
FROM debian:bookworm-slim

# 换国内 Debian 源加速构建；并打开 apt 重试/超时，避免单个连接卡死拖垮整次构建
ARG DEBIAN_MIRROR=mirrors.ustc.edu.cn
RUN set -eux; \
    echo "使用 Debian 镜像源: ${DEBIAN_MIRROR}"; \
    for f in /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list; do \
        [ -f "$f" ] && sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g; s|security.debian.org|${DEBIAN_MIRROR}|g" "$f" || true; \
    done; \
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
        > /etc/apt/apt.conf.d/99diagram-retries; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        graphviz \
        python3 \
        nodejs \
        npm \
        chromium \
        fonts-noto-cjk \
        ca-certificates \
        curl \
        xz-utils; \
    rm -rf /var/lib/apt/lists/*

# Mermaid CLI：跳过 puppeteer 自带的 Chromium 下载，复用系统 chromium
ENV NPM_CONFIG_REGISTRY=https://registry.npmmirror.com \
    PUPPETEER_SKIP_DOWNLOAD=1 \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1 \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
RUN npm install -g --unsafe-perm @mermaid-js/mermaid-cli@10.9.1 \
    && npm cache clean --force \
    && mmdc --version

# Chromium 在容器里必须关沙箱
RUN mkdir -p /etc/mermaid
COPY puppeteer.json /etc/mermaid/puppeteer.json
COPY server.py /app/server.py
RUN chmod +x /app/server.py

ENV PORT=8000 \
    MAX_CONCURRENCY=2 \
    TZ=Asia/Shanghai
EXPOSE 8000

HEALTHCHECK --interval=20s --timeout=5s --start-period=20s --retries=5 \
    CMD python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/health')"

ENTRYPOINT ["python3", "/app/server.py"]
