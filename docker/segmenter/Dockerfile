FROM node:20-slim

WORKDIR /app

# 国内构建：npm 走镜像，缓存放 /tmp（容器内 HOME 可能不可写）
ENV NPM_CONFIG_REGISTRY=https://registry.npmmirror.com \
    NPM_CONFIG_CACHE=/tmp/npm-cache

# onnxruntime-node 的 postinstall 会去 NuGet 下载可选的 CUDA EP 包；api.nuget.org 在这里
# 会 302 到 nuget.azure.cn，而它的下载脚本不跟随跳转，导致 npm install 失败。
# 我们只用 CPU 推理，核心库已经包含在 npm 包里，所以直接跳过可选下载。
ENV ONNXRUNTIME_NODE_INSTALL=skip

COPY package.json ./
RUN npm install --omit=dev && rm -rf /tmp/npm-cache

COPY server.mjs warm.mjs ./

EXPOSE 8000
CMD ["node", "server.mjs"]
