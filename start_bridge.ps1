param(
    [switch]$Execute,
    [switch]$NoRecord
)

$arguments = @(
    (Join-Path $PSScriptRoot 'bridge_server.py'),
    '--data-dir',
    (Join-Path $PSScriptRoot 'data')
)

if ($Execute) {
    $arguments += '--execute'
}

if ($NoRecord) {
    $arguments += '--no-record'
}

python @arguments
