# CallCaption Pro 2.1 — 预加载 + 热词 + 单字过滤

基线：`pro2.0-stable` tag（commit d67e14c）
构建：run `43390578725`，commit `fca4fb0`
模型包不变，仍在 `releases/net.user.callcaptionpro.models_1.0.0_arm64e.deb`

## 产物

| 文件 | 大小 | SHA256 |
|---|---:|---|
| `net.user.callcaptionpro_1.0.0-pro2.1_arm64e.deb` | 6,511,012 B | `a4922bf0899450ac700cbd46783a5a1ae2112cf65c526b88417b41617a7372c3` |
| `net.user.callcaptionpro_1.0.0-pro2.0_arm64e.deb`（回退基线） | 6,490,572 B | `37fdfa185d816da6e70a3575dfc87ee223b33648c746bd85a9e2b347f7156f13` |

## 2.1 改动

- 设置新增 `CPU ASR 预加载`：
  - `ring`：响铃时启动 helper，模型加载完等 arm（默认，空闲不占内存）
  - `resident`：helper 常驻，模型一直热着（约 200MB）
  - `off`：接通后才启动
- `asr_go` 同步标记：预加载/常驻 helper 看到 arm 后，等 daemon 清空 WAV 并写 `asr_go` 才开文件，避免重识别上一通旧 WAV。
- 设置新增 `热词（逗号分隔）`，默认 `去电,来电,字幕,翻译,微信,WhatsApp`。
  - 助手用 `modified_beam_search` + `modeling_unit=bpe` + `bpe.vocab`（由 `bpe.model` 导出，空格分隔）。
  - 主包 repack 时把 `bpe.vocab` 放到 `models/x-asr-480ms/bpe.vocab`，不需要重装模型包。
- 单字过滤：非语气词单字（如误识别的“下”“一”）只上字幕，不翻译、不 TTS。
- 离线自检前会停掉常驻 helper，90 秒内不自动重启，避免双模型内存。
- 版本日志/心跳：`pro2.1`。

## 说明

- Pro2.0 已验证：双向 CPU ASR、一个 Recognizer 两条流、翻译/TTS 全通。
- Pro2.1 的预加载/热词/单字过滤尚待真机验证。
- 热词修改对已常驻的 helper 不会热更新；改热词后重启 daemon/手机，或等 helper 重启。
