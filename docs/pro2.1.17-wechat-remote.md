# Pro 2.1.17：微信远端音频捕获（第一步）

- 日期：2026-11-14
- 包：`net.user.callcaptionpro_1.0.0-pro2.1.17_arm64e.deb`
- 大小：6,518,040 字节
- SHA-256：`d9dbb4bfa3e2b64a777fd07b3e99f09ceb61ea844d8ac51370b973ba32593e71`
- 构建：GitHub Actions run `43561253147`，commit `6b3ba54`，完整 Theos 编译
- 基线：2.1.16；本次只加微信远端捕获，WhatsApp 路径不变，英文 TTS 上行未动。

## 1. 改了什么

- `CallCaptionProAppProbe.plist`：
  - Executables 加 `WeChat`
  - Bundles 加 `com.tencent.xin`
- `CCAppProbe.m`：
  - 启动白名单允许 `WeChat`，其余逻辑与 WhatsApp 共用。
- `CCAudioService.m`：
  - 新增 `CCFindWeChatDocs()`（MCM 元数据 `com.tencent.xin`）。
  - 新增 `CCAllCallAppDocs()`，同时返回 WhatsApp / 微信 Documents。
  - `cc_cfg.txt`、`cc_tts.wav`、`cc_tts_zh_*.wav`、reset 标记同时写两边。
  - 远端 `cc_remote_*.wav` 扫描覆盖所有 App Documents，不再只盯 WhatsApp。
  - WhatsApp 的 `g_waDocsDir` 缓存不再被远端选文件改写，避免影响 WhatsApp 回归。
- 版本：2.1.17（daemon 心跳、Prefs、安装脚本同步）。

## 2. CI 产物核对

- `control`: `Version: 1.0.0-pro2.1.17`
- daemon：`audioservice started (pro2.1.17)`
- Prefs：`1.0.0-pro2.1.17`
- AppProbe filter：
  ```text
  Executables: WhatsApp, WeChat
  Bundles: net.whatsapp.WhatsApp, com.tencent.xin
  ```
- `preinst/postinst/postrm`：0755，control 0644
- daemon：`Mach-O 64-bit arm64e (caps: PAC00)`

## 3. 微信测试步骤

1. 安装 2.1.17，覆盖 2.1.16。
2. 让对方用微信打语音来电，你接听。
3. 面板出现后接通/激活（自动或点“译”）。
4. 双方各说几句，保持 30–60 秒。
5. 导出完整日志到 `测试日志/1.0.0-pro2.1.17/`：
   - `probe.log`
   - `asr.log`
   - `spool.txt`
   - `daemon.heartbeat`
   - `local16k.wav`
   - 如果存在 `remote16k.wav`
   - 微信 Documents 里的 `cc_remote_*.wav`（如果有）

## 4. 这次要看什么

### 4.1 微信是否被注入

```text
hook: dylib loaded proc=WeChat bundle=com.tencent.xin ...
hook: setprop hook ... OK
hook: render hook ... OK
```

如果完全没有 `dylib loaded proc=WeChat`，说明过滤器/进程名不对，或微信通话音频在扩展进程里。

### 4.2 微信是否走 AudioUnit render callback

```text
hook: fmt u... rate48000 ... ch1 bits16 ...
hook: renderCB ... ok1 ...
```

有 `fmt/renderCB`，说明 AppProbe 能包装微信的通话回调，远端 WAV 应该开始写。

### 4.3 远端 WAV 是否被 daemon 选中

```text
remote: file source cc_remote_...wav (...)
remote: alive, audio=... frames=... rms=...
```

如果 `frames` 持续增长，说明微信远端音频已经进来；spool 应出现 `I|` / `RQ|`，远端中文字幕和中文 TTS 应该工作。

### 4.4 失败分支

- 有 `dylib loaded proc=WeChat`，但没有 `fmt/renderCB`：微信音频不走主 App 的 AudioUnit render callback，第一步失败；下一步考虑系统 Tap(-2) 或微信扩展进程。
- 有 `renderCB`，但 `remote: alive frames=0`：daemon 没选中微信 WAV，或 `cc_cfg.txt` 没写到微信 Documents；把微信 Documents 文件列表发我。
- `frames>0`，但 `asr.log` 的 `R` 没有 final：微信 WAV 采样率/格式与 48k mono s16 不一致；把 `asr.log` 和 `cc_remote_*.wav` 发我。

## 5. 本次范围

- 本次只做“微信远端音频捕获”。
- 英文 TTS 上行（对方听到我们的英文）仍未动：当前 mixer 对所有 `AudioUnitRender` 盲混，微信的上行 buffer 可能不同；这是第二步。
- 如果第一步成功，微信可以先用于“对方英文→中文字幕 + 中文 TTS”，也就可以找远端朋友做 TTS 重叠测试；英文 TTS 回声 A–D 仍需第二步。

## 6. 回滚

- 2.1.16 / 2.1.15 仍在 releases 目录。
- 功能基线回滚：`STABLE-net.user.callcaptionpro_2.1.2-off_arm64e.deb`。
