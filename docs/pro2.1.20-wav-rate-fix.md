# Pro 2.1.20：修复微信 Pro 16k 远端 WAV 被按 48k 压缩 3 倍

- 日期：2026-11-14
- 包：`net.user.callcaptionpro_1.0.0-pro2.1.20_arm64e.deb`
- 大小：6,519,096 字节
- SHA-256：`f127cf78717e841cd1b33fb93bc65fb7aa9a4a3177bbaac329231634487836aa`
- 构建：GitHub Actions run `43570714654`，commit `673812c`

## 1. 真机证据

微信 Pro 的 AppProbe 日志：

```text
hook: fmt u1860 s2 e1 rate16000 ch1 bits16 fl0xc
hook: renderCB u1860 b0 ok1 fmt=16000/1/16 fl0xc wav=ok
hook: fmt u7050 ... rate16000 ch1 bits16 ...
hook: renderCB u7050 ... fmt=16000/1/16 ...
```

但 `CCAudioService.m` 的 `pumpFileAudio` 一直按 48k 处理，每 3 个样本取平均：

```c
outFrames = inSamples / 3;
v = (s[idx*3] + s[idx*3+1] + s[idx*3+2]) / 3;
```

结果：

| 文件 | 实际时长 | daemon 识别的时长 |
|---|---:|---:|
| `cc_remote_1860_14870.wav` | 147.49s | 49.1s（147/3） |
| `cc_remote_7050_14870.wav` | 56.61s | 18.87s（56.6/3） |

PC 上同一个 Sherpa 模型直接转原始 16k 文件，出了 12 条 final，包括：

```text
do you speak English?
What's up name
How do you do
good afternoon
```

app 拿到的却是压缩 3 倍、语速 3 倍的音频，所以只认出一个 `Welcome.`。这不是对方没讲，是采样率处理错了。

## 2. 修复

`pumpFileAudio` 先读 WAV 44 字节头，按真实采样率转换：

- `16000`：直接拷贝（微信 Pro）；
- `48000`：每 3 个样本取平均（WhatsApp）；
- 其它：线性插值重采样到 16k。

同时把文件大小/arm offset 的日志改成按实际字节率计算，不再用 96000 B/s。

## 3. CI 产物

- `control`: `1.0.0-pro2.1.20`
- daemon：`audioservice started (pro2.1.20)`
- filter：WhatsApp / WeChat / `com.tencent.xin` / `com.tencent.xin1`
- 脚本 0755，arm64e。

## 4. 测试

1. 安装 2.1.20，覆盖 2.1.19。
2. 打开微信 Pro，打/接语音。
3. `probe.log` 应出现：

```text
remote: wav rate 16000
remote: file source cc_remote_1860_14870.wav (size 147.x s)
```

4. `asr.log` 的 `R` samples 应接近 2.36M（147s × 16k），不再只有 786k。
5. spool 应出现大量 `I|` / `RQ|`；远端中文字幕、中文 TTS 应工作。

## 5. 注意

- 微信 Pro 的 render callback 是**通话混音**，文件里同时有本机中文和对方英文；远端 ASR 可能看到本机中文。UI/置信度门限应过滤掉大部分中文，如果出现重复/回声字幕，再单独处理。
- `app cfg write failed` 仍可能出现在原版微信容器 `286AA90E`；多开容器 `5B9738D0` 是写成功的，不影响本次测试。
- 英文 TTS 上行已经能听到；本次只修远端识别。

## 6. 回滚

- 2.1.19 / 2.1.18 仍在 releases。
- 功能基线：`STABLE-net.user.callcaptionpro_2.1.2-off_arm64e.deb`。
