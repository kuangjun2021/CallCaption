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

set /p "WAV_EN=English 16k WAV full path: "
set /p "WAV_ZH=Chinese 16k WAV full path: "
if "%WAV_EN%"=="" goto NO_WAV
if "%WAV_ZH%"=="" goto NO_WAV

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
echo Done. Output: %~dp0bailian_en.wav
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

:NO_WAV
echo [ERROR] WAV path is empty.
pause
exit /b 4
