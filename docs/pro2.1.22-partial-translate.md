# Pro 2.1.22：远端 partial 即时翻译（仅字幕，不播报）

- 日期：2026-11-14
- 包：`net.user.callcaptionpro_1.0.0-pro2.1.22_arm64e.deb`
- 大小：6,520,772 字节
- SHA-256：`e129db8259bc594984378e4e7e21621a256e468a663c92710c0406d5914cf18c`
- 构建：GitHub Actions run `43577158984`，commit `84b6656`
- 基础：2.1.21（`2c01cb2`）

## 1. 这是什么

不是替换语音，也不动对方原声。流程：

1. 对方说话，远端 ASR 持续出英文 partial（`I|`）；
2. 每 1.5 秒把当前 partial 发给翻译引擎（来电翻译引擎，默认 Google）；
3. 中文结果作为**临时字幕**显示，**不触发 TTS**；
4. 句子结束、ASR 出 final（`RQ|`）后，最终翻译再替换临时字幕；
5. 只有 final 才生成中文 TTS。

所以：

- 对方的声音一直正常播放，没有“没有语音”；
- partial 只加速**文字**，中文语音仍然等 final；
- partial 译文可能不完整/会变，final 会修正；
- 代价是翻译 API 调用变多，1.5 秒节流；设置页可关。

## 2. 实现

`CCSupport.m`：

- 收到 `I|` 后，除了更新英文原文，还调用 `CCUIRemotePartialText()`。

`CCUI.m`：

- `CCUIRemotePartialText()`：
  - 只在通话中/挂断 grace 内工作；
  - `PartialTranslate` 开关关闭时直接返回；
  - 少于 4 个字符不翻；
  - 对方本来就说中文（mostly-CJK）时直接显示中文，不翻译；
  - 1.5 秒节流，文本没变不重复请求；
  - 用 `g_remotePartialGen` 做失效控制：final 到达或新一通时 gen++，晚到的 partial 译文不会覆盖 final；
  - 回调只调用 `CCUIDeliverRemoteTranslated()`，**不调用 TTS**。
- `CCUIRemoteFinalText()`：
  - 进入时 gen++，取消在途 partial，final 优先。
- 新一通 `CCUIHandleCallActive(YES)` 重置 partial 节流状态。

`CCSettings.m`：

- `功能开关` 新增：
  **远端即时翻译（仅字幕，不播报）**，默认开，键名 `PartialTranslate`。

## 3. 日志

`asr.log` / 诊断日志应出现：

```text
R partial translate: How are you
R partial trans[Google]: 你好吗
R partial translate: How are you doing
R partial trans[Google]: 你好吗，你在做什么
RQ| ...
tts zh synth seq=...
```

- `R partial translate`：发起 partial 翻译；
- `R partial trans[...]`：显示临时中文字幕；
- final 后的 `tts zh synth`：只有 final 才播报。

## 4. 测试步骤

1. 安装 2.1.22，覆盖 2.1.21。
2. `设置 → 功能开关` 确认“远端即时翻译（仅字幕，不播报）”为开。
3. 用微信 Pro 接通真实通话，让对方连续说 2–3 句英文。
4. 观察：
   - 对方还在说的时候，中文字幕是否开始更新；
   - 中文 TTS 是否仍然只在句子结束后才播；
   - final 后字幕是否被最终译文替换。
5. 关闭该开关，再打一通：中文字幕应回到“final 才出现”。
6. 如果 API 调用过多/翻译引擎限流，关闭开关即可，不影响 final 翻译和 TTS。

## 5. 注意

- partial 译文可能比 final 粗糙，这是正常的；final 是准的。
- partial 不改变对方的原声，也不改变 TTS 队列；TTS 语速仍由 2.1.21 的设置控制。
- 如果 partial 请求很慢，可能出现“字幕跳一下再被 final 覆盖”；以 final 为准。
- 本版不改 ASR 模型/解码；两模型方案在 2.1.23 单独做。

## 6. 回滚

- 2.1.21 包：
  `net.user.callcaptionpro_1.0.0-pro2.1.21_arm64e.deb`
- 功能基线：`STABLE-net.user.callcaptionpro_2.1.2-off_arm64e.deb`。
