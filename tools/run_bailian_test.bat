@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
set "PYTHONIOENCODING=utf-8"

echo ============================================
echo  Bailian / DashScope ASR + TTS test
echo ============================================
echo.

python --version >nul 2>&1
if errorlevel 1 goto TRY_PY
set "PY=python"
goto INSTALL

:TRY_PY
py -3 --version >nul 2>&1
if errorlevel 1 goto NO_PY
set "PY=py -3"

:INSTALL
echo [1/3] Installing dashscope ...
%PY% -m pip install -U dashscope
if errorlevel 1 goto PIP_FAIL
echo.

set /p "KEY=DashScope API Key: "
if "%KEY%"=="" goto NO_KEY
set "DASHSCOPE_API_KEY=%KEY%"

set /p "WS=Workspace ID (press Enter if none): "
if not "%WS%"=="" set "DASHSCOPE_WORKSPACE=%WS%"
echo.

set "WAV_EN=D:\shoujichajian\CallCaption\测试日志\0.20.5\remote16k.wav"
set "WAV_ZH=D:\shoujichajian\CallCaption\测试日志\0.20.5\local16k.wav"

echo Default English WAV:
echo   %WAV_EN%
set /p "WAV_EN_IN=English WAV path (Enter for default): "
if not "%WAV_EN_IN%"=="" set "WAV_EN=%WAV_EN_IN%"

echo Default Chinese WAV:
echo   %WAV_ZH%
set /p "WAV_ZH_IN=Chinese WAV path (Enter for default): "
if not "%WAV_ZH_IN%"=="" set "WAV_ZH=%WAV_ZH_IN%"

if not exist "%WAV_EN%" goto BAD_WAV
if not exist "%WAV_ZH%" goto BAD_WAV

echo.
echo [2/3] ASR English ...
%PY% "%~dp0bailian_test.py" asr --wav "%WAV_EN%" --lang en --chunk-ms 100
echo.
echo [2/3] ASR Chinese ...
%PY% "%~dp0bailian_test.py" asr --wav "%WAV_ZH%" --lang zh --chunk-ms 100

echo.
echo [3/3] TTS English ...
%PY% "%~dp0bailian_test.py" tts --text "Hello, this is a Bailian TTS test." --out "%~dp0bailian_en.wav" --voice longanyang
echo.
echo [3/3] TTS Chinese ...
%PY% "%~dp0bailian_test.py" tts --text "你好，这是百炼语音合成测试。" --out "%~dp0bailian_zh.wav" --voice longanyang

echo.
echo Done. Output: %~dp0bailian_en.wav / bailian_zh.wav
pause
exit /b 0

:NO_PY
echo [ERROR] Python not found.
echo Install Python 3 and check "Add python.exe to PATH":
echo https://www.python.org/downloads/
pause
exit /b 1

:PIP_FAIL
echo [ERROR] pip install dashscope failed. Check network and retry.
pause
exit /b 2

:NO_KEY
echo [ERROR] API Key is empty.
pause
exit /b 3

:BAD_WAV
echo [ERROR] WAV not found:
echo   EN: %WAV_EN%
echo   ZH: %WAV_ZH%
echo Check the 0.20.5 test log folder, or paste the correct full path.
pause
exit /b 4
