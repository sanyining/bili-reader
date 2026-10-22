#!/usr/bin/env python3
"""asr.py — 本地 SenseVoice 语音转写（独立版）

不依赖任何私有项目：只需要 `pip install sherpa-onnx` 和一个 SenseVoice 模型目录。

用法：
    python asr.py <音频.wav> [--model-dir DIR] [--vad-model PATH] [--json]

输出：正文写 stdout，统计信息写 stderr。

为什么要有 VAD 切分：SenseVoice 单段超过 30 秒准确率会下降，而且长音频一次性喂进去
容易在中间丢字。按静音切段、逐段识别再拼接，是「不漏句」的关键。
"""

from __future__ import annotations

import argparse
import array
import json
import os
import sys
import time
import wave

import sherpa_onnx

TARGET_RATE = 16000
VAD_WINDOW = 512          # Silero VAD 必须按 window_size 分块喂
MIN_SILENCE = 0.6         # 只在真正的段落停顿处切；0.25 会在每个词间切碎
MIN_SPEECH = 0.25
MAX_SPEECH = 25           # SenseVoice 对 30 秒内片段最准
FALLBACK_WINDOW_SEC = 20  # 没有 VAD 模型时的固定切窗


def log(msg: str) -> None:
    print(f"[asr] {msg}", file=sys.stderr)


def die(msg: str) -> None:
    print(f"[asr] 错误：{msg}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------- 模型发现

def _home(*parts: str) -> str:
    return os.path.join(os.path.expanduser("~"), *parts)


def find_model_dir(explicit: str | None) -> str:
    """按优先级找一个可用的 SenseVoice 模型目录（含 model.int8.onnx + tokens.txt）。"""
    cands: list[str] = []
    if explicit:
        cands.append(explicit)
    env = os.environ.get("BILI_MODEL_DIR")
    if env:
        cands.append(env)
    here = os.path.dirname(os.path.abspath(__file__))
    cands += [
        os.path.join(os.path.dirname(here), "models", "sensevoice-onnx"),
        # 本机已有 DSH 安装时直接复用，免去 240MB 下载
        _home(".dsh", "speech-to-text", "sensevoice", "models", "sensevoice-onnx"),
        os.path.join(os.path.dirname(here), "models",
                     "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"),
    ]
    for d in cands:
        if d and os.path.isfile(os.path.join(d, "model.int8.onnx")) \
           and os.path.isfile(os.path.join(d, "tokens.txt")):
            return d
    die(
        "找不到 SenseVoice 模型。请任选一种方式：\n"
        "  1) 把模型放到 models/sensevoice-onnx/（需含 model.int8.onnx 和 tokens.txt）\n"
        "  2) 设置环境变量 BILI_MODEL_DIR=/path/to/model-dir\n"
        "  3) 运行 ./bili-read.sh --download-model 自动下载\n"
        f"已查找的路径：{chr(10).join('  - ' + c for c in cands if c)}"
    )
    raise AssertionError  # 让类型检查知道这里不会返回


def find_vad_model(model_dir: str, explicit: str | None) -> str | None:
    cands = [explicit] if explicit else []
    cands += [
        os.path.join(os.path.dirname(model_dir), "silero", "silero_vad.onnx"),
        os.path.join(model_dir, "silero_vad.onnx"),
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "models", "silero_vad.onnx"),
    ]
    for p in cands:
        if p and os.path.isfile(p):
            return p
    return None


# ---------------------------------------------------------------- WAV 读取

def load_wav(path: str) -> tuple[int, array.array]:
    """返回 (采样率, 16-bit 单声道 PCM)。非 16k/多声道时做降混与线性重采样。"""
    try:
        with wave.open(path, "rb") as w:
            nch, width, rate, nframes = (
                w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes())
            raw = w.readframes(nframes)
    except wave.Error as exc:
        die(f"不是可读的 WAV 文件：{path}（{exc}）")

    if width != 2:
        die(f"只支持 16-bit PCM，当前位宽 {width * 8} bit")

    samples = array.array("h")
    samples.frombytes(raw)
    if sys.byteorder == "big":
        samples.byteswap()

    if nch > 1:  # 降混成单声道
        samples = array.array("h", samples[::nch])

    if rate != TARGET_RATE:  # 线性重采样到 16k
        n_out = int(len(samples) * TARGET_RATE / rate)
        step = rate / TARGET_RATE
        resampled = array.array("h", bytes(n_out * 2))
        for i in range(n_out):
            resampled[i] = samples[int(i * step)]
        samples, rate = resampled, TARGET_RATE

    return rate, samples


def float_chunks(samples: array.array, size: int, scale: float = 1 / 32768):
    """把 PCM 切成浮点块，逐块产出（避免一次性构造巨大的 Python 列表）。"""
    for i in range(0, len(samples), size):
        yield [s * scale for s in samples[i:i + size]]


# ---------------------------------------------------------------- 主流程

def main() -> None:
    ap = argparse.ArgumentParser(description="本地 SenseVoice 转写")
    ap.add_argument("wav")
    ap.add_argument("--model-dir")
    ap.add_argument("--vad-model")
    ap.add_argument("--threads", type=int, default=0)
    ap.add_argument("--json", action="store_true", help="额外把统计信息以 JSON 打到 stderr")
    args = ap.parse_args()

    t0 = time.time()
    rate, samples = load_wav(args.wav)
    duration = len(samples) / rate
    if duration < 0.5:
        die(f"音频太短（{duration:.2f}s）")

    model_dir = find_model_dir(args.model_dir)
    vad_path = find_vad_model(model_dir, args.vad_model)

    threads = args.threads or max(2, min(4, (os.cpu_count() or 2) - 1))

    log(f"模型：{model_dir}")
    log(f"音频：{duration:.1f}s，{rate} Hz；VAD：{'有' if vad_path else '无（改用固定切窗）'}")

    recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=os.path.join(model_dir, "model.int8.onnx"),
        tokens=os.path.join(model_dir, "tokens.txt"),
        num_threads=threads,
        language="auto",
        use_itn=True,
        debug=False,
        provider="cpu",
    )

    texts: list[str] = []
    seg_count = 0
    failed = 0

    def transcribe_segment(pcm: list[float]) -> None:
        """pcm 为 -1~1 的浮点采样（VAD 输出的就是这个格式）。"""
        nonlocal seg_count, failed
        if not pcm:
            return
        seg_count += 1
        try:
            stream = recognizer.create_stream()
            stream.accept_waveform(rate, pcm)
            recognizer.decode_stream(stream)
            text = (stream.result.text or "").strip()
            if text:
                texts.append(text)
        except Exception as exc:  # 单段失败不该让整篇稿子丢掉
            failed += 1
            log(f"第 {seg_count} 段识别失败：{exc}")

    used_vad = False
    if vad_path:
        cfg = sherpa_onnx.VadModelConfig()
        cfg.silero_vad.model = vad_path
        cfg.silero_vad.threshold = 0.5
        cfg.silero_vad.min_silence_duration = MIN_SILENCE
        cfg.silero_vad.min_speech_duration = MIN_SPEECH
        cfg.silero_vad.max_speech_duration = MAX_SPEECH
        cfg.sample_rate = TARGET_RATE
        cfg.num_threads = 1
        vad = sherpa_onnx.VoiceActivityDetector(cfg, buffer_size_in_seconds=120)

        for chunk in float_chunks(samples, VAD_WINDOW):
            vad.accept_waveform(chunk)
            while not vad.empty():
                seg = vad.front
                pcm = list(seg.samples)
                vad.pop()
                transcribe_segment(pcm)
        vad.flush()
        while not vad.empty():
            seg = vad.front
            pcm = list(seg.samples)
            vad.pop()
            transcribe_segment(pcm)
        used_vad = seg_count > 0

    if not used_vad:  # 没 VAD 或 VAD 一段都没切出来 → 固定窗兜底
        step = FALLBACK_WINDOW_SEC * rate
        for i in range(0, len(samples), step):
            transcribe_segment([s / 32768.0 for s in samples[i:i + step]])

    text = "\n".join(texts)
    elapsed = time.time() - t0

    if args.json:
        print(json.dumps({
            "ok": True, "segments": seg_count, "segmentsFailed": failed,
            "usedVad": used_vad, "audioSeconds": round(duration, 2),
            "elapsedSec": round(elapsed, 2),
            "charCount": len(text.replace("\n", "").replace(" ", "")),
        }, ensure_ascii=False), file=sys.stderr)

    log(f"完成：{seg_count} 段，失败 {failed} 段，用时 {elapsed:.1f}s"
        f"（{duration / max(elapsed, 0.01):.0f}× 实时）")
    print(text)


if __name__ == "__main__":
    main()
