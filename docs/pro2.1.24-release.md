# Pro 2.1.24：LCT 式全量增量 TTS（实验开关，默认关）

- 日期：2026-11-15
- 包：`net.user.callcaptionpro_1.0.0-pro2.1.24_arm64e.deb`
- 大小：6,521,728 字节
- SHA-256：`d530b6be0798dc46150e201abf855ce596bf7e39c51cce1df81ec52578859e28`
- 构建：GitHub Actions run `43670813435`，commit `9a030ba`
- 模型包：不需要更新，继续用 `models_1.0.1`
- 设计稿：`docs/pro2.1.24-incremental-tts-design.md`

## 1. 这版做什么

按 LCT 的成功经验：

```text
不等整句 final
→ partial/稳定从句一到就翻译
→ 逐段 TTS
→ 100% 语速
→ final 只补未播尾段
```

同时满足老爹的硬约束：

- **不提高 TTS 语速**；
- **不丢句**；
- **不做口播简版/摘要**；
- **Google/DeepL 主链路，AI 只做翻译兜底**（不删除 AI，不改 prompt）。

## 2. 默认关闭

设置页新增：

```text
功能开关 → LCT 式增量播报（实验）   默认关
```

默认关是为了 A/B：

- 关：行为与 2.1.23 完全一致（final 后整句 TTS）；
- 开：走增量短段播报。

只对 **CPU 远端 ASR** 生效；腾讯远端路径（R|）保持原行为，避免双播。

## 3. 开启后链路

```text
x-asr partial I|
  → 稳定从句/标点切段
  → 全量翻译（Google/DeepL，AI 兜底）
  → 只播新增中文后缀
  → cc_tts_zh FIFO，不丢句

x-asr final RQ|
  → 完整 final 翻译用于字幕
  → 只补未提交的尾段
  → 不再触发整句 TTS
```

## 4. 关键行为

### 4.1 切段

- 优先从句标点 `, . ? ! ;`；
- partial 稳定 0.8 秒后，整段剩余部分可播；
- 超长兜底 50 字符，在空格处切，不切断单词；
- 不改变翻译内容，不做简版。

### 4.2 不丢句

增量模式下 `CCZhTTSEnqueue`：

- 关闭原来的 3 条/3 秒 merge、drop；
- 改为 FIFO，按顺序播；
- 日志会出现：
  ```text
  tts zh enqueue ... inc=1
  ```
  不应再出现 `tts zh drop`。

### 4.3 final 尾段

- final 到达时，只把当前句未提交的源文本尾巴送翻译/TTS；
- 已播从句不重播；
- 完整 final 翻译仍更新中文字幕。

### 4.4 AI 兜底

- `CCTranslateWithEngine` 的引擎顺序不改；
- Google/DeepL/MyMemory 失败后，仍可按现有顺序降级到 AI；
- AI 不参与简版/摘要，不改变正常主链路。

## 5. 测试步骤

1. 安装 2.1.24，覆盖 2.1.23；模型包 1.0.1 不用动。
2. 设置：
   - `中文字幕语音播报`：开；
   - `LCT 式增量播报（实验）`：开；
   - `对方原音`：30；
   - `远端即时翻译`：开（字幕用）。
3. 先用 7 段 TTS 素材连续播：
   ```text
   D:\shoujichajian\CallCaption\测试日志\english_tts_20261114
   ```
4. 看 `probe.log`/`asr.log`：
   ```text
   inc tts reset seq=...
   inc tts clause pending=...
   inc tts translate: ...
   inc tts commit[google]: ...
   inc tts final tail: ...
   tts zh enqueue ... inc=1
   ```
5. 重点看：
   - 第一条 `inc tts commit` 距离对应 partial/final 多久；
   - `tts zh gate` 最大值；
   - 是否还有 3 句以上落后；
   - 有没有重复播报、漏句；
   - 有没有 `tts zh drop`（增量模式下不应出现）。
6. A/B：同一段素材关掉开关再测一次，对比整句 TTS 的落后。

## 6. 失败判定

- 出现 `tts zh drop`：增量模式没生效，检查开关/远端 ASR 是否 CPU；
- 只有 `inc tts translate` 没有 `inc tts commit`：翻译失败，查 Key/网络/AI 兜底；
- 有 commit 但没有 `tts zh enqueue ... inc=1`：TTS 被关闭或通话已断；
- backlog 继续涨：全量中文 TTS 仍长于英文输入，记录 gate 曲线，下一步再调切段/重叠，不加速、不丢句。

## 7. 回滚

- 关闭 `LCT 式增量播报` 即回到 2.1.23 行为；
- 回滚包：`net.user.callcaptionpro_1.0.0-pro2.1.23_arm64e.deb`；
- 模型包 1.0.1 不变。
