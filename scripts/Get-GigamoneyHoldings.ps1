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

function Get-ScreenshotOcr {
    Initialize-Ocr

    $png = Join-Path $script:WorkDir ("gigamoney-holdings-{0}.png" -f ([guid]::NewGuid().ToString('N')))
    try {
        Save-AdbScreenshot $png

        $file = Wait-WinRtOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($png)) ([Windows.Storage.StorageFile])
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
            return [pscustomobject]@{
                Text      = $result.Text
                WordCount = @($result.Lines | ForEach-Object { $_.Words }).Count
            }
        } finally {
            $stream.Dispose()
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

function Get-UiXml {
    Invoke-AdbInput @('shell', 'uiautomator', 'dump', '/sdcard/window.xml')
    $raw = & $script:Adb exec-out cat /sdcard/window.xml
    $text = ($raw -join "`n").Trim()
    if (-not $text.StartsWith('<?xml')) {
        throw "Could not read a valid UIAutomator XML dump. Output was: $text"
    }
    return [xml]$text
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
    Write-Step 'Trade password prompt detected by UI dump; entering configured password.'
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

function Test-PortfolioTop([xml]$Xml) {
    return [bool](
        (Find-UiNodeByResourceId $Xml (Get-ResourceId 'card_portfolio_view')) -and
        (
            (Find-UiNodeByResourceId $Xml (Get-ResourceId 'tv_cash')) -or
            (Find-UiNodeByResourceId $Xml (Get-ResourceId 'tv_cash_value')) -or
            (Find-UiNodeByResourceId $Xml (Get-ResourceId 'll_cash'))
        )
    )
}

function Ensure-PortfolioTop([xml]$InitialXml = $null) {
    for ($attempt = 0; $attempt -le $MaxPortfolioScrolls; $attempt++) {
        $xml = if ($attempt -eq 0 -and $InitialXml) { $InitialXml } else { Get-UiXml }
        if (Test-PortfolioTop $xml) {
            Write-Step 'Portfolio top is visible.'
            return $xml
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
    Write-Step 'Opening Portfolio.'
    Tap $script:PortfolioTabCenter.X $script:PortfolioTabCenter.Y

    $result = Wait-ForUiNodeOrTradePassword {
        param($Xml)
        return Get-PortfolioPageMarker $Xml
    } 'Portfolio page' -TimeoutMs 8000
    if (-not $result) {
        throw 'Portfolio page did not open.'
    }

    return Ensure-PortfolioTop $result.Xml
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
    if (-not $existing.market -and $Position.market) {
        $existing.market = $Position.market
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

function Collect-PortfolioData([xml]$InitialXml) {
    $overview = Get-PortfolioOverview $InitialXml
    $positionsBySymbol = [System.Collections.Specialized.OrderedDictionary]::new()
    $summariesByMarket = [System.Collections.Specialized.OrderedDictionary]::new()
    $fundsByName = [System.Collections.Specialized.OrderedDictionary]::new()
    $lastSignature = ''
    $lastMarket = ''
    $bottomOcr = $null

    for ($scroll = 0; $scroll -le $MaxPortfolioScrolls; $scroll++) {
        $xml = if ($scroll -eq 0 -and $InitialXml) { $InitialXml } else { Get-UiXml }
        $visibleSummaries = Get-VisibleMarketSummaries $xml
        foreach ($summary in $visibleSummaries) {
            Add-MarketSummaryIfNew $summariesByMarket $summary
        }
        foreach ($position in Get-VisiblePositions $xml $lastMarket) {
            Add-PositionIfNew $positionsBySymbol $position
        }
        foreach ($fund in Get-VisibleFunds $xml) {
            Add-FundIfNew $fundsByName $fund
        }
        $markets = @($visibleSummaries | Where-Object { $_.market } | Select-Object -ExpandProperty market)
        if ($markets) {
            $lastMarket = $markets[-1]
        }

        if (Test-PortfolioBottom $xml) {
            Write-Step 'Reached bottom of Portfolio positions.'
            $bottomOcr = Get-ScreenshotOcr
            break
        }

        $signature = Get-TextSignature $xml
        if ($scroll -gt 0 -and $signature -eq $lastSignature) {
            Write-Step 'Reached bottom of Portfolio positions.'
            $bottomOcr = Get-ScreenshotOcr
            break
        }

        $lastSignature = $signature
        Swipe 540 2070 540 760 180
        Start-Sleep -Milliseconds 150
    }

    if (-not $bottomOcr) {
        $bottomOcr = Get-ScreenshotOcr
    }

    return [pscustomobject][ordered]@{
        overview                    = $overview
        marketSummaries             = @($summariesByMarket.Values)
        positions                   = @($positionsBySymbol.Values)
        funds                       = @($fundsByName.Values)
        bottomPositionsOcrWordCount = $bottomOcr.WordCount
    }
}

function Open-CashPage([xml]$PortfolioTopXml = $null) {
    $xml = if ($PortfolioTopXml) { $PortfolioTopXml } else { Get-UiXml }
    $cashNode = Find-UiNodeByResourceId $xml (Get-ResourceId 'tv_cash')
    if (-not $cashNode) {
        $cashNode = Find-UiNodeByResourceId $xml (Get-ResourceId 'tv_cash_value')
    }
    if (-not $cashNode) {
        $cashNode = Find-UiNodeByResourceId $xml (Get-ResourceId 'll_cash')
    }

    Write-Step 'Opening Cash page.'
    if ($cashNode) {
        Tap-Node $cashNode
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
$portfolioXml = Open-Portfolio
$cashXml = Open-CashPage $portfolioXml
$cash = Get-CashData $cashXml
Return-ToPortfolioFromCash -SkipVerification | Out-Null
$portfolio = Collect-PortfolioData $portfolioXml

$result = [pscustomobject][ordered]@{
    queriedAt = (Get-Date).ToString('o')
    portfolio = $portfolio
    cash      = $cash
}

$result | ConvertTo-Json -Depth 10
