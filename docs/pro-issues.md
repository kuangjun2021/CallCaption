# CallCaption Pro 待修问题（pro0 → pro1）

日期：2026-11-13  
基线：`net.user.callcaptionpro 1.0.0-pro0`  
稳定版：`net.user.callcaption 0.20.7.1`（冻结，不动）

## 1. 设置页“打开诊断日志”仍跳稳定版目录

- 位置：`CCSettings.m` `presentLogMenu:`
  - 路径写死 `/var/mobile/Library/CallCaption/probe.log`
  - Filza URL 写死 `filza://view/var/mobile/Library/CallCaption/probe.log`
- 现象：Pro 设置页里点“打开诊断日志”，打开的是稳定版 `CallCaption` 目录，不是 `CallCaptionPro`。
- 修法：按 `CC_PRO` 条件使用 `/var/mobile/Library/CallCaptionPro/probe.log`，Filza URL 同步。
- 同文件还有两处写死稳定版文案/路径：
  - `CCSettings.m` 约 411 行 `self.title = @"CallCaption";` → Pro 应为 `CallCaption Pro`
  - `CCSettings.m` 约 595 行 footer `日志：/var/mobile/Library/CallCaption/probe.log` → Pro 路径
- 修完后全局 grep 一遍 `/var/mobile/Library/CallCaption`，Pro 构建里只允许出现 `CallCaptionPro` 或 `CC_PRO` 条件分支。

## 2. Google 接口测试 “不支持的 URL”

- 位置：`CCSettings.m` `runApiTest` Google 分支，约 1006 行：
  ```objc
  @"https://translation.googleapis.com/language/translate/v2?key=%@&q=Hello&source=en&target=zh"
  ```
- 原因：GoogleKey 未 trim、未 URL 转义；粘贴带空格/换行时 `NSURL` 非法 → `NSURLErrorUnsupportedURL`（系统显示“不支持的 URL”）。
- DeepL/AI/MyMemory 的 Key 不在 URL 里，所以测试正常。
- 修法：
  1. `gk = [gk stringByTrimmingCharactersInSet:whitespaceAndNewline];`
  2. 用 `CCEscape(gk)` 转义；
  3. 或改成和生产 `TranslateGoogleCloud` 一致的 POST（Key 放 query，文本放 form body）；
  4. `NSURL URLWithString` 返回 nil 时，明确提示“GoogleKey 含空格/换行”。
- 不影响通话主路径：生产翻译对 Key 做了 `CCEscape`，失败会回退免费接口；日志里 `translate[google] ok` 说明通话 Google 正常。

## 3. 其他 Pro 专属检查

- `CCSettings.m` 里所有稳定版域/路径/标题都要按 `CC_PRO` 条件化。
- `CallCaptionRootListController.m` 的标题已条件化（`CallCaption Pro`）。
- Pro 的日志/WAV/spool 都在 `/var/mobile/Library/CallCaptionPro`。

## 4. pro1 / pro1.1 已修（2026-11-13）

### 4.1 arm64 helper 链接（已静态验证）

- helper：`Mach-O 64-bit arm64`，`LC_LOAD_DYLIB = @rpath/SherpaOnnxC.framework/SherpaOnnxC`
- helper：`LC_RPATH = /var/jb/Library/Frameworks`
- framework：install-name 同为 `@rpath/SherpaOnnxC.framework/SherpaOnnxC`，含 `LC_CODE_SIGNATURE`
- 运行时解析到 `/var/jb/Library/Frameworks/SherpaOnnxC.framework/SherpaOnnxC`，路径成立。

### 4.2 模型加载参数

- `model_type = "zipformer2"` 是 sherpa-onnx **合法值**（官方 `online-model-config.cc`：conformer / lstm / zipformer / zipformer2 / wenet_ctc / nemo_ctc）。
- 显式指定可避免 sherpa 为探测类型把 169MB 模型加载两遍；不要删。
- `feat 80 维 / 16k / greedy / num_threads=2 / endpoint 0.8s` 与 PC 验证脚本一致。

### 4.3 helper 写 spool 后必须发 Darwin 通知

- `CCTransportSendLine` 只在守护进程里用；helper 直接 `O_APPEND` 写 spool，不会触发通知。
- 已加 `CFNotificationCenterPostNotification(... @"net.user.callcaptionpro.line")`，否则远端安静时本地字幕要等下一帧腾讯结果才 drain。

### 4.4 Pro 目录权限

- 模型包先装时，dpkg 以 root 创建 `/var/mobile/Library/CallCaptionPro`，daemon/helper/Settings 都是 mobile，写不了日志/spool/结果。
- 主包 `postinst` 与模型包 `postinst` 都 `chown -R mobile:mobile /var/mobile/Library/CallCaptionPro`。
- 模型包 `postinst` 在 CI 里用 `printf` 生成，避免 YAML heredoc 破坏 `on:`。

### 4.5 离线自检不再依赖“先打一通电话”

- 主包内置 `selftest16k.wav`（官方 10s 16k mono 测试音）。
- `CCStartASROfflineTest` 优先 `local16k.wav`，没有就用 `selftest16k.wav`；Settings 同步检查。

### 4.6 其余 Pro 路径泄漏清理

- `CCAudioHook` 的 probe/off、`CCAppProbe` 的 appprobe.off、`CCUI` 的 tts_until/selftest.wav、`CCSupport` 的 markers.log、`CCAudioService` 的 sirihelper.pid 全部改用 `CC_DIR`。
- Pro `postinst` 杀掉 `Preferences`，清 PreferenceLoader 缓存，避免稳定版设置入口残留。

## 5. 安装完成界面被冲掉（已修，pro2.1.14/2.1.15）

- 根因：dpkg 覆盖升级会执行**已安装旧包**的 `postrm upgrade`；Pro 2.0~2.1.13 的 postrm 不判断 `$1`，无条件 `killall -9 SpringBoard`，安装最后把 Sileo 完成页一起冲掉。
- 2.1.13 的“无 preinst/postinst”对照包无效：升级时跑的仍是已安装 2.1.12 的 postrm。
- 修复：
  - `postrm`：仅 `remove/purge` 做事；`upgrade/abort-*` 直接退出；永不再杀 SpringBoard/WhatsApp。
  - `postinst`：只启动 daemon，不杀进程、不 sleep。
  - `preinst`：在 dpkg 调用旧 postrm 前做一次性 upgrade 拦截，保证 2.1.12/2.1.13 → 2.1.14 第一次安装就恢复完整流程。
- 2.1.15：把 `pro2.1.15` 编译/写入守护进程与 Prefs Info.plist，修正 `probe.log` 仍显示 `pro2.1.12` 的问题。
- 详见 `docs/pro2.1.15-release.md`。

