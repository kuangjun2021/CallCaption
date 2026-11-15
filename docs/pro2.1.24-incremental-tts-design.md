# Pro 2.1.24：LCT 式全量增量 TTS 设计方案

- 日期：2026-11-15
- 状态：设计稿，未改代码
- 目标：解决 TTS 落后 3 句以上，同时满足老爹的硬约束：
  - **不提高 TTS 语速**（130–150% 听不清，禁止）；
  - **不丢句**；
  - **不做口播简版/摘要**；
  - **保留 AI 作为翻译兜底**，但 AI 不做简版、不参与正常主链路；
  - 全量翻译，Google/DeepL 为主。

---

## 1. 结论先行

LCT 能跟得上，不是 TTS 引擎更快，而是：

```text
不等整句 final
→ partial/短文本一到就翻译
→ 逐段 TTS
→ 100% 语速，原声压低后混音
```

我们 2.1.23 的问题：

```text
等 final
→ 整句翻译
→ 整句 7–10 秒 TTS
→ 串行播放
```

所以队列必然积压。2.1.24 要做的不是“简版”，而是：

> **把 TTS 的播报单元从整句拆成 partial/从句，翻译仍然全量，TTS 仍然 100%，所有内容都播，只是提前、拆小、去重。**

---

## 2. LCT 整条链路的逆向证据

分析对象：

```text
D:\shoujichajian\Livecalltranslator\LiveCallTranslator.dylib
D:\shoujichajian\Livecalltranslator\LiveCallTranslatorSB.dylib
net.limneos.livecalltranslator_0.1-61_iphoneos-arm64.deb → livecallhelper
LCT-逆向分析与优化方案-v1.md
```

### 2.1 识别：流式 token/partial

`LiveCallTranslator.dylib` 中可见：

```text
remoteSpeechTokens
localSpeechTokens
enqueueRemoteRecognition
processRemoteRecognition
setShouldReportPartialResults:
setupRemoteRequestAndWait
remoteSpeechRecognizer
remoteSpeechResult
localSpeechResult
```

逆向文档确认：

- assistantd 使用 Siri 的 `SiriCoreLocalSpeechRecognizer`；
- `speechCapturingDidRecordPCMAudioData:` 收 PCM；
- `didRecognizeTokens:` / `didRecognizeRawEagerRecognitionCandidate:` 出 token/partial；
- LCT **不等整句 final**，token/partial 就进入翻译管线。

### 2.2 翻译：短文本、随到随翻

`LiveCallTranslator.dylib` 中可见：

```text
translateText:from:to:
translateTextDeepl:from:to:
translateTextFree:from:to:
translateTextSubscribed:from:to:
```

URL 常量：

```text
https://api.mymemory.translated.net/get?q=%@&langpair=%@%7C%@
https://translation.googleapis.com/language/translate/v2
https://translate.yandex.net/api/v1.5/tr.json/translate
https://api-free.deepl.com/v2/translate
```

逆向文档还记录了 Apple 私有 `Translation.framework`（`_LTTranslator`、`_LTLocalePair`、`_LTTextTranslationRequest`）作为可选本地翻译。

翻译特征：

- **短文本请求**，不是整句；
- 每次只翻一小段，HTTP/本地延迟低；
- 译文回来立即更新 UI；
- 翻译服务可切换：MyMemory/Google/Yandex/Lingvanex/DeepL，Apple 本地优先尝试。

### 2.3 TTS：逐段合成/播放

`LiveCallTranslator.dylib` 中可见：

```text
speakStringToLocal
speakStringToRemote
speakStringToDaemon:withVoiceID:transferToRemote:
remoteSynth
remoteSynthSpeaking
speakingUtterance
speakingUtteranceFinished
newUtterance
writeUtterance:toBufferCallback:
AVSpeechSynthesizer
AVSpeechUtterance
```

`LiveCallTranslatorSB.dylib` 中可见：

```text
speakString:withVoiceID:
speakStringToDaemon:withVoiceID:transferToRemote:
speakUtterance:
speakingUtterance:withRange:isLocal:
stopSpeakingAtBoundary:
```

逆向文档确认：

- `transferToRemote=0`：对方译文，本地播放；
- `transferToRemote=1`：我方译文，送到对端（上行）；
- TTS 固定 100%；
- `originalVoiceVolume` / `remoteOriginalVoiceVolume` 控制原声；
- 原声压低后与 TTS 混音。

**关键结论：**

- LCT 没有证据表明用了更快的 TTS 引擎；
- 它每段文本很短，`speakUtterance` 的播放单元小；
- TTS 在对方还在说话时就开始，和原声重叠；
- 队列不会积 10 秒整句，所以听感上“跟得上”。

### 2.4 LCT 可能付出的代价

从现有逆向材料不能确认：

- 新段到来时是否打断上一条 TTS；
- 是否跳句/丢句；
- partial 译文修正后是否重播。

我们不复刻这些不确定行为。2.1.24 明确：

- **不打断、不跳句、不丢句**；
- partial 修正只影响字幕，不重播已播内容；
- final 只补未播尾段。

---

## 3. 当前 2.1.23 链路与差距

### 3.1 当前链路

```text
x-asr partial I|
  → CCUIRemotePartialText（1.5s 节流，只更新字幕，不 TTS）
  → CCTranslateWithEngine（Google 主，AI 兜底）

x-asr final RQ|
  → CCUIRemoteFinalText
  → 整句翻译
  → CCZhTTSEnqueue
  → AVSpeechSynthesizer 整句 TTS
  → cc_tts_zh_*.wav 串行播放
```

### 3.2 实测问题

```text
tts zh merge: 0
tts zh drop:  0
tts zh gate: 10.61s → 11.32s → 12.35s → 12.48s → 13.47s
```

每句 TTS 7–10 秒，输入也约 5–10 秒；TTS 只在 final 后开始，串行播放，必然落后 3 句以上。

### 3.3 差距

| 环节 | LCT | 2.1.23 |
|---|---|---|
| 识别 | token/partial 进管线 | partial 只做字幕 |
| 翻译 | 短文本随到随翻 | final 整句翻译 |
| TTS | 逐段、早播 | 整句、final 后播 |
| 队列 | 短段，不积长句 | 长句串行，积 3 句 |
| 语速 | 100% | 100%（一致） |

---

## 4. 2.1.24 目标架构

### 4.1 总链路

```text
x-asr partial I|
  → ClauseBuilder（稳定从句/短语）
  → 全量短文本翻译（Google/DeepL 主，AI 兜底）
  → 字幕更新
  → TTSCommitter（只播新增后缀）
  → cc_tts_zh 队列（FIFO，不丢句，100% 语速）
  → 下行混音播放

x-asr final RQ|
  → 全量 final 翻译
  → 字幕以 final 为准
  → TTSCommitter 只补未播尾段
```

### 4.2 与 LCT 对齐的点

- 不等整句 final；
- 短文本翻译；
- 逐段 TTS；
- 100% 语速；
- 原声压低后混音；
- 翻译服务 Google/DeepL 为主，AI 仅兜底。

### 4.3 我们比 LCT 更保守的点

- 不打断上一条 TTS；
- 不跳句、不丢句；
- partial 译文修正不重播已播内容；
- final 字幕为准；
- 高风险句（数字/否定/人名/条件）可延后到从句稳定/final，但不做简版。

---

## 5. ClauseBuilder：把 partial 变成可播单元

### 5.1 输入

- `I|` partial 文本（英文）；
- 当前通话 seq；
- 当前 partial 的稳定时间；
- 标点/词边界。

### 5.2 可播条件（满足任一）

1. partial 末尾出现从句标点：`,` `.` `?` `!` `;`；
2. partial 文本连续 `0.8–1.2s` 未变化，且长度 ≥ 6 个英文词/20 字符；
3. 达到最大段长（例如 25–30 个英文词或 12 秒），强制切一段；
4. final 到达：剩余部分作为最后一段。

### 5.3 切分规则

- 不切断单词；
- 优先在标点/连词处切；
- 单段中文译文目标 8–20 字，TTS 约 2–4 秒；
- 如果译文过长，按中文标点再切；
- 段与段之间保留 100–200ms 自然间隔，避免粘连。

### 5.4 防抖

- 同一段文本 0.8–1.2s 内不变才提交；
- 提交后记录 `committedSourceText`；
- 新 partial 如果只是追加，进入下一段；
- 如果新 partial 改写了已提交段，字幕更新，但**不重播已播音频**；
- 改写只影响 final 字幕和未播尾段。

---

## 6. 翻译：全量，Google/DeepL 主，AI 兜底

### 6.1 引擎顺序（保留现有 AI 兜底）

远端默认 `RemoteTranslateEngine`：

- `google`：Google → MyMemory → DeepL（有 Key）→ AI（有 Key）
- `deepl`：DeepL → AI → Google → MyMemory
- `ai`：AI → DeepL → Google → MyMemory
- `auto`：DeepL → AI → Google → MyMemory

2.1.24 **不改这个顺序**，AI 只在前面引擎失败/超时时兜底。

### 6.2 翻译请求策略

- 每个可播段一次全量翻译，不做简版；
- 同一方向最多 1 个 in-flight 请求，保证顺序；
- 新段到达时，如果上一个请求未回，排队等；
- 返回结果带 seq/gen，旧通话/旧段结果丢弃；
- 缓存复用：同一文本直接取缓存；
- 记录实际引擎 `RE|`，字幕显示实际成功的引擎。

### 6.3 保留 AI 兜底

- 不删除 AI 设置、不修改 AI prompt；
- AI 仅在 Google/DeepL/MyMemory 失败时触发；
- AI 延迟高，只作为兜底，不参与正常主链路；
- 如果 AI 也失败，该段字幕保留原文/上一段，TTS 不播该段，不阻塞后续。

---

## 7. TTSCommitter：只播新增后缀

### 7.1 状态

每个通话 seq 维护：

```text
g_spokenText        已送 TTS 的中文（或已播前缀）
g_spokenSeq         已送 TTS 的段序号
g_translationGen    翻译失效代号
g_ttsSeq            TTS 文件序号
```

### 7.2 提交规则

1. 新段译文 `T`；
2. 计算 `T` 与 `g_spokenText` 的最长公共前缀 `P`；
3. 新增部分 `D = T[P:]`；
4. 如果 `D` 为空，不播；
5. 如果 `D` 太短（<2 字），等下一段一起播；
6. 将 `D` 送 `CCZhTTSEnqueue`；
7. 更新 `g_spokenText = T`（或 `g_spokenText + D`）。

### 7.3 final 到达

- 翻译 final 全文；
- 字幕用 final 全文；
- 计算 final 与 `g_spokenText` 的最长公共前缀；
- 只播 final 的未播尾段；
- 如果 final 与已播内容有实质差异：
  - 字幕以 final 为准；
  - 语音默认不重播；
  - 只有关键 token（数字/人名/否定/条件）变化时，才考虑补一句短更正（可配置，默认关）。

### 7.4 TTS 参数

- 语速 100%，不加速；
- 音色沿用设置；
- 每段 TTS 目标 2–4 秒；
- 不改变 `AVSpeechUtterance` 的音量/音高；
- 不缩短文本、不做摘要。

---

## 8. 队列：FIFO，不丢句

### 8.1 现状

`CCZhTTSEnqueue` 目前有：

- 最多 3 条；
- 待播总时长 3 秒/6 秒；
- 超限会 merge 两条或 drop 最老。

2.1.24 增量模式下：

- **禁止 drop**；
- **禁止为了队列上限丢句**；
- 保持 FIFO；
- 如果队列积压，先调小段长/提前触发，不允许丢内容。

### 8.2 失败兜底

- TTS 合成失败：记录日志，跳过该段，不阻塞后续；
- 翻译失败：该段不播，后续继续；
- 通话结束：清空队列，不跨通话播放；
- 队列积压超过验收阈值：记录 `tts backlog high`，作为测试失败，不回退到丢句。

---

## 9. 风险控制（不做简版、不做 AI 主链路）

### 9.1 短文本翻译歪曲风险

高风险内容：

- 数字、金额、时间；
- 人名、地名、产品名；
- 否定（not/never/without）；
- 条件/因果（if/unless/before/after）；
- 疑问/请求/承诺；
- 指代（he/she/it/this/that）。

控制：

- 高风险段可以等从句稳定更久（例如 1.2s）或等 final；
- 不做简版，减少压缩导致的语义丢失；
- final 字幕以全文为准；
- 关键 token 不一致时记录日志，供测试统计；
- 不引入 AI 重写。

### 9.2 partial 改写风险

- partial 可能改词；
- 已播内容不重播；
- 字幕 final 修正；
- 如果关键信息被改，默认不回补语音；可配置“短更正”。

### 9.3 中英混说

- 远端可能中英混说；
- 继续使用现有 `CCRemoteTextIsMostlyChinese` 判定；
- 中文段直接显示/播报，不走英译中；
- 英文段走增量 TTS；
- 语言判定错误只影响该段，不影响后续。

---

## 10. 验收指标

### 10.1 延迟

- 首段 TTS：从句稳定后 ≤ 2.0 秒开始合成/入队；
- `tts zh gate` 最大值：≤ 3.0 秒（目标）；
- 队列落后：≤ 1 段（约 2–3 秒）。

### 10.2 完整性

- 不丢句：翻译段数 = 播报段数（允许空段/失败段单独计数）；
- final 尾段必须播；
- 不出现整段静默。

### 10.3 语义

- 数字/人名/否定/条件专项句库，关键 token 错误率 ≤ 基线；
- 不允许把否定播成肯定；
- 不允许把金额/时间播错。

### 10.4 听感

- 不出现明显重复；
- 不出现连续 3 段以上断裂；
- TTS 与原声重叠可接受；
- 用户主观通过。

### 10.5 稳定性

- 10 分钟连续通话；
- helper 不重启；
- 内存/温度可接受；
- 翻译失败率、AI 兜底率有日志。

---

## 11. 测试计划

### 11.1 基线

- 2.1.23 final-only；
- 7 段长英文 TTS（`测试日志\english_tts_20261114`）；
- 微信 / WhatsApp；
- TTS 开，原音 30；
- 记录 `tts zh gate`、R final、播放段数。

### 11.2 2.1.24 A/B

- 功能开关 `IncrementalTTS` 默认关；
- 同一通话/同一素材，A/B 对比：
  - 首段延迟；
  - backlog；
  - 播放段数；
  - 语义错误；
  - 听感。

### 11.3 专项句库

新增 20–30 句英文，覆盖：

- 否定：`I don't think...` / `He never...`
- 数字：`fifteen dollars` / `thirty minutes`
- 人名/地名；
- 条件：`if` / `unless` / `before` / `after`
- 疑问/请求；
- 中英混说。

### 11.4 真机

- 微信 Pro 来电（博士手机接听）；
- PC/另一台手机播放；
- TTS 开；
- 连续 10 分钟；
- 导出 `asr.log`、`probe.log`、`spool.txt`、`remote16k.wav`。

---

## 12. 实施步骤（确认设计后）

1. 备份：`CCUI.m`、`CCAudioService.m`、`CCSupport.m`、`CCCommon.h`、`CCSettings.m`、`control`、`Info.plist`；
2. 加设置开关 `IncrementalTTS`（默认关）；
3. 实现 ClauseBuilder；
4. 实现增量翻译协调器（复用 `CCTranslateWithEngine`，保留 AI 兜底）；
5. 实现 TTSCommitter（前缀去重、final 尾段）；
6. 增量模式下关闭 `CCZhTTSEnqueue` 的 drop/merge；
7. 加日志：`inc tts clause`、`inc tts delta`、`inc tts final tail`、`inc tts backlog`；
8. 先 7 段素材 A/B，再真机；
9. 通过后默认开启，出 2.1.24。

---

## 13. 待确认

1. ClauseBuilder 的稳定阈值：0.8s 还是 1.2s；
2. 高风险句是否等 final，还是只等更长稳定；
3. final 关键 token 变化时，是否补短更正（默认关）；
4. 翻译是否带上一段上下文（DeepL context / 拼接），会增加延迟，先不做；
5. TTS 段间间隔 100ms 还是 200ms；
6. 验收时 `tts zh gate` 目标 3 秒是否合理，按实测调整。

---

## 14. 回滚

- 功能开关默认关，随时可关；
- 回滚包：2.1.23；
- 模型包 1.0.1 不变；
- 不改 ASR/模型，只改 TTS 链路。
