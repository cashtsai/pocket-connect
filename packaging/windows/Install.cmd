@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Pocket-Connect.ps1" -Action Install
if errorlevel 1 (
  echo Installation did not finish. Read the error above and README before retrying.
  pause
  exit /b 1
)
pause
