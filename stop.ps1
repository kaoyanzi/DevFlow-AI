# DevFlow AI stopper
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File "stop.ps1"
#   powershell -ExecutionPolicy Bypass -File "stop.ps1" -WithContainers   # also stop postgres/etcd/minio/milvus (data kept)

param(
    [switch]$WithContainers
)

Write-Host "== DevFlow AI stop ==" -ForegroundColor Cyan

foreach ($port in @(8000, 3000)) {
    $connections = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if (-not $connections) {
        Write-Host "  port $port : nothing listening"
        continue
    }
    foreach ($connection in $connections) {
        $procId = $connection.OwningProcess
        $procName = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
        Write-Host "  port $port : stopping $procName (PID $procId)"
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
}

if ($WithContainers) {
    $dockerPath = "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
    if (Test-Path -LiteralPath $dockerPath -PathType Leaf) {
        $projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
        Push-Location $projectRoot
        try { & $dockerPath compose stop postgres etcd minio milvus | Out-Null }
        finally { Pop-Location }
        Write-Host "  containers stopped (volumes kept)"
    }
}

Write-Host "Done." -ForegroundColor Green
