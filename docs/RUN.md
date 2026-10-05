# 运行命令

- 项目：openai/whisper（语音识别 CLI）
- 生成时间：2026-09-08
- 运行方式：直接运行（`uv` + 可编辑安装）
- 硬件评估：**满足**
  - 官方最大模型 `large` 约需 ~10GB 显存；`turbo` ~6GB
  - 本机 RTX 4080 / 16376 MiB；评估时已用约 3.5GB、剩余约 12.8GB，可跑全部官方尺寸
  - 注意：评估时已有其他 `python.exe` 占卡，启动前建议再看一眼 `nvidia-smi`

## 环境准备

```powershell
# ffmpeg（本机已有，会话 PATH）
$env:Path = "E:\Programs\ffmpeg-master-latest-win64-gpl\bin;$env:Path"

# PyPI 官方超时则用清华源（实测：pypi.org 超时，tuna ~400ms）
$env:UV_INDEX_URL = "https://pypi.tuna.tsinghua.edu.cn/simple"

cd E:\AI\local-voice\whisper
uv venv --python 3.11
.\.venv\Scripts\Activate.ps1

# 先装 CUDA 版 torch（Windows 上勿只写 --index-url：uv 可能解析到 +cpu）
# 直接装 cu128 wheel（本机驱动 CUDA 13.x，实测可用）
uv pip install "https://download.pytorch.org/whl/cu128/torch-2.8.0%2Bcu128-cp311-cp311-win_amd64.whl"
uv pip install -e .

# 确认必须是 +cu128 且 True
.\.venv\Scripts\python.exe -c "import torch; print(torch.__version__, torch.cuda.is_available())"
```

模型权重首次运行时从 `openaipublic.azureedge.net` 下载到 `%USERPROFILE%\.cache\whisper`（实测 CDN 可达，无需 HF 镜像）。

## 启动

- 推荐：`pwsh -NoProfile -File .\start.ps1`
- 说明：启动后按提示选模型（默认可选 turbo）；再输入音频路径（回车用 `tests\jfk.flac`）
- 等价手动命令：

```powershell
$env:Path = "E:\Programs\ffmpeg-master-latest-win64-gpl\bin;$env:Path"
cd E:\AI\local-voice\whisper
.\.venv\Scripts\Activate.ps1

# 默认推荐
whisper .\tests\jfk.flac --model turbo --device cuda

# 快速验证（小模型）
whisper .\tests\jfk.flac --model tiny --device cuda

# 高质量
whisper .\tests\jfk.flac --model large --device cuda

# 非英语翻译成英文请用 multilingual 模型（勿用 turbo）
# whisper .\audio.wav --model medium --language Japanese --task translate --device cuda
```

## 验证

1. `.\.venv\Scripts\python.exe -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"` → `True` + `RTX 4080`
2. `whisper .\tests\jfk.flac --model tiny --device cuda` 退出码 0
3. 转录文本应包含类似 `My fellow Americans` / `ask not what your country can do for you` 等 JFK 演讲片段

## 备注

- 端口：无服务端口（纯 CLI）
- Python：勿用系统 3.14；本机用 uv 固定 **3.11**
- 镜像源：`UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple`；torch 用官方 cu128 直链 wheel（约 3.2GiB）
- 已验证：`whisper tests\jfk.flac --model tiny --device cuda` 输出含 *My fellow Americans...*
- ffmpeg：`E:\Programs\ffmpeg-master-latest-win64-gpl\bin`
- 显存占用参考（官方）：tiny/base ~1GB，small ~2GB，medium ~5GB，turbo ~6GB，large ~10GB
- `docs/RUN.md` 与根目录 `start.ps1` 为本机运行材料，默认不提交

## 审计备注（2026-09-09）
- 已修复 editable 映射到 `E:\AI\local-voice\whisper`。
- `start.ps1` 不使用 `whisper.exe` trampoline；将仓库根插入 `sys.path` 后调用 `whisper.transcribe.cli`。
