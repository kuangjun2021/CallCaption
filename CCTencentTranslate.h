// CCTencentTranslate.h — v0.19.1 方案 D+
// 守护进程内两条腾讯实时语音翻译 WebSocket：
//   remote: en -> zh，只取文本；中文 TTS 仍走 SpringBoard 的 0.19.0 队列
//   local : zh -> en，取文本 + 英文 TTS PCM，混入上行
#import <Foundation/Foundation.h>

void CCTencentStart(void);
void CCTencentStop(void);
BOOL CCTencentIsActive(void);
void CCTencentPushRemote(const int16_t *samples, NSUInteger count);
void CCTencentPushLocal(const int16_t *samples, NSUInteger count);
