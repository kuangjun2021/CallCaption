# CallCaption Pro 1.0.0-pro1.1 发布与真机验证

日期：2026-11-13  
构建：GitHub Actions run `43362320373`，commit `4f2d968`  
包：`net.user.callcaptionpro`（主包）+ `net.user.callcaptionpro.models`（模型包，装一次）

## 产物（D:\shoujichajian\CallCaption\releases）

| 文件 | 大小 | SHA256 |
|---|---:|---|
| `net.user.callcaptionpro_1.0.0-pro1.1_arm64e.deb` | 6,484,944 B | `01457f1effb3f5319523fb690c24c30eb69602f008de91b14fae20f30359c313` |
| `net.user.callcaptionpro.models_1.0.0_arm64e.deb` | 127,149,428 B | `cfbe002a36a6f5fef8047ca21039b02d095466214fdbd0a53852e713f964900a` |

## 安装顺序（不卸载 pro0.1）

1. 先装模型包 `net.user.callcaptionpro.models_1.0.0_arm64e.deb`（169MB 解压，装一次）。
2. 再装主包 `net.user.callcaptionpro_1.0.0-pro1.1_arm64e.deb`，覆盖 pro0.1。
3. 安装脚本会停稳定版、启 Pro daemon、respring；稳定版文件/配置不删。

## 离线自检（不打电话）

设置 → CallCaption Pro → 诊断 → “CPU ASR 离线测试”。

- 有 `local16k.wav` 就用上一通电话的录音；没有就用主包内置 10s 官方测试音。
- 首次加载 169MB 模型约 20–60 秒。
- 结果：`/var/mobile/Library/CallCaptionPro/asr_test.txt`
- 过程日志：`/var/mobile/Library/CallCaptionPro/asr.log`
- daemon 日志：`/var/mobile/Library/CallCaptionPro/probe.log`

期望 `asr_test.txt` 出现类似：

```
[first] +X.XXs: ...
[partial] ...
[final] ...
[final-end] ...
[done] wall=... audio=10.1s rtf=... first=... finals=...
```

`[done]` 前有文本 = 模型加载、dylib、CPU 推理全部通了。若只有 `start mode=...` 没有 `model loaded`，看 `asr.log` 的 `create recognizer failed`/`missing model file`。

## 通话验证

1. 设置 → CallCaption Pro → 我方识别引擎 → “本机 CPU（Sherpa）”。
2. 打一通 WhatsApp 电话（对方说中文或英文，我方说中文）。
3. 期望：我方中文 `LI|` 实时字幕 → `LQ|` 触发 DeepL/Google 译英 → `LR|` 英文字幕 + 本机英文 TTS 混入上行。
4. 导出 Pro `probe.log`；关注 `asr helper started pid=...`、`asr helper exited ...`、`tencent asr started remote=1 local=0`。
5. 若本地字幕不出：先确认 `asr.log` 是否持续写 `[partial]`；若 helper 退出，看 `probe.log` 的 status。

## 已知边界

- Pro1 只有“我方”走 CPU；对方仍走腾讯实时翻译。
- 每通电话启动 helper，模型加载时间会体现在本通开头；Pro2 再做常驻/双流共用 Recognizer。
- 热点词（去电/字幕/翻译/微信/WhatsApp）尚未启用，Pro2 加 `hotwords_file` + `bpe.vocab`。
