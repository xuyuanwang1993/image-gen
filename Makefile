# 「AI 生图 + 流程图」服务 —— 常用命令
SHELL := /bin/bash

# 配置以 .env 为准。注意：这些变量不进环境，避免盖住 docker compose 自己读的 .env，
# 唯一例外是 PROJECT_DIR —— manager 容器必须按宿主机同路径挂载仓库，所以显式导出。
-include .env

PROJECT_DIR ?= $(CURDIR)
export PROJECT_DIR

# 受限环境（沙箱）里 ~/.docker 不可写，buildx 会报 "read-only file system"，
# 这时自动把 DOCKER_CONFIG 落到仓库内的 .docker-config/
DOCKER_CONFIG ?= $(shell [ -w "$$HOME/.docker" ] && echo "$$HOME/.docker" || echo "$(CURDIR)/.docker-config")
export DOCKER_CONFIG

.PHONY: help prepare up down restart logs logs-diagram ps test pull-models models fetch-image \
        build-diagram build-manager build-segmenter gen flow perms status model model-real model-anime

help:
	@echo "make prepare       一键预准备：写 .env、建镜像、下权重、启动、冒烟（首次部署用这个）"
	@echo "make up            启动服务"
	@echo "make down          停止并删除容器"
	@echo "make restart       重启"
	@echo "make perms         修复文件权限（页面 403 时用）"
	@echo "make ps            查看容器状态"
	@echo "make logs          跟踪生图日志"
	@echo "make logs-diagram  跟踪画图日志"
	@echo "make fetch-image   拉取 sd.cpp CUDA 镜像（绕过 docker pull 卡顿）"
	@echo "make build-diagram 构建画图镜像（Mermaid + Graphviz）"
	@echo "make build-manager 构建模型切换控制面镜像"
	@echo "make build-segmenter 构建自动选区（分割）镜像"
	@echo "make pull-models   下载/校验权重（MODEL=real|anime|all，分片并行）"
	@echo "make models        列出 config/models.json 里的模型和磁盘状态"
	@echo "make test          冒烟测试（探活 + 出一张 768x768）"
	@echo "make gen P=\"...\"   命令行出图，结果存到 outputs/"
	@echo "make flow F=a.mmd  命令行画流程图 -> a.svg"
	@echo "make model         当前模型 + 目录"
	@echo "make model-real    切到 id=real 的模型（id 来自 config/models.json）"
	@echo "make model-anime   切到 id=anime 的模型"
	@echo "make status        GPU + 服务状态一览"

prepare:
	./scripts/prepare.sh

up: perms
	docker compose up -d

# web/ 是只读挂载进 nginx 的，文件权限必须是全局可读，否则页面 403
perms:
	@chmod -R a+rX . 2>/dev/null || true

down:
	docker compose down

restart:
	docker compose restart

logs:
	docker compose logs -f --tail=200 sd-server

logs-diagram:
	docker compose logs -f --tail=200 diagram

ps:
	docker compose ps

fetch-image:
	./scripts/fetch-image.sh

build-diagram:
	docker compose build diagram

build-manager:
	docker compose build manager

build-segmenter:
	docker compose build segmenter

pull-models:
	./scripts/download-models.sh

models:
	@python3 scripts/catalog.py list

# 切换生图模型（id 来自 config/models.json）
model:
	./scripts/use-model.sh

model-real:
	./scripts/use-model.sh real

model-anime:
	./scripts/use-model.sh anime

gen:
	@test -n "$(P)" || { echo '用法: make gen P="提示词" [W=1024 H=1024 S=28 N=1]'; exit 1; }
	./scripts/gen.sh "$(P)" $(W) $(H) $(S) $(N)

flow:
	@test -n "$(F)" || { echo '用法: make flow F=examples/cicd.mmd [O=out.svg]'; exit 1; }
	./scripts/flowchart.sh "$(F)" $(O)

test:
	./scripts/smoke-test.sh

status:
	@docker compose ps
	@echo "--- 生图 API ---"
	@curl -fsS --max-time 5 "http://127.0.0.1:$(or $(SDCPP_PORT),18234)/v1/models" || echo "生图 API 未就绪"
	@echo
	@echo "--- 画图 API ---"
	@curl -fsS --max-time 5 "http://127.0.0.1:$(or $(DIAGRAM_PORT),18000)/health" || echo "画图 API 未就绪"
	@echo "--- GPU ---"
	@docker compose exec -T sd-server nvidia-smi 2>/dev/null | head -12 || true
