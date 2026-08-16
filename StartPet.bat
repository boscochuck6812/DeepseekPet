@echo off
rem Start the DeepSeek desktop pet. Local only, no network.
rem Use Windows PowerShell 5.1 (always present) — the tested path.
cd /d "%~dp0"
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0DeepSeekPet.ps1"
