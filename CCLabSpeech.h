// CCLabSpeech.h — v0.20.8-lab
// 离线 SFSpeech 实验：把 16k mono s16 WAV 按实时速度喂给 on-device 识别，
// 不打电话、不联网、不翻译、不 TTS。用于验证：
//   1) on-device 连续 150 秒是否在 60 秒附近报 203/1110；
//   2) SpringBoard + 守护进程双路 SFSpeech 是否互杀；
//   3) 同一段通话音频 SFSpeech 与腾讯的字准率差异。
#import <Foundation/Foundation.h>

@interface CCLabSpeech : NSObject
- (instancetype)initWithTag:(NSString *)tag
                     locale:(NSString *)locale
                       path:(NSString *)path
                   duration:(double)duration;
- (void)start;
- (void)stop;
- (BOOL)isRunning;
@end

// localSide=YES：守护进程跑我方 zh-CN；NO：SpringBoard 跑对方 en-US。
// 读取 prefs 的 LabSpeechMode（remote/local/dual），只有匹配的一侧才启动。
void CCLabSpeechStartFromMode(BOOL localSide);
