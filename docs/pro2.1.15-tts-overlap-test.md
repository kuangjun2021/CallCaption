# Pro 2.1.15 TTS 重叠真机测试记录

- 日期：2026-11-14
- 版本：`pro2.1.15`（`daemon.heartbeat = 1794609853 pro2.1.15`）
- 场景：WhatsApp 通话，双向 CPU ASR，`local=1 remote=1`
- 关键设置：`ttsMute=0`（未启用“TTS 播放时暂停对方识别”）
- 通话时间：01:26:46 – 01:28:57（本地时间，UTC+8）
- 日志：`测试日志/1.0.0-pro2.1.15/`

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

## 5. AEC 怎么定

这次证据说明：

- 对“中文 TTS 播放时对方继续说话”这个具体问题，当前架构（预混音抓取 + 连续 ASR）**没有丢音**；
- AEC 不是当前 ASR 丢音问题的必要条件。

但还不能直接关闭 AEC 议题，原因：

- 这次中文 TTS 只有 1.37–2.70 秒，对方说的是重复短句；
- 没覆盖“长 TTS（5–10 秒）+ 对方连续说一段新内容”的压力场景。

建议下一次专门做一次长重叠测试：

1. 对方先说一句会触发较长中文 TTS 的话；
2. 在 TTS 播放期间连续说一段 5–10 秒、内容不重复的英文；
3. 检查 `asr.log` 是否有完整 final、`spool.txt` 是否有对应 `RQ|`、字幕是否缺词。

如果那次也完整，就可以把 AEC 标为“当前架构不需要”。

## 6. 注意

- 不要打开「TTS 播放时暂停对方识别」（`AsrTTSMute=1`）。这个开关会在 TTS 窗口内暂停/重置远端流，重叠时必然丢音；这次测试是关闭状态。
- TTS 与对方英文在本地是叠加播放（hook 里 `duck 0.00/0.00`，没有 ducking）。这是“本地听感”问题，不是 ASR 丢音；如果觉得吵，应该做混音 ducking，不是 AEC。
