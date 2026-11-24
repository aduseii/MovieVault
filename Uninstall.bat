@echo off
setlocal
set "DEST=%LOCALAPPDATA%\MovieVault"
echo Removing Movie Vault. Your vault folder and movies are KEPT, just unlocked.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*MovieVault.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%DEST%\MovieVault.ps1" -Unprotect
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v MovieVault /f >nul 2>&1
powershell -NoProfile -Command "Remove-Item -LiteralPath ([Environment]::GetFolderPath('Programs')+'\Movie Vault.lnk') -ErrorAction SilentlyContinue"
del /q "%DEST%\MovieVault.ps1" >nul 2>&1
echo Done.
pause
(goto) 2>nul & del /q "%DEST%\Uninstall.bat"
