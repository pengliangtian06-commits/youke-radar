param([string]$DevEco = 'C:\Program Files\Huawei\DevEco Studio')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$env:DEVECO_SDK_HOME = Join-Path $DevEco 'sdk'
$env:JAVA_HOME = Join-Path $DevEco 'jbr'
$env:Path = (Join-Path $DevEco 'jbr\bin') + ';' + (Join-Path $DevEco 'tools\node') + ';' + (Join-Path $DevEco 'tools\ohpm\bin') + ';' + $env:Path
Push-Location (Join-Path $projectRoot 'harmony')
try {
    & (Join-Path $DevEco 'tools\hvigor\bin\hvigorw.bat') assembleHap --mode module -p product=default -p module=entry@default -p buildMode=debug --no-daemon
    if ($LASTEXITCODE -ne 0) { throw 'HarmonyOS build failed.' }
    $outputDir = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    Get-ChildItem 'entry\build\default\outputs\default' -Filter '*.hap' | Copy-Item -Destination $outputDir
} finally { Pop-Location }
