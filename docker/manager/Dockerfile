# 模型切换控制面：docker CLI + compose + python3（只用标准库）
#
# docker:cli 自带 docker / docker compose，但没有 python；alpine 源换成阿里云，
# 构建约 1~2 分钟，镜像 100 MB 左右。
FROM docker:cli

RUN sed -i 's#dl-cdn.alpinelinux.org#mirrors.aliyun.com#g' /etc/apk/repositories \
    && apk add --no-cache python3 bash curl \
    && rm -rf /var/cache/apk/*

COPY manager.py /app/manager.py
WORKDIR /app

EXPOSE 18235
ENTRYPOINT ["python3", "-u", "/app/manager.py"]
