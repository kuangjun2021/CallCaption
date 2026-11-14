# Pro 2.1.19：修复 app cfg 每 0.5 秒重复写/刷日志

- 日期：2026-11-14
- 包：`net.user.callcaptionpro_1.0.0-pro2.1.19_arm64e.deb`
- 大小：6,517,672 字节
- SHA-256：`23ff210802f5917da9cdb194e15392abd786141ad449af875a1ab20da64bde34`
- 构建：GitHub Actions run `43565400066`，commit `77e501b`

## 1. 2.1.18 真机安装结果

- `audioservice started (pro2.1.18)`，daemon/UI 正常。
- `app cfg ... apps=3`：daemon 已找到 WhatsApp、原版微信、微信 Pro 三个容器，多开容器识别成功。

## 2. 2.1.18 的问题

`CCWriteAppCfg` 用“`cc_cfg.txt` 是否存在”判断是否需要重写。只要有一个容器写入失败，下一 tick 又会判定需要写，导致：

```text
app cfg ... apps=3
app cfg ... apps=3
app cfg ... apps=3
```

每 0.5 秒刷一次，既刷日志，也可能掩盖真正写失败的容器。

## 3. 2.1.19 修复

- `CCWriteAppCfg` 改为“配置内容或容器列表变化才写”：
  - `lastCfg` 比较配置内容；
  - `lastDocsSig` 比较容器路径列表；
  - 不再用文件存在性判断。
- 写失败时打印一次失败容器路径：

```text
app cfg write failed: /var/mobile/Containers/Data/Application/.../Documents
```

- 正常只出现一次：

```text
app cfg remote=0 local=0 on=1/1 call=0 apps=3 fail=0
```

## 4. 测试步骤

1. 安装 2.1.19，覆盖 2.1.18。
2. 打开「微信 Pro」（`com.tencent.xin1`）。
3. 看 `probe.log`：
   - `app cfg ... apps=3 fail=0` 只出现一次（或配置/通话状态变化时出现）。
   - `dylib loaded proc=WeChat bundle=com.tencent.xin1`。
4. 用微信 Pro 打/接语音，面板出现并激活，双方说 30–60 秒。
5. 检查：
   ```text
   hook: fmt u... rate48000 ... ch1 bits16 ...
   hook: renderCB ... ok1 ...
   remote: file source cc_remote_...wav
   remote: alive, audio=... frames=... rms=...
   ```
   spool 出现 `I|` / `RQ|`。

## 5. 失败分支

- `app cfg ... fail=1`：看下一行 `app cfg write failed: <path>`，把该容器路径发我；说明该微信容器 Documents 写不进去。
- 没有 `dylib loaded proc=WeChat bundle=com.tencent.xin1`：把 `probe.log` 和多开 Info.plist 的 `CFBundleExecutable` 发我。
- 有 `dylib loaded` 但没有 `fmt/renderCB`：多开音频不走主 App 的 AudioUnit render callback。
- 有 `renderCB` 但 `frames=0`：多开 Documents 没有 `cc_cfg.txt`，或 daemon 没选中 WAV。
- `frames>0` 但 `asr.log` 的 `R` 没有 final：WAV 格式/采样率问题。

## 6. 范围

- 本次只修配置写入缓存；远端捕获逻辑与 2.1.18 相同。
- 英文 TTS 上行仍是第二步。
- 回滚：2.1.18 / 2.1.17 / 2.1.16。
