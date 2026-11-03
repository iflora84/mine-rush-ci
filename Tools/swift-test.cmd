@echo off
set "PATH=C:\Program Files (x86)\Microsoft Visual Studio\Installer;%PATH%"
call "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\Common7\Tools\VsDevCmd.bat" -arch=amd64 -host_arch=amd64 >nul
set "SDKROOT=%LOCALAPPDATA%\Programs\Swift\Platforms\6.4.2\Windows.platform\Developer\SDKs\Windows.sdk\"
set "PATH=%LOCALAPPDATA%\Programs\Swift\Toolchains\6.4.2+Asserts\usr\bin;%LOCALAPPDATA%\Programs\Swift\Runtimes\6.4.2\usr\bin;%PATH%"
swift test --package-path "C:\Users\claws\Downloads\Minesweeper\Packages\MineRushCore" %*
