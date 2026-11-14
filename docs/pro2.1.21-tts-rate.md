# Pro 2.1.21：播报语速设置（中文/英文分开）

- 日期：2026-11-14
- 包：待构建 `net.user.callcaptionpro_1.0.0-pro2.1.21_arm64e.deb`
- 基础：2.1.20（`673812c` + 文档 `34b4695`）

## 1. 为什么做

2.1.20 真机日志显示，远端中文字幕和翻译已经可用，但中文 TTS 是串行队列：
长句（例如 `One...ten`）一次播报约 6 秒，后面的 TTS 只能排队，听感上“越来越慢”。
先把播报语速做成设置项，用速度换队列追赶时间，不改 ASR/翻译链路。

## 2. 改了什么

### 2.1 设置页

`设置 → 播报语速与音色` 新增两个滑杆：

- **中文播报语速**：80%–150%，默认 100%
- **英文播报语速**：80%–150%，默认 100%

100% = 系统默认语速；数值写入 `RemoteTTSRate` / `LocalTTSRate`。

### 2.2 中文 TTS（远端）

`CCUI.m`：

- `CCTTSRateMultiplier()` 读取 `RemoteTTSRate`，映射到 `AVSpeechUtterance.rate`
  （`AVSpeechUtteranceDefaultSpeechRate × 倍率`，clamp 到系统最小/最大）。
- `CCTTSBufferNow()` 在合成中文前应用语速，并记录：
  ```text
  tts rate zh-CN 150% (0.750)
  ```
- `CCZhTTSEst()` 的队列时长估算按同一倍率折算，避免语速调快后仍按旧时长误合并/误丢。
- `CCUISpeakText()` 的扬声器兜底路径也应用中文语速。

### 2.3 英文 TTS（本机上行）

`CCUI.m`：

- `CCTTSBufferNow()` 对 `en-US` 应用 `LocalTTSRate`，`cc_tts.wav` 合成速度随之变化。

`CCAudioService.m`：

- `CCSpeakEnglish()` 与 `CCGenerateUplinkTTS()` 应用 `LocalTTSRate`。
- `CCSpeakEnglish()` 的静音窗口时长按语速倍率折算，避免语速调快后静音窗口过长。

### 2.4 试听

音色选择页的试听也跟随当前中文/英文语速，改完滑杆再点音色即可听到实际速度。

## 3. 测试步骤

1. 安装 2.1.21，覆盖 2.1.20。
2. 打开 `设置 → 播报语速与音色`：
   - 中文调到 150%，英文保持 100%。
   - 点中文音色试听，确认明显变快。
3. 用微信 Pro 接通一次真实通话，双方说话 60 秒以上。
4. 检查 `asr.log` / 诊断日志：
   ```text
   tts rate zh-CN 150% (0.750)
   tts zh synth seq=...
   tts zh-CN -> cc_tts_zh_....wav ...
   ```
5. 主观检查：
   - 中文 TTS 是否变快、队列是否更容易追上；
   - 英文上行 TTS 是否仍正常，对方能听到；
   - 字幕/翻译不受影响。
6. 再把中文调到 80%，确认变慢且不破音；最后调回 100% 或你习惯的值。

## 4. 注意

- 语速只影响 TTS，不影响 ASR、翻译、字幕时间。
- 中文 150% 时部分系统音色可能略机械；以实际听感为准。
- 远端 TTS 仍然是“final 后才播”，partial 翻译是下一步，不在本版。
- 微信 Pro 远端仍是 16k 通话混音；本版不动远端捕获/模型。

## 5. 回滚

- 2.1.20 包仍在 releases：
  `net.user.callcaptionpro_1.0.0-pro2.1.20_arm64e.deb`
- 功能基线：`STABLE-net.user.callcaptionpro_2.1.2-off_arm64e.deb`。
