#!/usr/bin/env bash
# bili-read.sh — 让本机「离线读懂」一个 B 站视频
#
# 给一个 B 站链接（b23.tv 短链 / BV 号 / 完整 URL），产出一份 Markdown：
#   1. 逐字稿  —— 音频全量转写（SenseVoice，本机离线）
#   2. 画面关键帧 —— 下载低码率视频流，本地抽帧 + Apple Vision 画面文字 OCR
#   3. 弹幕    —— x/v1/dm/list.so（raw deflate XML，免登录）
#   4. 热门评论 —— x/v2/reply 旧接口（免登录，只拿热门第一页）
#
# 不登录账号、不把任何内容上传到任何地方 —— 全程本地 CPU 完成。
#
# 用法：
#   ./bili-read.sh https://b23.tv/qIWgzBn
#   ./bili-read.sh BV13cBKBhEob ~/notes
#   ./bili-read.sh --download-model        # 首次使用：下载语音模型（约 240MB）
#
# 环境变量：
#   BILI_MODEL_DIR   指定 SenseVoice 模型目录（已有模型时跳过下载）
#   PIP_INDEX_URL    指定 pip 镜像（默认阿里云，国内直连 PyPI 通常不通）
#   BILI_NO_FRAMES=1    跳过画面关键帧（省下载视频流 + 抽帧 OCR 的时间）
#   BILI_NO_DANMAKU=1   跳过弹幕
#   BILI_NO_COMMENTS=1  跳过评论
#   NODE_BIN         已弃用，保留兼容

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV="$SCRIPT_DIR/.venv"
HELPER="$SCRIPT_DIR/.build/video-helper"
MODEL_DIR="$SCRIPT_DIR/models/sensevoice-onnx"
VAD_PATH="$SCRIPT_DIR/models/silero_vad.onnx"
PIP_INDEX="${PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
MOBILE_UA="Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

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

# ------------------------------------------------------- 0a. 本地文件模式

# 非在线平台通道：给一个本机媒体文件（mp4/mov/m4v/m4a/mp3/wav…）直接走本地识别。
# 用途：抖音、视频号等无法免登录抓取视频流的平台——在手机上「保存到相册」，
# 文件传到电脑后喂给本命令，逐字稿/画面 OCR 引擎与 B 站通道完全一致。
read_local() { # read_local <文件路径> <输出目录>
  local f="$1" out="$2"
  f="$(python3 -c "import os,sys;print(os.path.abspath(sys.argv[1]))" "$f")"
  [ -s "$f" ] || die "本地文件不存在或为空：$f"
  local key
  key="$(basename "$f")"; key="${key%.*}"
  key="$(printf '%s' "$key" | tr '/\\:*?"<>| ' '___________')"
  local w
  w="$(mktemp -d)"
  LOCAL_WORK="$w"  # 全局：EXIT trap 触发时 local 变量已销毁，trap 只能读全局
  cleanup_local() { rm -rf "${LOCAL_WORK:-}"; }
  trap cleanup_local EXIT

  mkdir -p "$out" "$w/out"
  info "本地文件模式：$(basename "$f")"
  build_helper
  ensure_venv

  # 1. 音轨（顺便拿时长）
  "$HELPER" extract "$f" "$w/out" > "$w/extract.json" 2>/dev/null
  grep -q '"ok":true' "$w/extract.json" || die "音轨解码失败：$(head -c 200 "$w/extract.json")"
  local dur
  dur="$(python3 -c "import json;print(json.load(open('$w/extract.json')).get('audio',{}).get('seconds',0))")"
  [ -f "$w/out/audio.wav" ] || die "该文件没有音频轨（无法转写语音）。若是纯视频流（如 B 站 DASH video-only），请换含声音的完整文件。"
  info "时长：${dur%.*} 秒"

  # 2. 关键帧 + 画面 OCR（可选，与 B 站通道同一开关）
  local frame_md=""
  if [ "${BILI_NO_FRAMES:-0}" != "1" ]; then
    local interval
    interval="$(awk "BEGIN{v=$dur/20; print (v<3)?3:v}")"
    "$HELPER" extract "$f" "$w/out" --interval "$interval" --max-frames 25 --ocr \
      > "$w/frames.json" 2>/dev/null || true
    if grep -q '"frameCount":[1-9]' "$w/frames.json" 2>/dev/null; then
      mkdir -p "$out/images/$key"
      cp "$w/out"/f*.png "$out/images/$key/" 2>/dev/null || true
      frame_md="$w/frames.md"
      python3 - "$w/frames.json" "$frame_md" "$key" "$interval" <<'PY'
import json, os, sys
frames = json.load(open(sys.argv[1])).get('frames') or []
out, key, interval = sys.argv[2], sys.argv[3], float(sys.argv[4])
lines = [f'每约 {interval:.0f} 秒抽一帧；画面文字为 Apple Vision 本地 OCR，可能有识别错误。', '']
for fr in frames:
    name = os.path.basename(fr['path'])
    sec = float(fr['t'])
    mm, ss = int(sec) // 60, int(sec) % 60
    lines.append(f'![{mm:02d}:{ss:02d}](images/{key}/{name})')
    text = (fr.get('text') or '').strip()
    if text:
        if len(text) > 200: text = text[:200] + '…'
        lines += ['', '> 画面文字：' + text.replace('\n', ' ／ ')]
    lines.append('')
open(out, 'w', encoding='utf-8').write('\n'.join(lines))
PY
      info "画面关键帧：$(ls "$w/out"/f*.png 2>/dev/null | wc -l | tr -d ' ') 张"
    else
      info "（抽帧失败，跳过画面部分，不影响逐字稿）"
    fi
  fi

  # 3. 语音识别（与 B 站同一引擎）
  info "正在本地识别语音…"
  "$VENV/bin/python" "$SCRIPT_DIR/src/asr.py" "$w/out/audio.wav" --json 2>"$w/asr.log" \
    > "$w/transcript.txt" || { cat "$w/asr.log" >&2; die "语音识别失败"; }
  [ -s "$w/transcript.txt" ] || die "识别结果为空"
  local chars
  chars="$(python3 -c "import sys;print(len(open(sys.argv[1],encoding='utf-8').read().replace(chr(10),'')))" "$w/transcript.txt")"
  info "识别完成：${chars} 字"

  # 4. 落盘
  local o="$out/${key}_本地转写.md"
  {
    printf '%s\n' "# ${key}（本地文件转写）" ''
    printf '%s\n' "- **来源文件**：${f}"
    printf '%s\n' "- **时长**：$(awk "BEGIN{print int($dur/60)}") 分 $(awk "BEGIN{print int($dur%60)}") 秒"
    printf '%s\n' "- **整理时间**：$(date '+%Y-%m-%d %H:%M')"
    printf '%s\n' "- **来源**：语音 SenseVoice + 画面 OCR（Apple Vision），全程本机，转写可能存在同音字错误"
    printf '%s\n' '' '---' '' '## 逐字稿' ''
    cat "$w/transcript.txt"
    if [ -n "$frame_md" ]; then
      printf '%s\n' '' '---' '' '## 画面关键帧' ''
      cat "$frame_md"
    fi
  } > "$o"
  printf '\n已写入：%s\n' "$o"
}

if [ -f "$INPUT" ]; then
  read_local "$INPUT" "$OUTDIR"
  exit 0
fi

# ------------------------------------------------------- 0b. 图文动态（opus）

# B 站除视频外还有「图文动态」（opus，纯文字+图片）。
# 它没有音频可转写，但文字是现成的 —— 直接抓页面 SSR 数据即可，2 秒出全文。
read_opus() { # read_opus <opus_id> <输出目录>
  local oid="$1" out="$2"
  info "识别为图文动态（opus/${oid}），走图文抓取（无需语音识别）"
  local tmp && tmp="$(mktemp -d)"
  local page="$tmp/opus.html"
  curl -sL -m 25 -A "$MOBILE_UA" -c "$tmp/ck" -b "$tmp/ck" \
       -H 'Referer: https://www.bilibili.com' \
       "https://m.bilibili.com/opus/$oid" -o "$page" || die "页面拉取失败"
  local oid_arg="$1"
  python3 - "$page" "$out" "$oid_arg" <<'PY'
import json, os, re, sys, urllib.request

page, out, oid_arg = sys.argv[1], sys.argv[2], sys.argv[3]
html = open(page, encoding='utf-8', errors='ignore').read()
m = re.search(r'window\.__INITIAL_STATE__\s*=\s*(\{.*?\});', html, re.S)
if not m:
    sys.exit('页面里没有 SSR 数据（可能被风控，稍后重试或用完整链接）')
try:
    d = json.loads(m.group(1).replace('undefined', 'null'))
except json.JSONDecodeError as e:
    sys.exit(f'SSR 数据解析失败：{e}')

det = d.get('opus', {}).get('detail')
if not det:
    sys.exit('SSR 数据里找不到 opus.detail（动态可能已被删除）')

title = det.get('title') or ''
author = (det.get('author') or {}).get('name') or ''
if not author:  # 图文动态的作者在 AUTHOR 模块的 module_author.name
    for _m in det.get('modules', []):
        author = (_m.get('module_author') or {}).get('name') or ''
        if author:
            break
imgs_dir = os.path.join(out, 'images')
os.makedirs(imgs_dir, exist_ok=True)

lines = []
if title:
    lines += [f'# {title}', '']
lines.append(f'> 来源：B 站图文动态（opus/{oid_arg}）｜作者：{author or "未知"}｜本机离线抓取，未经云端')
lines.append('')

n_img = 0
for mod in det.get('modules', []):
    mc = mod.get('module_content')
    if mod.get('module_type') == 'MODULE_TYPE_TITLE':
        continue  # 标题已放头部
    if not isinstance(mc, dict):
        continue
    for para in mc.get('paragraphs', []):
        pt = para.get('para_type')
        if pt == 1:  # 文本段落
            txt = ''.join(
                n.get('word', {}).get('words', '')
                for n in para.get('text', {}).get('nodes', [])
            ).strip()
            if txt:
                lines += [txt, '']
        elif pt == 2:  # 图片段落
            for pic in para.get('pic', {}).get('pics', []):
                url = pic.get('url', '')
                if not url:
                    continue
                n_img += 1
                fn = f'img{n_img:02d}.png'
                try:
                    req = urllib.request.Request(url, headers={
                        'User-Agent': 'Mozilla/5.0',
                        'Referer': 'https://www.bilibili.com'})
                    data = urllib.request.urlopen(req, timeout=20).read()
                    open(os.path.join(imgs_dir, fn), 'wb').write(data)
                    lines += [f'![图{n_img}]({fn})', '']
                except Exception as exc:
                    lines += [f'![图{n_img}]({url}) <!-- 下载失败：{exc} -->', '']
if not title:
    # 有的动态标题在正文首段，兜底用页面 <title>
    mt = re.search(r'<title>(.*?)</title>', html)
    if mt:
        fallback = re.sub(r'\s*-\s*哔哩哔哩\s*$', '', mt.group(1).strip())
        lines.insert(0, f'# {fallback}')
        lines.insert(1, '')

body = '\n'.join(lines)
fn = os.path.join(out, '图文笔记.md')
open(fn, 'w', encoding='utf-8').write(body)
chars = len(re.sub(r'\s', '', body))
print(f'完成：{chars} 字 / {n_img} 张图 -> {fn}')
PY
  rm -rf "$tmp"
}

# ---------------------------------------------------------------- 1. 拿 BV 号

BV=""
case "$INPUT" in
  *b23.tv*|*bilibili.com*)
    FINAL="$(curl -sIL -m 20 -o /dev/null -w '%{url_effective}' "$INPUT" || true)"
    BV="$(printf '%s' "$FINAL" | grep -oE 'BV[0-9A-Za-z]{10}' | head -1 || true)"
    ;;
esac
OPUS_ID="$(printf '%s' "${FINAL:-}" | grep -oE 'opus/[0-9]+' | head -1 | cut -d/ -f2 || true)"
[ -n "$OPUS_ID" ] || OPUS_ID="$(printf '%s' "$INPUT" | grep -oE 'opus/[0-9]+' | head -1 | cut -d/ -f2 || true)"
if [ -n "$OPUS_ID" ]; then
  mkdir -p "$OUTDIR"
  read_opus "$OPUS_ID" "$OUTDIR"
  exit 0
fi

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

# ------------------------------------------------- 4b. 视频流 + 画面关键帧

# 抽帧策略（BILI_NO_FRAMES=1 可关）：
#   ≤30 分钟的视频选 avc1 480p（OCR 清楚）；更长的选全池最低码率（省流量）。
#   帧数目标 ~20 张：interval = max(3s, 时长/20)。
FRAME_MD=""
if [ "${BILI_NO_FRAMES:-0}" != "1" ]; then
  VIDEO_URL="$(python3 - "$WORK/playurl.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
vids = ((d.get('data') or {}).get('dash') or {}).get('video') or []
if not vids: raise SystemExit
avc = [v for v in vids if v.get('codecs', '').startswith('avc1')]
pool = avc if avc else vids
pool.sort(key=lambda v: v['bandwidth'])
pick = next((v for v in pool if v['id'] == 32), pool[0])  # avc1 480p 优先
print(pick['baseUrl'])
PY
)"
  if [ -n "$VIDEO_URL" ]; then
    info "正在下载视频流（仅用于抽帧）…"
    if curl -s -L -m 300 "$VIDEO_URL" -H "User-Agent: $UA" \
         -H "Referer: https://www.bilibili.com/video/$BV" -o "$WORK/video.m4s" \
       && [ -s "$WORK/video.m4s" ]; then
      mv "$WORK/video.m4s" "$WORK/video.mp4"
      INTERVAL="$(awk "BEGIN{v=$DUR/20; print (v<3)?3:v}")"
      "$HELPER" extract "$WORK/video.mp4" "$WORK/out" --interval "$INTERVAL" \
        --max-frames 25 --ocr > "$WORK/frames.json" 2>/dev/null || true
      if grep -q '"ok":true' "$WORK/frames.json" 2>/dev/null \
         && grep -q '"frameCount":[1-9]' "$WORK/frames.json" 2>/dev/null; then
        mkdir -p "$OUTDIR/images/$BV"
        cp "$WORK/out"/f*.png "$OUTDIR/images/$BV/" 2>/dev/null || true
        FRAME_MD="$WORK/frames.md"
        python3 - "$WORK/frames.json" "$FRAME_MD" "$BV" "$INTERVAL" <<'PY'
import json, os, sys
frames = json.load(open(sys.argv[1])).get('frames') or []
bv, out, interval = sys.argv[3], sys.argv[2], float(sys.argv[4])
lines = [f'每约 {interval:.0f} 秒抽一帧；画面文字为 Apple Vision 本地 OCR，可能有识别错误。', '']
for f in frames:
    name = os.path.basename(f['path'])
    sec = float(f['t'])
    mm, ss = int(sec) // 60, int(sec) % 60
    lines.append(f'![{mm:02d}:{ss:02d}](images/{bv}/{name})')
    text = (f.get('text') or '').strip()
    if text:
        if len(text) > 200: text = text[:200] + '…'
        lines.append('')
        lines.append(f'> 画面文字：' + text.replace('\n', ' ／ '))
    lines.append('')
open(out, 'w', encoding='utf-8').write('\n'.join(lines))
PY
        info "画面关键帧：$(ls "$WORK/out"/f*.png 2>/dev/null | wc -l | tr -d ' ') 张（含画面文字 OCR）"
      else
        info "（抽帧失败，跳过画面部分，不影响逐字稿）"
      fi
    else
      info "（视频流下载失败，跳过画面部分，不影响逐字稿）"
    fi
  else
    info "（没拿到视频流，跳过画面部分）"
  fi
fi

# ------------------------------------------------------- 4c. 弹幕

# x/v1/dm/list.so 返回 raw deflate 压缩的 XML（实测 wbits=-15 解压），
# 全量弹幕做「时间桶 + 刷屏统计」两级聚合，避免长视频刷屏把 md 撑爆。
DANMAKU_MD=""
if [ "${BILI_NO_DANMAKU:-0}" != "1" ]; then
  curl -s -m 30 "https://api.bilibili.com/x/v1/dm/list.so?oid=$CID" \
    -H "User-Agent: $UA" -H "Referer: https://www.bilibili.com" -o "$WORK/dm.so" || true
  if [ -s "$WORK/dm.so" ]; then
    DANMAKU_MD="$WORK/danmaku.md"
    python3 - "$WORK/dm.so" "$DANMAKU_MD" <<'PY' || DANMAKU_MD=""
import re, sys, zlib, json
from collections import Counter
from html import unescape
raw = open(sys.argv[1], 'rb').read()
try:
    xml = zlib.decompress(raw, -15).decode('utf-8')
except Exception:
    sys.exit('弹幕数据解压失败')  # 接口变了或返回风控，直接跳过
ds = sorted((float(p.split(',')[0]), unescape(t))
            for p, t in re.findall(r'<d p="([^"]+)">([^<]+)</d>', xml))
if not ds:
    open(sys.argv[2], 'w').write('')
    raise SystemExit
total = len(ds)
lines = [f'共抓到 **{total}** 条弹幕（免登录接口，分段拉全量未做）。', '']
burst = [(t, c) for t, c in Counter(t for _, t in ds).most_common(8) if c >= 3]
if burst:
    lines += ['**刷屏弹幕**：' + '、'.join(f'「{t}」×{c}' for t, c in burst), '']
lines += ['**时间轴**（每 30 秒一桶，桶内去重）', '']
for b in sorted({int(t // 30) for t, _ in ds}):
    texts = [x for tm, x in ds if int(tm // 30) == b]
    uniq = list(dict.fromkeys(texts))
    mm, ss = b * 30 // 60, b * 30 % 60
    more = f' …等{len(texts)}条' if len(texts) > 5 else ''
    lines.append(f'- [{mm:02d}:{ss:02d}] ' + '、'.join(uniq[:5]) + more)
    if sum(len(l) for l in lines) > 20000:
        lines.append('- （后段弹幕过长已截断）')
        break
open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(lines))
PY
    [ -n "$DANMAKU_MD" ] && [ -s "$DANMAKU_MD" ] && info "弹幕：已抓取并聚合" || DANMAKU_MD=""
  fi
fi

# ------------------------------------------------------- 4d. 热门评论

# 旧接口 x/v2/reply 免登录可用但只给第一页热门（x/v2/reply/main 有 -352 风控）。
COMMENTS_MD=""
if [ "${BILI_NO_COMMENTS:-0}" != "1" ]; then
  AID="$(python3 -c "import json;print(json.load(open('$WORK/view.json'))['data']['aid'])" 2>/dev/null || true)"
  if [ -n "$AID" ]; then
    curl -s -m 25 "https://api.bilibili.com/x/v2/reply?type=1&oid=$AID&pn=1&ps=20&sort=1" \
      -H "User-Agent: $UA" -H "Referer: https://www.bilibili.com" -o "$WORK/reply.json" || true
    if [ -s "$WORK/reply.json" ]; then
      COMMENTS_MD="$WORK/comments.md"
      python3 - "$WORK/reply.json" "$COMMENTS_MD" <<'PY' || COMMENTS_MD=""
import json, sys
d = json.load(open(sys.argv[1]))
if d.get('code') != 0:
    raise SystemExit('评论接口返回 ' + str(d.get('code')))
data = d.get('data') or {}
reps = data.get('replies') or []
if not reps:
    open(sys.argv[2], 'w').write('')
    raise SystemExit
total = (data.get('page') or {}).get('count') or len(reps)
out = [f'共 **{total}** 条，本机只取热门前 {len(reps)} 条（免登录拿不到全部）：', '']
for r in reps[:15]:
    name = (r.get('member') or {}).get('uname', '?')
    like = r.get('like', 0)
    msg = ((r.get('content') or {}).get('message') or '').strip().replace('\n', ' ')
    if len(msg) > 120: msg = msg[:120] + '…'
    out += [f'> **{name}**（赞 {like}）：{msg}', '']
open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(out))
PY
      [ -n "$COMMENTS_MD" ] && [ -s "$COMMENTS_MD" ] && info "评论：已抓热门页" || COMMENTS_MD=""
    fi
  fi
fi

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
  printf '%s\n' "- **来源**：语音 SenseVoice + 画面 OCR（Apple Vision）+ 弹幕/评论（B 站公开接口），全程本机免登录，转写可能存在同音字错误"
  printf '%s\n' '' '---' '' '## 逐字稿' ''
  cat "$WORK/transcript.txt"
  if [ -n "$FRAME_MD" ]; then
    printf '%s\n' '' '---' '' '## 画面关键帧' ''
    cat "$FRAME_MD"
  fi
  if [ -n "$DANMAKU_MD" ]; then
    printf '%s\n' '' '---' '' '## 弹幕' ''
    cat "$DANMAKU_MD"
  fi
  if [ -n "$COMMENTS_MD" ]; then
    printf '%s\n' '' '---' '' '## 热门评论' ''
    cat "$COMMENTS_MD"
  fi
} > "$OUT"

printf '\n已写入：%s\n' "$OUT"
