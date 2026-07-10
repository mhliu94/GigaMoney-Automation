function Test-GigamoneyForegroundOutput {
    param(
        [string[]]$WindowOutput,
        [string[]]$ActivityOutput,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    $focusLines = @($WindowOutput | Where-Object { $_ -match 'mCurrentFocus|mFocusedApp' })
    $resumedLines = @($ActivityOutput | Where-Object { $_ -match 'mResumedActivity|topResumedActivity' })
    $foregroundText = (@($focusLines) + @($resumedLines)) -join "`n"
    return ($foregroundText -match [regex]::Escape($PackageName))
}

function Test-GigamoneyAppForeground {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$PackageName
    )

    $windowOutput = @(& $AdbPath shell dumpsys window windows 2>$null)
    $activityOutput = @(& $AdbPath shell dumpsys activity activities 2>$null)
    return (Test-GigamoneyForegroundOutput -WindowOutput $windowOutput -ActivityOutput $activityOutput -PackageName $PackageName)
}

function Ensure-GigamoneyAppForeground {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [int]$TimeoutSeconds = 15,
        [int]$SettleMilliseconds = 2500
    )

    if (Test-GigamoneyAppForeground -AdbPath $AdbPath -PackageName $PackageName) {
        return
    }

    Write-Step 'Gigamoney is not in the foreground; bringing the app forward.'
    & $AdbPath shell monkey -p $PackageName -c android.intent.category.LAUNCHER 1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not launch Gigamoney package $PackageName with adb."
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        if (Test-GigamoneyAppForeground -AdbPath $AdbPath -PackageName $PackageName) {
            Write-Step 'Gigamoney is now running in the foreground; waiting for the UI to settle.'
            if ($SettleMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $SettleMilliseconds
            }
            return
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "Gigamoney did not reach the foreground within $TimeoutSeconds seconds after launch."
}
