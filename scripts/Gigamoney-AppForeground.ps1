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

function Test-GigamoneyNotRespondingOcrText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $normalized = ($Text -replace '[\u2018\u2019\u02BC\uFF07]', "'") -replace '\s+', ' '
    return ($normalized -match "(?i)\bisn't responding\b")
}

function Restart-GigamoneyApp {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [Parameter(Mandatory = $true)][string]$Reason,
        [int]$StopSettleMilliseconds = 1000,
        [int]$LaunchSettleMilliseconds = 3500
    )

    Write-Step "$Reason; closing and reopening the app before the operation."
    & $AdbPath shell am force-stop $PackageName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not force-stop Gigamoney package $PackageName with adb."
    }

    if ($StopSettleMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $StopSettleMilliseconds
    }

    & $AdbPath shell monkey -p $PackageName -c android.intent.category.LAUNCHER 1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not relaunch Gigamoney package $PackageName with adb."
    }

    if ($LaunchSettleMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $LaunchSettleMilliseconds
    }
}

function Restart-GigamoneyAppAfterNotResponding {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$PackageName,
        [int]$StopSettleMilliseconds = 1000,
        [int]$LaunchSettleMilliseconds = 3500
    )

    Restart-GigamoneyApp `
        -AdbPath $AdbPath `
        -PackageName $PackageName `
        -Reason "Gigamoney isn't responding" `
        -StopSettleMilliseconds $StopSettleMilliseconds `
        -LaunchSettleMilliseconds $LaunchSettleMilliseconds
}

function New-GigamoneyLightRegionStats {
    param(
        [long]$LumaSum,
        [int]$Count,
        [int]$DarkCount,
        [int]$BrightCount
    )

    if ($Count -le 0) {
        throw 'Ad-screen detection region did not contain any sampled pixels.'
    }

    return [pscustomobject]@{
        Mean           = [double]$LumaSum / $Count
        DarkFraction   = [double]$DarkCount / $Count
        BrightFraction = [double]$BrightCount / $Count
        SampleCount    = $Count
    }
}

function Get-GigamoneyAdScreenProfile {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::new($ImagePath)
    try {
        if ($bitmap.Width -lt 100 -or $bitmap.Height -lt 100) {
            throw "Ad-screen screenshot is unexpectedly small: $($bitmap.Width)x$($bitmap.Height)."
        }

        # Normalized regions keep the detector independent of emulator resolution.
        # The footer ends above Android's navigation area and covers Gigamoney's
        # bottom confirmation controls. An ad must be dark in both bottom regions.
        $step = [Math]::Max(6, [int]([Math]::Min($bitmap.Width, $bitmap.Height) / 100))

        [long]$centerLuma = 0; [int]$centerCount = 0; [int]$centerDark = 0; [int]$centerBright = 0
        [long]$outerLuma = 0; [int]$outerCount = 0; [int]$outerDark = 0; [int]$outerBright = 0
        [long]$lowerLuma = 0; [int]$lowerCount = 0; [int]$lowerDark = 0; [int]$lowerBright = 0
        [long]$footerLuma = 0; [int]$footerCount = 0; [int]$footerDark = 0; [int]$footerBright = 0

        for ($y = [int]($step / 2); $y -lt $bitmap.Height; $y += $step) {
            $ny = [double]$y / $bitmap.Height
            for ($x = [int]($step / 2); $x -lt $bitmap.Width; $x += $step) {
                $nx = [double]$x / $bitmap.Width
                $region = if ($nx -ge 0.22 -and $nx -le 0.78 -and $ny -ge 0.22 -and $ny -le 0.70) {
                    'Center'
                } elseif ($nx -ge 0.04 -and $nx -le 0.96 -and $ny -ge 0.76 -and $ny -le 0.90) {
                    'Lower'
                } elseif ($nx -ge 0.04 -and $nx -le 0.96 -and $ny -gt 0.90 -and $ny -le 0.965) {
                    'Footer'
                } elseif (
                    ($nx -ge 0.04 -and $nx -le 0.96 -and $ny -ge 0.06 -and $ny -lt 0.18) -or
                    (($nx -ge 0.04 -and $nx -lt 0.18) -or ($nx -gt 0.82 -and $nx -le 0.96)) -and
                    $ny -ge 0.18 -and $ny -lt 0.76
                ) {
                    'Outer'
                } else {
                    $null
                }

                if (-not $region) {
                    continue
                }

                $pixel = $bitmap.GetPixel($x, $y)
                $red = [int]$pixel.R
                $green = [int]$pixel.G
                $blue = [int]$pixel.B
                $luma = [int]((54 * $red + 183 * $green + 19 * $blue) / 256)
                $maxChannel = [Math]::Max($red, [Math]::Max($green, $blue))
                $isDark = $luma -le 90 -and $maxChannel -le 125
                $isBright = $luma -ge 140 -or $maxChannel -ge 180

                switch ($region) {
                    'Center' {
                        $centerLuma += $luma; $centerCount++
                        if ($isDark) { $centerDark++ }
                        if ($isBright) { $centerBright++ }
                    }
                    'Outer' {
                        $outerLuma += $luma; $outerCount++
                        if ($isDark) { $outerDark++ }
                        if ($isBright) { $outerBright++ }
                    }
                    'Lower' {
                        $lowerLuma += $luma; $lowerCount++
                        if ($isDark) { $lowerDark++ }
                        if ($isBright) { $lowerBright++ }
                    }
                    'Footer' {
                        $footerLuma += $luma; $footerCount++
                        if ($isDark) { $footerDark++ }
                        if ($isBright) { $footerBright++ }
                    }
                }
            }
        }

        return [pscustomobject]@{
            Width  = $bitmap.Width
            Height = $bitmap.Height
            Center = New-GigamoneyLightRegionStats $centerLuma $centerCount $centerDark $centerBright
            Outer  = New-GigamoneyLightRegionStats $outerLuma $outerCount $outerDark $outerBright
            Lower  = New-GigamoneyLightRegionStats $lowerLuma $lowerCount $lowerDark $lowerBright
            Footer = New-GigamoneyLightRegionStats $footerLuma $footerCount $footerDark $footerBright
        }
    } finally {
        $bitmap.Dispose()
    }
}

function Get-GigamoneyAdScreenClassification {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    $profile = Get-GigamoneyAdScreenProfile -ImagePath $ImagePath
    $centerContrast = $profile.Center.Mean - $profile.Outer.Mean
    $centralCandidate = (
        $centerContrast -ge 14 -and
        $profile.Center.BrightFraction -ge 0.08 -and
        $profile.Center.BrightFraction -ge ($profile.Outer.BrightFraction + 0.04)
    )
    $strongCenter = (
        $profile.Outer.Mean -le 120 -and
        $profile.Outer.BrightFraction -le 0.14 -and
        $centerContrast -ge 22 -and
        $profile.Center.BrightFraction -ge 0.14 -and
        $profile.Center.BrightFraction -ge ($profile.Outer.BrightFraction + 0.06)
    )
    $bottomLit = (
        $profile.Lower.Mean -ge 108 -or
        $profile.Footer.Mean -ge 108 -or
        $profile.Lower.BrightFraction -ge 0.16 -or
        $profile.Footer.BrightFraction -ge 0.16
    )
    $bottomDark = (
        $profile.Lower.Mean -le 92 -and
        $profile.Footer.Mean -le 92 -and
        $profile.Lower.DarkFraction -ge 0.58 -and
        $profile.Footer.DarkFraction -ge 0.58 -and
        $profile.Lower.BrightFraction -le 0.10 -and
        $profile.Footer.BrightFraction -le 0.10 -and
        $profile.Lower.Mean -le ($profile.Outer.Mean + 25) -and
        $profile.Footer.Mean -le ($profile.Outer.Mean + 25) -and
        $profile.Center.Mean -ge ([Math]::Max($profile.Lower.Mean, $profile.Footer.Mean) + 20)
    )

    # Check the lit footer first so a normal confirmation screen can never pass
    # the dark-bottom ad rule even if its center resembles an advertisement.
    $kind = if ($centralCandidate -and $bottomLit) {
        'ConfirmationLike'
    } elseif ($strongCenter -and $bottomDark) {
        'Ad'
    } elseif ($centralCandidate) {
        'Ambiguous'
    } else {
        'None'
    }

    return [pscustomobject]@{
        Kind    = $kind
        Profile = $profile
    }
}

function Test-GigamoneyAdScreenImage {
    param([Parameter(Mandatory = $true)][string]$ImagePath)

    return ((Get-GigamoneyAdScreenClassification -ImagePath $ImagePath).Kind -eq 'Ad')
}

function Save-GigamoneyAdGuardScreenshot {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutMilliseconds = 10000
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $AdbPath
    $psi.Arguments = 'exec-out screencap -p'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = $null
    $stream = $null
    $stderr = ''
    $exitCode = -1
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($stream)
        $errorTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            throw "Timed out after $TimeoutMilliseconds ms while capturing the screen for the ad guard."
        }
        if (-not $copyTask.Wait(5000)) {
            throw 'Timed out while reading the ad-guard screenshot from adb.'
        }
        if (-not $errorTask.Wait(1000)) {
            throw 'Timed out while reading adb diagnostics for the ad guard.'
        }

        $stream.Flush()
        $stderr = $errorTask.Result
        $exitCode = $process.ExitCode
    } finally {
        if ($stream) {
            $stream.Dispose()
        }
        if ($process) {
            $process.Dispose()
        }
    }

    if ($exitCode -ne 0) {
        throw "Could not capture the screen for the ad guard (exit code $exitCode): $stderr"
    }
    if ((Get-Item -LiteralPath $Path).Length -le 0) {
        throw 'Could not capture the screen for the ad guard: adb returned an empty image.'
    }
}

function Get-CurrentGigamoneyAdScreenClassification {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$WorkDir
    )

    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $path = Join-Path $WorkDir ("gigamoney-ad-guard-{0}.png" -f ([guid]::NewGuid().ToString('N')))
    try {
        Save-GigamoneyAdGuardScreenshot -AdbPath $AdbPath -Path $path
        return Get-GigamoneyAdScreenClassification -ImagePath $path
    } finally {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

function Get-StableGigamoneyAdScreenClassification {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [int]$RecheckMilliseconds = 200
    )

    $first = Get-CurrentGigamoneyAdScreenClassification -AdbPath $AdbPath -WorkDir $WorkDir
    if ($first.Kind -notin @('Ad', 'Ambiguous')) {
        return $first
    }

    Start-Sleep -Milliseconds $RecheckMilliseconds
    $second = Get-CurrentGigamoneyAdScreenClassification -AdbPath $AdbPath -WorkDir $WorkDir
    if ($first.Kind -eq 'Ad' -and $second.Kind -eq 'Ad') {
        return $second
    }
    if ($second.Kind -in @('None', 'ConfirmationLike')) {
        return $second
    }

    return [pscustomobject]@{
        Kind    = 'Ambiguous'
        Profile = $second.Profile
    }
}

function Dismiss-GigamoneyAdScreenIfPresent {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [string]$PackageName = 'lb.whale.hkwinner.android',
        [int]$MaxDismissals = 2,
        [int]$SettleMilliseconds = 600
    )

    $handledScreens = 0
    $backPresses = 0
    $restartedAfterAmbiguous = $false
    while ($true) {
        $classification = Get-StableGigamoneyAdScreenClassification -AdbPath $AdbPath -WorkDir $WorkDir
        if ($classification.Kind -in @('None', 'ConfirmationLike')) {
            if ($handledScreens -gt 0) {
                Write-Step "Ad or ambiguous overlay cleared; continuing the requested Gigamoney operation."
            }
            return $handledScreens
        }

        if ($classification.Kind -eq 'Ambiguous') {
            if ($restartedAfterAmbiguous) {
                throw 'The screen still resembles an ambiguous dim overlay after Gigamoney was restarted. Refusing to perform the operation.'
            }

            $profile = $classification.Profile
            $reason = "Ambiguous dim overlay detected (center={0:N0}, lower={1:N0}, footer={2:N0})" -f $profile.Center.Mean, $profile.Lower.Mean, $profile.Footer.Mean
            Restart-GigamoneyApp -AdbPath $AdbPath -PackageName $PackageName -Reason $reason
            Ensure-GigamoneyAppForeground -AdbPath $AdbPath -PackageName $PackageName
            $restartedAfterAmbiguous = $true
            $handledScreens++
            continue
        }
        if ($backPresses -ge $MaxDismissals) {
            throw "An ad screen is still visible after $MaxDismissals Back presses. Refusing to perform the operation."
        }

        $profile = $classification.Profile
        Write-Step ("Ad screen detected (center={0:N0}, lower={1:N0}, footer={2:N0}); pressing Back before the operation." -f $profile.Center.Mean, $profile.Lower.Mean, $profile.Footer.Mean)
        & $AdbPath shell input keyevent BACK | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not dismiss the ad screen with the Android Back key (adb exit code $LASTEXITCODE)."
        }

        $backPresses++
        $handledScreens++
        Start-Sleep -Milliseconds $SettleMilliseconds
    }
}
