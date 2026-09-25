@echo off
rem FC 27 Optimizer: undo all changes made by 2_Optimize.bat. Asks for administrator rights (UAC).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\FC27-Restore.ps1" %*
