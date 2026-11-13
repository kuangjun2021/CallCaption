# CallCaption Pro 2.1.3 — TTS 回声门控 + 置信度过滤

基线：`pro2.1.2-off-stable` tag
构建：run `43421751486`，commit `821d1b1`

## 产物

| 文件 | 大小 | SHA256 |
|---|---:|---|
| `net.user.callcaptionpro_1.0.0-pro2.1.3_arm64e.deb` | 6,516,352 B | `22c55f7869580e24979a5bfcdafb10380face1c8a78b02b1dbf68769872e089a` |
| `STABLE-net.user.callcaptionpro_2.1.2-off_arm64e.deb`（回退） | 6,512,532 B | `f3ac1d3c4c3ea4bd1c7175c235d980b6a0c0de303a6c143415f07bf6aa1e9bbe` |

模型包不变。

## 2.1.3 改动

- **对方 TTS 回声门控**：daemon 复制 `cc_tts_zh_*.wav` 时写 `remote_tts_until`；
  helper 在该窗口内把 `remote16k.wav` 推到文件尾并 reset，TTS 结束再恢复。
  解决“TTS 被 speaker Tap 抓回来又被 ASR 识别”的问题。
- **对方 final 置信度过滤**：解析 `ys_probs`；
  `avg < -1.4` 或 1–2 字且 `avg < -1.3` 的 final 丢弃，并发送 `RC|` 清掉残留字幕。
- **日志轮转**：helper 每次启动把 `asr.log` 移到 `asr.log.prev`。
- **安装日志持久化**：postinst 结束时复制到
  `/var/mobile/Library/CallCaptionPro/install.log`，重启后仍可查。
- **安装 daemon 兜底**：kickstart 后心跳未更新则解析 PID、`kill -9`，靠 KeepAlive
  重启新二进制；仍失败才需要用户空间重启。
- **ring 设为默认预加载**；resident 仍可选；off 保留。

## 待验证

- 来电时 `R muted for remote TTS` / `R unmuted after remote TTS` 是否成对出现。
- `R final` 中不再出现 TTS 回声（如“棒了。你好”“你好，你好”“知道”“非常”）。
- 低置信度噪声 final 是否被 `final DROPPED` 丢弃。
- 安装后是否不再必须用户空间重启。
