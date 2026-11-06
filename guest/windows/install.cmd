@echo off
rem Installs the UTM Power Helper, plus the VirtIO serial driver and QEMU guest agent if missing.
rem Asks for administrator rights, then runs utm-power-helper.ps1 -Install from this folder.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File ""%~dp0utm-power-helper.ps1"" -Install'"
