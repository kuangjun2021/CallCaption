# Pro 2.1.18：微信多开（微信 Pro / com.tencent.xin1）远端捕获

- 日期：2026-11-14
- 包：`net.user.callcaptionpro_1.0.0-pro2.1.18_arm64e.deb`
- 大小：6,518,620 字节
- SHA-256：`974923546e379501f6c77dac42fd9b265f09d5a3e26269d0a8736a561a4d15f1`
- 构建：GitHub Actions run `43563981238`，commit `c7ef278`，完整 Theos 编译

## 1. 真机确认的标识

- 原版微信：`com.tencent.xin`，可执行名 `WeChat`
- 多开「微信 Pro 8.0.60」：`com.tencent.xin1`，可执行名 `WeChat`
- App 路径：
  - 原版：`/var/containers/Bundle/Application/0784B6BC-.../WeChat.app`
  - 多开：`/var/containers/Bundle/Application/5321CF13-.../WeChat.app`
- 数据容器：
  - `com.tencent.xin` → `/var/mobile/Containers/Data/Application/286AA90E-...`
  - `com.tencent.xin1` → `/var/mobile/Containers/Data/Application/5B9738D0-...`

## 2. 改了什么

- AppProbe filter：
  - Executables：`WhatsApp`、`WeChat`（一个 `WeChat` 同时覆盖原版和多开）
  - Bundles：`net.whatsapp.WhatsApp`、`com.tencent.xin`、`com.tencent.xin1`
- daemon：
  - `CCIsWeChatContainerID()`：接受 `com.tencent.xin` 以及数字后缀 `com.tencent.xin1/2/...`，排除 `.watch`。
  - `CCAllWeChatDocs()`：扫描所有微信容器，原版 + 多开全部返回。
  - `CCAllCallAppDocs()`：WhatsApp + 所有微信容器。
  - `cc_cfg.txt`、`cc_tts.wav`、`cc_tts_zh_*.wav` 写入所有微信容器，多开版 AppProbe 能读到自己的配置。
  - 远端 `cc_remote_*.wav` 仍然扫描所有 App Documents，多开版写出的 WAV 会被找到。
- 版本：2.1.18；WhatsApp 路径不变，英文 TTS 上行仍未动。

## 3. CI 产物核对

- `control`: `Version: 1.0.0-pro2.1.18`
- daemon：`audioservice started (pro2.1.18)`
- Prefs：`1.0.0-pro2.1.18`
- filter：
  ```text
  Executables: WhatsApp, WeChat
  Bundles: net.whatsapp.WhatsApp, com.tencent.xin, com.tencent.xin1
  ```
- 脚本 0755，control 0644，arm64e。

## 4. 微信 Pro 测试步骤

1. 安装 2.1.18，覆盖 2.1.17。
2. 打开「微信 Pro」（`com.tencent.xin1`），用它的语音通话。
3. 面板出现并激活（自动或点“译”）。
4. 双方各说几句，保持 30–60 秒。
5. 导出 `probe.log`、`asr.log`、`spool.txt`、`daemon.heartbeat`；如果多开 Documents 有 `cc_remote_*.wav`，一起带上。

## 5. 这次看什么

### 5.1 多开是否被注入

```text
hook: dylib loaded proc=WeChat bundle=com.tencent.xin1 ...
hook: setprop hook ... OK
hook: render hook ... OK
```

`bundle=com.tencent.xin1` 是多开；`bundle=com.tencent.xin` 是原版。

### 5.2 多开是否走 AudioUnit render callback

```text
hook: fmt u... rate48000 ... ch1 bits16 ...
hook: renderCB ... ok1 ...
```

### 5.3 daemon 是否选中多开的远端 WAV

```text
remote: file source cc_remote_...wav (...)
remote: alive, audio=... frames=... rms=...
```

`frames` 增长后，spool 应出现 `I|` / `RQ|`，远端中文字幕和中文 TTS 应该工作。

### 5.4 多开容器的配置

多开 Documents 里应出现：

```text
/var/mobile/Containers/Data/Application/5B9738D0-.../Documents/cc_cfg.txt
```

里面应有 `call=1`。

## 6. 失败分支

- 没有 `dylib loaded proc=WeChat bundle=com.tencent.xin1`：过滤器/进程名仍未命中；把 `probe.log` 和多开 Info.plist 的 `CFBundleExecutable` 发我。
- 有 `dylib loaded`，但没有 `fmt/renderCB`：多开音频不走主 App 的 AudioUnit render callback。
- 有 `renderCB`，但 `frames=0`：多开 Documents 没有 `cc_cfg.txt` 或 daemon 没选中 WAV；检查多开 Documents 文件列表。
- `frames>0` 但 `asr.log` 的 `R` 没有 final：WAV 格式/采样率问题。

## 7. 回滚

- 2.1.17 / 2.1.16 仍在 releases 目录。
- 功能基线：`STABLE-net.user.callcaptionpro_2.1.2-off_arm64e.deb`。
