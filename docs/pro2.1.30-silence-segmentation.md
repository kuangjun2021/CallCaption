# Pro 2.1.30：0.65 秒静音切句，删除 46 字符硬上限

- 日期：2026-11-16
- 包：`net.user.callcaptionpro_1.0.0-pro2.1.30_arm64e.deb`
- 大小：6,525,560 字节
- SHA-256：`50ad8421af08f6f0191464183bb54af5ff5e4303e83863bdd9311b6e82f41691`
- 构建：GitHub Actions run `43787743359`，commit `d86ea47`
- 模型包：不变，继续 `models_1.0.1`

## 1. 为什么改

2.1.29 A 组实测延迟已经降下来：

- 25 段中文 TTS，0 merge / 0 drop，每次 `pending=1`；
- 启动等待中位 0.00s，最大 2.71s（2.1.28 是 0.91s / 5.34s）。

但 46 字符硬切造成语义错误，最严重：

```text
x-asr: The agent told me that the flight would be de layed by
max cut: The agent told me that the flight would be de
→ TTS: 代理人告诉我航班将会取消。
layed by thirty minutes,
→ TTS: 相隔三十分钟
```

原意是“航班延误三十分钟”。同句 final 字幕翻译是对的，说明问题在切点，不在模型/翻译引擎。

LCT 深挖（`docs/lct-tts-pipeline-deepdive.md`）确认：LCT 的切句是 **0.1 秒定时器 + 0.65 秒静音 + 新词尾段**，没有 46 字符上限、没有稳定门、没有短语表。

## 2. 2.1.30 改了什么

### 2.1 删除 46 字符硬上限

`CCIncFlushNatural` 不再按长度切。没有标点时，等 0.65 秒静音收尾。

### 2.2 静音收尾 1.2 秒 → 0.65 秒

对齐 LCT 的 `timerFired` 阈值：

```text
0xA000+0xAF8 = 0.65
0xA000+0xB00 = 0.1（LCT 定时器周期）
```

日志：

```text
inc tts idle flush: ...
```

### 2.3 保留句号/逗号切

x-asr 的标点常比静音更早到，能提前开播；这不是稳定门，只是把同一个停顿提前用上。

- 句末标点 `.?!;:` 后面是空格/结尾 → 立即切；
- 逗号前已有 ≥12 字符 → 切到逗号；
- 不再有 `inc tts max cut`。

### 2.4 翻译前修 ASR 断词

x-asr 偶尔把 `delayed` 吐成 `de layed`、`coffee` 吐成 `coffe e`。新增：

```objc
CCIncRepairSplitWords()
```

规则：

- 相邻两个 token 都不是合法英文词；
- 拼起来是合法英文词；
- 只有同时满足才合并。

例子：

```text
de + layed = delayed
coffe + e = coffee
flig + ht = flight
```

使用 `UITextChecker`，结果缓存 512 条；只在切句/翻译前跑。日志：

```text
inc tts word repair: de + layed -> delayed
```

### 2.5 静音点不结在虚词/半词上

只删 46 字符上限还不够：x-asr 的 partial 间隔有抖动，0.65 秒静音可能落在 `by`、`am`、`I` 这类虚词上。2.1.30 增加：

```objc
CCIncShouldHoldAtSilence()
```

- 静音点最后一个是虚词（封闭词类，约 100 个）→ 先不结句；
- 或者是长度 ≤5 的不合法英文半词（如 `de`、`flig`、`coffe`）→ 先不结句；
- 最多再等两拍（2×0.65s）；仍没有新内容就照常播，不丢句。

这不是译文稳定门，不要求文本重复；只防止：

```text
The agent ... delayed by / thirty minutes,
Hello, I am / a Chinese speaker.
Last week I / visited a friend ...
```

被切成两句。

### 2.6 不变的部分

- 100% 语速；
- 不丢句、不合并、不做简版；
- 不加稳定门、不加短语表；
- AI 仍只做翻译兜底；
- 远端 AGC、x-asr + zh-14M 模型不变；
- TTS FIFO，不打断；
- 腾讯 ASR 路径仍走整句 TTS。

## 3. 新增/变化日志

```text
inc tts pending len=...
inc tts word repair: ... + ... -> ...
inc tts phrase q=...: ...
inc tts translate: ...
inc tts speak[google]: ...
inc tts comma cut: ...
inc tts hold incomplete(1/2): ...
inc tts idle flush: ...
inc tts segment flush: ...
inc tts reset seq=...
```

`inc tts max cut` 在 2.1.30 已不存在。

## 4. 测试

这轮只测 A（增量开）；B 已取消，不再作为对比组。

接听：老爹的博士手机，只接听、导日志，不播放 MP3。  
拨号：另一台手机用微信 Pro 拨号，并播放短版 5 段 MP3。

设置：

- 中文字幕语音播报：开
- LCT 式增量播报：开
- 对方原音：30
- 远端即时翻译：开
- TTS 语速：100%

等面板显示 `● 本机 CPU ASR 已启动` 再播；段间 1–2 秒；导出 `probe.log`、`asr.log`、`spool.txt`。

重点看：

1. `The agent told me that the flight would be delayed by thirty minutes,` 是否播成“延误三十分钟”，不再是“取消”；
2. `took a train ... two hours before my flight.` 是否整句正确，不再出现“大约到达”；
3. `Yesterday ... near my office.` 是否整句；
4. `so I called ... late for the meeting.` 是否整句；
5. 是否还有半词/虚词结句；
6. `inc tts phrase` → `inc tts speak` 间隔；
7. `tts zh enqueue` 是否仍 `pending=1`；
8. 5 段是否完整，第 5 段低声是否仍出字幕。

## 5. 预期与风险

- 语义错误应消失：不再有 46 字符硬切，断词先修；
- 延迟可能比 2.1.29 略增，因为要等 0.65 秒静音；但仍应远低于 2.1.28；
- `inc tts hold incomplete` 可能在虚词/半词上多等 0.65–1.3 秒，这是为了避免切坏句子；
- 如果 0.65 秒在 x-asr 上仍太碎或太晚，明天只调 0.65/虚词策略，不加速、不丢句。

## 6. 回滚

- 2.1.29 包仍在 releases；
- 模型包 1.0.1 不变；
- 关闭“LCT 式增量播报”即回到整句 TTS（不作为测试方向）；
- 代码备份：`D:\shoujichajian\CallCaption\backup\2.1.30-pre-20261116-093603`。
