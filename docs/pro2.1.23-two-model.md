# Pro 2.1.23：两模型各司其职（远端 x-asr greedy + 本机 zh-14M）

- 日期：2026-11-14
- 包：待构建 `net.user.callcaptionpro_1.0.0-pro2.1.23_arm64e.deb`
- 模型包：待构建 `net.user.callcaptionpro.models_1.0.1_iphoneos-arm64.deb`
- 基础：2.1.22（`84b6656`）

## 1. 验证结论（PC 实测）

详见 `docs/pro2.1.21-model-validation.md`。

- 本机中文：zh-14M 比 x-asr 更准、更小（约 25MB int8）、更快。
- 远端英文：试过的英文专用模型（Kroko、en-2023-06-26）都没有全面超过 x-asr，不能直接换。
- `五百`：同一段音频，`greedy_search` 出 `how much`，`modified_beam_search` 出 `五百`；不是热词问题，是波束解码把英文压成中文。
- `好爱哟`：greedy/beam 都出中文，是 x-asr 对带口音英文的误判，需要更强的口音/电话英文模型，暂不解决。

## 2. 改了什么

### 2.1 helper：两个 recognizer

`CCProASR.m`：

- `CCASRStream` 自己持有 `rec` 指针，不再由 `RunLive` 传同一个 recognizer。
- `RunLive(remoteRec, localRec, ...)`：
  - 本机流用 `localRec`（zh-14M）；
  - 远端流用 `remoteRec`（x-asr）。
- `CCCreateRecognizer(modelDir, isLocal, tag)`：
  - 远端：`model_type=zipformer2`，`greedy_search`；
  - 本机：`model_type=zipformer`，`greedy_search`；
  - 两边都关闭热词/BPE/beam，避免 `五百` 类波束误判。
- 新增参数 `--local-model-dir`，默认 `models/zh-14m`。
- 本机模型缺失时，自动回退到远端 recognizer（不会导致 helper 启动失败），日志：
  `local model unavailable, fallback to remote recognizer`。

### 2.2 daemon

`CCAudioService.m`：

- 新增 `CCASRLocalModelDir()` → `models/zh-14m`。
- 启动 helper 时增加 `--local-model-dir`。

### 2.3 模型包 1.0.1

`.github/workflows/build.yml`：

- 模型包增加 `models/zh-14m/`：
  - `encoder.int8.onnx`
  - `decoder.onnx`
  - `joiner.int8.onnx`
  - `tokens.txt`
- 模型包版本 `1.0.1`，安装后主包即可使用本机中文专用模型。

### 2.4 设置页

- 移除“热词（逗号分隔）”：2.1.23 两边都用 greedy，热词不参与解码。
- 其余设置不变；TTS 语速、partial 翻译、音量、音色都保留。

## 3. 资源与风险

- 内存：x-asr 约 169MB + zh-14M 约 25MB；helper 常驻约 200MB 量级（以真机 `ps`/Instruments 为准）。
- 启动：x-asr 约 4.5s + zh-14M 约 0.5–1s；响铃预加载/常驻模式可覆盖。
- CPU：两个 recognizer 各 2 线程，A16 6 核；需要真机看温度/掉电。
- 回退：本机模型缺失时自动用远端模型，不会黑屏/不出字。

## 4. 测试步骤

1. 先安装模型包 1.0.1，再安装主包 2.1.23（覆盖 2.1.22）。
2. 检查模型目录：
   ```text
   /var/mobile/Library/CallCaptionPro/models/x-asr-480ms/
   /var/mobile/Library/CallCaptionPro/models/zh-14m/
   ```
3. 微信 Pro 接通，双方各说 60 秒以上。
4. 看 `asr.log`：
   ```text
   start mode=live ... remoteModel=x-asr-480ms localModel=zh-14m
   R model loaded in ... (x-asr-480ms, greedy)
   L model loaded in ... (zh-14m, greedy)
   ```
5. 重点验证：
   - 远端最后一句是否从 `五百` 回到 `how much`；
   - 远端是否仍有 `好爱哟`（预期仍可能，属模型口音问题）；
   - 本机中文是否更准（`想到哪儿说的了` 等）；
   - 面板/字幕/TTS/partial 翻译是否正常；
   - 通话 5–10 分钟后温度、内存、是否有 helper 被杀/重启。
6. 如果内存吃紧或启动太慢：
   - 先把预加载改成 `resident` 或 `ring` 观察；
   - 必要时回滚 2.1.22 + models 1.0.0。

## 5. 回滚

- 主包：`net.user.callcaptionpro_1.0.0-pro2.1.22_arm64e.deb`（SHA `e129db…`）
- 模型包：`net.user.callcaptionpro.models_1.0.0_iphoneos-arm64.deb`
- 功能基线：`STABLE-net.user.callcaptionpro_2.1.2-off_arm64e.deb`
