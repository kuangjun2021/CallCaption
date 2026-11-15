# Pro 2.1.29：LCT 式短句增量播报（取消稳定门）

- 日期：2026-11-15
- 包：`net.user.callcaptionpro_1.0.0-pro2.1.29_arm64e.deb`
- 大小：6,524,292 字节
- SHA-256：`783fad0a2a442c14a4102666adc1fd6175de46fbb8090472787d145ce24b3fd5`
- 构建：GitHub Actions run `43727074040`，commit `b55009c`
- 模型包：不变，继续 `models_1.0.1`

## 1. 为什么再改

2.1.28 仍然是“整段 partial 翻译 + 中文块稳定门”：

- 英文 partial 整段送翻译；
- 中文按标点切块；
- 一个块要在上一版 partial 译文里再次出现，才允许 TTS；
- 不稳定就 hold，final 才补。

老爹明确说这仍然偏离 LCT：TTS 还是会被稳定门拖住，听感像 B。

2.1.29 改成 **英文侧短句增量**：

```text
ASR partial 新增英文
→ 在自然标点/短句长度处切开
→ 立即翻译这一小段
→ 立即 TTS
→ final 只补当前分段最后没送出的部分
```

不再要求 partial 译文稳定，不再维护短语表，不再整段等 final。

## 2. 具体规则

### 2.1 只取新增英文

- `g_incSegmentText` 记录当前 ASR 分段已经见过的原文；
- 新 partial 是上一版的延长时，只把新增后缀加入 `g_incPending`；
- 同一分段内原样拼接，保留 partial 自带的空格和词内续接，绝不人为插空格；
- ASR 回退时只更新基线，不重复播；
- 同一分段内改写时，如果能从 pending 末尾回滚，就替换；已经送出去的内容不重复补。

### 2.2 切短句

`g_incPending` 按以下顺序切：

1. **句末标点**：`.` `?` `!` `;` `:` 后面是空格或结尾，立即切；
2. **逗号**：pending 长度 ≥16，且逗号前已有 ≥12 字符，切到逗号；
3. **硬上限**：没有标点时，超过 46 字符就在最后一个空格处切，绝不切半个词；
4. **静音收尾**：pending 连续 1.2 秒没有新增，说明说话停住，剩余部分收尾。

不等待第二次 partial 确认，不做译文稳定性比较。

### 2.3 立即翻译、立即 TTS

- 每个短句进入 `g_incDeltaQ`；
- 同一时间只翻译一句，保证顺序；
- 翻译完成立即 `CCZhTTSEnqueue`；
- TTS 仍然 100%，不加速、不做简版、不丢句；
- AI 仍只是翻译兜底，不是主链路。

### 2.4 final 只补尾巴

- final 到达时，只把当前分段最后没送出的英文补进 pending；
- 有句末标点就立即切；
- 没有句末标点就留给下一段或 1.2 秒静音收尾；
- 增量模式下，final 的整句翻译只用于字幕，不再触发整句 TTS。

### 2.5 ASR 词中断句

这份 x-asr 模型偶尔会在词中间 endpoint，例如：

```text
final: ... the flig
next partial: ht would be de
```

2.1.29 在“上一段没有句末标点、下一段以小写开头”时，用 `UITextChecker` 判断：

- `flig + ht = flight` 是合法英文词，且 `flig` 不是词 → 无缝拼接；
- `think + we = thinkwe` 不合法 → 补空格，不粘词。

只在跨分段补断词时查词典，正常路径不查。

## 3. 不变的部分

- 远端 AGC：不变；
- 远端 x-asr + 本机 zh-14M：不变；
- TTS 100%：不变；
- 不丢句、不做简版；
- AI 只做翻译兜底；
- TTS 首尾静音裁剪：不变；
- 增量开关默认关；
- 腾讯 ASR 路径仍走原来的整句 TTS，避免双播。

## 4. 新增日志

```text
inc tts phrase q=...: ...
inc tts translate: ...
inc tts speak[google]: ...
inc tts pending len=...: ...
inc tts comma cut: ...
inc tts max cut: ...
inc tts idle flush: ...
inc tts segment flush: ...
inc tts word glue: ... + ...
inc tts rewrite: ... -> ...
inc tts final rewrite: ... -> ...
inc tts reset seq=...
```

`tts zh gate` 在 2.1.29 已不存在。

## 5. 测试

1. 安装 2.1.29，覆盖 2.1.28。
2. 设置：
   - 中文字幕语音播报：开
   - LCT 式增量播报：开
   - 对方原音：30
   - TTS 语速：100%
3. 短版 5 段，同音量/位置/顺序，等 ASR 启动后再播。
4. 先测 A（增量开），再测 B（增量关）。
5. 重点看：
   - 每个句号/逗号后是否很快有中文 TTS；
   - `inc tts phrase` 到 `inc tts speak` 的间隔；
   - 是否还有整句等 final 的情况；
   - `Chinese subtitles` 是否完整；
   - `flig + ht` 是否能拼成 `flight`；
   - 是否有重复、漏句、半词；
   - 第 5 段低声是否仍能出字幕。
6. 如果短句太碎或翻译上下文不够，再调 46 字符上限/逗号阈值；不加速、不丢句。

## 6. 预期与代价

- 比 2.1.28 更早：句号/逗号一到就翻译，不再等稳定门；
- 短句翻译天然缺少跨句上下文，可能出现代词/主语省略；这是 LCT 式增量的代价；
- 连续说话时 TTS 仍可能排队，但不会因为稳定门整句卡住；
- 如果 TTS 队列持续落后，下一步只能调短句长度/翻译并发，不能加速或丢句。

## 7. 回滚

- 2.1.28 包仍在 releases；
- 模型包 1.0.1 不变；
- 关闭“LCT 式增量播报”即回到整句 TTS；
- 代码备份：`D:\shoujichajian\CallCaption\backup\2.1.29-lct-delta-20261115-224148`。
