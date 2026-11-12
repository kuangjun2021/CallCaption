@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
set "PYTHONIOENCODING=utf-8"

echo ============================================
echo  Bailian / DashScope ASR + TTS test
echo ============================================
echo.

where python >nul 2>&1
if errorlevel 1 (
    where py >nul 2>&1
    if errorlevel 1 (
        echo [ERROR] Python not found. Install Python 3 first:
        echo         https://www.python.org/downloads/
        echo         Remember to check "Add python.exe to PATH".
        pause
        exit /b 1
    )
    set "PY=py"
) else (
    set "PY=python"
)

echo [1/4] Installing dashscope SDK ...
%PY% -m pip install -U dashscope
if errorlevel 1 (
    echo [ERROR] pip install failed. Check network/proxy and run again.
    pause
    exit /b 2
)
echo.

set /p "DASHSCOPE_API_KEY=请粘贴 DashScope API Key 后回车: "
if not defined DASHSCOPE_API_KEY (
    echo [ERROR] API Key empty.
    pause
    exit /b 3
)

set /p "WS=业务空间 ID（可留空，直接回车）: "
if not "%WS%"=="" set "DASHSCOPE_WORKSPACE=%WS%"
echo.

set "WAV_EN=D:\shoujichajian\CallCaption\测试日志\0.20.5\remote16k.wav"
set "WAV_ZH=D:\shoujichajian\CallCaption\测试日志\0.20.5\local16k.wav"

if not exist "%WAV_EN%" (
    echo English WAV not found at:
    echo   %WAV_EN%
    set /p "WAV_EN=请输入 English 16k WAV 完整路径: "
)
if not exist "%WAV_ZH%" (
    echo Chinese WAV not found at:
    echo   %WAV_ZH%
    set /p "WAV_ZH=请输入 Chinese 16k WAV 完整路径: "
)

echo.
echo ============================================
echo  ASR English
echo ============================================
%PY% "%~dp0bailian_test.py" asr --wav "%WAV_EN%" --lang en --chunk-ms 100

echo.
echo ============================================
echo  ASR Chinese
echo ============================================
%PY% "%~dp0bailian_test.py" asr --wav "%WAV_ZH%" --lang zh --chunk-ms 100

echo.
echo ============================================
echo  TTS Chinese (cosyvoice-v3-flash / longanyang)
echo ============================================
%PY% "%~dp0bailian_test.py" tts --text "你好，这是百炼语音合成测试。" --out "%~dp0bailian_zh.wav"

echo.
echo ============================================
echo  TTS English (cosyvoice-v3-flash / longanyang)
echo ============================================
%PY% "%~dp0bailian_test.py" tts --text "Hello, this is a Bailian TTS test." --out "%~dp0bailian_en.wav" --voice longanyang

echo.
echo ============================================
echo  Done
echo  Output WAVs: %~dp0bailian_zh.wav / bailian_en.wav
echo ============================================
pause
