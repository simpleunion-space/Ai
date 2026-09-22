[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$moduleRoot = Split-Path -Parent $PSCommandPath
Set-Location -LiteralPath $moduleRoot

function Stop-Run([string]$Message) {
    Write-Error $Message
    exit 1
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Stop-Run 'Docker CLI не найден. Установите Docker Desktop и повторите запуск.'
}

& docker info --format '{{.ServerVersion}}' *> $null
if ($LASTEXITCODE -ne 0) {
    Stop-Run 'Docker Desktop daemon недоступен. Запустите Docker Desktop и убедитесь, что текущая учётная запись имеет к нему доступ.'
}

$keyScript = Join-Path $moduleRoot 'set-api-keys.ps1'
if (Test-Path -LiteralPath $keyScript) {
    . $keyScript
} else {
    Write-Warning 'Локальный set-api-keys.ps1 не найден. Runner создаст диагностический preflight-отчёт с отсутствующими переменными.'
}

$configPath = Join-Path $moduleRoot 'benchmark.json'
try {
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
} catch {
    Stop-Run "Не удалось прочитать benchmark.json: $($_.Exception.Message)"
}

$environmentNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($provider in $config.providers) {
    if (-not $provider.enabled) { continue }
    if ($provider.api_key_env) { [void]$environmentNames.Add([string]$provider.api_key_env) }
    if ($provider.base_url_env) { [void]$environmentNames.Add([string]$provider.base_url_env) }
}

$runArguments = [System.Collections.Generic.List[string]]::new()
foreach ($name in $environmentNames) {
    if (-not (Test-Path -LiteralPath "Env:$name")) {
        Set-Item -LiteralPath "Env:$name" -Value ''
    }
    [void]$runArguments.Add('--env')
    [void]$runArguments.Add($name)
}

$resultsRoot = Join-Path $moduleRoot 'results'
New-Item -ItemType Directory -Force -Path $resultsRoot | Out-Null

& docker compose -f (Join-Path $moduleRoot 'compose.yaml') build --pull --no-cache benchmark
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& docker compose -f (Join-Path $moduleRoot 'compose.yaml') run --rm @runArguments benchmark
exit $LASTEXITCODE
