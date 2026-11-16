# Pro 2.1.31：低声抓音修复（live 尾部 flush + 置信度/AGC）

- 日期：2026-11-16
- 包：`net.user.callcaptionpro_1.0.0-pro2.1.31_arm64e.deb`
- 大小：6,527,240 字节
- SHA-256：`65b26b4ee9149b24bc08f982bd1613e2959c7f81f92be7e99f8fa0b9e505ca3f`
- 构建：GitHub Actions run `43791276494`，commit `d11de6c`
- 模型包：不变，继续 `models_1.0.1`

## 1. 问题确认

老爹说的“低声”是**对方说话声音小，抓音抓不到**，不是播放音量小。  
这轮先把它拆成三个可验证点：

1. **干净低声**：把干净的第 5 段衰减到 RMS 0.0002，x-asr 仍能完整识别；
2. **真实极低段**：2.1.4 A 的低声段 RMS 0.0002–0.0017，放大 24/48/64/96/160 倍都无输出；
3. **挂断尾部**：`CCProASR.m` 的 live 模式退出时没有 flush，最后一句没等到 endpoint 就丢。

结论：**低声不是单纯增益不够**。模型对干净低电平不敏感；真实失败主要是噪声/断帧/尾部没 flush。盲目把增益拉到 64/96 只会放大噪声，不能恢复听不清的语音。

## 2. 2.1.31 改了什么

### 2.1 P0：live 尾部 flush

`RunLive` 在 armed file gone / 停流退出前，对每条流调用：

```objc
- (void)flushTail {
    SherpaOnnxOnlineStreamInputFinished(_stream);
    while (SherpaOnnxIsOnlineStreamReady(_rec, _stream)) {
        SherpaOnnxDecodeOnlineStream(_rec, _stream);
    }
    // 取 result，发 I|/RQ| 或 LI|/LQ|
}
```

- 之前只有 `!live`（离线文件）路径做 `InputFinished`；
- live 路径直接退出，挂断前最后一句没有 final；
- 现在先 flush，再打印 done；`lastFinalText` 做重复保护；
- 日志：
  ```text
  R tail flush conf=...: ...
  L tail flush conf=...: ...
  R tail flush duplicate skipped: ...
  R tail flush empty
  ```
- 这条对远端/本机都生效，不只低声。

### 2.2 P1：远端 AGC 上限 24 → 32

- 只对 ASR 副本 `flt` 生效，不改 `remote16k.wav`、不改播放原声；
- 目标 RMS 仍 0.06；
- 上限从 24 提到 32，给极低声多一点余量；
- 没有盲目拉到 64/96：离线实验证明拉到 160 倍也救不回 2.1.4 极低段，只会放大噪声。

### 2.3 P1：低声时动态放宽置信度

远端原来的门限：

```text
confAvg < -1.4        → 压 partial / 丢 final
text <= 2 && conf < -1.3 → 丢 final
```

2.1.31 改成：

```text
如果 AGC gain >= 12（输入很低）：
  confLimit = -1.8
否则：
  confLimit = -1.4
短句门限 = confLimit + 0.1
```

- 低声时置信度天然偏低，避免把有效轻声误杀；
- 正常音量不变；
- 日志：
  ```text
  R conf relaxed avg=... gain=...
  ```

### 2.4 本机低声

- 目前没有一条“老爹自己轻声说中文”的有效样本；
- `local16k.wav` 只有环境噪声/碎片，不能作为依据；
- 这次不动本机 AGC，避免把噪声放大成假字幕；
- 尾部 flush 对 local 也生效。

## 3. 离线验证

### 3.1 干净第 5 段衰减

| 目标 RMS | raw x-asr |
|---:|---|
| 0.004 | 完整 |
| 0.002 | 完整 |
| 0.001 | 完整 |
| 0.0005 | 完整 |
| 0.0002 | 完整 |

→ 模型不怕干净低声；低声失败主要是噪声/断帧。

### 3.2 2.1.4 A 极低段

- RMS 0.0002–0.0017；
- AGC 24 / 48 / 64 / 96 / 160 倍全部无输出；
- 这段音频本身已不可识别，不是增益问题。

### 3.3 尾部 flush

用 4 秒截断的干净第 5 段，离线脚本在 `input_finished` 后能补出：

```text
final-end: I am speaking more quietly now.
```

→ live 路径补同样的 flush 后，挂断前最后一句不会再因为没等到 endpoint 而丢。

## 4. 测试

2.1.30 先别装；2.1.31 同时包含 TTS 修复和低声修复，一次测完。

接听：老爹的博士手机，只接听、导日志，不播放 MP3。  
拨号：另一台手机用微信 Pro 拨号，并播放短版 5 段 MP3。

设置：

- 中文字幕语音播报：开
- LCT 式增量播报：开
- 对方原音：30
- 远端即时翻译：开
- TTS 语速：100%

等 `● 本机 CPU ASR 已启动` 再播；段间 1–2 秒；导出 `probe.log`、`asr.log`、`spool.txt`。

重点看：

1. 第 5 段低声是否出字幕/TTS；
2. 挂断前最后一句是否有 `tail flush` final；
3. `R agc` gain 是否超过 24（说明新上限生效）；
4. 是否有 `R conf relaxed`，且没有明显噪声假字幕；
5. `The agent ... delayed by thirty minutes` 是否说“延误三十分钟”；
6. 是否还有半词/虚词结句；
7. `tts zh enqueue` 是否仍 `pending=1`。

## 5. 预期与边界

- **有把握**：挂断前最后一句不再因为没 flush 而丢；极低声多一点增益余量；低声有效 final 不再被 -1.4 误杀。
- **不保证**：如果对方声音小到被环境噪声淹没，AGC/置信度都救不回来；那需要降噪或换采集链路，不是继续加增益。
- 本机轻声中文还没有样本，这次不盲改。

## 6. 回滚

- 2.1.30 包仍在 releases；
- 模型包 1.0.1 不变；
- 代码备份：`D:\shoujichajian\CallCaption\backup\2.1.31-pre-20261116-101332`。
