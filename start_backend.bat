@echo off
rem GradeMonitor 后端启动脚本 (Windows)
rem 使用项目内便携版 Python 3.12，数据目录固定在项目 .data 文件夹

setlocal
set PYTHON=%~dp0runtime\tools\python.exe
set GRADEMONITOR_DATA_DIR=%~dp0.data

if not exist "%PYTHON%" (
    echo [ERROR] Python interpreter not found: %PYTHON%
    pause
    exit /b 1
)

echo Starting GradeMonitor Backend on http://127.0.0.1:18923 ...
"%PYTHON%" -m uvicorn backend.api.app:app --host 127.0.0.1 --port 18923

endlocal
