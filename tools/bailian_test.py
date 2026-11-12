#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
阿里云百炼（DashScope）实时 ASR / TTS 独立验证脚本（不依赖 CallCaption）

官方 API Key 与 base URL：
  - OpenAI-compatible chat：https://dashscope.aliyuncs.com/compatible-mode/v1
  - 实时 ASR/TTS：同一个 Key，走 DashScope SDK / wss://.../api-ws/v1/inference
本脚本用官方 DashScope Python SDK，区域默认北京 cn-beijing。

安装：
  pip install -U dashscope

准备：
  set DASHSCOPE_API_KEY=...
  rem 如果控制台提示业务空间，填业务空间 ID；没有就留空
  set DASHSCOPE_WORKSPACE=...

ASR：
  python tools\bailian_test.py asr --wav remote16k.wav --lang en --chunk-ms 100
  python tools\bailian_test.py asr --wav local16k.wav  --lang zh --chunk-ms 100

TTS：
  python tools\bailian_test.py tts --text "你好，这是百炼语音合成测试。" --out bailian_zh.wav
  python tools\bailian_test.py tts --text "Hello, this is a Bailian TTS test." --out bailian_en.wav --voice longanyang

注意：不要把 API Key 发到聊天或提交仓库。
"""

import argparse
import os
import sys
import threading
import time
import wave

try:
    import dashscope
except ImportError:
    print("缺少 dashscope，请先执行：pip install -U dashscope")
    sys.exit(2)


def make_client(args):
    key = (args.api_key or os.environ.get("DASHSCOPE_API_KEY", "")).strip()
    if not key:
        raise SystemExit("需要 DASHSCOPE_API_KEY / --api-key")
    workspace = (args.workspace or
                 os.environ.get("DASHSCOPE_WORKSPACE", "")).strip()
    kwargs = {"api_key": key, "region": args.region}
    if workspace:
        kwargs["workspace"] = workspace
    return dashscope.Client(**kwargs)


def read_wav_16k(path):
    with wave.open(path, "rb") as w:
        ch = w.getnchannels()
        width = w.getsampwidth()
        rate = w.getframerate()
        frames = w.readframes(w.getnframes())
    if ch != 1 or width != 2 or rate != 16000:
        raise SystemExit("WAV 必须是 16kHz / mono / 16-bit，当前：%dHz ch=%d "
                         "width=%d" % (rate, ch, width))
    return frames


def asr(args):
    client = make_client(args)
    frames = read_wav_16k(args.wav)
    print("[asr] wav=%s bytes=%d lang=%s chunk=%dms region=%s" %
          (args.wav, len(frames), args.lang, args.chunk_ms, args.region))

    audio_at = [0.0]
    first_partial = [0.0]
    finals = []
    done = threading.Event()

    def receive(rec):
        try:
            for event in rec.events():
                try:
                    payload = event.get("payload") or {}
                    output = payload.get("output") or {}
                    sentence = output.get("sentence") or {}
                    text = sentence.get("text") or ""
                    if sentence.get("heartbeat"):
                        continue
                    if text and not first_partial[0] and audio_at[0]:
                        first_partial[0] = time.time()
                        print("[asr] first partial +%.3fs: %s" %
                              (first_partial[0] - audio_at[0], text))
                    elif text and not sentence.get("sentence_end"):
                        print("[asr] partial: %s" % text)
                    if sentence.get("sentence_end"):
                        if text:
                            print("[asr] final +%.3fs: %s" %
                                  (time.time() - audio_at[0], text))
                            finals.append(text)
                        else:
                            print("[asr] final (empty)")
                except Exception as e:
                    print("[asr] event parse exc: %s" % e)
        except Exception as e:
            print("[asr] receive exc: %s" % e)
        finally:
            done.set()

    hints = ["zh", "en"] if args.lang == "both" else [args.lang]
    rec = client.audio.asr.recognize(
        model=args.model,
        format="pcm",
        sample_rate=16000,
        parameters={
            "language_hints": hints,
            "max_sentence_silence": args.max_silence,
        },
    )
    with rec:
        th = threading.Thread(target=receive, args=(rec,), daemon=True)
        th.start()
        chunk_bytes = max(3200, int(16000 * 2 * args.chunk_ms / 1000))
        chunk_bytes -= chunk_bytes % 2
        interval = args.chunk_ms / 1000.0
        audio_at[0] = time.time()
        sent = 0
        next_at = time.time()
        while sent < len(frames):
            part = frames[sent:sent + chunk_bytes]
            if not part:
                break
            rec.send_audio_frame(part)
            sent += len(part)
            next_at += interval
            delay = next_at - time.time()
            if delay > 0:
                time.sleep(delay)
        print("[asr] audio sent %.2fs, stop..." %
              (time.time() - audio_at[0]))
        rec.stop()
        th.join(20)
        try:
            rec.close()
        except Exception:
            pass
    try:
        print("[asr] request_id=%s first_package_delay=%s last_package_delay=%s" %
              (getattr(rec, "request_id", "?"),
               getattr(rec, "first_package_delay", "?"),
               getattr(rec, "last_package_delay", "?")))
    except Exception:
        pass
    print("\n[asr] finals:")
    for x in finals:
        print("  - %s" % x)
    return 0 if finals else 4


def tts(args):
    client = make_client(args)
    print("[tts] model=%s voice=%s text=%d chars" %
          (args.model, args.voice, len(args.text)))
    audio = client.audio.tts.synthesize(
        args.text,
        model=args.model,
        voice=args.voice,
        format=args.format,
        sample_rate=args.sample_rate,
    )
    if not audio:
        raise SystemExit("TTS 返回空")
    with open(args.out, "wb") as f:
        f.write(audio)
    print("[tts] saved %s (%d bytes)" % (args.out, len(audio)))
    return 0


def main():
    ap = argparse.ArgumentParser(description="阿里云百炼 ASR/TTS 验证")
    ap.add_argument("--api-key", default="",
                    help="DashScope API Key；或用 DASHSCOPE_API_KEY")
    ap.add_argument("--workspace", default="",
                    help="业务空间 ID；或用 DASHSCOPE_WORKSPACE")
    ap.add_argument("--region", default=os.environ.get("DASHSCOPE_REGION", "cn-beijing"))
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("asr")
    a.add_argument("--wav", required=True)
    a.add_argument("--lang", default="zh", choices=["zh", "en", "both"])
    a.add_argument("--model", default="paraformer-realtime-v2")
    a.add_argument("--chunk-ms", type=int, default=100, choices=[100, 200])
    a.add_argument("--max-silence", type=int, default=600)
    a.set_defaults(func=asr)

    t = sub.add_parser("tts")
    t.add_argument("--text", required=True)
    t.add_argument("--model", default="cosyvoice-v3-flash")
    t.add_argument("--voice", default="longanyang")
    t.add_argument("--format", default="wav", choices=["wav", "mp3", "pcm"])
    t.add_argument("--sample-rate", type=int, default=48000)
    t.add_argument("--out", default="bailian_tts.wav")
    t.set_defaults(func=tts)

    args = ap.parse_args()
    try:
        return args.func(args)
    except Exception as e:
        print("[error] %s: %s" % (type(e).__name__, e))
        return 8


if __name__ == "__main__":
    sys.exit(main())
