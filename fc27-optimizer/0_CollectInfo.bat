@echo off
rem FC 27 Optimizer: collect full diagnostics into one report (Desktop + clipboard). Changes nothing.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\FC27-CollectInfo.ps1" %*
