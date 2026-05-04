param(
    [ValidateSet("sim", "tune", "doctor")]
    [string]$Mode = "sim",
    [string]$SerialPort = "",
    [switch]$Plain,
    [ValidateSet("zh", "en")]
    [string]$Lang = "zh",
    [string]$ApiKey = "",
    [string]$ApiBaseUrl = "",
    [string]$Model = "",
    [string]$Provider = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$Python = Join-Path $Root ".venv\Scripts\python.exe"
if (-not (Test-Path $Python)) {
    throw "Virtual environment not found: $Python"
}

foreach ($name in "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "GIT_HTTP_PROXY", "GIT_HTTPS_PROXY") {
    $value = [Environment]::GetEnvironmentVariable($name, "Process")
    if ($value -match "127\.0\.0\.1:9") {
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
}

$internetSettings = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
if ($internetSettings.ProxyEnable -eq 1 -and $internetSettings.ProxyServer) {
    $proxy = [string]$internetSettings.ProxyServer
    if ($proxy -notmatch "://") {
        $proxy = "http://$proxy"
    }
    if (-not $env:HTTP_PROXY) { $env:HTTP_PROXY = $proxy }
    if (-not $env:HTTPS_PROXY) { $env:HTTPS_PROXY = $proxy }
    if (-not $env:ALL_PROXY) { $env:ALL_PROXY = $proxy }
}

if ($ApiKey) { $env:LLM_API_KEY = $ApiKey }
if ($ApiBaseUrl) { $env:LLM_API_BASE_URL = $ApiBaseUrl }
if ($Model) { $env:LLM_MODEL_NAME = $Model }
if ($Provider) { $env:LLM_PROVIDER = $Provider }

if ($Mode -eq "doctor") {
    & $Python "doctor.py"
    exit $LASTEXITCODE
}

$argsList = @("launcher.py", $Mode)
if ($Mode -eq "tune" -and $SerialPort) {
    $argsList = @("launcher.py", $SerialPort)
}
if ($Plain) { $argsList += "--plain" }
if ($Lang) { $argsList += @("--lang", $Lang) }

& $Python @argsList
