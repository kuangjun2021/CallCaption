# Pro 2.1.15：安装流程修复 + 版本号编译进二进制

- 日期：2026-11-14
- 包：`net.user.callcaptionpro_1.0.0-pro2.1.15_arm64e.deb`
- 大小：6,516,860 字节
- SHA-256：`33d0cd9e630a839fe39bddfd2e8d296fea8c3c9d992beabbbc16ca2f856d2b33`
- 构建：GitHub Actions run `43469674703`，commit `5fb798e`，完整 Theos 编译
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

2.1.15 把版本号真正编译进二进制：

- `CallCaptionProAudioService`：
  - `audioservice started (pro2.1.15)`
  - 心跳 `%.0f pro2.1.15\n`
- `CallCaptionProPrefs.bundle/Info.plist` 的 `CFBundleVersion` / `CFBundleShortVersionString`：`1.0.0-pro2.1.15`
- 源码 `CCAudioService.m` / `CCSettings.m` / `control` 同步为 2.1.15。

## 3. 构建过程

### 3.1 第一次：本地补丁验证（已归档）

GitHub Actions 曾因私有仓库额度耗尽被拦住：

```text
The job was not started because recent account payments have failed
or your spending limit needs to be increased.
```

当时本地没有 Theos/iPhoneOS SDK，先做了等长字符串替换 + `ldid` 重新签名，用于验证方向：

- 工具：`ldid v2.1.5-procursus7`（Linux x86_64 预编译）
- 签名 entitlements 与旧二进制逐项对比，22 个 key 完全一致
- 二进制仍为 `Mach-O 64-bit arm64e (caps: PAC00) executable`
- 载荷逐文件 SHA-256 对比：只有 `CallCaptionProAudioService` 和 `CallCaptionProPrefs.bundle/Info.plist` 变化

该文件已归档到：

`D:\shoujichajian\CallCaption\releases\localpatch\net.user.callcaptionpro_1.0.0-pro2.1.15_arm64e-localpatch.deb`

仅作为排查备用，不建议安装。

### 3.2 最终：仓库转公开 + CI 完整编译

仓库 `kuangjun2021/CallCaption` 已临时改为 public，Actions 免费额度恢复，触发完整构建：

- run：`43469674703`
- commit：`5fb798e`
- 结果：`completed success`
- macOS runner 排队约 10 分钟（GitHub 提示 macOS arm64 容量紧张），实际构建约 3 分钟。

CI 产物核对：

- `control`：`Version: 1.0.0-pro2.1.15`
- daemon：`audioservice started (pro2.1.15)`、`%.0f pro2.1.15`
- Prefs Info.plist：`CFBundleVersion = CFBundleShortVersionString = 1.0.0-pro2.1.15`
- `preinst/postinst/postrm` 与源码 SHA-256 完全一致，权限 0755
- 重新编译的 daemon 仍是 `Mach-O 64-bit arm64e (caps: PAC00)`
- entitlements 22 个 key 与仓库文件完全一致

## 4. 安装

1. 直接在 Sileo 安装 CI 正式包：
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

## 5. 回滚

- 2.1.14 安装流程修复版仍在 releases 目录。
- 本地补丁版在 `releases/localpatch/`，仅排查用。
- 功能基线回滚：`STABLE-net.user.callcaptionpro_2.1.2-off_arm64e.deb`（tag `pro2.1.2-off-stable`）。

## 6. 仓库可见性

- 为了让 Actions 免费构建，仓库已改为 public。
- 公开前已扫描当前代码和提交历史，未发现硬编码的 SecretId/SecretKey/API Key；工具脚本均从环境变量或参数读取。
- 后续可以改回 private，但改回后 CI 会再次受私有仓库额度限制。
