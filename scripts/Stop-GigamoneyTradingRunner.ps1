#requires -Version 5.1

param(
    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 300,

    # Immediately terminates the runner and any child helper process. This can interrupt an order in progress.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $scriptRoot
$workDir = Join-Path $projectRoot 'work'
$pidPath = Join-Path $workDir 'gigamoney-runner.pid.json'
$stopRequestPath = Join-Path $workDir 'gigamoney-runner.stop'

function Read-PidRecord {
    if (-not (Test-Path -LiteralPath $pidPath)) {
        return $null
    }
    try {
        $raw = (Get-Content -LiteralPath $pidPath -Raw).Trim()
        if ($raw.StartsWith('{')) {
            return ($raw | ConvertFrom-Json)
        }
        $legacyPid = 0
        if ([int]::TryParse($raw, [ref]$legacyPid)) {
            return [pscustomobject]@{ processId = $legacyPid }
        }
    } catch {
        return $null
    }
    return $null
}

function Remove-ControlFiles {
    foreach ($path in @($pidPath, $stopRequestPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

function Get-DescendantProcessIds([int]$ParentId, $AllProcesses) {
    $children = @($AllProcesses | Where-Object { [int]$_.ParentProcessId -eq $ParentId })
    $ids = @()
    foreach ($child in $children) {
        $ids += Get-DescendantProcessIds -ParentId ([int]$child.ProcessId) -AllProcesses $AllProcesses
        $ids += [int]$child.ProcessId
    }
    return @($ids)
}

$record = Read-PidRecord
if (-not $record) {
    Write-Host 'Gigamoney trading runner is not running.'
    Remove-ControlFiles
    exit 0
}

$runnerPid = [int]$record.processId
$process = Get-Process -Id $runnerPid -ErrorAction SilentlyContinue
if (-not $process) {
    Write-Host "Gigamoney trading runner is not running; removed stale PID record $runnerPid."
    Remove-ControlFiles
    exit 0
}

try {
    $details = Get-CimInstance Win32_Process -Filter "ProcessId = $runnerPid" -ErrorAction Stop
    if (-not $details.CommandLine -or $details.CommandLine -notmatch 'Start-GigamoneyTradingRunner\.ps1') {
        throw "Refusing to stop PID $runnerPid because it does not appear to be the Gigamoney trading runner."
    }
} catch {
    if ($_.Exception.Message -like 'Refusing to stop*') {
        throw
    }
    if ($process.ProcessName -notmatch 'powershell|pwsh') {
        throw "Refusing to stop PID $runnerPid because it is not a PowerShell process."
    }
}

if ($Force) {
    Write-Warning 'Force-stopping the runner. Any in-progress emulator operation will be interrupted.'
    $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $descendantIds = @(Get-DescendantProcessIds -ParentId $runnerPid -AllProcesses $allProcesses)
    foreach ($childId in $descendantIds) {
        Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue
    }
    Stop-Process -Id $runnerPid -Force -ErrorAction SilentlyContinue
    Remove-ControlFiles
    Write-Host "Gigamoney trading runner PID $runnerPid was force-stopped."
    exit 0
}

New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Set-Content -LiteralPath $stopRequestPath -Value ([DateTimeOffset]::UtcNow.ToString('o')) -Encoding ASCII
Write-Host "Requested a graceful stop for Gigamoney trading runner PID $runnerPid."

$deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    Start-Sleep -Milliseconds 250
    $process = Get-Process -Id $runnerPid -ErrorAction SilentlyContinue
} while ($process -and [DateTimeOffset]::UtcNow -lt $deadline)

if ($process) {
    Write-Warning "The runner is still completing an operation after $TimeoutSeconds seconds. It was not killed because that could interrupt an order. Run this script again with -Force to terminate it immediately."
    exit 2
}

Remove-ControlFiles
Write-Host 'Gigamoney trading runner stopped cleanly.'
exit 0
