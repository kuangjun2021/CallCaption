# Pro 2.1.14：Sileo 安装完成界面修复

- 日期：2026-11-14
- 包：`net.user.callcaptionpro_1.0.0-pro2.1.14_arm64e.deb`
- 大小：6,516,380 字节
- SHA-256：`1635ec5245d9e013559a48a6980d36363ab5151f9b9a1e6db5b14a5992b1ed68`
- 核心 ASR/TTS 代码与 2.1.13 完全相同，本次只改安装/卸载脚本。

## 1. 现象

从 Pro 2.0 起，Sileo 安装 Pro 后不显示正常的“执行 → 完成 → 手动注销”界面，而是在安装最后自动注销/重启 SpringBoard，看起来像没装完。

之前怀疑过：

- Sileo 本身或 `Sileo Respring` 插件；
- preinst/postinst 太慢、被 Sileo 打断；
- 稳定版 `net.user.callcaption` 干扰。

这些都不是根因。

## 2. 根因（已用 dpkg 1.22.6 实测复现）

dpkg 覆盖升级同一个包时，会执行**已安装旧包**的 postrm：

```sh
/var/lib/dpkg/info/<pkg>.postrm upgrade <new-version>
```

Pro 2.0 ~ 2.1.13 的 postrm 没有判断 `$1`，无条件执行：

```sh
"$KILLALL" -9 WhatsApp
"$KILLALL" -9 SpringBoard
```

所以每次“在旧 Pro 上装新 Pro”，安装最后都是旧包的 postrm 杀掉 SpringBoard，Sileo 的完成页被一起冲掉。Pro 2.0 的 postinst 结尾也直接杀过 SpringBoard，属于同一类问题。

这也解释了 2.1.13 的“无 preinst/postinst 对照包”为什么无效：2.1.13 自己虽然没有安装脚本，但覆盖安装时 dpkg 执行的是**已安装的 2.1.12 的 postrm**，照样杀 SpringBoard。

## 3. 修复内容

### postrm

- `upgrade` / `abort-upgrade` / `abort-remove` / `disappear`：立即 `exit 0`，不做任何清理。
- 只有 `remove` / `purge`：停 Pro daemon。
- 永远不再杀 `SpringBoard` / `WhatsApp`；注销由用户点 Sileo 完成页的按钮。
- 恢复稳定版文件前先用 `dpkg -s` 确认 `net.user.callcaption` 仍是 installed 状态，避免稳定版已卸载但 `.disabled` 残留被误恢复。

### postinst

- 只做运行目录权限 + `launchctl kickstart/bootstrap`。
- 不杀 Preferences / WhatsApp / SpringBoard，不做 sleep 轮询，脚本瞬间结束。

### preinst

一次性兼容旧包：在 dpkg 调用旧 postrm 之前，把旧 postrm 换成包装器：

```sh
case "$1" in
  remove|purge) exec /bin/sh "<旧 postrm 备份>" "$@" ;;
  *) exit 0 ;;
esac
```

因此这次从 2.1.12/2.1.13 升到 2.1.14，旧 postrm 的 `killall SpringBoard` 不会执行，第一次安装就能看到完整流程。升级完成后，新包自带的 postrm 会覆盖包装器。

## 4. 验证结果

### 4.1 dpkg 行为实测（WSL dpkg 1.22.6）

- 构造 v1 → v2 同包升级：确认 dpkg 执行的是**旧 v1 的 postrm**，参数为 `upgrade`。
- v2 preinst 在 dpkg 调用旧 postrm 之前改写成功；旧 postrm 的 `upgrade` 分支被包装器拦截，未执行 `killall`。
- 最终 deb 内脚本权限：`preinst/postinst/postrm = 0755`，`control = 0644`，属主 root。
- 新旧包数据文件 SHA-256 逐文件对比：完全一致（本次只改 DEBIAN 脚本）。

### 4.2 真机验证（2026-11-14 00:44）

Sileo 覆盖安装 2.1.14，安装完成页正常停留，手动注销成功。`/var/mobile/Library/CallCaptionPro/install.log`：

```text
[2026-11-14 00:44:40] preinst patched old postrm: /var/jb/var/lib/dpkg/info/net.user.callcaptionpro.postrm
[2026-11-14 00:44:40] pro preinst done
[2026-11-14 00:44:41] pro postinst start (2.1.14)
Warning: Please switch to user/foreground/net.user.callcaptionpro.audioservice service identifier
[2026-11-14 00:44:41] kickstart rc=0
[2026-11-14 00:44:41] pro postinst done
```

说明：

- 旧 postrm 路径确认为 `/var/jb/var/lib/dpkg/info/net.user.callcaptionpro.postrm`，preinst 一次命中。
- `Warning: Please switch to user/foreground/...` 是 Procursus `launchctl` 对 `system/` 标识的提示，不是错误；`kickstart rc=0`，守护进程随后正常启动。
- 安装流程已恢复到 0.20.7.1 之前的“执行 → 完成 → 手动注销”。


## 5. 真机安装步骤

1. 在 Sileo 里直接安装：
   `D:\shoujichajian\CallCaption\releases\net.user.callcaptionpro_1.0.0-pro2.1.14_arm64e.deb`
2. 正常应看到：加入队列 → 点“执行” → 进度 → **完成页停留**。
3. 确认完成后，**手动**点完成页的“注销/重启 SpringBoard”。
4. 注销后打开设置，确认仍是 `CallCaption Pro` 入口；打一通 WhatsApp 验证字幕/翻译/TTS 未回退。

如果仍然自动注销，请导出：

- `/var/mobile/Library/CallCaptionPro/install.log`
- `/var/jb/var/lib/dpkg/info/net.user.callcaptionpro.postrm`（如果存在）
- `/var/lib/dpkg/info/net.user.callcaptionpro.postrm`（如果存在）

`install.log` 里应出现：

```text
pro preinst patched old postrm: /var/jb/var/lib/dpkg/info/net.user.callcaptionpro.postrm
pro postinst start (2.1.14)
kickstart rc=0
pro postinst done
```

## 6. 说明

- 守护进程二进制未重编译，`probe.log` 的启动心跳仍显示 `pro2.1.12`；功能与 2.1.13 相同，仅安装脚本升级为 2.1.14。
- 回滚包保持不变：`STABLE-net.user.callcaptionpro_2.1.2-off_arm64e.deb`（`pro2.1.2-off-stable`）。
- TTS 重叠/AEC 仍未下结论，等下一通电话导出 `probe.log`、`asr.log`、`spool.txt` 后再判断。
