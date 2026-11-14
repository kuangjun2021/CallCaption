# Pro 2.1.21：真实 WAV 两模型验证记录

- 日期：2026-11-14
- 目的：回答“远端英文一个模型、本机中文一个模型”是否值得做
- 数据：2.1.20 真机 `remote16k.wav`（162.5s，16k mono）与 `local16k.wav`（164.3s）
- 工具：`sherpa-test/sherpa_test.py`，PC CPU 2 线程，`--no-realtime`
- 注意：PC 侧默认 `greedy_search`，App 用 `modified_beam_search`（热词）；两者文本会有差异，本文同时给了同解码对比。

## 1. 模型与体积（int8 优先）

| 模型 | 用途 | 编码器/解码器/joiner | 合计 |
|---|---|---:|---:|
| x-asr-480ms（当前） | 远端+本机 | 155.3 + 11.3 + 2.6 MB | 约 169 MB |
| zh-14M-2023-02-23 | 中文专用候选 | 21.6 + 1.9 + 1.8 MB | 约 25 MB |
| Kroko en-2025-08-06 | 英文专用候选 | 70.1 + 0.6 + 0.3 MB（fp32） | 约 71 MB |
| zipformer-en-2023-06-26 | 英文专用候选 | 70.1 + 0.5 + 0.3 MB | 约 71 MB |
| bilingual-2023-02-20 | 旧双语对照 | 181.9 + 13.1 + 3.2 MB | 约 198 MB |

## 2. 远端英文（2.1.20 remote16k.wav）

### 2.1 当前 x-asr，greedy（PC 基线）

```text
One two three four five six seven eight nine ten
Hello.
Hello.
好爱哟
How are you?
What's your name?
How do you do?
Go to bed.
Where are you doing?
Where are you doing?
What's this?
Noodle
I'm eating
how much
```

RTF 0.098，14 条 final。

### 2.2 当前 x-asr，modified_beam_search + 中文热词（App 实际配置）

```text
...（前面同上）...
I'm eating
豪迈
五百
```

RTF 约 0.10，15 条 final。

### 2.3 当前 x-asr，modified_beam_search，不加中文热词

结果与 2.2 完全一致，最后仍是 `豪迈`、`五百`。

**结论：`五百` 不是热词造成的，是 `modified_beam_search` 的波束把 `how much` 压成了中文；greedy 会给出 `how much`。**

### 2.4 英文专用模型

Kroko（57MB 包，fp32）RTF 0.046：

```text
One, two, three, four, five six seven eight nine ten
Hello
Hello
How are you
How are you?
What their name?
How to two
go to pay the
word
what are you doing?
What is
no dog
A meeting
How much
oh bye
```

标准 en-2023-06-26（int8，RTF 0.082）更差，出现大量全大写碎片：

```text
WHITE UNTIL THEY GO FANCY SEVEN AT THE NINETEENTH
HELLO
HALLO
ARE AYO
HALL
WHAT THEIR NAME WILL
HOW DO
YOU
CALLEDA
...
```

**结论：这两个英文专用模型都没有全面超过 x-asr。Kroko 只把 `what are you doing?`、`how much` 等个别句子改好，`What's your name?`、`How do you do?`、`Go to bed`、`noodle`、`I'm eating` 反而退化。不能为了“分开模型”直接换英文模型。**

## 3. 本机中文（2.1.20 local16k.wav）

### 3.1 当前 x-asr（greedy）

```text
说话呀
你好
你是哪一位
你你听得到我说话吗
你继续说
继续说
想到哪说到哪
就是验证一下通话
我要验证通话和翻译
继续说呀
感觉速度有点慢
好，先测试到这里吧
非常感谢你，谢谢，再见
```

### 3.2 zh-14M（greedy）

```text
吃化
你好
你是哪一位
你你听得到我说话吗
你继续说啊
继续说啊
想到哪儿说的了
就是验证一下通话
我要验证通话和翻译
继续说呀
感觉速度有点慢
测试到这里吧
非常感谢你
谢谢再见
```

zh-14M 在中文上更完整、更准，RTF 0.022，模型只有约 25MB。

### 3.3 旧 bilingual-2023-02-20

出现大量重复（`你你你你你`、`慢慢慢慢`），不适合。

## 4. 结论

1. **本机中文：zh-14M 明确胜出**，更准、更小、更快，可以作为本机专用模型。
2. **远端英文：不要换成本次测试的两个英文专用模型**；x-asr 仍是综合最好的。
3. **`五百` 的根因是 modified_beam_search**；远端改用 greedy 可回到 `how much`。`好爱哟` 仍是 x-asr 对带口音英文的误判，需要更强的电话/口音英文模型或纯远端音频才能进一步解决。
4. **两模型方案应改成：远端 x-asr + greedy；本机 zh-14M + 自己的解码/热词。** 内存只增加约 25MB，不是把远端换成英文模型。
5. 两模型需要两个 recognizer（每个流一个），helper 和模型包要改；手机上还要测内存、启动时间和温度。

## 5. 下一步（2.1.22）

- `CCProASR` 增加第二个 recognizer：远端 x-asr（greedy），本机 zh-14M（greedy 或 modified_beam + 中文热词）。
- 模型包增加 zh-14M 文件。
- 日志打印每个流的模型/解码方式/RTF，真机对比：
  - 远端 `五百` 是否消失、`how much` 是否回来；
  - 本机中文是否更准；
  - 内存/启动时间/温度是否可接受。
- 不丢弃 mostly-CJK 文本；不改置信度门限；不引入英文专用模型。
