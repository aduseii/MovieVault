@echo off
setlocal
set "DEST=%LOCALAPPDATA%\MovieVault"
echo Installing Movie Vault...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*MovieVault.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1
if not exist "%DEST%" mkdir "%DEST%"
copy /y "%~dp0MovieVault.ps1" "%DEST%\MovieVault.ps1" >nul
copy /y "%~dp0Uninstall.bat" "%DEST%\Uninstall.bat" >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -LiteralPath '%DEST%\MovieVault.ps1'; $s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Programs')+'\Movie Vault.lnk'); $s.TargetPath='powershell.exe'; $s.Arguments='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File '+[char]34+$env:LOCALAPPDATA+'\MovieVault\MovieVault.ps1'+[char]34; $s.WorkingDirectory='%DEST%'; $s.Save()"
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%DEST%\MovieVault.ps1"
echo.
echo Done. Movie Vault is running (look in the tray, bottom-right) and is in the Start menu.
pause
