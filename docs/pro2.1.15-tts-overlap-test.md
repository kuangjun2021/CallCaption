# Pro 2.1.15 TTS 重叠真机测试记录

- 日期：2026-11-14
- 版本：`pro2.1.15`（`daemon.heartbeat = 1794609853 pro2.1.15`）
- 场景：WhatsApp 通话，双向 CPU ASR，`local=1 remote=1`
- 关键设置：`ttsMute=0`（未启用“TTS 播放时暂停对方识别”）
- 通话时间：01:26:46 – 01:28:57（本地时间，UTC+8）
- 日志：`测试日志/1.0.0-pro2.1.15/`

> 本文包含两轮：01:26–01:28（第一轮）和 08:55–08:57（第二轮）。第二轮更长，结论以两轮合并为准。

## 1. 结论先说

这次测试里，**中文 TTS 播放期间对方继续说话，没有被丢掉**：

- 对方识别流全程没有 `R muted` / `R unmuted`，也没有因 TTS 重置；
- 至少两次明确的“TTS 正在播、对方同时在说”场景，远端 ASR 仍然出了完整 final，并正常翻译、上屏、进中文 TTS 队列；
- 没有看到中文 TTS 被识别成中文字幕；唯一一次中文候选被置信度门限丢弃，没有上屏。

但这次 TTS 片段较短（1.37–2.70 秒），对方的话也高度重复；还不能据此宣布 AEC 永远不需要。

## 2. 关键时间线

| 本地时间 | 中文 TTS | 远端 ASR | 结果 |
|---|---|---|---|
| 01:28:11 | seq2「抱歉，我不知道。」加载，2.21s | 01:28:12–15 出现中文候选「上课外，拜拜」，conf avg=-1.56 / min=-2.47 | `final DROPPED`，`RC|` 清屏，未上屏 |
| 01:28:27 | seq3「抱歉，我不知道。」加载，2.21s | 01:28:27 对方开始说 "Thank you very much. Bye-bye."；01:28:30 出 `RQ|` final | 完整识别；翻译成功；进入 seq4 中文 TTS |
| 01:28:40 | seq5「非常感谢。再见。」加载，2.70s | 01:28:40 对方开始说 "Thank you very much. Bye-bye."；01:28:44 出 `RQ|` final | 完整识别；进入 seq6 中文 TTS |
| 01:28:44 | seq6「非常感谢。再见。」加载，2.70s | 对方语音约 01:28:47 才开始 | 不是真正的重叠 |
| 01:28:51 | seq7「非常感谢。再见。」加载 | 对方 final 在 01:28:51 已经产出 | 不是真正的重叠 |

两次明确重叠（seq3、seq5）的远端识别：

```text
[01:28:27] ui line: I|Thank you very
[01:28:28] ui line: I|Thank you very much. Bye-
[01:28:29] ui line: I|Thank you very much. Bye-bye.
[01:28:30] ui line: RQ|Thank you very much. Bye-bye.

[01:28:40] ui line: I|Thank
[01:28:41] ui line: I|Thank you very much
[01:28:42] ui line: I|Thank you very much. Bye-bye
[01:28:44] ui line: RQ|Thank you very much. Bye-bye.
```

## 3. 为什么没有丢

- `asr.log` 第一行：`ttsMute=0`，helper 没有启用 TTS 静音逻辑。
- 远端 WAV 是 AppProbe 在 `CCMixZhDownlink` **混音之前**录的：
  `原 render → CCRecordCB → CCMixZhDownlink`
  所以 ASR 看到的是干净的对方音频，中文 TTS 没有混进识别源。
- 远端 RMS 在 TTS 窗口内仍有明显语音能量：
  - seq3：01:28:27.5–28.5，rms 0.0176 / 0.0069；
  - seq5：01:28:39.5–41.5，rms 0.0754 / 0.0639 / 0.0676。
- 识别出的英文句子与中文 TTS 内容完全无关，说明不是 TTS 回声。

## 4. 唯一的中文候选

`01:28:12–15` 的「上课外，拜拜」：

- 置信度 avg=-1.56、min=-2.47，低于远端 final 门限（avg<-1.4 或 短文本 avg<-1.3）；
- helper 判定 `final DROPPED`，写 `RC|` 清掉远端字幕；
- 更可能是把英文 "Okay, bye-bye" 误识别成中文，而不是 TTS 回声（TTS 内容是「抱歉，我不知道」，文本对不上）；
- 没有产生错误中文字幕。

## 4.5 第二轮实测（08:55–08:57，新日志）

这轮是更长的双向测试，`daemon.heartbeat` 仍是 `pro2.1.15`，`ttsMute=0`。

### 远端在中文 TTS 播放期间说话

| 时间 | 中文 TTS | 远端 ASR |
|---|---|---|
| 08:56:08–11.83 | seq2「你好吗？我不知道。对不起。」 | 08:56:10 `RQ|How are you?`，完整 |
| 08:56:11–12.25 | seq3「你好吗？」 | 08:56:13 `RQ|I don't look.`，完整 |
| 08:56:14–15.23 | seq4「我没看。」 | 08:56:14–19 长句 `RQ|Thank you very much. Bye bye. Thank you very much. Bye-bye.`，完整 |

### 本机在 TTS 播放期间说话

- 中文 TTS seq5（08:56:20–25.45）播放时，本机说「我们现在开始测试」，08:56:26 出完整 local final。
- 长英文 TTS（08:56:38–43.4 等）播放期间，本机连续说长句；7 条 local final 全部完整，没有英文 TTS 回声混进中文识别。

### 关键缺口：对方没有在长英文 TTS 期间说话

- 长英文 TTS 窗口（08:56:38–43、46–50、56–61）内，远端 RMS 只有 0.0000–0.0025，且没有任何 remote partial。
- 也就是说，**“对方听着英文 TTS 同时说话”的英文回声场景，这轮仍然没测到**。这才是 AEC 真正要防的上行回声路径。

### 一处真实的低置信度误丢

- 08:55:59–08:56:00，远端 final `As I see you.` 被置信度门限丢弃（avg=-1.95，min=-2.23）。
- 用 PC 上的同一 Sherpa 模型重跑 `remote16k.wav`，greedy 解码也得到 `[FINAL] audio_end=11.20s As I see you`，说明 WAV 里确实有这段语音，不是模型幻觉。
- 它紧贴中文 TTS seq1 的尾部（seq1 08:55:56–58.4），但 helper 是 `ttsMute=0`，没有静音；这是**置信度门限误杀**，不是 TTS 重叠静音丢音。
- 如果对方当时确实说了这句，这是一次真实的内容丢失，需要单独调门限/解码策略（例如长英文句子的阈值单独放宽，或二次解码确认）。

## 5. AEC 怎么定（两轮合并）

两轮证据合并：

- 中文 TTS 播放期间，远端 ASR 在第一轮 seq3/seq5、第二轮 seq2/3/4 都出了完整 final；没有 TTS 静音/重置。
- 本机在中文 TTS seq5 和长英文 TTS 期间连续说话，local final 全部完整；没有 TTS 文本混进识别。
- 没有看到中文 TTS 被识别成字幕。
- 第二轮出现一次真实的低置信度误丢（`As I see you.`），不是 TTS 静音；需要单独调门限。
- 最关键的英文 TTS 回声场景（对方听着英文 TTS 同时说话）仍未测到：第二轮长英文 TTS 期间对方 RMS 近 0、无 remote partial。

结论：

- 对“中文 TTS 播放时对方继续说话”，当前架构（预混音抓取 + 连续 ASR）**没有丢音**；AEC 不是这个问题的必要条件。
- 不能关闭 AEC 议题，因为英文 TTS 的上行回声路径还没测。
- 下一次专门测：本机说长中文 → 长英文 TTS；英文 TTS 播放期间让对方连续说 5–10 秒新英文；检查 remote final 是否完整、有没有英文 TTS 回声。

## 6. 注意

- 不要打开「TTS 播放时暂停对方识别」（`AsrTTSMute=1`）。这个开关会在 TTS 窗口内暂停/重置远端流，重叠时必然丢音；这次测试是关闭状态。
- 第二轮 `As I see you.` 的误丢是置信度门限问题，和 AEC/静音无关；要单独处理。
- TTS 与对方英文在本地是叠加播放（hook 里 `duck 0.00/0.00`，没有 ducking）。这是“本地听感”问题，不是 ASR 丢音；如果觉得吵，应该做混音 ducking，不是 AEC。
