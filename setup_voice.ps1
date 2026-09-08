$ErrorActionPreference = 'Stop'
$project = $PSScriptRoot
$venv = Join-Path $project '.venv-tts'
$python = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    py -3.11 -m venv $venv
}
& $python -m pip install --upgrade pip
& $python -m pip install piper-tts sounddevice
$models = Join-Path $project 'models\piper'
New-Item -ItemType Directory -Force -Path $models | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $models 'ru_RU-dmitri-medium.onnx'))) {
    & $python -m piper.download_voices --data-dir $models ru_RU-dmitri-medium
}
Write-Host 'Piper and the Russian Dmitri voice are ready.' -ForegroundColor Green
