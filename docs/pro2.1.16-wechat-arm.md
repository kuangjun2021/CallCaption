# Pro 2.1.16：微信 CallKit 响铃阶段手动激活兼容

- 日期：2026-11-14
- 包：`net.user.callcaptionpro_1.0.0-pro2.1.16_arm64e.deb`
- 大小：6,517,072 字节
- SHA-256：`4d194d0c3e6ebd641a626bf54279166bbb42abea00819e1120e3ab8420a69149`
- 构建：GitHub Actions run `43558114703`，commit `78e7ae6`，完整 Theos 编译
- 基线：2.1.15；本次只改 `CCUI.m` 的 `toggleSession`，WhatsApp 已接通逻辑不变。

## 1. 问题

微信来电走 CallKit 时，系统会回调 **ringing**，小面板/地球能出来；但微信不一定把 `hasConnected=YES` 上报给 `CXCallObserver`。结果：

```text
ringing: globe shown, captions cleared, not armed
asr helper started ...
panel button tag=0
session: no active call, ignore arm
```

面板出来了，但点“译”被 `toggleSession` 里的 `!g_callActive` 判断拦住，无法激活；`CCUIHandleCallActive(YES)` 也不会自动执行。

## 2. 修法

`CCUI.m` `toggleSession`：

- 原来：`!g_sessionActive && !g_callActive` → 直接忽略。
- 现在：如果 `g_ringing=YES` 且主开关开启，调用 `CCUIHandleCallActive(YES)`，走正常接通路径：
  - 置 `g_callActive=YES`；
  - 停 ringing；
  - `CCSetArmed(YES)`；
  - 启动 ASR/字幕。

WhatsApp 已接通（`g_callActive=YES`）时的逻辑完全不动；只有“响铃中且未激活”时点“译”的行为从“忽略”变为“激活”。

## 3. CI 产物核对

- `control`: `Version: 1.0.0-pro2.1.16`
- daemon：`audioservice started (pro2.1.16)`、`%.0f pro2.1.16`
- Prefs `Info.plist`：`CFBundleVersion = CFBundleShortVersionString = 1.0.0-pro2.1.16`
- `preinst/postinst/postrm`：0755，control 0644
- daemon 仍为 `Mach-O 64-bit arm64e (caps: PAC00)`

## 4. 微信测试步骤

1. 安装 2.1.16，覆盖 2.1.15。
2. 让对方用微信打语音来电，你接听。
3. 响铃时小面板/地球应该出现。
4. **接通后点一下“译”按钮**（面板 button tag 0）。
5. `probe.log` 应出现：

```text
session: activate from ringing (manual compat)
call state: ACTIVE
call seq=... armed=1
```

6. 本机中文应开始出字幕；`asr helper` 已在响铃阶段预加载。

## 5. 本次范围

- 本次只解决“面板能激活、本机字幕能进”。
- 微信远端音频仍未接入：当前 remote 还是 WhatsApp AppProbe WAV，微信不在过滤器里，所以对方英文→中文字幕不会出来。
- 英文 TTS 上行（对方听到我们的英文）仍走 WhatsApp AppProbe，微信不支持；这是下一步。
- 不注入微信、不改 CallKit。

## 6. 回滚

- 2.1.15 仍在 releases 目录，可随时覆盖回滚。
- 功能基线回滚：`STABLE-net.user.callcaptionpro_2.1.2-off_arm64e.deb`（tag `pro2.1.2-off-stable`）。
