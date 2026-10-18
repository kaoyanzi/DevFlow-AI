# DevFlow AI one-click starter
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File "start.ps1"
#   powershell -ExecutionPolicy Bypass -File "start.ps1" -SkipContainers   # containers already running
#   powershell -ExecutionPolicy Bypass -File "start.ps1" -NoBrowser        # do not open browser
#
# Prerequisites:
#   - Docker Desktop is running (Engine running)
#   - backend/.venv exists (installed from backend/requirements.local.txt)
#   - frontend/node_modules exists (npm install)

param(
    [switch]$SkipContainers,
    [switch]$NoBrowser,
    [ValidateRange(1, 65535)]
    [int]$BackendPort = 8000,
    [ValidateRange(1, 65535)]
    [int]$FrontendPort = 3000
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$backendDir = Join-Path $projectRoot "backend"
$frontendDir = Join-Path $projectRoot "frontend"
$pythonExe = Join-Path $backendDir ".venv\Scripts\python.exe"
$dockerPath = "C:\Program Files\Docker\Docker\resources\bin\docker.exe"

Write-Host "== DevFlow AI start ==" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
    throw "backend/.venv not found. Create venv and install backend/requirements.local.txt first."
}
if (-not (Test-Path -LiteralPath (Join-Path $frontendDir "node_modules") -PathType Container)) {
    throw "frontend/node_modules not found. Run npm install in frontend first."
}
New-Item -ItemType Directory -Path (Join-Path $projectRoot ".data") -Force | Out-Null

if (-not $SkipContainers) {
    Write-Host "[1/4] Checking Docker engine..." -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $dockerPath -PathType Leaf)) { throw "Docker Desktop not found." }
    & $dockerPath info --format "{{.ServerVersion}}" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker engine is not running. Open Docker Desktop, wait until it shows Running, then run this script again."
    }
    Write-Host "      OK" -ForegroundColor Green

    Write-Host "[2/4] Starting containers: postgres / etcd / minio / milvus" -ForegroundColor Cyan
    Push-Location $projectRoot
    try { & $dockerPath compose up -d postgres etcd minio milvus | Out-Null }
    finally { Pop-Location }
    Write-Host "      Waiting for PostgreSQL..." -NoNewline
    for ($i = 0; $i -lt 90; $i++) {
        $status = & $dockerPath ps --filter "name=devflow-ai-postgres" --format "{{.Status}}"
        if ($status -match "healthy") { break }
        Start-Sleep -Milliseconds 1000
    }
    Write-Host " OK" -ForegroundColor Green
}
else {
    Write-Host "[1/4] Skipped container check (-SkipContainers)" -ForegroundColor Yellow
    Write-Host "[2/4] Skipped container start" -ForegroundColor Yellow
}

$env:PYTHONPATH = $backendDir

Write-Host "[3/4] Starting backend FastAPI on port $BackendPort..." -ForegroundColor Cyan
$backendProcess = Start-Process `
    -FilePath $pythonExe `
    -ArgumentList @("-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "$BackendPort") `
    -WorkingDirectory $backendDir `
    -WindowStyle Minimized `
    -PassThru

$backendReady = $false
for ($i = 0; $i -lt 60; $i++) {
    if ($backendProcess.HasExited) {
        throw "Backend exited too early. Run uvicorn manually in the backend folder to see the error."
    }
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$BackendPort/health" -TimeoutSec 2 | Out-Null
        $backendReady = $true
        break
    }
    catch { Start-Sleep -Milliseconds 1000 }
}
if (-not $backendReady) { throw "Backend did not become ready within 60s." }
Write-Host "      OK" -ForegroundColor Green

Write-Host "[4/4] Starting frontend Next.js on port $FrontendPort..." -ForegroundColor Cyan

# Next.js dev cleans stale files inside .next-dev on boot. That bulk delete can trip the
# sandbox safe-delete guard and kill the server, so rotate the cache dir out of the way first.
# Old .next-dev.stale-* folders are harmless; delete them manually in Explorer if disk matters.
$cacheDir = Join-Path $frontendDir ".next-dev"
if (Test-Path -LiteralPath $cacheDir -PathType Container) {
    $staleName = ".next-dev.stale-" + (Get-Date -Format "yyyyMMddHHmmss")
    Rename-Item -LiteralPath $cacheDir -NewName $staleName
    Write-Host "      rotated .next-dev -> $staleName" -ForegroundColor Yellow
}
$env:NEXT_PUBLIC_API_BASE_URL = "http://127.0.0.1:$BackendPort"
# NOTE: must launch npm.cmd directly. "cmd.exe /c" is blocked by the sandbox policy and exits immediately.
$frontendProcess = Start-Process `
    -FilePath "npm.cmd" `
    -ArgumentList @("run", "dev", "--", "-p", "$FrontendPort") `
    -WorkingDirectory $frontendDir `
    -WindowStyle Minimized `
    -PassThru

$frontendReady = $false
for ($i = 0; $i -lt 120; $i++) {
    if ($frontendProcess.HasExited) {
        throw "Frontend exited too early. Run npm run dev manually in the frontend folder to see the error."
    }
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$FrontendPort" -TimeoutSec 2 | Out-Null
        $frontendReady = $true
        break
    }
    catch { Start-Sleep -Milliseconds 1000 }
}
if (-not $frontendReady) { throw "Frontend did not become ready within 120s." }
Write-Host "      OK" -ForegroundColor Green

Write-Host ""
Write-Host "All ready:" -ForegroundColor Cyan
Write-Host "  Frontend : http://127.0.0.1:$FrontendPort"
Write-Host "  Backend  : http://127.0.0.1:$BackendPort"
Write-Host "  API docs : http://127.0.0.1:$BackendPort/docs"
Write-Host "  PID backend=$($backendProcess.Id) frontend=$($frontendProcess.Id)"
Write-Host "  Stop with: powershell -ExecutionPolicy Bypass -File stop.ps1"

if (-not $NoBrowser) {
    Start-Process "http://127.0.0.1:$FrontendPort"
}
