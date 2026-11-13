# Pro 2.1.15：安装流程修复 + 版本号编译进二进制

- 日期：2026-11-14
- 包：`net.user.callcaptionpro_1.0.0-pro2.1.15_arm64e.deb`
- 大小：6,515,720 字节
- SHA-256：`e5cc5b19cf39ec11e60e1a360a08d9a67081576fa00bf4ec0c4988bb1d84b840`
- 基线：2.1.14（安装流程已真机验证）；2.1.15 只补版本号，ASR/TTS 代码未变。

## 1. 2.1.14 已完成

- 根因：dpkg 覆盖升级会执行已安装旧包的 `postrm upgrade`，旧 postrm 无条件 `killall -9 SpringBoard`，冲掉 Sileo 完成页。
- 修复：postrm 仅 `remove/purge` 做事；preinst 一次性拦截旧 postrm 的 upgrade；postinst 只启动 daemon。
- 真机验证：`install.log` 出现 `preinst patched old postrm`、`kickstart rc=0`，Sileo 完成页停留，手动注销成功。

## 2. 2.1.15 做了什么

2.1.13/2.1.14 都是脚本重打包，守护进程二进制还是 2.1.12 那一版，所以 `probe.log` 一直显示：

```text
audioservice started (pro2.1.12)
```

2.1.15 把版本号真正写进二进制：

- `CallCaptionProAudioService` 内两处 `pro2.1.12` → `pro2.1.15`：
  - `audioservice started (pro2.1.15)`
  - 心跳 `%.0f pro2.1.15\n`
- `CallCaptionProPrefs.bundle/Info.plist` 的 `CFBundleVersion` / `CFBundleShortVersionString`：`1.0.0-pro2.1.12` → `1.0.0-pro2.1.15`
- 源码 `CCAudioService.m` / `CCSettings.m` / `control` 同步为 2.1.15。

### 为什么是二进制补丁

GitHub Actions 本次被账户额度拦住，任务在启动前就失败：

```text
The job was not started because recent account payments have failed
or your spending limit needs to be increased.
```

本地没有 Theos/iPhoneOS SDK，因此采用等长字符串替换 + 重新签名：

- 工具：`ldid v2.1.5-procursus7`（Linux x86_64 预编译）
- 签名 entitlements：与旧二进制逐项对比，22 个 key 完全一致（`orig == repo == new`）
- 二进制仍为 `Mach-O 64-bit arm64e (caps: PAC00) executable`
- 载荷逐文件 SHA-256 对比：只有 `CallCaptionProAudioService` 和 `CallCaptionProPrefs.bundle/Info.plist` 两个文件变化，其余与 2.1.14 完全一致。

## 3. 安装

1. 直接在 Sileo 安装：
   `D:\shoujichajian\CallCaption\releases\net.user.callcaptionpro_1.0.0-pro2.1.15_arm64e.deb`
2. 覆盖 2.1.14，正常应保持“执行 → 完成 → 手动注销”。
3. 注销后确认 `probe.log`：

```text
audioservice started (pro2.1.15)
```

以及 `daemon.heartbeat` 内容包含 `pro2.1.15`。

如果仍显示 `pro2.1.12`，说明新二进制没有真正落盘/重启，导出：

- `/var/mobile/Library/CallCaptionPro/install.log`
- `/var/mobile/Library/CallCaptionPro/probe.log`
- `/var/mobile/Library/CallCaptionPro/daemon.heartbeat`

## 4. 回滚

- 2.1.14 安装流程修复版仍在 releases 目录。
- 功能基线回滚：`STABLE-net.user.callcaptionpro_2.1.2-off_arm64e.deb`（tag `pro2.1.2-off-stable`）。
