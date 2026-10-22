#!/usr/bin/env bash
# bili-read.sh — 让本机「离线读懂」一个 B 站视频
#
# 给一个 B 站链接（b23.tv 短链 / BV 号 / 完整 URL），把视频语音全部转成文字，
# 连带标题、简介、UP 主、时长一起写成一份 Markdown。
#
# 不下载画面、不登录账号、不把音频上传到任何地方 —— 全程本地 CPU 完成。
#
# 用法：
#   ./bili-read.sh https://b23.tv/qIWgzBn
#   ./bili-read.sh BV13cBKBhEob ~/notes
#   ./bili-read.sh --download-model        # 首次使用：下载语音模型（约 240MB）
#
# 环境变量：
#   BILI_MODEL_DIR   指定 SenseVoice 模型目录（已有模型时跳过下载）
#   PIP_INDEX_URL    指定 pip 镜像（默认阿里云，国内直连 PyPI 通常不通）
#   NODE_BIN         已弃用，保留兼容

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV="$SCRIPT_DIR/.venv"
HELPER="$SCRIPT_DIR/.build/video-helper"
MODEL_DIR="$SCRIPT_DIR/models/sensevoice-onnx"
VAD_PATH="$SCRIPT_DIR/models/silero_vad.onnx"
PIP_INDEX="${PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

die() { printf '错误：%s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1"; }

# 模型文件直链：优先国内镜像（huggingface.co 在国内多数网络下不可达）
HF_REPO="csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
HF_MIRROR="${HF_MIRROR:-https://hf-mirror.com/$HF_REPO/resolve/main}"
HF_OFFICIAL="https://huggingface.co/$HF_REPO/resolve/main"
VAD_URLS="
https://hf-mirror.com/deepghs/silero-vad-onnx/resolve/main/silero_vad.onnx
https://hf-mirror.com/onnx-community/silero-vad/resolve/main/onnx/model.onnx
https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
"

fetch() { # fetch <url> <dest> <描述>
  local url="$1" dest="$2" label="$3"
  info "  下载 $label …"
  # --http1.1：GitHub Releases 走 HTTP/2 时常报 "Error in the HTTP2 framing layer"（curl 16）
  if curl -fL --progress-bar --http1.1 --connect-timeout 15 --retry 3 --retry-delay 2 \
       -o "$dest.part" "$url"; then
    mv "$dest.part" "$dest"
    return 0
  fi
  rm -f "$dest.part"
  return 1
}

download_model() {
  mkdir -p "$MODEL_DIR" "$(dirname "$VAD_PATH")"

  if [ -f "$MODEL_DIR/model.int8.onnx" ] && [ -f "$MODEL_DIR/tokens.txt" ]; then
    info "主模型已存在：$MODEL_DIR"
  else
    info "开始下载 SenseVoice 模型（约 240MB，只需一次）…"
    local ok=0
    for base in "$HF_MIRROR" "$HF_OFFICIAL"; do
      if fetch "$base/model.int8.onnx" "$MODEL_DIR/model.int8.onnx" "model.int8.onnx"; then
        fetch "$base/tokens.txt" "$MODEL_DIR/tokens.txt" "tokens.txt" || continue
        ok=1; break
      fi
    done
    [ "$ok" = 1 ] || die "模型下载失败。可手动下载后放到 $MODEL_DIR/
  $HF_MIRROR/model.int8.onnx
  $HF_MIRROR/tokens.txt"
  fi

  # VAD 是独立文件，即使主模型已存在也要单独补齐。
  # GitHub Releases 在国内常被墙（实测连接失败 / 502），所以把 HF 镜像放在前面。
  if [ ! -f "$VAD_PATH" ]; then
    local got_vad=0
    for vurl in $VAD_URLS; do
      if fetch "$vurl" "$VAD_PATH" "silero_vad.onnx"; then got_vad=1; break; fi
    done
    [ "$got_vad" = 1 ] \
      || info "  （VAD 模型下载失败，将退回固定 20 秒切窗，识别质量略有下降）"
  fi
  info "模型就绪：$MODEL_DIR"
}

ensure_venv() {
  if [ -x "$VENV/bin/python" ]; then
    return 0
  fi
  info "首次运行：创建 Python 环境并安装识别引擎（只需一次）…"
  command -v python3 >/dev/null 2>&1 || die "找不到 python3"
  python3 -m venv "$VENV" || die "创建虚拟环境失败"
  # 国内直连 PyPI 常常超时（实测 25s 未响应），所以默认走镜像
  "$VENV/bin/pip" install --quiet --disable-pip-version-check \
    -i "$PIP_INDEX" --trusted-host "$(printf '%s' "$PIP_INDEX" | awk -F/ '{print $3}')" \
    sherpa-onnx 2>/dev/null \
    || "$VENV/bin/pip" install --quiet --disable-pip-version-check sherpa-onnx \
    || die "安装 sherpa-onnx 失败。请检查网络，或用 PIP_INDEX_URL 指定可用镜像"
  "$VENV/bin/python" -c "import sherpa_onnx" || die "sherpa-onnx 安装后无法导入"
}

build_helper() {
  if [ -x "$HELPER" ] && [ "$HELPER" -nt "$SCRIPT_DIR/src/video-helper.swift" ]; then
    return 0
  fi
  info "编译音轨解码器（只需一次）…"
  command -v swiftc >/dev/null 2>&1 || die "缺少 swiftc：请先运行 xcode-select --install"
  mkdir -p "$(dirname "$HELPER")"
  swiftc -O -o "$HELPER" "$SCRIPT_DIR/src/video-helper.swift" 2>/dev/null \
    || die "音轨解码器编译失败"
}

# ---------------------------------------------------------------- 参数

if [ "${1:-}" = "--download-model" ]; then
  download_model
  exit 0
fi
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

INPUT="$1"
OUTDIR="${2:-$PWD}"

for bin in curl python3; do
  command -v "$bin" >/dev/null 2>&1 || die "缺少依赖：$bin"
done

# ---------------------------------------------------------------- 1. 拿 BV 号

BV=""
case "$INPUT" in
  *b23.tv*|*bilibili.com*)
    FINAL="$(curl -sIL -m 20 -o /dev/null -w '%{url_effective}' "$INPUT" || true)"
    BV="$(printf '%s' "$FINAL" | grep -oE 'BV[0-9A-Za-z]{10}' | head -1 || true)"
    ;;
esac
[ -n "$BV" ] || BV="$(printf '%s' "$INPUT" | grep -oE 'BV[0-9A-Za-z]{10}' | head -1 || true)"
[ -n "$BV" ] || die "没能从输入里认出 BV 号（若短链已失效，请直接给完整视频地址）"
info "视频编号：$BV"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------- 2. 元数据

curl -s "https://api.bilibili.com/x/web-interface/view?bvid=$BV" \
  -H "User-Agent: $UA" -H 'Referer: https://www.bilibili.com' -o "$WORK/view.json"

META="$(python3 - "$WORK/view.json" <<'PY'
import json, sys, re
d = json.load(open(sys.argv[1]))
if d.get('code') != 0:
    print('ERR'); print(d.get('message')); raise SystemExit
x = d['data']
def clean(s): return re.sub(r'[\t\r]+', ' ', (s or '').strip())
print('OK')
print(x['title'].replace('\t', ' '))
print(x['cid'])
print(x['duration'])
print((x.get('owner') or {}).get('name', ''))
print(clean(x.get('desc', '')).replace('\n', ' / '))
PY
)"
[ "$(printf '%s' "$META" | head -1)" = "OK" ] || die "取视频信息失败：$(printf '%s' "$META" | sed -n '2p')"

TITLE="$(printf '%s' "$META" | sed -n '2p')"
CID="$(printf '%s' "$META" | sed -n '3p')"
DUR="$(printf '%s' "$META" | sed -n '4p')"
OWNER="$(printf '%s' "$META" | sed -n '5p')"
DESC="$(printf '%s' "$META" | sed -n '6p')"
info "标题：$TITLE"
info "UP主：$OWNER    时长：$((DUR / 60))分$((DUR % 60))秒"

# ---------------------------------------------------------------- 3. 音频流

curl -s "https://api.bilibili.com/x/player/playurl?bvid=$BV&cid=$CID&fnval=16&fnver=0&fourk=1" \
  -H "User-Agent: $UA" -H "Referer: https://www.bilibili.com/video/$BV" -o "$WORK/playurl.json"

AUDIO_URL="$(python3 - "$WORK/playurl.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
auds = ((d.get('data') or {}).get('dash') or {}).get('audio') or []
if not auds: raise SystemExit
auds.sort(key=lambda a: a['bandwidth'])   # 最低码率：转写够用，文件最小
print(auds[0]['baseUrl'])
PY
)"
[ -n "$AUDIO_URL" ] || die "没拿到音频流（可能是番剧/课程等受限内容，需要登录）"

info "正在下载音频…"
# UA 和 Referer 缺一不可，否则 CDN 返回 403
curl -s -L "$AUDIO_URL" -H "User-Agent: $UA" \
  -H "Referer: https://www.bilibili.com/video/$BV" -o "$WORK/audio.m4s"
# 关键：AVFoundation 不认 .m4s 扩展名，必须改成 .mp4 才肯打开
mv "$WORK/audio.m4s" "$WORK/audio.mp4"
info "音频大小：$(du -h "$WORK/audio.mp4" | cut -f1)"

# ---------------------------------------------------------------- 4. 解码音轨

build_helper
info "正在解码音轨…"
mkdir -p "$WORK/out"
"$HELPER" extract "$WORK/audio.mp4" "$WORK/out" > "$WORK/extract.json" 2>/dev/null
grep -q '"ok":true' "$WORK/extract.json" || die "音轨解码失败：$(cat "$WORK/extract.json")"
[ -f "$WORK/out/audio.wav" ] || die "没有得到音频波形文件"

# ---------------------------------------------------------------- 5. 本地识别

ensure_venv
info "正在本地识别语音…"
"$VENV/bin/python" "$SCRIPT_DIR/src/asr.py" "$WORK/out/audio.wav" --json 2>"$WORK/asr.log" \
  > "$WORK/transcript.txt" || { cat "$WORK/asr.log" >&2; die "语音识别失败"; }
grep '^\[asr\]' "$WORK/asr.log" >&2 || true

[ -s "$WORK/transcript.txt" ] || die "识别结果为空"
CHARS="$(python3 -c "import sys;print(len(open(sys.argv[1],encoding='utf-8').read().replace(chr(10),'')))" "$WORK/transcript.txt")"
info "识别完成：${CHARS} 字"

# ---------------------------------------------------------------- 6. 落盘

mkdir -p "$OUTDIR"
SAFE_TITLE="$(printf '%s' "$TITLE" | tr '/\\:*?"<>| ' '___________')"
OUT="$OUTDIR/${BV}_${SAFE_TITLE}.md"

{
  printf '%s\n' "# $TITLE" ''
  # 注意：macOS 自带 bash 3.2 的 printf 不认 `--` 选项终止符，
  # 格式串以 `-` 开头时必须走「格式串放 %s 里」这条安全写法。
  printf '%s\n' "- **UP 主**：$OWNER"
  printf '%s\n' "- **时长**：$((DUR / 60)) 分 $((DUR % 60)) 秒"
  printf '%s\n' "- **链接**：https://www.bilibili.com/video/$BV"
  printf '%s\n' "- **简介**：$DESC"
  printf '%s\n' "- **整理时间**：$(date '+%Y-%m-%d %H:%M')"
  printf '%s\n' "- **来源**：本机离线语音识别（SenseVoice），未经过云端，可能存在个别同音字错误"
  printf '%s\n' '' '---' '' '## 逐字稿' ''
  cat "$WORK/transcript.txt"
} > "$OUT"

printf '\n已写入：%s\n' "$OUT"
