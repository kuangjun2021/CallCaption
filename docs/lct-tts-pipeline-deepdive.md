# LCT TTS 链路深挖：0.65 秒静音 + 新词尾段

- 日期：2026-11-15
- 对象：`D:\shoujichajian\Livecalltranslator\LiveCallTranslator.dylib`（arm64e slice）
- 方法：`llvm-lipo` 取 arm64e slice，`radare2` 解析 ObjC 方法表并反汇编
- 目的：给 2.1.30 定切句/播报逻辑，不再靠猜

## 1. 先给结论

LCT 的 TTS 不是“按字符切”，也不是“等中文译文稳定”，而是：

```text
SFSpeech partial 持续更新 speechString / wordCount / lastRecognitionTime
→ 0.1 秒定时器每 tick 检查
→ 距离最后一次 partial ≥ 0.65 秒，且还有新词
→ 取“上次已处理词下标 → 当前末尾”的新词尾段
→ translateText:from:to:
→ msay:withVoice: → AVSpeechSynthesizer 排队播
```

关键常量（从 `__DATA` 直接读）：

| 常量 | 值 | 用途 |
|---|---:|---|
| `0xA000+0xAF8` | `0.65` | 距最后一次 partial 的静音阈值 |
| `0xA000+0xB00` | `0.1` | 定时器周期 |

也就是说，LCT 的“切句”本质是 **0.65 秒静音检测**，不是稳定性门，不是短语表，也不是 46 字符上限。

## 2. 方法表（arm64e）

`r2 -q -c "ic"` 得到的关键方法：

| 地址 | 方法 | 作用 |
|---:|---|---|
| `0x6584` | `speechRecognitionTask:didHypothesizeTranscription:` | 每个 partial 更新状态 |
| `0x637c` | `timerFired:` | 0.1 秒轮询，0.65 秒静音后取新词尾 |
| `0x64e4` | C 辅助函数 | 从第 N 个词拼接到末尾 |
| `0x5808` | `translateText:from:to:` | 按服务设置分派翻译 |
| `0x4e80` | `receivedSBTranslation:` | 翻译回来，按 isLocal 选 voice |
| `0x4edc` | `msay:withVoice:` | 创建 `AVSpeechUtterance` 并 `speakUtterance:` |
| `0x53b4` | `speechSynthesizer:didStartSpeechUtterance:` | `synthSpeaking = YES` |
| `0x53bc` | `speechSynthesizer:didFinishSpeechUtterance:` | `synthSpeaking = NO` |

`0x6b14 processRemoteRecognition`、`0x6b00 setupRemoteRequestAndWait` 在这个版本里是空实现（直接 `ret`），不能把它们当主链路。

## 3. didHypothesizeTranscription

反汇编要点（ivar 偏移）：

```text
+0x08 = speechString      = transcription.formattedString
+0x10 = lastRecognitionTime = CFAbsoluteTimeGetCurrent()
+0x20 = wordCount          = [speechString componentsSeparatedByString:@" "] count
+0x28 = timer              （如果为 nil，创建 0.1 秒定时器）
+0x38 = isLocal
```

它还会在开启 UI 时通过 XPC 把识别原文发给 SpringBoard，但这条不影响 TTS 切句。

## 4. timerFired:

反汇编逻辑：

```text
now = CFAbsoluteTimeGetCurrent()
if (now - lastRecognitionTime < 0.65) return;

if (lastProcessedWord < wordCount) {
    tail = joinWords(speechString, from: lastProcessedWordIndex);
    [self translateText:tail from:... to:...];
    lastProcessedWordIndex = wordCount;
}
```

`0x64e4` 辅助函数的行为：

```text
words = [speechString componentsSeparatedByString:@" "];
result = [NSMutableString string];
for (i = startIndex; i < words.count; i++) {
    [result appendString:words[i]];
    [result appendString:@" "];
}
return result;
```

这就是“新词尾段”的来源：不是重翻整段 partial，而是只翻上次没处理过的那几个词。

`timerFired` 后面还有两个分支：

- `hasDataReadyFromRemote == 1` 且距上次 partial ≥ 1.0 秒：清理 timer、走恢复/重启路径；
- `isLocal` 且距上次 partial ≥ 3.0 秒：另一条本地恢复路径。

这两个是识别/路由恢复，不是 TTS 切句。

## 5. 翻译与 TTS

`translateText:from:to:` 根据设置里的服务编号分派：

```text
1/2/3 → translateTextSubscribed:from:to: / Free / ...
4     → translateTextDeepl:from:to:
其他  → translateTextFree:from:to:
```

方法名和字符串证据：

```text
translateText:from:to:
translateTextDeepl:from:to:
translateTextFree:from:to:
translateTextSubscribed:from:to:
```

翻译回来后走：

```text
receivedSBTranslation:
→ 按 isLocal 选 voice
→ msay:withVoice:
→ AVSpeechUtterance
→ [speechSynthesizer speakUtterance:]
```

`msay` 没有 `stopSpeakingAtBoundary:`，也没有按字数丢句；`AVSpeechSynthesizer` 自己按队列播。  
`didStart` / `didFinish` 只维护 `synthSpeaking` 标志。

## 6. 和 2.1.29 的差异

2.1.29 做了两件 LCT 没做的事：

1. **46 字符硬上限**：在自然停顿前切，切点可能落在半词/虚词上；
2. **句号/逗号立即切**：比 LCT 的 0.65 秒静音更早。

第 2 条本身是 latency 优化，问题不大；第 1 条是这次语义错误的直接原因：

```text
x-asr: The agent told me that the flight would be de layed by
2.1.29 max cut: The agent told me that the flight would be de
→ Google: 代理人告诉我航班将会取消。
```

LCT 不会在这里切：它会等 0.65 秒静音，拿到包含 `delayed by thirty minutes` 的完整尾段再翻。

## 7. 对 2.1.30 的直接结论

- **删除 46 字符硬上限**；
- **保留句号/逗号切**，作为 x-asr 标点比静音更早到达时的 latency 优化；
- **静音收尾从 1.2 秒改成 0.65 秒**，对齐 LCT；
- **翻译前修复 ASR 断词**：`de layed → delayed`、`coffe e → coffee`、`flig ht → flight`；
- 100% 语速、不丢句、不做简版、不加稳定门、不加短语表；
- TTS 仍用 FIFO，不打断、不丢句，和 LCT 的 `AVSpeechSynthesizer` 队列一致。

这样既保留 LCT 的“0.65 秒静音 + 新词尾段”，又利用 x-asr 已有的标点提前开播；语义错误的最大来源（46 字符硬切）被移除。

## 8. 证据边界

- 0.65 / 0.1 是从 `__DATA` 原始字节读出的 double，不是猜的；
- `timerFired` 调用 `translateText:from:to:` 由 selector ref `0x14d78 → 0xcb6d` 确认；
- `joinWords` 从第 N 个词拼接，由 `0x64e4` 反汇编确认；
- “按空格分词”由 `componentsSeparatedByString:` + `count` 的使用推断，分隔符常量未逐字节打印；
- `msay` 使用单个 `AVSpeechSynthesizer`，未发现 stop/drop 逻辑；
- 该 dylib 是 0.1-61 版本，不能保证所有 LCT 版本完全一致，但这是目前能拿到的最直接证据。
