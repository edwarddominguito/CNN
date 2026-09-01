param(
    [switch]$Restart,
    [string]$HostName = '0.0.0.0',
    [int]$Port = 8000
)

$ErrorActionPreference = 'Stop'

$backendRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$python = Join-Path $backendRoot '.venv\Scripts\python.exe'
$healthHost = '127.0.0.1'
$baseUrl = "http://${healthHost}:$Port"

if (-not (Test-Path $python)) {
    Write-Error "Missing backend virtual environment. Run setup first, then try again."
}

$listenerLine = netstat -ano |
    Select-String -Pattern "^\s*TCP\s+\S+:$Port\s+\S+\s+LISTENING\s+\d+\s*$" |
    Select-Object -First 1

if ($listenerLine) {
    $columns = ($listenerLine.Line.Trim() -split '\s+')
    $processId = [int]$columns[-1]

    if ($Restart) {
        Write-Host "Stopping existing listener on port $Port (PID $processId)..."
        Stop-Process -Id $processId -Force
        Start-Sleep -Seconds 1
    } else {
        try {
            $metrics = Invoke-RestMethod -Uri "$baseUrl/metrics" -TimeoutSec 3
            $modelState = if ($metrics.model_available) { 'model loaded' } else { 'demo mode' }
            Write-Host "Backend is already running at $baseUrl (PID $processId, $modelState)."
            Write-Host "Use .\run_backend.ps1 -Restart if you want to restart it."
            exit 0
        } catch {
            Write-Host "Port $Port is already in use by PID $processId, but it did not respond as this backend."
            Write-Host "Stop that process or run .\run_backend.ps1 -Restart."
            exit 1
        }
    }
}

Set-Location $backendRoot
Write-Host "Starting backend on $HostName`:$Port ..."
Write-Host "Use your device's IPv4 address with port $Port from phones on the same Wi-Fi."
& $python -m uvicorn main:app --host $HostName --port $Port
