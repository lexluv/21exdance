@echo off
rem FC 27 Optimizer: apply optimizations. Asks for administrator rights (UAC).
rem Preview only, without changes:  2_Optimize.bat -DryRun
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\FC27-Optimize.ps1" %*
