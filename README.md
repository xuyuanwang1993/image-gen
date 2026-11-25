# image-gen · 本地 SDXL 生图服务（写实 + 二次元）

> 🚀 **只想知道怎么用？看 [QUICKSTART.md](QUICKSTART.md)（一页版）。** 下面是完整手册。

本机 Docker Compose 一套栈，提供两种出图能力，都带 HTTP API 和中文网页界面：

| 能力 | 用于 | 技术 | 网页 | API |
|---|---|---|---|---|
| **AI 生图** | 写实人像 / 场景、二次元插画、立绘 | stable-diffusion.cpp + SDXL checkpoint（两套可切换） | `/` | `127.0.0.1:18234` |
| **流程图 / 架构图** | 开发流程、调用时序、服务架构 | 自建渲染服务（Mermaid CLI + Graphviz + 中文字体） | `/flowchart.html` | `127.0.0.1:18000` |

生图侧**没有内置内容过滤**（权重和推理链路都不带 safety checker），审核与合规由使用者自己负责。
API 也没有鉴权，默认监听 `0.0.0.0` 是为了让 Windows / 局域网能访问；只在本机用就把
`.env` 里的 `SDCPP_HOST` 改成 `127.0.0.1`。

> 历史说明：这套栈最早跑的是 FLUX.1-schnell / dev（GGUF）。FLUX 对身体结构和敏感题材的表现不够，
> 已整套移除，权重也删了（腾出 16.4 GB），现在只保留 SDXL 单文件 checkpoint 架构。

```
image-gen/
├── docker-compose.yml          # sd-server（生图）+ diagram（画图）+ manager（切换）+ web（网页）
├── .env.example                # 配置模板（.env 由 prepare.sh 生成，不进 git）
├── config/
│   └── models.json             # 模型目录：id / 风格 / 文件 / 采样参数 / 下载源（唯一来源）
├── models/
│   ├── checkpoints/            # SDXL 权重（按目录里的 file 命名）
│   └── loras/                  # 放 LoRA .safetensors（可选）
├── docker/
│   ├── diagram/                # 流程图渲染服务（Mermaid + Graphviz）
│   ├── manager/                # 模型切换控制面（python + docker CLI，网页按钮的后端）
│   └── segmenter/              # 自动选区（SegFormer 衣物分割，Node + onnxruntime）
├── web/
│   ├── index.html              # 生图页（切换按钮/预设由后端与 JSON 提供，不写死）
│   ├── presets.json            # 提示词预设（按风格分组）
│   ├── model.json              # 当前模型元信息，由 use-model.sh 生成（不进 git）
│   ├── flowchart.html          # 流程图页
│   ├── nginx.conf              # /api/* -> sd-server，/manager/* -> manager，/diagram/* -> diagram
│   └── lightbox.{js,css}       # 结果缓存（最多 12 条）+ 双击看原图
├── scripts/
│   ├── prepare.sh              # 一键预准备：环境检查 → .env → 镜像 → 权重 → 启动 → 冒烟
│   ├── catalog.py              # 读写 config/models.json（list/resolve/download-plan）
│   ├── sd-launch.sh            # 容器入口：按 .env 拼 --model/--steps 等参数
│   ├── use-model.sh            # 切换模型（读目录 → 写 .env/model.json → 重建容器）
│   ├── gen.sh                  # 命令行出图 -> outputs/
│   ├── download-models.sh      # 下载权重（按目录的 download 字段，调 dl-parallel.py）
│   ├── dl-parallel.py          # 分片并行下载（HF 单连接被限速时用）
│   ├── smoke-test.sh           # 冒烟测试
│   └── flowchart.sh            # 命令行渲染 .mmd/.dot
└── outputs/                    # 命令行出图落盘目录
```

---

## 1. 快速开始

```bash
git clone <repo> && cd image-gen
./scripts/prepare.sh        # 或 make prepare：一条命令完成首次部署
```

`prepare.sh` 是幂等的，按顺序做六件事，缺什么补什么：

1. **环境检查**：docker / compose v2 / python3 / GPU（检测不到 GPU 只警告，CPU 也能跑）；
2. **生成 `.env`**：从 `.env.example` 复制，并写入 `PROJECT_DIR`（manager 容器要按同路径挂载仓库）；
3. **准备镜像**：拉 sd.cpp CUDA 镜像、构建 manager 和 segmenter（首次还会构建流程图镜像）；
4. **下载权重**：按 `config/models.json` 的 `download` 字段分片并行下载、校验大小；
5. **启动服务**：`docker compose up -d`，等待生图 API 就绪；
6. **冒烟测试**：探活 + 出一张 768×768。

常用开关：

```bash
./scripts/prepare.sh --skip-models   # 权重已就绪
./scripts/prepare.sh --skip-build    # 镜像已构建
./scripts/prepare.sh --no-smoke      # 不跑冒烟
```

打开 <http://127.0.0.1:18080/> 即可用。

| 入口 | 地址 |
|---|---|
| 网页 · 生图 | http://127.0.0.1:18080/ |
| 网页 · 流程图 | http://127.0.0.1:18080/flowchart.html |
| 生图 API | http://127.0.0.1:18234 （A1111 / OpenAI 双协议） |
| 流程图 API | http://127.0.0.1:18000 （Kroki 兼容） |

> `web/` 是只读挂载进 nginx 的，文件权限必须是全局可读，否则页面和静态 JSON 会 403。
> `prepare.sh` 会自动 `chmod -R a+rX web config`；手动执行 `make perms` 也可。

## 2. 访问与网络（WSL + Windows）

三个服务都绑定 `0.0.0.0`（`.env` 里 `SDCPP_HOST`），所以下面三种来源都能用：

| 从哪访问 | 地址 |
|---|---|
| WSL 内部 | `http://127.0.0.1:18080` |
| Windows 浏览器 | `http://localhost:18080` 或 `http://<WSL_IP>:18080` |
| 局域网其它机器 | `http://<WSL_IP>:18080`（需要端口转发 + 防火墙，见下） |

WSL IP：`hostname -I | awk '{print $1}'`（每次重启 WSL 会变）。

**从 Windows 打不开，通常是这两个原因：**

1. 端口被 Windows 自己的进程占了：`netstat -ano | findstr :18080`，有输出就用
   `tasklist /FI "PID eq <PID>"` 看是哪个。本仓库已避开 8080/8000 这类常用端口。
2. 服务只监听了 `127.0.0.1`。确认 `.env` 里是 `SDCPP_HOST=0.0.0.0`。

**局域网访问**（WSL2 默认 NAT，别的机器进不来）：

```powershell
# 管理员 PowerShell，$wslIp 换成 hostname -I 的结果
netsh interface portproxy add v4tov4 listenport=18080 listenaddress=0.0.0.0 `
      connectport=18080 connectaddress=$wslIp
New-NetFirewallRule -DisplayName "image-gen 18080" -Direction Inbound -LocalPort 18080 -Protocol TCP -Action Allow
```

## 3. 硬件与实测性能

| 项目 | 实测值 |
|---|---|
| GPU | NVIDIA GeForce RTX 4080 SUPER，16376 MiB（WSL2 直通） |
| 显存占用 | SDXL 常驻约 **8.0 GB** |
| 宿主机内存 | 15 GB（sd.cpp 用 `--auto-fit` 自动规划） |
| Docker | 29.7.2 + Compose v5.5.0，`--gpus` 可用 |

| 任务 | 实测耗时 |
|---|---|
| 切模型（重建容器 + 加载 6.7 GB 权重） | 约 10~20 秒 |
| 换模型后**第一张** | 约 18~40 秒（同时在读写大文件时会明显变慢） |
| 写实 1024×1024 / 28 步 / CFG 6 | **17~24 秒** |
| 二次元 832×1216 / 28 步 / CFG 6 | **15~20 秒** |
| 512×512 / 4 步（只适合试验参数） | 约 2~4 秒 |

16 GB 显存放不下两套 SDXL，所以是**切换**而不是同时加载。流程图侧是纯 CPU（Mermaid 走
Chromium），单张几十到几百毫秒。

## 4. 模型

### 4.1 模型目录（唯一事实来源）

模型清单在 **`config/models.json`**，脚本、后端、网页都读它，任何地方都不再写死模型名：

```json
{
  "defaults": { "width": 1024, "height": 1024, "steps": 28, "cfg": 6.0, "sampler": "euler_a" },
  "models": [
    {
      "id": "real",
      "style": "real",
      "label": "写实",
      "name": "Juggernaut XL v9",
      "file": "Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors",
      "clip_skip": null,
      "negative": "cartoon, anime, ...",
      "download": {
        "repo": "RunDiffusion/Juggernaut-XL-v9",
        "path": "Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors",
        "size": 7105348188
      }
    }
  ]
}
```

- `id` 是切换用的标识（`./scripts/use-model.sh real`），网页页头的按钮也按它生成；
- `style` 决定前端用哪套提示词预设（`web/presets.json` 里的 `real` / `anime` / `custom`）；
- `file` 是 `models/checkpoints/` 下的文件名，其余字段缺省时回落到 `defaults`；
- `download` 供 `prepare.sh` / `download-models.sh` 使用，`size` 用于校验和续传。

**加一个新模型**：把权重放进 `models/checkpoints/`，在 `config/models.json` 里加一个条目，完事——
`use-model.sh list`、网页切换按钮、下载流程都会自动带上它。

查看目录和磁盘状态：

```bash
make models            # 等价于 python3 scripts/catalog.py list
./scripts/use-model.sh list
```

### 4.2 两套预置权重

```
models/checkpoints/
├── Juggernaut-XL_v9_RunDiffusionPhoto_v2.safetensors   6.7 GB   写实
└── Illustrious-XL-v1.1.safetensors                     6.5 GB   二次元
```

| 模型 | 风格 | 来源（HF） | 采样参数 | 许可 |
|---|---|---|---|---|
| Juggernaut XL v9 | 写实 | [RunDiffusion/Juggernaut-XL-v9](https://huggingface.co/RunDiffusion/Juggernaut-XL-v9) | 28 步 / CFG 6 / euler_a | CreativeML OpenRAIL++-M 类，商用前看模型卡 |
| Illustrious XL v1.1 | 二次元 | [OnomaAIResearch/Illustrious-XL-v1.1](https://huggingface.co/OnomaAIResearch/Illustrious-XL-v1.1) | 28 步 / CFG 6 / euler_a / **clip skip 2** | Fair AI Public License 1.0-SD，商用前看模型卡 |

两个都是 A1111 单文件格式（权重里烘了 VAE 和 CLIP-L/G），sd.cpp 用 `-m` 直接加载。

### 4.3 切换

```bash
./scripts/use-model.sh            # 看当前模型 + 目录
./scripts/use-model.sh list       # 只列目录和磁盘状态
./scripts/use-model.sh real       # 按 id 切（id 来自 config/models.json）
./scripts/use-model.sh anime
make model-real                   # 等价写法
make model-anime
```

网页页头的切换按钮**按目录动态生成**，加一个模型就多一个按钮（见 6.1），走的也是同一条路径。

切换会改写 `.env` 的 `SD_MODEL_*` / 采样参数、重新生成 `web/model.json`（网页据此换预设和
默认负面提示词），然后重建容器并等它就绪才返回。网页刷新一下就是新模型。

### 4.4 换任意 checkpoint / 加 LoRA

任何 SDXL / SD1.5 的 `.safetensors` 丢进 `models/checkpoints/` 就能用，两种方式：

```bash
# 方式 A：不改目录，直接按文件名切（会按文件名猜风格，合成一个临时条目）
cp ~/Downloads/SomeModel_v2.safetensors models/checkpoints/
./scripts/use-model.sh SomeModel_v2.safetensors

# 方式 B（推荐）：在 config/models.json 里加条目，之后切换/下载/网页按钮都会带上它
```

LoRA 放到 `models/loras/`（容器启动参数已带 `--lora-model-dir /models/loras`），
通过 `/sdapi/v1/loras` 可以列出来。

### 4.5 写实 vs 二次元的提示词差别

| | 写实（Juggernaut） | 二次元（Illustrious） |
|---|---|---|
| 提示词风格 | 自然语言 + 摄影词：`85mm lens, window light, shallow depth of field, film grain` | danbooru 标签：`1girl, solo, upper body, detailed eyes, soft lighting` |
| 负面提示词 | 去掉画风：`cartoon, anime, cgi, 3d render, illustration` | 去掉写实：`photorealistic, photo, 3d render` |
| CFG | 5~7（默认 6） | 5~7（默认 6） |
| clip skip | 1（不传） | **2**（已自动设置） |
| 尺寸 | 1024×1024 / 832×1216 / 1216×832 | 832×1216（立绘）/ 1024×1024 |

网页上的预设 chip 已经按风格分好；负面提示词在切换模型时会自动换成对应那套（可以手动改）。

## 5. API

### 5.1 A1111 兼容（推荐，参数最全）

```bash
curl -s http://127.0.0.1:18234/sdapi/v1/txt2img \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"close-up portrait of a woman, soft window light, 85mm lens",
       "negative_prompt":"cartoon, anime, lowres, blurry",
       "width":1024,"height":1024,"steps":28,"cfg_scale":6,
       "sampler_name":"euler_a","batch_size":1,"seed":-1}' \
  | python3 -c 'import sys,json,base64;d=json.load(sys.stdin);open("out.png","wb").write(base64.b64decode(d["images"][0]))'
```

返回 `{"images":["<base64 png>", ...], "info":"<JSON 字符串，含 seed/steps/尺寸>"}`。

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/sdapi/v1/txt2img` | 文生图 |
| POST | `/sdapi/v1/img2img` | 图生图：`init_images`(base64) + `denoising_strength` |
| GET | `/sdapi/v1/progress` | 进度：`progress`(0~1) |
| GET | `/sdapi/v1/options` | 当前模型 |
| GET | `/sdapi/v1/samplers`、`/schedulers`、`/loras` | 可选资源 |

常用参数：

| 参数 | 说明 |
|---|---|
| `prompt` / `negative_prompt` | 正向 / 负向提示词（SDXL 下负向**是生效的**） |
| `width` / `height` | 建议 1024 级别；太小的分辨率 SDXL 会糊 |
| `steps` | 25~30 是甜点，>35 收益很小 |
| `cfg_scale` | 5~7。太低发糊，太高发硬、过饱和 |
| `sampler_name` | `euler_a`（默认）、`euler`、`dpm++2m` 等 |
| `seed` | `-1` 随机；固定种子便于对比参数 |
| `batch_size` | 一次出几张（1~4） |

**图生图（img2img）**：同一条协议，换成 `/sdapi/v1/img2img`，多两个字段：

```bash
# 把参考图 base64 后放进 init_images；denoising_strength 控制改动幅度
python3 - <<'PY' > /tmp/i2i.json
import base64, json
print(json.dumps({
    "init_images": [base64.b64encode(open("ref.png", "rb").read()).decode()],
    "prompt": "photorealistic portrait of a man in a dark raincoat, neon city at night, 50mm",
    "negative_prompt": "cartoon, anime, lowres, blurry",
    "denoising_strength": 0.55,
    "steps": 24, "cfg_scale": 6, "sampler_name": "euler_a", "seed": 12,
}))
PY
curl -s http://127.0.0.1:18234/sdapi/v1/img2img \
  -H 'Content-Type: application/json' -d @/tmp/i2i.json \
  | python3 -c 'import sys,json,base64;d=json.load(sys.stdin);open("out.png","wb").write(base64.b64decode(d["images"][0]))'
```

| 参数 | 说明 |
|---|---|
| `init_images` | 参考图，base64（不带 `data:` 前缀），可以放多张 |
| `denoising_strength` | 改动幅度：0.3~0.45 换风格/调色，0.5~0.7 换元素换场景，0.75+ 基本只借构图 |
| `mask` | 可选。与参考图同尺寸的黑白图（**白=重绘，黑=保留**），传了它就只改遮罩区域，适合换衣服 / 换背景 |
| `width` / `height` | 输出尺寸（不传则按参考图）；服务端会把参考图缩放到这个尺寸 |

实测 768×768、24 步、denoise 0.55 约 **4~6 秒**（有效步数只有 24×0.55）。

### 5.2 OpenAI 兼容

```bash
curl -s http://127.0.0.1:18234/v1/images/generations \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"isometric 3d icon of a database, white background","size":"1024x1024","n":1}'
# -> {"created":..., "data":[{"b64_json":"..."}]}
```

只接收 `prompt / size / n / output_format`；要控制步数、CFG、负面提示词请用 5.1。

### 5.3 Python

```python
import base64, requests
r = requests.post("http://127.0.0.1:18234/sdapi/v1/txt2img", json={
    "prompt": "1girl, solo, detailed eyes, soft lighting, illustration",
    "negative_prompt": "photorealistic, lowres, bad anatomy",
    "width": 832, "height": 1216, "steps": 28, "cfg_scale": 6, "sampler_name": "euler_a",
}, timeout=600)
open("out.png", "wb").write(base64.b64decode(r.json()["images"][0]))
```

### 5.4 分割接口（自动选区背后的服务）

`segmenter` 容器提供一个语义分割接口，输入一张 PNG，返回各区域的 mask（白色 + alpha 表示选区）：

```bash
curl -s -X POST http://127.0.0.1:18080/segment/segment \
  -H 'Content-Type: application/json' \
  -d '{"image": "<base64 png>"}' \
  | python3 -c 'import sys,json,base64;d=json.load(sys.stdin);open("mask.png","wb").write(base64.b64decode(d["masks"]["upper"]))'
```

返回：

```json
{
  "width": 832, "height": 1216, "ms": 1024,
  "ratios": {"upper": 7.4, "lower": 6.5, "garment": 14.7, "person": 18.6, "background": 81.4},
  "masks": {"upper": "<base64 png>", "lower": "...", "garment": "...", "person": "...", "...": "..."}
}
```

可选的 key：`upper` 上衣、`lower` 下装、`dress` 连衣裙、`shoes` 鞋、`garment` 整套衣物、
`accessory` 配饰、`person` 人物整体、`skin` 皮肤、`hair` 头发、`background` 背景。

模型 `Xenova/segformer_b2_clothes`（q8，约 29MB）首次使用会下载到 `models/segformer/`；
CPU 推理，单张 832×1216 约 1 秒，不占显存。

## 6. 网页

<http://127.0.0.1:18080/> 打开就是生图页：

- 页头有 **写实 / 二次元** 分段按钮，点一下就能换模型（约 15 秒，成功后预设、负面提示词、
  默认参数会一起刷新）。按钮只在 manager 服务可用时出现，挂了会自动隐藏、退回命令行；
- 参数面板顶部可以切 **文生图 / 图生图**：图生图支持点击或拖拽上传参考图，自动缩到最长边
  1280、按 8 对齐，并带「重绘幅度」滑杆；输出尺寸由参考图决定，不再用尺寸下拉框。
  上传后可随时点 **移除参考图** 清空重来，或直接再拖一张覆盖；
- **自动选区（推荐）**：上传参考图后选「自动（衣物）/ 上衣 / 下装 / 连衣裙 / 整套衣物 / 鞋 /
  人物 / 皮肤 / 头发 / 配饰 / 背景」，点一下「自动选区」，分割服务直接生成遮罩
  （CPU 推理约 1 秒），青色高亮就是会被重绘的区域；
  - 识别后每一类变成可点的小标签，显示实测占比（如「上衣 0%」「连衣裙 12.6%」）；
  - **支持多选**：勾几个就取几个的并集（比如「连衣裙 + 人物」一起重绘），再点一次取消；
  - 首次识别会自动挑一个占比最大的衣物类；选了 0% 的类时也会兜底并说明原因
    （传统长袍常被认成「连衣裙」而不是「上衣」）；
- **魔棒补选**：模型漏掉某块（比如下摆、配饰）时，切到魔棒点一下同色区域，把那块并进遮罩；
  容差越大吃进去的颜色越多；
- **手动遮罩**：矩形框选 / 椭圆 / 画笔 / 橡皮随时可以叠加精修；不选则整图重绘；
- **参数预设**：把当前整套参数（模式、提示词、负向、尺寸、步数、CFG、采样器、张数、重绘幅度）
  存成命名配置，存在后端 `data/presets.json` 里，换浏览器也还在；下拉选一个点「应用」即可套用，
  同名再保存会覆盖；
- 顶部显示**当前模型和风格**，参数默认值跟着模型走；
- 预设 chip 按风格分两套（写实偏摄影词，二次元偏 danbooru 标签）；
- 可以调尺寸、步数、CFG、采样器、张数、种子，有负面提示词输入框；
- 结果区是缩略图：**单击下载，双击看原图**；鼠标移上去右上角有 **×** 单条删除，
  右上角还有「清空全部」；最近 12 次结果会存进浏览器的 IndexedDB，**刷新、关掉浏览器再打开都还在**
  （删除会连本地记录一起清；浏览器「清除站点数据」才会全丢）；超出的自动释放内存，磁盘上的
  `outputs/` 文件不受影响——
- 底部有「本地 API 调用示例」，跟着当前模型生成 curl 命令，复制即可用。

### 6.1 切换按钮是怎么工作的

sd.cpp 不支持运行时换模型（`/sdapi/v1/sd-models` 只列出当前加载的那个），所以换模型必须
重建容器。网页按钮走的是这条链路：

```
浏览器 ──POST /manager/switch──> nginx ──> manager 容器 ──> scripts/use-model.sh
                                             │                   │
                                      挂 docker.sock       docker compose 重建 sd-server
```

- `manager` 是个 100 MB 的小镜像（python3 + docker CLI + compose），只做「列出模型 / 触发切换 /
  回报状态」三件事，切换逻辑完全复用 `use-model.sh`，命令行和网页不会出现两套行为；
- `POST /manager/switch` 立即返回 202，网页轮询 `/manager/state` 直到完成，期间禁用生成按钮；
- 切换失败会把 `use-model.sh` 的报错尾部回显到页面状态栏。

⚠️ **安全**：manager 容器挂载了 `/var/run/docker.sock`，等于宿主机 root。它的端口只发布到
`127.0.0.1:18235`，但网页端口 18080 上的 `/manager/*` 是通的——如果你把 18080 暴露到局域网，
别人也能触发模型切换（接口只接受固定的 real/anime，不能执行任意命令，但仍建议不要对外）。

### 6.2 参数预设的接口

预设存 `data/presets.json`（`.gitignore` 里已忽略），由 manager 读写：

```bash
# 列表
curl -s http://127.0.0.1:18235/presets

# 保存 / 覆盖（name 相同即覆盖）
curl -s -X POST http://127.0.0.1:18235/presets -H 'Content-Type: application/json' -d '{
  "name": "写实人像·竖版",
  "params": {"mode":"txt2img","prompt":"close-up portrait, 85mm","negative":"cartoon",
             "width":832,"height":1216,"steps":28,"cfg":6,"sampler":"euler_a","batch":1}
}'

# 删除
curl -s -X POST http://127.0.0.1:18235/presets/delete \
  -H 'Content-Type: application/json' -d '{"name":"写实人像·竖版"}'
```

服务端只接收白名单字段并做范围夹取（步数 ≤64、CFG 0.1~30、尺寸 ≤4096 等），最多 100 个配置。

### 6.3 实操：换衣服 / 换背景

1. 切到**图生图**，上传原图；
2. 遮罩用 **自动选区**：选「上衣」→ 自动选区，一秒出遮罩，不用手涂；
   要连下装一起换就选「整套衣物」，只换上装就选「上衣」；不准再用框选/画笔修；
3. 提示词要写**完整画面**，不是只写新衣服：
   `full body photograph of a young man in a bright studio, wearing a black leather jacket and blue jeans, plain grey background, natural light`
   —— 只写 "black leather jacket" 会丢掉场景上下文，容易把背景也改坏；
4. 重绘幅度 0.8~0.9（局部要换干净，强度不能低），步数 24~30；
5. 不满意就固定 seed 再调遮罩/提示词，一次只动一个变量。

实测（832×1216 / 24 步 / 强度 0.85）：遮罩内像素差 **62.4**，头部 **1.5**、腿脚 **2.2**——
脸和没涂的地方基本没动。

常见坑：遮罩边界切在衣服中间，会出现「半件新衣」（黑裤子到大腿又变回蓝牛仔）。
要么把整件衣服连边缘一起涂，要么连裤子一起涂、在提示词里写新裤子。



和生图无关，保留原有能力：Mermaid / Graphviz 源码 → SVG/PNG/PDF，带中文字体。

```bash
# 网页：http://127.0.0.1:18080/flowchart.html
# API：
curl -sS -H 'Content-Type: text/plain' --data-binary @examples/cicd.mmd \
     http://127.0.0.1:18000/mermaid/svg -o cicd.svg
```

`{type}`：`mermaid` / `graphviz`，`{format}`：`svg` / `png` / `pdf` / `jpeg`。

## 8. 配置与运维

`.env` 关键项：

| 变量 | 默认 | 说明 |
|---|---|---|
| `SD_MODEL_DIR` / `SD_MODEL_FILE` | `checkpoints` / 当前模型 | 权重位置（相对 `models/`） |
| `SD_STEPS` / `SD_CFG_SCALE` / `SD_SAMPLER` | 28 / 6.0 / euler_a | 默认采样参数 |
| `SD_CLIP_SKIP` | 空（写实）/ `2`（二次元） | CLIP skip |
| `SD_WIDTH` / `SD_HEIGHT` | 1024 / 1024 | 服务端默认尺寸 |
| `SD_CKPT_VAE` | 空 | 可选，覆盖 VAE（文件名在 `models/checkpoints/` 下） |
| `SDCPP_EXTRA_ARGS` | 空 | 追加参数，如 `--vae-tiling` |
| `SDCPP_PORT` / `WEB_PORT` / `DIAGRAM_PORT` / `MANAGER_PORT` | 18234 / 18080 / 18000 / 18235 | 端口 |
| `SEGMENTER_IMAGE` | `image-gen-segmenter:local` | 自动选区的分割镜像（本地构建） |
| `HF_ENDPOINT` | `https://hf-mirror.com` | 分割模型下载源 |
| `SDCPP_HOST` | `0.0.0.0` | 监听地址 |
| `PROJECT_DIR` | 仓库绝对路径（自动写入） | manager 容器按同路径挂载仓库；由 `prepare.sh` / `make` 维护，换目录重跑 `make prepare` |
| `MANAGER_PORT` | 18235 | 控制面端口，只绑 `127.0.0.1` |

常用命令：

```bash
make status       # 容器 + 两个 API + GPU
make test         # 冒烟测试
make gen P="prompt" W=832 H=1216 S=28
make model        # 当前模型 + 已装权重
make model-real / make model-anime
make logs         # 生图日志
make down / make up
```

**四个容易踩的坑（都已在代码里修掉，改配置时注意）：**

1. **单文件挂载的 inode**：`web/nginx.conf`、`scripts/sd-launch.sh` 是单文件只读挂载。
   用编辑器「写新文件 + rename」的方式改它们，容器里看到的还是旧内容。改完要
   `docker compose up -d --force-recreate web`（或 `sd-server`）。
2. **shell 里的同名环境变量会盖掉 `.env`**：`docker compose` 的 `${VAR}` 插值优先读环境变量。
   所以 `sd-server` 的参数改用 `env_file: .env` 注入，不再受当前 shell 影响。
   如果你在 shell 里 `export` 过 `SD_*`，先 `unset` 再操作。
3. **nginx 只解析一次域名**：换模型会重建 `sd-server`、IP 变化，写死 upstream 名字会 502。
   已改成 `resolver 127.0.0.11` + 变量 `proxy_pass`，10 秒内自动跟上。
4. **浏览器缓存静态资源**：改了 `lightbox.js` / `index.html` 但页面行为没变，多半是旧缓存。
   nginx 已对 html/json 发 `no-store`、js/css 发 `no-cache`，并且脚本用 `?v=N` 显式版本号；
   改前端文件时记得把 `index.html` 里的 `?v=` 加一，或者强刷一次（Ctrl/Cmd+Shift+R）。

## 9. 常见问题

**网页 403**：`web/` 下文件不是全局可读，`make perms` 后刷新。

**换模型后网页报 502**：等 `use-model.sh` 打印「就绪」再刷新；若仍 502，看
`docker compose logs sd-server` 是否在反复重启（多半是 `.env` 指向了不存在的权重）。

**页头没有切换按钮**：说明 `/manager/state` 不通。`curl http://127.0.0.1:18080/manager/state`
看返回；常见原因是 manager 镜像没构建（`make build-manager`）、`PROJECT_DIR` 写错，
或 `docker compose logs sd-manager` 里报 `PROJECT_DIR 不对`。

**网页点切换报「切换失败」**：状态栏会带出 `use-model.sh` 的报错尾部；完整日志：
`docker compose logs sd-manager`。切完 `.env` / `model.json` 的属主会被还成当前用户，
如果看到 root 属主说明 chown 那步失败了。

**出图糊 / 结构崩**：先确认分辨率在 832~1024 级别、CFG 5~7、步数 25 以上；写实题材要带
摄影词，否则 Juggernaut 会往插画风飘。

**显存不够（OOM）**：降到 768×1024，或给 `SDCPP_EXTRA_ARGS` 加 `--vae-tiling`。

**下载很慢 / 中断**：`./scripts/download-models.sh` 可重复执行，分片文件 `.partNN` 会续传；
单连接被限速时它已经用 8 线程了。

**许可**：两套权重都是开放权重，但各有使用限制（尤其商用），见第 4 节表格，用的前请看模型卡。
