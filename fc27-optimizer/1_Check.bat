@echo off
rem FC 27 Optimizer: diagnostics of PC and internet. Changes nothing.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\FC27-Check.ps1" %*
