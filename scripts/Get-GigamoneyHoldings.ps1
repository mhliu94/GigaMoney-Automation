param(
    [string]$ConfigPath = '',
    [int]$MaxHomeBacks = 3,
    [int]$MaxPortfolioScrolls = 8
)

$ErrorActionPreference = 'Stop'

$script:ScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Parent $PSCommandPath
} elseif (-not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    (Get-Location).Path
}
$script:ProjectRoot = Split-Path -Parent $script:ScriptRoot
$script:ConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    Join-Path $script:ProjectRoot 'config\gigamoney.config.json'
} elseif ([System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath
} else {
    Join-Path $script:ProjectRoot $ConfigPath
}
$script:Config = $null
$script:Adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$script:WorkDir = Join-Path $script:ProjectRoot 'work'
$script:PackageName = 'lb.whale.hkwinner.android'
$script:OcrEngine = $null
$script:AsTaskGeneric = $null
$script:PortfolioTabCenter = [pscustomobject]@{ X = 756; Y = 2332 }
$script:CashTileCenter = [pscustomobject]@{ X = 945; Y = 462 }

. (Join-Path $script:ScriptRoot 'Gigamoney-AppForeground.ps1')

New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null

function Write-Step([string]$Message) {
    [Console]::Error.WriteLine(("[{0:HH:mm:ss.fff}] {1}" -f (Get-Date), $Message))
}

function Get-GigamoneyConfig {
    if ($script:Config) {
        return $script:Config
    }

    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "Gigamoney config file was not found: $script:ConfigPath"
    }

    try {
        $script:Config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
    } catch {
        throw "Could not read Gigamoney config file: $script:ConfigPath. $($_.Exception.Message)"
    }

    return $script:Config
}

function Get-ConfiguredTradePassword {
    $config = Get-GigamoneyConfig
    $password = [string]$config.gigamoney.tradePassword
    if ([string]::IsNullOrWhiteSpace($password)) {
        throw "Trade password prompt appeared, but gigamoney.tradePassword is not set in config: $script:ConfigPath"
    }

    return $password
}

function Assert-Environment {
    if (-not (Test-Path -LiteralPath $script:Adb)) {
        throw "adb was not found at $script:Adb"
    }

    $devices = & $script:Adb devices
    if (($devices -join "`n") -notmatch "`tdevice") {
        throw 'No attached adb device/emulator is available.'
    }
}

function Initialize-Ocr {
    if ($script:OcrEngine) {
        return
    }

    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
    [Windows.Storage.FileAccessMode, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapPixelFormat, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapAlphaMode, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null

    $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.IsGenericMethod -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1)

    $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if (-not $script:OcrEngine) {
        throw 'Could not create a Windows OCR engine from the current user profile languages.'
    }
}

function Wait-WinRtOperation($Operation, [Type]$ResultType) {
    $task = $script:AsTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

function Save-AdbScreenshot([string]$Path) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:Adb
    $psi.Arguments = 'exec-out screencap -p'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $proc = [System.Diagnostics.Process]::Start($psi)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    try {
        $proc.StandardOutput.BaseStream.CopyTo($fs)
    } finally {
        $fs.Dispose()
    }

    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) {
        throw "adb screencap failed with exit code $($proc.ExitCode): $stderr"
    }
}

function Invoke-ImageOcr([string]$Path) {
    Initialize-Ocr

    $file = Wait-WinRtOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
    $stream = Wait-WinRtOperation ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    try {
        $decoder = Wait-WinRtOperation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Wait-WinRtOperation ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        if ($bitmap.BitmapPixelFormat -ne [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8 -or
            $bitmap.BitmapAlphaMode -ne [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied) {
            $bitmap = [Windows.Graphics.Imaging.SoftwareBitmap]::Convert(
                $bitmap,
                [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
                [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied
            )
        }

        $result = Wait-WinRtOperation ($script:OcrEngine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
        $words = foreach ($line in $result.Lines) {
            foreach ($word in $line.Words) {
                [pscustomobject]@{
                    Text   = [string]$word.Text
                    X      = [double]$word.BoundingRect.X
                    Y      = [double]$word.BoundingRect.Y
                    Width  = [double]$word.BoundingRect.Width
                    Height = [double]$word.BoundingRect.Height
                }
            }
        }

        return [pscustomobject]@{
            Text      = [string]$result.Text
            WordCount = @($words).Count
            Words     = @($words)
        }
    } finally {
        $stream.Dispose()
    }
}

function Get-EnlargedLeftColumnOcrWords([string]$ScreenshotPath) {
    Add-Type -AssemblyName System.Drawing

    $source = [System.Drawing.Bitmap]::new($ScreenshotPath)
    $cropPaths = [System.Collections.Generic.List[string]]::new()
    try {
        # The ticker symbols are rendered in faint gray. OCR them in overlapping,
        # enlarged strips so symbols near a strip edge are not lost.
        $cropX = 20
        $cropWidth = [Math]::Min(380, $source.Width - $cropX)
        $firstY = 280
        $lastY = [Math]::Max($firstY, $source.Height - 220)
        $chunkHeight = 650
        $chunkStep = 500
        $scale = 3.0
        $mappedWords = [System.Collections.Generic.List[object]]::new()

        for ($top = $firstY; $top -lt $lastY; $top += $chunkStep) {
            $height = [Math]::Min($chunkHeight, $lastY - $top)
            if ($height -le 0) {
                break
            }

            $cropPath = Join-Path $script:WorkDir ("gigamoney-holdings-left-{0}.png" -f ([guid]::NewGuid().ToString('N')))
            $cropPaths.Add($cropPath)
            $target = [System.Drawing.Bitmap]::new([int]($cropWidth * $scale), [int]($height * $scale))
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($target)
                try {
                    $graphics.Clear([System.Drawing.Color]::White)
                    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $graphics.DrawImage(
                        $source,
                        [System.Drawing.Rectangle]::new(0, 0, $target.Width, $target.Height),
                        [System.Drawing.Rectangle]::new($cropX, $top, $cropWidth, $height),
                        [System.Drawing.GraphicsUnit]::Pixel
                    )
                } finally {
                    $graphics.Dispose()
                }
                $target.Save($cropPath, [System.Drawing.Imaging.ImageFormat]::Png)
            } finally {
                $target.Dispose()
            }

            $cropOcr = Invoke-ImageOcr $cropPath
            foreach ($word in $cropOcr.Words) {
                $mappedWords.Add([pscustomobject]@{
                    Text   = [string]$word.Text
                    X      = $cropX + ([double]$word.X / $scale)
                    Y      = $top + ([double]$word.Y / $scale)
                    Width  = [double]$word.Width / $scale
                    Height = [double]$word.Height / $scale
                })
            }
        }

        # Overlapping strips deliberately produce duplicates. Keep one copy of
        # each word at approximately the same screen position.
        $deduplicated = [System.Collections.Generic.List[object]]::new()
        foreach ($word in @($mappedWords | Sort-Object Y, X)) {
            $duplicate = @($deduplicated | Where-Object {
                $_.Text -eq $word.Text -and
                [Math]::Abs($_.X - $word.X) -lt 8 -and
                [Math]::Abs($_.Y - $word.Y) -lt 8
            } | Select-Object -First 1)
            if (-not $duplicate) {
                $deduplicated.Add($word)
            }
        }

        return @($deduplicated)
    } finally {
        $source.Dispose()
        foreach ($cropPath in $cropPaths) {
            if (Test-Path -LiteralPath $cropPath) {
                Remove-Item -LiteralPath $cropPath -Force
            }
        }
    }
}

function Get-ScreenshotOcr {
    param([switch]$IncludeEnhancedLeftColumn)

    $png = Join-Path $script:WorkDir ("gigamoney-holdings-{0}.png" -f ([guid]::NewGuid().ToString('N')))
    try {
        Save-AdbScreenshot $png
        $fullOcr = Invoke-ImageOcr $png
        $leftWords = if ($IncludeEnhancedLeftColumn) {
            @(Get-EnlargedLeftColumnOcrWords $png)
        } else {
            @()
        }

        return [pscustomobject]@{
            Text      = $fullOcr.Text
            WordCount = $fullOcr.WordCount
            Words     = @($fullOcr.Words)
            LeftWords = @($leftWords)
        }
    } finally {
        if (Test-Path -LiteralPath $png) {
            Remove-Item -LiteralPath $png -Force
        }
    }
}

function Invoke-AdbInput([string[]]$Arguments) {
    & $script:Adb @Arguments | Out-Null
}

function Invoke-AdbShell([string]$Command) {
    & $script:Adb shell $Command | Out-Null
}

function Tap([int]$X, [int]$Y) {
    Invoke-AdbInput @('shell', 'input', 'tap', "$X", "$Y")
}

function Swipe([int]$X1, [int]$Y1, [int]$X2, [int]$Y2, [int]$DurationMs = 450) {
    Invoke-AdbInput @('shell', 'input', 'swipe', "$X1", "$Y1", "$X2", "$Y2", "$DurationMs")
}

function Press-Back {
    Invoke-AdbInput @('shell', 'input', 'keyevent', 'BACK')
}

function Get-ResourceId([string]$Name) {
    return "${script:PackageName}:id/$Name"
}

function Get-UiXml([int]$MaxAttempts = 2) {
    $lastOutput = ''
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        # Never reuse a previous screen's XML when UIAutomator cannot reach idle state.
        & $script:Adb shell rm -f /sdcard/window.xml 2>$null | Out-Null
        $savedErrorActionPreference = $ErrorActionPreference
        try {
            # UIAutomator writes its ordinary "could not get idle state" failure to stderr.
            # Capture it for retry diagnostics without promoting it to a terminating PowerShell error.
            $ErrorActionPreference = 'Continue'
            $dumpOutput = @(& $script:Adb shell uiautomator dump --compressed /sdcard/window.xml 2>&1)
            $dumpExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedErrorActionPreference
        }
        $lastOutput = ($dumpOutput -join "`n").Trim()

        if ($dumpExitCode -eq 0) {
            $raw = @(& $script:Adb exec-out cat /sdcard/window.xml 2>$null)
            $text = ($raw -join "`n").Trim()
            if ($text.StartsWith('<?xml')) {
                return [xml]$text
            }
            $lastOutput = "UIAutomator reported success, but no valid XML was produced. cat output: $text"
        }

        if ($attempt -lt $MaxAttempts) {
            Write-Step "UI dump attempt $attempt failed; retrying once."
            Start-Sleep -Milliseconds 200
        }
    }

    throw "Could not capture a current UIAutomator XML dump after $MaxAttempts attempts. Last output: $lastOutput"
}

function Get-NodeAttribute($Node, [string]$Name) {
    return $Node.GetAttribute($Name)
}

function Convert-BoundsToRect([string]$Bounds) {
    if ($Bounds -notmatch '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$') {
        throw "Unrecognized bounds format: $Bounds"
    }

    $left = [int]$Matches[1]
    $top = [int]$Matches[2]
    $right = [int]$Matches[3]
    $bottom = [int]$Matches[4]

    return [pscustomobject]@{
        Left    = $left
        Top     = $top
        Right   = $right
        Bottom  = $bottom
        CenterX = [int](($left + $right) / 2)
        CenterY = [int](($top + $bottom) / 2)
    }
}

function Tap-Node($Node) {
    $rect = Convert-BoundsToRect (Get-NodeAttribute $Node 'bounds')
    Tap $rect.CenterX $rect.CenterY
}

function Find-UiNodeByResourceId([xml]$Xml, [string]$ResourceId) {
    return $Xml.SelectSingleNode("//node[@resource-id='$ResourceId']")
}

function Find-UiNodeByText(
    [xml]$Xml,
    [string]$Text,
    [switch]$Exact,
    [switch]$PreferBottom,
    [scriptblock]$Where
) {
    $needle = $Text.ToUpperInvariant()
    $nodes = @($Xml.SelectNodes('//node') | Where-Object {
        $value = (Get-NodeAttribute $_ 'text')
        if (-not $value) {
            return $false
        }

        $candidate = $value.ToUpperInvariant()
        $matchesText = if ($Exact) { $candidate -eq $needle } else { $candidate -like "*$needle*" }
        if (-not $matchesText) {
            return $false
        }

        if ($Where) {
            return (& $Where $_)
        }
        return $true
    })

    if (-not $nodes) {
        return $null
    }

    if ($PreferBottom) {
        return $nodes | Sort-Object { (Convert-BoundsToRect (Get-NodeAttribute $_ 'bounds')).Top } -Descending | Select-Object -First 1
    }

    return $nodes | Sort-Object { (Convert-BoundsToRect (Get-NodeAttribute $_ 'bounds')).Top } | Select-Object -First 1
}

function Wait-ForUiNode([scriptblock]$FindNode, [int]$TimeoutMs = 6000, [int]$PollMs = 250) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    do {
        $xml = Get-UiXml
        $node = & $FindNode $xml
        if ($node) {
            return [pscustomobject]@{
                Xml  = $xml
                Node = $node
            }
        }
        Start-Sleep -Milliseconds $PollMs
    } while ([DateTime]::UtcNow -lt $deadline)

    return $null
}

function Get-TradePasswordPromptMarker([xml]$Xml) {
    $passwordInput = Find-UiNodeByResourceId $Xml (Get-ResourceId 'et_pwd')
    if ($passwordInput) {
        return $passwordInput
    }

    return Find-UiNodeByText $Xml 'Enter Trade Password' -Exact
}

function Enter-ConfiguredTradePassword {
    Write-Step 'Trade password prompt detected; entering configured password.'
    $password = Get-ConfiguredTradePassword
    Invoke-AdbInput @('shell', 'input', 'text', (ConvertTo-AdbInputText $password))
}

function Wait-ForUiNodeOrTradePassword(
    [scriptblock]$FindNode,
    [string]$DestinationName,
    [int]$TimeoutMs = 8000,
    [int]$PollMs = 250
) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    do {
        $xml = Get-UiXml
        $node = & $FindNode $xml
        if ($node) {
            return [pscustomobject]@{
                Xml             = $xml
                Node            = $node
                PasswordHandled = $false
            }
        }

        $passwordPrompt = Get-TradePasswordPromptMarker $xml
        if ($passwordPrompt) {
            Enter-ConfiguredTradePassword
            $afterPassword = Wait-ForUiNode $FindNode -TimeoutMs $TimeoutMs -PollMs $PollMs
            if (-not $afterPassword) {
                throw "$DestinationName did not appear after entering the trade password."
            }

            return [pscustomobject]@{
                Xml             = $afterPassword.Xml
                Node            = $afterPassword.Node
                PasswordHandled = $true
            }
        }

        Start-Sleep -Milliseconds $PollMs
    } while ([DateTime]::UtcNow -lt $deadline)

    return $null
}

function Get-ChildTextByResourceName($Node, [string]$Name) {
    $resourceId = Get-ResourceId $Name
    $child = $Node.SelectSingleNode(".//node[@resource-id='$resourceId']")
    if (-not $child) {
        return ''
    }

    return Get-NodeAttribute $child 'text'
}

function Get-TextByResourceName([xml]$Xml, [string]$Name) {
    $node = Find-UiNodeByResourceId $Xml (Get-ResourceId $Name)
    if (-not $node) {
        return ''
    }

    return Get-NodeAttribute $node 'text'
}

function ConvertTo-AdbInputText([string]$Text) {
    return ($Text -replace '\\', '\\\\' -replace ' ', '%s' -replace '&', '\&' -replace '<', '\<' -replace '>', '\>' -replace '\(', '\(' -replace '\)', '\)')
}

function Test-HomeOcrText([string]$Text) {
    return (
        $Text -match '\bWatchlist\b' -and
        $Text -match '\bMarket\b' -and
        $Text -match '\bFeed\b' -and
        $Text -match '\bPortfolio\b'
    )
}

function Ensure-Home {
    Ensure-GigamoneyAppForeground -AdbPath $script:Adb -PackageName $script:PackageName
    Dismiss-GigamoneyAdScreenIfPresent -AdbPath $script:Adb -WorkDir $script:WorkDir | Out-Null

    for ($attempt = 0; $attempt -le $MaxHomeBacks; $attempt++) {
        $ocr = Get-ScreenshotOcr
        if (Test-HomeOcrText $ocr.Text) {
            Write-Step 'Landing page detected by OCR.'
            return
        }

        if ($attempt -eq $MaxHomeBacks) {
            throw "Landing page was not detected after $MaxHomeBacks back presses. Last OCR text: $($ocr.Text)"
        }

        Write-Step "Landing page not detected; pressing Back ($($attempt + 1)/$MaxHomeBacks)."
        Press-Back
        Start-Sleep -Milliseconds 850
    }
}

function Test-PortfolioPage([xml]$Xml) {
    return [bool](Get-PortfolioPageMarker $Xml)
}

function Get-PortfolioPageMarker([xml]$Xml) {
    $markerNames = @('viewpager_fund', 'recycle_view_fund_dist', 'card_portfolio_view', 'wealth_stock_hold_item_view')
    foreach ($name in $markerNames) {
        $node = Find-UiNodeByResourceId $Xml (Get-ResourceId $name)
        if ($node) {
            return $node
        }
    }

    return $null
}

function Find-CashButtonByOcr($Ocr) {
    $candidates = @($Ocr.Words | Where-Object {
        $centerX = [double]$_.X + ([double]$_.Width / 2)
        $centerY = [double]$_.Y + ([double]$_.Height / 2)
        return (
            (($_.Text -replace '[^A-Za-z]', '').ToUpperInvariant() -eq 'CASH') -and
            $centerX -ge 650 -and
            $centerY -ge 250 -and
            $centerY -le 900
        )
    })
    if (-not $candidates) {
        return $null
    }

    # Prefer the Cash > control near its recorded top-card position. The bounds above
    # deliberately exclude the lower "Opt in Cash Plus >" row and the Cash Plus page title.
    $target = $candidates | Sort-Object {
        $centerX = [double]$_.X + ([double]$_.Width / 2)
        $centerY = [double]$_.Y + ([double]$_.Height / 2)
        [math]::Pow($centerX - $script:CashTileCenter.X, 2) + [math]::Pow($centerY - $script:CashTileCenter.Y, 2)
    } | Select-Object -First 1

    return [pscustomobject]@{
        Text    = $target.Text
        CenterX = [int]([double]$target.X + ([double]$target.Width / 2))
        CenterY = [int]([double]$target.Y + ([double]$target.Height / 2))
    }
}

function Ensure-PortfolioTop {
    for ($attempt = 0; $attempt -le $MaxPortfolioScrolls; $attempt++) {
        $ocr = Get-ScreenshotOcr

        if (($ocr.Text -replace '\s+', ' ') -match '(?i)\bEnter\s+Trade\s+Password\b') {
            Enter-ConfiguredTradePassword
            Start-Sleep -Milliseconds 3000
            continue
        }

        $cashButton = Find-CashButtonByOcr $ocr
        if ($cashButton) {
            Write-Step 'Portfolio top Cash > button matched by OCR.'
            return $cashButton
        }

        if ($attempt -eq $MaxPortfolioScrolls) {
            throw 'Portfolio top did not become visible.'
        }

        if ($attempt -eq 0) {
            Write-Step 'Portfolio top not visible; seeking top without over-pulling.'
        }

        Swipe 540 1120 540 1560 280
        Start-Sleep -Milliseconds 350
    }
}

function Open-Portfolio {
    Dismiss-GigamoneyAdScreenIfPresent -AdbPath $script:Adb -WorkDir $script:WorkDir | Out-Null
    Write-Step 'Opening Portfolio.'
    Tap $script:PortfolioTabCenter.X $script:PortfolioTabCenter.Y
    Start-Sleep -Milliseconds 700
    return Ensure-PortfolioTop
}

function Get-PortfolioOverview([xml]$Xml) {
    $summaryInt = Get-TextByResourceName $Xml 'tv_summary_value_int'
    $summaryFloat = Get-TextByResourceName $Xml 'tv_summary_value_float'
    $totalAssets = if ($summaryInt -or $summaryFloat) { "$summaryInt$summaryFloat" } else { Get-TextByResourceName $Xml 'tv_summary_value' }

    return [ordered]@{
        accountName        = Get-TextByResourceName $Xml 'tv_wealth_account'
        accountType        = Get-TextByResourceName $Xml 'tv_account_name'
        currency           = Get-TextByResourceName $Xml 'tv_currency'
        totalAssets        = $totalAssets
        dailyPL            = Get-TextByResourceName $Xml 'tv_today_income_value'
        totalPositionValue = Get-TextByResourceName $Xml 'tv_hold_value'
        positionPL         = Get-TextByResourceName $Xml 'tv_hold_profit_value'
        cash               = Get-TextByResourceName $Xml 'tv_cash_value'
    }
}

function Get-MarketForPositionRow([xml]$Xml, $Row) {
    $rowTop = (Convert-BoundsToRect (Get-NodeAttribute $Row 'bounds')).Top
    $headers = @($Xml.SelectNodes("//node[@resource-id='$(Get-ResourceId 'wealth_stock_hold_header')']") | Where-Object {
        (Convert-BoundsToRect (Get-NodeAttribute $_ 'bounds')).Top -le $rowTop
    })
    if (-not $headers) {
        return ''
    }

    $header = $headers | Sort-Object { (Convert-BoundsToRect (Get-NodeAttribute $_ 'bounds')).Top } -Descending | Select-Object -First 1
    return Get-ChildTextByResourceName $header 'tv_market_title'
}

function Get-VisibleMarketSummaries([xml]$Xml) {
    $summaries = foreach ($header in @($Xml.SelectNodes("//node[@resource-id='$(Get-ResourceId 'wealth_stock_hold_header')']"))) {
        $market = Get-ChildTextByResourceName $header 'tv_market_title'
        if (-not $market) {
            continue
        }

        [pscustomobject][ordered]@{
            market              = $market
            totalValue          = Get-ChildTextByResourceName $header 'tv_total_value'
            marketValue         = Get-ChildTextByResourceName $header 'tv_hold_price_value'
            positionPL          = Get-ChildTextByResourceName $header 'tv_income_value'
            dailyPL             = Get-ChildTextByResourceName $header 'tv_today_income_value'
        }
    }

    return @($summaries)
}

function Get-VisiblePositions([xml]$Xml, [string]$DefaultMarket = '') {
    $positions = foreach ($row in @($Xml.SelectNodes("//node[@resource-id='$(Get-ResourceId 'wealth_stock_hold_item_view')']"))) {
        $code = Get-ChildTextByResourceName $row 'tv_stock_code'
        $name = Get-ChildTextByResourceName $row 'tv_stock_name'
        if (-not ($code -or $name)) {
            continue
        }

        $market = Get-MarketForPositionRow $Xml $row
        if (-not $market) {
            $market = $DefaultMarket
        }

        [pscustomobject][ordered]@{
            market         = $market
            symbol         = $code
            name           = $name
            marketValue    = Get-ChildTextByResourceName $row 'tv_column_00'
            quantity       = Get-ChildTextByResourceName $row 'tv_column_01'
            marketPrice    = Get-ChildTextByResourceName $row 'tv_column_10'
            cost           = Get-ChildTextByResourceName $row 'tv_column_11'
            dailyPL        = Get-ChildTextByResourceName $row 'tv_column_20'
            dailyPLPercent = Get-ChildTextByResourceName $row 'tv_column_21'
        }
    }

    return @($positions)
}

function Add-PositionIfNew([System.Collections.Specialized.OrderedDictionary]$PositionsBySymbol, $Position) {
    $key = if ($Position.market) { "$($Position.market):$($Position.symbol)" } else { $Position.symbol }
    if ([string]::IsNullOrWhiteSpace($key)) {
        return
    }

    if (-not $PositionsBySymbol.Contains($key)) {
        $PositionsBySymbol.Add($key, $Position)
        return
    }

    $existing = $PositionsBySymbol[$key]
    foreach ($name in @('market', 'name', 'marketValue', 'quantity', 'marketPrice', 'cost', 'dailyPL', 'dailyPLPercent')) {
        if (-not $existing.$name -and $Position.$name) {
            $existing.$name = $Position.$name
        }
    }
}

function Add-MarketSummaryIfNew([System.Collections.Specialized.OrderedDictionary]$SummariesByMarket, $Summary) {
    if ([string]::IsNullOrWhiteSpace($Summary.market)) {
        return
    }

    if (-not $SummariesByMarket.Contains($Summary.market)) {
        $SummariesByMarket.Add($Summary.market, $Summary)
        return
    }

    $existing = $SummariesByMarket[$Summary.market]
    foreach ($name in @('totalValue', 'marketValue', 'positionPL', 'dailyPL')) {
        if (-not $existing.$name -and $Summary.$name) {
            $existing.$name = $Summary.$name
        }
    }
}

function Get-VisibleFunds([xml]$Xml) {
    $funds = foreach ($row in @($Xml.SelectNodes("//node[@resource-id='$(Get-ResourceId 'wealth_ut_item_view')']"))) {
        $title = Get-ChildTextByResourceName $row 'wealth_tv_ut_title'
        $totalValue = Get-ChildTextByResourceName $row 'wealth_tv_ut_total_value'
        if (-not ($title -or $totalValue)) {
            continue
        }

        [pscustomobject][ordered]@{
            name       = $title
            totalValue = $totalValue
            action     = Get-ChildTextByResourceName $row 'tv_collapse_mmf'
        }
    }

    return @($funds)
}

function Test-PortfolioBottom([xml]$Xml) {
    return [bool](
        (Find-UiNodeByResourceId $Xml (Get-ResourceId 'wealth_ut_item_view')) -or
        (Find-UiNodeByResourceId $Xml (Get-ResourceId 'tv_collapse_mmf')) -or
        (Find-UiNodeByResourceId $Xml (Get-ResourceId 'wealth_tv_ut_title'))
    )
}

function Add-FundIfNew([System.Collections.Specialized.OrderedDictionary]$FundsByName, $Fund) {
    if ([string]::IsNullOrWhiteSpace($Fund.name)) {
        return
    }

    if (-not $FundsByName.Contains($Fund.name)) {
        $FundsByName.Add($Fund.name, $Fund)
    }
}

function Get-TextSignature([xml]$Xml) {
    return (@($Xml.SelectNodes('//node') | ForEach-Object { Get-NodeAttribute $_ 'text' } | Where-Object { $_ }) -join '|')
}

function Get-OcrWordCenterX($Word) {
    return [double]$Word.X + ([double]$Word.Width / 2.0)
}

function Get-OcrWordCenterY($Word) {
    return [double]$Word.Y + ([double]$Word.Height / 2.0)
}

function Test-OcrNumericText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text -notmatch '\d') {
        return $false
    }
    return ($Text -notmatch '[A-Za-z]')
}

function Find-OcrColumnWord {
    param(
        [object[]]$Words,
        [double]$TargetY,
        [double]$MinCenterX,
        [double]$MaxCenterX,
        [double]$ToleranceY = 36,
        [switch]$RequirePercent
    )

    return @($Words | Where-Object {
        $centerX = Get-OcrWordCenterX $_
        $centerY = Get-OcrWordCenterY $_
        $numeric = Test-OcrNumericText ([string]$_.Text)
        $percentMatches = -not $RequirePercent -or ([string]$_.Text).Contains('%')
        $numeric -and $percentMatches -and
        $centerX -ge $MinCenterX -and $centerX -le $MaxCenterX -and
        [Math]::Abs($centerY - $TargetY) -le $ToleranceY
    } | Sort-Object @{ Expression = { [Math]::Abs((Get-OcrWordCenterY $_) - $TargetY) } },
                    @{ Expression = { [Math]::Abs((Get-OcrWordCenterX $_) - (($MinCenterX + $MaxCenterX) / 2.0)) } } |
        Select-Object -First 1)
}

function Get-VisiblePositionsByOcr($Ocr) {
    $excludedSymbols = @(
        'ACCOUNT', 'BUY', 'CASH', 'COST', 'DAILY', 'FUND', 'HK', 'MP', 'MV',
        'NAME', 'ORDERS', 'PORTFOLIO', 'PL', 'QTY', 'SELL', 'TRADE', 'US'
    )
    $candidateRows = [System.Collections.Generic.List[object]]::new()

    foreach ($word in @($Ocr.LeftWords | Sort-Object Y, X)) {
        $symbol = ([string]$word.Text).Trim().ToUpperInvariant()
        if ($symbol -notmatch '^(?:[A-Z][A-Z0-9.\-]{0,11}|[0-9]{4,6})$' -or $symbol -in $excludedSymbols) {
            continue
        }

        $tickerY = Get-OcrWordCenterY $word
        $percent = Find-OcrColumnWord -Words $Ocr.Words -TargetY $tickerY -MinCenterX 840 -MaxCenterX 1075 -RequirePercent
        if (-not $percent) {
            # Company names and navigation labels may also be uppercase. The
            # percentage in the right column uniquely identifies the ticker row.
            continue
        }

        $existing = @($candidateRows | Where-Object {
            $_.Symbol -eq $symbol -and [Math]::Abs($_.TickerY - $tickerY) -lt 12
        } | Select-Object -First 1)
        if (-not $existing) {
            $candidateRows.Add([pscustomobject]@{
                Symbol  = $symbol
                TickerY = $tickerY
                Percent = $percent
            })
        }
    }

    $positions = foreach ($row in $candidateRows) {
        $upperY = $row.TickerY - 50
        $marketValue = Find-OcrColumnWord -Words $Ocr.Words -TargetY $upperY -MinCenterX 390 -MaxCenterX 625
        $quantity = Find-OcrColumnWord -Words $Ocr.Words -TargetY $row.TickerY -MinCenterX 390 -MaxCenterX 625
        $marketPrice = Find-OcrColumnWord -Words $Ocr.Words -TargetY $upperY -MinCenterX 640 -MaxCenterX 840
        $cost = Find-OcrColumnWord -Words $Ocr.Words -TargetY $row.TickerY -MinCenterX 640 -MaxCenterX 840
        $dailyPL = Find-OcrColumnWord -Words $Ocr.Words -TargetY $upperY -MinCenterX 840 -MaxCenterX 1075

        if (-not $quantity -or -not $cost) {
            Write-Step "Ignoring partially visible OCR row for $($row.Symbol)."
            continue
        }

        [pscustomobject][ordered]@{
            market         = ''
            symbol         = $row.Symbol
            name           = ''
            marketValue    = if ($marketValue) { [string]$marketValue.Text } else { '' }
            quantity       = [string]$quantity.Text
            marketPrice    = if ($marketPrice) { [string]$marketPrice.Text } else { '' }
            cost           = [string]$cost.Text
            dailyPL        = if ($dailyPL) { [string]$dailyPL.Text } else { '' }
            dailyPLPercent = [string]$row.Percent.Text
            ocrRowY        = [double]$row.TickerY
        }
    }

    return @($positions)
}

function Test-PortfolioBottomByOcr($Ocr) {
    return [bool]($Ocr.Text -match '(?i)\bFund\b|Opt\s+in\s+Cash\s+Plus|Cash\s+Plus')
}

function Collect-PortfolioData {
    $positionsBySymbol = [System.Collections.Specialized.OrderedDictionary]::new()
    $lastSignature = ''
    $reachedBottom = $false

    for ($scroll = 0; $scroll -le $MaxPortfolioScrolls; $scroll++) {
        $ocr = Get-ScreenshotOcr -IncludeEnhancedLeftColumn
        $visiblePositions = @(Get-VisiblePositionsByOcr $ocr)
        foreach ($position in $visiblePositions) {
            Add-PositionIfNew $positionsBySymbol $position
        }

        if (Test-PortfolioBottomByOcr $ocr) {
            Write-Step 'Reached bottom of Portfolio positions.'
            $reachedBottom = $true
            break
        }

        # Ignore live prices when deciding whether scrolling moved. Only stable
        # ticker names and their vertical locations participate in the signature.
        $signature = (@($visiblePositions | ForEach-Object {
            "{0}:{1}" -f $_.symbol, [Math]::Round($_.ocrRowY / 20.0)
        }) -join '|')
        if ($scroll -gt 0 -and $signature -eq $lastSignature) {
            Write-Step 'Reached bottom of Portfolio positions.'
            $reachedBottom = $true
            break
        }

        $lastSignature = $signature
        if ($scroll -eq $MaxPortfolioScrolls) {
            break
        }

        Swipe 540 2070 540 760 180
        Start-Sleep -Milliseconds 350
    }

    if (-not $reachedBottom) {
        throw "Portfolio bottom was not reached after $MaxPortfolioScrolls scrolls; refusing to publish partial holdings."
    }

    return [pscustomobject][ordered]@{
        positions = @($positionsBySymbol.Values | ForEach-Object {
            $_.PSObject.Properties.Remove('ocrRowY')
            $_
        })
    }
}

function Open-CashPage($CashButtonMatch) {
    Write-Step 'Opening Cash page.'
    if ($CashButtonMatch) {
        Tap $CashButtonMatch.CenterX $CashButtonMatch.CenterY
    } else {
        Tap $script:CashTileCenter.X $script:CashTileCenter.Y
    }

    $result = Wait-ForUiNodeOrTradePassword {
        param($Xml)
        return Get-CashPageMarker $Xml
    } 'Cash page' -TimeoutMs 8000
    if (-not $result) {
        throw 'Cash page did not open.'
    }

    return $result.Xml
}

function Get-CashPageMarker([xml]$Xml) {
    $title = Find-UiNodeByResourceId $Xml (Get-ResourceId 'title_bar_title')
    if ($title -and (Get-NodeAttribute $title 'text') -eq 'Cash') {
        return $title
    }

    return Find-UiNodeByResourceId $Xml (Get-ResourceId 'group_cash')
}

function Return-ToPortfolioFromCash {
    param([switch]$SkipVerification)

    Write-Step 'Returning to Portfolio.'
    Press-Back
    if ($SkipVerification) {
        Start-Sleep -Milliseconds 450
        return $null
    }

    Start-Sleep -Milliseconds 500
    $xml = Get-UiXml
    if (Test-PortfolioPage $xml) {
        return $xml
    }

    $result = Wait-ForUiNode {
        param($Xml)
        return Get-PortfolioPageMarker $Xml
    } -TimeoutMs 8000
    if (-not $result) {
        throw 'Portfolio page did not reappear after closing Cash.'
    }

    return $result.Xml
}

function Get-CashBalances([xml]$Xml) {
    $balances = foreach ($row in @($Xml.SelectNodes("//node[@resource-id='$(Get-ResourceId 'rootContainer')']"))) {
        $currency = Get-ChildTextByResourceName $row 'tv_currency'
        $balance = Get-ChildTextByResourceName $row 'tv_balance'
        if (-not ($currency -or $balance)) {
            continue
        }

        [pscustomobject][ordered]@{
            currency = $currency
            balance  = $balance
        }
    }

    return @($balances)
}

function Get-CashData([xml]$Xml) {
    return [pscustomobject][ordered]@{
        totalUsd         = Get-TextByResourceName $Xml 'tv_summary_value'
        withdrawableCash = Get-TextByResourceName $Xml 'tv_withdraw_cash_value'
        incomingFunds    = Get-TextByResourceName $Xml 'tv_cash_in_arrive_value'
        blocked          = Get-TextByResourceName $Xml 'frozenTag'
        outstanding      = Get-TextByResourceName $Xml 'settleTag'
        balances         = Get-CashBalances $Xml
    }
}

Assert-Environment
Write-Step 'Starting Gigamoney holdings query.'
Ensure-Home
$cashButtonMatch = Open-Portfolio
$cashXml = Open-CashPage $cashButtonMatch
$cash = Get-CashData $cashXml
Return-ToPortfolioFromCash -SkipVerification | Out-Null
$portfolio = Collect-PortfolioData

$result = [pscustomobject][ordered]@{
    queriedAt = (Get-Date).ToString('o')
    cash      = $cash
    positions = @($portfolio.positions)
}

$result | ConvertTo-Json -Depth 10
