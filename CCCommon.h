// CCCommon.h — CallCaption 公共定义（mediaserverd + SpringBoard 共用）
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>

#define CC_DOMAIN         @"net.user.callcaption"
#define CC_NOTIF_PREFIX   @"net.user.callcaption."
#define CC_NOTIF_PREFS    @"net.user.callcaption.prefschanged"
#define CC_DIR            @"/var/mobile/Library/CallCaption"
#define CC_LOG_PATH       @"/var/mobile/Library/CallCaption/probe.log"
#define CC_SPOOL_PATH     @"/var/mobile/Library/CallCaption/spool.txt"
#define CC_ARM_PATH       @"/var/mobile/Library/CallCaption/armed"   // v0.10: 采集开关（SB 创建/删除，守护进程监视）
// v0.20.5：拨号/响铃阶段预先激活守护进程的 AVAudioSession。
// 不能等到接通后才 setActive：那会打断 WhatsApp 已建立的音频路由，
// 第二次通话出现 local tap 停帧、远端 WAV 只写一半。SB 在 ringing 写，
// 守护进程只激活会话、不启动 ASR；接通后才 arm。
#define CC_PREPARE_PATH   @"/var/mobile/Library/CallCaption/prepare"

// ---------- 设置键（与 PreferenceLoader 面板一致） ----------
#define CC_K_ENABLED          @"Enabled"          // 总开关
#define CC_K_REMOTE_ENABLED   @"RemoteEnabled"    // 对方语音→中文字幕
#define CC_K_LOCAL_ENABLED    @"LocalEnabled"     // 我的语音→英文(扬声器中继,实验)
#define CC_K_TTS_ENABLED      @"TTSEnabled"       // 中文播报
#define CC_K_CLOUD_ASR       @"CloudASR"         // 云端语音识别（更准，需联网）
#define CC_K_TAP_STALL_SEC   @"TapStallSec"       // Tap 帧停滞重启阈值（秒，2..10）
#define CC_K_LAB_MODE        @"LabSpeechMode"     // v0.20.8-lab：remote/local/dual
#define CC_K_SHOW_RECOGNIZED @"ShowRecognized"    // 显示识别原文
#define CC_K_SHOW_TRANSLATED @"ShowTranslated"    // 显示译文
#define CC_K_TTS_VOICE       @"TTSVoice"          // 中文播报音色 identifier
#define CC_K_LOCAL_VOICE     @"LocalVoice"        // 英文播报音色 identifier
#define CC_K_ALWAYS_PANEL    @"AlwaysShowPanel"   // 面板常驻（默认关：仅通话时显示）
#define CC_K_ENGINE           @"Engine"           // auto / deepl / ai
#define CC_K_DEEPL_KEY        @"DeepLKey"
#define CC_K_GOOGLE_KEY       @"GoogleKey"        // 可选：Google Cloud Translation API Key（不填走免费接口）
#define CC_K_AI_URL           @"AIURL"
#define CC_K_AI_KEY           @"AIKey"
#define CC_K_AI_MODEL         @"AIModel"
#define CC_K_REMOTE_LOCALE    @"RemoteLocale"     // 对方识别语言（默认 en-US）
#define CC_K_LOCAL_LOCALE     @"LocalLocale"      // 我方识别语言（默认 zh-CN）
#define CC_K_LARGE_CAPTIONS   @"LargeCaptions"
#define CC_K_DIAGNOSTICS      @"Diagnostics"
#define CC_K_CAPTION_X        @"CaptionX"
#define CC_K_CAPTION_Y        @"CaptionY"

// v0.19.1 腾讯实时翻译（方案 D+）
#define CC_K_TC_ENABLED       @"TencentTranslateEnabled"
#define CC_K_TC_APPID         @"TencentAppID"
#define CC_K_TC_SECRETID      @"TencentSecretID"
#define CC_K_TC_SECRETKEY     @"TencentSecretKey"
#define CC_K_TC_LOCAL_VOICE   @"TencentLocalVoice"    // 我方英文 TTS voice_type，默认 501009
#define CC_K_TC_LOCAL_MODEL   @"TencentLocalModel"    // lite / standard
#define CC_K_TC_REMOTE_MODEL  @"TencentRemoteModel"   // en→zh 必须 standard
#define CC_K_TC_LOCAL_VOLUME  @"TencentLocalVolume"   // -10..10
#define CC_K_TC_LOCAL_SPEED   @"TencentLocalSpeed"    // -2..6
#define CC_K_TC_LOCAL_SOURCE  @"TencentLocalSource"   // zh / zh_en
#define CC_K_ENGLISH_TTS      @"EnglishTTSEngine"     // local / tencent / off，默认 local
#define CC_K_TC_VAD_SILENCE   @"TencentVadSilence"    // 500..2000 ms
#define CC_K_TC_MAX_SPEAK     @"TencentMaxSpeak"      // 5000..90000 ms
#define CC_K_TC_SAMPLE_RATE   @"TencentSampleRate"    // 16000 / 8000，双开卡时用 8000
#define CC_K_TC_LOCAL_ENGINE  @"TencentLocalEngine"   // 旧混合 A 设置，B1 不再使用
#define CC_K_REMOTE_TRANSLATE_ENGINE @"RemoteTranslateEngine"  // google / deepl / bing / ai
#define CC_K_LOCAL_TRANSLATE_ENGINE  @"LocalTranslateEngine"   // deepl / google / bing / ai

// ---------- 进程判断 ----------
void CCProcessInit(void);
BOOL CCIsSpringBoard(void);
BOOL CCIsMediaServerd(void);
BOOL CCIsAudioService(void);

// ---------- URL/字符串工具 ----------
NSString *CCEscape(NSString *s);

// ---------- UI 交付（CCUI.m 实现，供传输层调用） ----------
void CCUIDeliverRemoteOriginal(NSString *text);    // 对方：识别原文
void CCUIDeliverRemoteTranslated(NSString *text);  // 对方：译文
void CCUIDeliverLocalOriginal(NSString *text);     // 我方：识别原文
void CCUIDeliverLocalTranslated(NSString *text);   // 我方：译文
void CCUIDeliverRemoteEngine(NSString *engine);    // 对方：实际翻译引擎
void CCUIDeliverLocalEngine(NSString *engine);     // 我方：实际翻译引擎
void CCUIDeliverState(NSString *state);
void CCUIClearCaptions(void);                      // 通话开始/结束清空字幕
void CCUIEnqueueRemoteTTS(NSString *text);          // v0.19.1：把腾讯译文送进下行 TTS 队列
void CCUIEnqueueLocalEnglishTTS(NSString *text);    // v0.19.2：本机英文 TTS，写入 cc_tts.wav 供上行混音
void CCUIRemoteFinalText(NSString *text);           // v0.20.0 B1：来电 ASR 最终文本 -> Google/DeepL -> 中文字幕/TTS
void CCUILocalFinalText(NSString *text);            // v0.20.0 B1：去电 ASR 最终文本 -> DeepL/Google -> 英文字幕/TTS
NSString *CCFindWhatsAppDocs(void);                 // v0.19.1：守护进程/腾讯模块共用
// 兼容旧接口
void CCUIDeliverCaption(NSString *translated);
void CCUIDeliverOriginal(NSString *original);

// ---------- 日志（诊断） ----------
void CCLogLine(NSString *msg);                 // 诊断日志（SB 落盘 / MS 发通知）
void CCLogf(NSString *fmt, ...);
void CCMark(NSString *tag);                    // 启动路标（挂起定位用）

// ---------- Darwin 通知 ----------
void CCPostNotif(NSString *suffix);

// ---------- 设置 ----------
void CCPrefsReload(void);
id    CCPref(NSString *key);
BOOL  CCPrefBool(NSString *key, BOOL def);
NSString *CCPrefStr(NSString *key, NSString *def);
void  CCSetPrefBool(NSString *key, BOOL value);   // SB 侧写设置并广播

// ---------- v0.20.8-lab：离线 SFSpeech 实验 ----------
void CCLabSpeechStartFromMode(BOOL localSide);

// ---------- v0.21.0：本机 SFSpeech 可用性 ----------
BOOL CCLocalSpeechAvailable(NSString *locale);

// ---------- 传输（MS→SB 结果行） ----------
void CCTransportBoot(void);                    // SB 侧：建目录/文件、订阅通知
void CCTransportSendLine(NSString *line);      // MS 侧：发送一行结果
void CCTransportDrain(void);                   // SB 侧：读取 spool 新增行
void CCTransportSkipToEnd(void);               // v0.19.6：通话开始丢弃上一通残留行
void CCTransportHandleChunk(NSString *suffix); // SB 侧：分片兜底重组

// ---------- 翻译 ----------
void CCTranslate(NSString *text, NSString *fromLang, NSString *toLang,
                 void (^done)(NSString *translated));
// 带实际引擎回报的版本：engine = deepl/google/bing/ai/cache
void CCTranslateEx(NSString *text, NSString *fromLang, NSString *toLang,
                   void (^done)(NSString *translated, NSString *engine));
// v0.20.0 B1：指定引擎（google/deepl/bing/ai），供来电/去电分别使用
void CCTranslateWithEngine(NSString *text, NSString *fromLang, NSString *toLang,
                           NSString *engine,
                           void (^done)(NSString *translated, NSString *engine));

// ---------- 音频抓取 / 识别 / TTS（mediaserverd 侧，旧架构） ----------
void CCEngineBoot(void);                       // 预分配环缓冲、创建识别器/TTS
void CCAudioTapObserve(AudioUnit unit, UInt32 bus, UInt32 frames, AudioBufferList *ioData);
void CCTTSInitIfNeeded(void);
void CCTTSSpeak(NSString *text, NSString *lang); // lang: "zh-CN"/"en-US"
void CCTTSStopAll(void);

// ---------- v0.9.0 旧架构：SpringBoard 进程内麦克风采集（已由 v0.10 守护进程取代） ----------
void CCMicStart(void);
void CCMicStop(void);

// ---------- v0.10 新架构：独立音频守护进程（系统级 Tap） ----------
void CCSetArmed(BOOL armed);          // SB 侧：写/删 armed 文件并广播通知
void CCSetPrepared(BOOL prepared);    // v0.20.5：SB 侧：ringing 预先激活音频会话（不 arm）
void CCUISpeakText(NSString *text);   // SB 侧：中文 TTS 播报

// ---------- UI（SpringBoard 侧） ----------
void CCUIBoot(void);
void CCUICallStateChanged(NSString *state);    // CALL CONNECTED / ENDED / ...
void CCUIRefreshPanel(void);                   // 设置变化后刷新按钮状态
