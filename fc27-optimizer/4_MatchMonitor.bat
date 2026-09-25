@echo off
rem FC 27 Optimizer: record ping, packet loss, CPU and GPU load while you play a match. Changes nothing.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\FC27-MatchMonitor.ps1" %*
