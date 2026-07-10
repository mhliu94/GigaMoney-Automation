#requires -Version 5.1

param(
    [int]$LogLines = 10
)

$ErrorActionPreference = 'Stop'
$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $scriptRoot
$pidPath = Join-Path $projectRoot 'work\gigamoney-runner.pid.json'
$errorLogPath = Join-Path $projectRoot 'logs\gigamoney-runner.err.log'

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
            return [pscustomobject]@{ processId = $legacyPid; startedAt = $null; configPath = $null }
        }
    } catch {
        return $null
    }
    return $null
}

$record = Read-PidRecord
if (-not $record) {
    Write-Host 'Gigamoney trading runner is NOT running (no PID record).'
    exit 1
}

$runnerPid = [int]$record.processId
$process = Get-Process -Id $runnerPid -ErrorAction SilentlyContinue
if (-not $process) {
    Write-Host "Gigamoney trading runner is NOT running (stale PID record: $runnerPid)."
    exit 1
}

try {
    $details = Get-CimInstance Win32_Process -Filter "ProcessId = $runnerPid" -ErrorAction Stop
    if (-not $details.CommandLine -or $details.CommandLine -notmatch 'Start-GigamoneyTradingRunner\.ps1') {
        Write-Host "Gigamoney trading runner is NOT running (PID $runnerPid belongs to another process)."
        exit 1
    }
} catch {
    if ($process.ProcessName -notmatch 'powershell|pwsh') {
        Write-Host "Gigamoney trading runner is NOT running (PID $runnerPid belongs to another process)."
        exit 1
    }
}

Write-Host 'Gigamoney trading runner is RUNNING.'
Write-Host "PID:        $runnerPid"
if ($record.startedAt) { Write-Host "Started:    $($record.startedAt)" }
if ($record.configPath) { Write-Host "Config:     $($record.configPath)" }
Write-Host "Error log:  $errorLogPath"

if ($LogLines -gt 0 -and (Test-Path -LiteralPath $errorLogPath)) {
    Write-Host ''
    Write-Host "Latest activity ($LogLines lines):"
    Get-Content -LiteralPath $errorLogPath -Tail $LogLines
}

exit 0
