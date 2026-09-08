$ErrorActionPreference = 'Stop'
$project = $PSScriptRoot
$python = Join-Path $project '.venv-tts\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    throw 'TTS environment is missing. Run setup_voice.ps1 first.'
}
$key = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'Process')
if ([string]::IsNullOrWhiteSpace($key)) {
    $key = [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User')
    $env:OPENROUTER_API_KEY = $key
}
if ([string]::IsNullOrWhiteSpace($key)) {
    throw 'OPENROUTER_API_KEY is not configured. Run configure_openrouter.bat.'
}
$listeners = Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue
foreach ($listener in @($listeners)) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)"
    if (-not $process -or $process.CommandLine -notmatch 'bridge_server\.py') {
        throw "Port 8765 is occupied by another application (PID $($listener.OwningProcess))."
    }
    Stop-Process -Id $listener.OwningProcess -Force
}
if ($listeners) { Start-Sleep -Milliseconds 400 }
Set-Location -LiteralPath $project
& $python -u bridge_server.py --chat-responder --no-record --openrouter-model 'qwen/qwen3.7-flash' --tts-device 'CABLE Input'
