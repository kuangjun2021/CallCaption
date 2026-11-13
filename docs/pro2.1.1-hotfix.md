# Pro2.1 崩溃根因与 2.1.2 修复

## 现象

- Pro2.1 响铃时 WhatsApp/SpringBoard 崩溃，手机最终需要物理重启。
- `probe.log` 里同一秒反复出现：
  `ring preload: starting asr helper` → `asr helper started` → `asr helper stopped`
- `asr.log` 里几十个 helper 同时加载 169MB 模型，加载时间被拖到 27–68 秒。

## 根因

`CCAudioService` 的 `if (!armed)` 清理分支每 0.5 秒都执行一次。
Pro2.1 的响铃预加载 helper 在 `prepared=1, armed=0` 时启动，紧接着又被这个
每 tick 的 `CCStopASRHelper()` 杀掉；下一 tick 再次拉起，形成模型加载风暴，
内存耗尽后 WhatsApp/SpringBoard 被 jetsam 杀掉。

Pro2.0 没有预加载路径，所以没有这个问题。

## 2.1.2 修复

- 停止 helper 只在真正挂断（`wasArmed`）或响铃取消（`!prepared`）时执行，
  响铃期间保留预加载 helper。
- 3 秒 spawn 节流，任何路径 bug 都不会连续拉起模型。
- helper 单实例锁 `asr_helper.lock`：第二个 helper 在加载模型前直接退出。
- helper 异常退出后常驻模式 60 秒内不自动重拉。
- 响铃预加载每次响铃只尝试一次。
- 预加载默认改为 `off`，先验证基础稳定性；稳定后再手动切 `ring`/`resident`。

## 产物

- `net.user.callcaptionpro_1.0.0-pro2.1.2_arm64e.deb`
  - 6,512,532 B
  - SHA256 `f3ac1d3c4c3ea4bd1c7175c235d980b6a0c0de303a6c143415f07bf6aa1e9bbe`
- 回退基线 `net.user.callcaptionpro_1.0.0-pro2.0_arm64e.deb`
  - SHA256 `37fdfa185d816da6e70a3575dfc87ee223b33648c746bd85a9e2b347f7156f13`
