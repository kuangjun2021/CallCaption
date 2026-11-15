# Pro 2.1.26：短碎片合并 + 短语保护 + TTS 静音裁剪

- 日期：2026-11-15
- 包：`net.user.callcaptionpro_1.0.0-pro2.1.26_arm64e.deb`
- 大小：6,523,648 字节
- SHA-256：`771de406678952d45f0e3ba1da6ded752a7b0ec23fd148c95320a7f646e580df`
- 构建：GitHub Actions run `43719574971`，commit `31e1ea7`
- 模型包：不变，继续 `models_1.0.1`

## 1. 2.1.25 的问题

A（增量开）已经比 B（整句）快：

- A gate 最大 8.18s，中位约 4.14s；
- B gate 最大 10.71s，中位约 9.29s。

但 A 有短碎片：

```text
Chinese / subtitles 被切开 → “中国人 / 字幕完成了吗”
that the、so I、would be a 被单独翻
```

## 2. 这版改了什么

### 2.1 短语保护

切段边界不能落在固定短语内部：

```text
chinese subtitles / beef noodles / hot tea / fifteen dollars
thirty minutes / two hours / going shopping / short passage
another city / train station / a little late / for the meeting
```

### 2.2 功能词回退

如果切段末尾是：

```text
the / a / and / so / that / to / of / would / be / is / ...
```

就把下一个词一起带上，避免 `that the`、`so I`、`would be a`。

### 2.3 短碎片合并

- 少于 3 个英文词或 12 个字符的碎片，先压 0.6 秒；
- 下一段或 final 到了，合并后再翻译/TTS；
- 不单独播 `tea.`、`a`、`that the`。

### 2.4 最大段长

从 50 调到 60 字符，并经过短语保护/功能词回退修正。  
目标：少切出碎片，同时每段中文 TTS 仍控制在约 3–5 秒。

### 2.5 TTS 首尾静音裁剪

每段 `cc_tts_zh_*.wav` 写盘前裁掉首尾静音：

- 阈值约 -42 dBFS；
- 保留 50ms 余量；
- 不改语速、不改文本。

## 3. 不变的部分

- 远端 AGC 保留；
- 远端 x-asr + 本机 zh-14M 不变；
- TTS 100% 不变；
- 增量开关默认关；
- 不丢句、不做简版、AI 只做翻译兜底。

## 4. 测试

1. 安装 2.1.26，覆盖 2.1.25。
2. 设置：
   - 中文字幕语音播报：开
   - LCT 式增量播报：开（A 组）
   - 对方原音：30
3. 短版 5 段，同音量/位置/顺序，等 ASR 启动后再播。
4. 看：
   - `inc tts pending flush` 是否减少碎片；
   - 是否还出现 `Chinese / subtitles` 被切开；
   - `tts zh gate` 最大值、中位；
   - 第 5 段是否出字幕。
5. 再关增量开关测 B 组，做 A/B。

## 5. 预期

- A 的短碎片明显减少；
- `Chinese subtitles` 不再被切成“中国人 / 字幕”；
- TTS 首尾静音减少，gate 峰值有机会从 8.18s 再降；
- 如果 gate 仍高，下一步才考虑翻译并发。

## 6. 回滚

- 2.1.25 包仍在 releases；
- 模型包 1.0.1 不变；
- 关闭增量开关即回到整句 TTS。
