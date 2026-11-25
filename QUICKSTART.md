# 怎么用（一页版）

首次部署：`./scripts/prepare.sh`（或 `make prepare`），它会把依赖、配置、镜像、权重、启动、
冒烟全做完。之后直接开浏览器。详细说明见 [README.md](README.md)。

## 1. 打开

| 想干什么 | 网址 |
|---|---|
| 写实人像 / 场景、二次元插画 | **http://localhost:18080** |
| 画流程图 / 架构图 | **http://localhost:18080/flowchart.html** |

## 2. 出图页

1. **换风格**：页头点 **写实 / 二次元**，约 15 秒切完（预设和默认参数自动跟着换）；
2. **文生图 / 图生图**：参数面板顶部切换。图生图点选或拖入参考图，用「重绘幅度」控制改多少
   （0.3~0.45 换风格、0.5~0.7 换场景、0.75+ 只借构图）；换图直接再拖一张，
   点「移除参考图」清空。**换衣服**：上传原图 → 遮罩选「上衣」→ 点
   **自动选区**（约 1 秒，青色高亮就是要改的区域）→ 强度 0.8~0.9 → 重绘；
   识别后各类变成标签，可以**多选**（勾中即并集，再点取消），标签上带实测占比；
   模型漏掉某块（比如下摆）就用「魔棒补选」点一下同色区域，或者用框选/画笔补；
   点错了按「撤销」或 `Ctrl+Z`（魔棒、框选、画笔、自动选区都能退）；
   接缝明显时把「边缘羽化」调到 8~24（生成后按模糊遮罩混合，模型本身不认羽化）；
3. 点风格预设（写实：人像特写 / 环境人像 / 室内场景 / 产品静物 / 电影感夜景；
   二次元：角色立绘 / 头像半身 / 动漫场景 / 赛璐璐 / 厚涂），再改提示词；
4. 选尺寸：竖版人像用 `832×1216`，方图 `1024×1024`，场景 `1216×832`（图生图按参考图尺寸）；
5. 步数 28、CFG 6 是默认甜点，不懂就别动；
6. 点「生成图片」（图生图是「重绘图片」）→ 右边出图，**单击下载，双击看原图**；
7. **参数预设**：左边「配置名」填个名字 →「保存当前参数」；下拉选一个 →「应用」套用，
   「删除」移除。存在后端，换浏览器/换机器都还在；
8. 结果图右上角 **×** 可单条删除（鼠标移上去才显示），整块右上角「清空全部」；
9. 结果最近 12 次会存在浏览器本地（IndexedDB），刷新/重开浏览器都还在；「×」或「清空全部」
   会连本地记录一起删，`outputs/` 里的文件不受影响。

**写实**要带摄影词：`85mm lens, window light, shallow depth of field, detailed skin texture`。
**二次元**用danbooru 标签：`1girl, solo, detailed eyes, soft lighting, illustration`。
别写 `masterpiece, best quality, 4k` 这种 SD1.5 老咒语，对 SDXL 收益很小。

## 3. 切换风格

网页页头直接点 **写实 / 二次元**（推荐）。命令行也可以：

```bash
./scripts/use-model.sh real     # 写实：Juggernaut XL v9
./scripts/use-model.sh anime    # 二次元：Illustrious XL v1.1（自动 clip skip 2）
./scripts/use-model.sh          # 看当前用哪个
```

约 10~20 秒切换完成，之后**刷新网页**即可（预设和负面提示词会跟着换）。

## 4. 命令行 / 脚本调用

```bash
cd ~/work/image-gen

# 出图（存到 outputs/，步数/CFG/负面提示词自动跟随当前模型）
make gen P="photorealistic portrait of a woman, 85mm lens" W=832 H=1216
NEG="lowres, blurry" CFG=7 SEED=42 ./scripts/gen.sh "1girl, solo, illustration" 832 1216

# 直接调 API
curl -s http://127.0.0.1:18234/sdapi/v1/txt2img -H 'Content-Type: application/json' \
  -d '{"prompt":"isometric 3d icon of a database, white background","width":1024,"height":1024,"steps":28}' \
  | python3 -c 'import sys,json,base64;d=json.load(sys.stdin);open("out.png","wb").write(base64.b64decode(d["images"][0]))'
```

## 5. 日常命令

```bash
make status        # 容器 + API + GPU 一眼看完
make model         # 当前模型 + 已装权重
make test          # 冒烟测试
make logs          # 生图日志
make down / make up
```

## 6. 出问题了看哪里

| 现象 | 先看 |
|---|---|
| 网页打不开 | `make status`；端口冲突见 README 第 2 节 |
| 换模型后 502 | 等命令打印「就绪」，再刷新网页 |
| 出图糊 | 分辨率是否 ≥832、CFG 是否 5~7、提示词有没有摄影词 |
| 网页 403 | `make perms` |
| 权重丢了 | `make pull-models`（断点续传） |
