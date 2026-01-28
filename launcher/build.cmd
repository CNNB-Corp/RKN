@echo off
setlocal

set CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
if not exist "%CSC%" (
  set CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe
)

if not exist "%CSC%" (
  echo Не найден csc.exe. Установите .NET Framework или Visual Studio Build Tools.
  exit /b 1
)

"%CSC%" /nologo /target:exe /out:RKN.exe RKNLauncher.cs
if errorlevel 1 exit /b 1

echo Готово: RKN.exe
endlocal
