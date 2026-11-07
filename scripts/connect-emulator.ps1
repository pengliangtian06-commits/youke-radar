param([string]$DevEco = 'C:\Program Files\Huawei\DevEco Studio')
$ErrorActionPreference = 'Stop'
$hdcPath = Join-Path $DevEco 'sdk\default\openharmony\toolchains\hdc.exe'
& $hdcPath list targets
& $hdcPath rport tcp:8000 tcp:8000
Write-Host 'In the application, set the service address to http://127.0.0.1:8000 and test the connection.'
