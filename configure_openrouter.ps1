$ErrorActionPreference = 'Stop'
$secure = Read-Host 'Paste a NEW OpenRouter API key' -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ([string]::IsNullOrWhiteSpace($key) -or -not $key.StartsWith('sk-or-')) {
        throw 'The value does not look like an OpenRouter API key.'
    }
    [Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $key, 'User')
    Write-Host 'OPENROUTER_API_KEY saved for the current Windows user.' -ForegroundColor Green
} finally {
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
    $key = $null
}
