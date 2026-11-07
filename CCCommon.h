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

// ---------- 设置键（与 PreferenceLoader 面板一致） ----------
#define CC_K_ENABLED          @"Enabled"          // 总开关
#define CC_K_REMOTE_ENABLED   @"RemoteEnabled"    // 对方语音→中文字幕
#define CC_K_LOCAL_ENABLED    @"LocalEnabled"     // 我的语音→英文(扬声器中继,实验)
#define CC_K_TTS_ENABLED      @"TTSEnabled"       // 中文播报
#define CC_K_ENGINE           @"Engine"           // auto / deepl / ai
#define CC_K_DEEPL_KEY        @"DeepLKey"
#define CC_K_AI_URL           @"AIURL"
#define CC_K_AI_KEY           @"AIKey"
#define CC_K_AI_MODEL         @"AIModel"
#define CC_K_LARGE_CAPTIONS   @"LargeCaptions"
#define CC_K_DIAGNOSTICS      @"Diagnostics"
#define CC_K_CAPTION_X        @"CaptionX"
#define CC_K_CAPTION_Y        @"CaptionY"

// ---------- 进程判断 ----------
void CCProcessInit(void);
BOOL CCIsSpringBoard(void);
BOOL CCIsMediaServerd(void);

// ---------- URL/字符串工具 ----------
NSString *CCEscape(NSString *s);

// ---------- UI 交付（CCUI.m 实现，供传输层调用） ----------
void CCUIDeliverCaption(NSString *translated);
void CCUIDeliverOriginal(NSString *original);
void CCUIDeliverState(NSString *state);

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

// ---------- 传输（MS→SB 结果行） ----------
void CCTransportBoot(void);                    // SB 侧：建目录/文件、订阅通知
void CCTransportSendLine(NSString *line);      // MS 侧：发送一行结果
void CCTransportDrain(void);                   // SB 侧：读取 spool 新增行
void CCTransportHandleChunk(NSString *suffix); // SB 侧：分片兜底重组

// ---------- 翻译 ----------
void CCTranslate(NSString *text, NSString *fromLang, NSString *toLang,
                 void (^done)(NSString *translated));

// ---------- 音频抓取 / 识别 / TTS（mediaserverd 侧） ----------
void CCEngineBoot(void);                       // 预分配环缓冲、创建识别器/TTS
void CCAudioTapObserve(AudioUnit unit, UInt32 bus, UInt32 frames, AudioBufferList *ioData);
void CCTTSInitIfNeeded(void);
void CCTTSSpeak(NSString *text, NSString *lang); // lang: "zh-CN"/"en-US"
void CCTTSStopAll(void);

// ---------- UI（SpringBoard 侧） ----------
void CCUIBoot(void);
void CCUICallStateChanged(NSString *state);    // CALL CONNECTED / ENDED / ...
