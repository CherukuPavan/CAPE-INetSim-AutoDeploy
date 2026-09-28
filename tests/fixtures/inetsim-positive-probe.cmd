@echo off
setlocal
rem AutoDeploy controlled route=inetsim positive probe.
rem This is deliberately benign: it performs DNS and HTTP to the .invalid
rem acceptance marker. INetSim should synthesize the DNS/HTTP response.
set "MARKER=cape-inetsim-accept.invalid"
%SystemRoot%\System32\nslookup.exe %MARKER%
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$wc=New-Object Net.WebClient; try { $null=$wc.DownloadString('http://%MARKER%/') } catch { }"
exit /b 0
