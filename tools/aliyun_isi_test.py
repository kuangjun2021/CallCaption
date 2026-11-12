#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
阿里云智能语音交互 ISI 独立验证脚本（不依赖 CallCaption 插件）

用途：
  1) 用本地 16k mono s16 WAV 跑实时语音识别，按 100ms/200ms 推流，
     打印首包/每句 final 延迟和文本；
  2) 调 ISI 语音合成 REST，保存 WAV，试听阿里音色。

依赖：
  pip install websocket-client

鉴权：
  - 最省事：从 ISI 控制台拿一个临时 Token（有效期以 ExpireTime 为准，通常 24h）
  - 或者提供 AccessKey ID/Secret，本脚本调用 CreateToken
  - AppKey 来自 ISI 项目；英文项目和中文项目各一个
  - 不要把 AccessKey Secret / Token 发到聊天或提交仓库

示例：
  set ALIYUN_TOKEN=...
  set ALIYUN_APPKEY_EN=...
  set ALIYUN_APPKEY_ZH=...

  python tools\aliyun_isi_test.py asr --wav remote16k.wav --appkey %ALIYUN_APPKEY_EN% --chunk-ms 100
  python tools\aliyun_isi_test.py asr --wav local16k.wav  --appkey %ALIYUN_APPKEY_ZH% --chunk-ms 100
  python tools\aliyun_isi_test.py tts --text "你好，这是阿里云语音合成测试。" --voice xiaoyun --appkey %ALIYUN_APPKEY_ZH% --out aliyun_zh.wav
  python tools\aliyun_isi_test.py tts --text "Hello, this is an Alibaba TTS test." --voice cally --appkey %ALIYUN_APPKEY_EN% --out aliyun_en.wav

如果没有 Token，也可以用 AccessKey：
  set ALIYUN_ACCESS_KEY_ID=...
  set ALIYUN_ACCESS_KEY_SECRET=...
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import threading
import time
import uuid
import urllib.parse
import urllib.request
import wave

REGION_HOST = {
    "cn-shanghai": ("nls-meta.cn-shanghai.aliyuncs.com",
                     "nls-gateway-cn-shanghai.aliyuncs.com"),
    "cn-beijing": ("nls-meta.cn-beijing.aliyuncs.com",
                    "nls-gateway-cn-beijing.aliyuncs.com"),
}


def pct(s):
    # 阿里云 OpenAPI RPC 签名要求 RFC3986；~ 不编码
    return urllib.parse.quote(str(s), safe="~")


def create_token(region, ak_id, ak_secret):
    meta_host, _ = REGION_HOST.get(region, REGION_HOST["cn-shanghai"])
    params = {
        "Action": "CreateToken",
        "Version": "2019-02-28",
        "Format": "JSON",
        "RegionId": region,
        "AccessKeyId": ak_id,
        "SignatureMethod": "HMAC-SHA1",
        "SignatureVersion": "1.0",
        "SignatureNonce": uuid.uuid4().hex,
        "Timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    canon = "&".join("%s=%s" % (pct(k), pct(params[k]))
                     for k in sorted(params))
    string_to_sign = "GET&%2F&" + pct(canon)
    sig = base64.b64encode(
        hmac.new((ak_secret + "&").encode("utf-8"),
                 string_to_sign.encode("utf-8"), hashlib.sha1).digest()
    ).decode("ascii")
    params["Signature"] = sig
    url = "https://%s/?%s" % (meta_host,
                              "&".join("%s=%s" % (pct(k), pct(v))
                                       for k, v in params.items()))
    with urllib.request.urlopen(url, timeout=15) as r:
        body = r.read().decode("utf-8")
    data = json.loads(body)
    token = (data.get("Token") or {}).get("Id")
    expire = (data.get("Token") or {}).get("ExpireTime")
    if not token:
        raise RuntimeError("CreateToken 失败：%s" % body[:400])
    print("[token] ok expire=%s" % expire)
    return token


def get_token(args):
    token = args.token or os.environ.get("ALIYUN_TOKEN", "").strip()
    if token:
        return token
    ak_id = (args.ak_id or os.environ.get("ALIYUN_ACCESS_KEY_ID", "")).strip()
    ak_secret = (args.ak_secret or
                 os.environ.get("ALIYUN_ACCESS_KEY_SECRET", "")).strip()
    if ak_id and ak_secret:
        return create_token(args.region, ak_id, ak_secret)
    raise SystemExit("需要 --token/ALIYUN_TOKEN，或 "
                     "ALIYUN_ACCESS_KEY_ID + ALIYUN_ACCESS_KEY_SECRET")


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


class Reader(threading.Thread):
    def __init__(self, ws, started, completed, result):
        super().__init__(daemon=True)
        self.ws = ws
        self.started = started
        self.completed = completed
        self.result = result
        self.audio_at = 0.0
        self.first_partial_at = 0.0
        self.last_partial = ""
        self.stop = False

    def run(self):
        while not self.stop:
            try:
                msg = self.ws.recv()
            except Exception:
                if self.stop:
                    return
                time.sleep(0.05)
                continue
            if not msg:
                continue
            try:
                obj = json.loads(msg)
            except Exception:
                continue
            h = obj.get("header") or {}
            name = h.get("name") or ""
            status = h.get("status")
            p = obj.get("payload") or {}
            if status and int(status) != 20000000 and name == "TaskFailed":
                print("[task failed] %s" % json.dumps(obj, ensure_ascii=False)[:600])
                self.completed.set()
                return
            if name == "TranscriptionStarted":
                print("[asr] TranscriptionStarted")
                self.started.set()
            elif name == "SentenceBegin":
                print("[asr] SentenceBegin index=%s time=%s" %
                      (p.get("index"), p.get("time")))
            elif name == "TranscriptionResultChanged":
                text = p.get("result") or ""
                if text != self.last_partial:
                    self.last_partial = text
                    if not self.first_partial_at and self.audio_at:
                        self.first_partial_at = time.time()
                        print("[asr] first partial +%.3fs: %s" %
                              (self.first_partial_at - self.audio_at, text))
                    else:
                        print("[asr] partial: %s" % text)
            elif name == "SentenceEnd":
                text = p.get("result") or ""
                if self.audio_at:
                    print("[asr] final +%.3fs: %s" %
                          (time.time() - self.audio_at, text))
                else:
                    print("[asr] final: %s" % text)
                if text:
                    self.result.append(text)
            elif name == "TranscriptionCompleted":
                print("[asr] TranscriptionCompleted")
                self.completed.set()
                return
            elif name == "TaskFailed":
                print("[asr] TaskFailed %s" % json.dumps(obj, ensure_ascii=False)[:600])
                self.completed.set()
                return


def asr(args):
    try:
        import websocket  # websocket-client，仅 ASR 需要
    except ImportError:
        print("缺少 websocket-client，请先执行：pip install websocket-client")
        return 2
    token = get_token(args)
    appkey = (args.appkey or os.environ.get("ALIYUN_APPKEY", "")).strip()
    if not appkey:
        raise SystemExit("需要 --appkey/ALIYUN_APPKEY")
    frames = read_wav_16k(args.wav)
    _, gw_host = REGION_HOST.get(args.region, REGION_HOST["cn-shanghai"])
    url = "wss://%s/ws/v1?token=%s" % (gw_host,
                                        urllib.parse.quote(token, safe=""))
    print("[asr] wav=%s bytes=%d chunk=%dms region=%s" %
          (args.wav, len(frames), args.chunk_ms, args.region))
    ws = websocket.create_connection(url, timeout=10, enable_multithread=True)
    started = threading.Event()
    completed = threading.Event()
    result = []
    reader = Reader(ws, started, completed, result)
    reader.start()

    task_id = uuid.uuid4().hex
    msg_id = uuid.uuid4().hex
    start_obj = {
        "header": {
            "appkey": appkey,
            "message_id": msg_id,
            "task_id": task_id,
            "namespace": "SpeechTranscriber",
            "name": "StartTranscription",
        },
        "payload": {
            "format": "pcm",
            "sample_rate": 16000,
            "enable_intermediate_result": True,
            "enable_punctuation_prediction": True,
            "enable_inverse_text_normalization": True,
            "max_sentence_silence": args.max_silence,
        },
    }
    ws.send(json.dumps(start_obj, ensure_ascii=False))
    if not started.wait(10):
        print("[asr] 等待 TranscriptionStarted 超时")
        reader.stop = True
        ws.close()
        return 3

    chunk_bytes = max(3200, int(16000 * 2 * args.chunk_ms / 1000))
    chunk_bytes -= chunk_bytes % 2
    interval = args.chunk_ms / 1000.0
    reader.audio_at = time.time()
    sent = 0
    next_at = time.time()
    while sent < len(frames):
        part = frames[sent:sent + chunk_bytes]
        if not part:
            break
        ws.send_binary(part)
        sent += len(part)
        next_at += interval
        delay = next_at - time.time()
        if delay > 0:
            time.sleep(delay)
    print("[asr] audio sent %.2fs, waiting final..." %
          (time.time() - reader.audio_at))
    ws.send(json.dumps({
        "header": {
            "appkey": appkey,
            "message_id": uuid.uuid4().hex,
            "task_id": task_id,
            "namespace": "SpeechTranscriber",
            "name": "StopTranscription",
        },
        "payload": {},
    }, ensure_ascii=False))
    completed.wait(15)
    time.sleep(0.2)
    reader.stop = True
    try:
        ws.close()
    except Exception:
        pass
    print("\n[asr] finals:")
    for x in result:
        print("  - %s" % x)
    return 0 if result else 4


def tts(args):
    token = get_token(args)
    appkey = (args.appkey or os.environ.get("ALIYUN_APPKEY", "")).strip()
    if not appkey:
        raise SystemExit("需要 --appkey/ALIYUN_APPKEY")
    _, gw_host = REGION_HOST.get(args.region, REGION_HOST["cn-shanghai"])
    params = {
        "appkey": appkey,
        "token": token,
        "text": args.text,
        "voice": args.voice,
        "format": "wav",
        "sample_rate": str(args.sample_rate),
    }
    url = "https://%s/stream/v1/tts?%s" % (
        gw_host,
        "&".join("%s=%s" % (pct(k), pct(v)) for k, v in params.items()))
    print("[tts] voice=%s rate=%d text=%d chars" %
          (args.voice, args.sample_rate, len(args.text)))
    with urllib.request.urlopen(url, timeout=30) as r:
        ctype = r.headers.get("Content-Type", "")
        data = r.read()
    if not data:
        raise SystemExit("TTS 返回空")
    if data[:4] == b"RIFF":
        with open(args.out, "wb") as f:
            f.write(data)
        print("[tts] saved %s (%d bytes, %s)" % (args.out, len(data), ctype))
        return 0
    head = data[:500].decode("utf-8", "replace")
    print("[tts] 返回不是 WAV：%s" % head)
    return 5


def main():
    ap = argparse.ArgumentParser(description="阿里云 ISI 独立验证")
    ap.add_argument("--token", default="", help="ISI Token；或用 ALIYUN_TOKEN")
    ap.add_argument("--ak-id", default="", help="AccessKey ID；或用环境变量")
    ap.add_argument("--ak-secret", default="", help="AccessKey Secret；或用环境变量")
    ap.add_argument("--region", default=os.environ.get("ALIYUN_REGION", "cn-shanghai"),
                    choices=sorted(REGION_HOST.keys()))
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("asr")
    a.add_argument("--wav", required=True)
    a.add_argument("--appkey", default="")
    a.add_argument("--chunk-ms", type=int, default=100, choices=[100, 200])
    a.add_argument("--max-silence", type=int, default=600)
    a.set_defaults(func=asr)

    t = sub.add_parser("tts")
    t.add_argument("--text", required=True)
    t.add_argument("--voice", default="xiaoyun")
    t.add_argument("--appkey", default="")
    t.add_argument("--out", default="aliyun_tts.wav")
    t.add_argument("--sample-rate", type=int, default=48000)
    t.set_defaults(func=tts)

    args = ap.parse_args()
    try:
        sys.exit(args.func(args))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:600]
        print("[http %s] %s" % (e.code, body))
        sys.exit(6)
    except urllib.error.URLError as e:
        print("[network] %s" % e)
        sys.exit(7)


if __name__ == "__main__":
    main()
