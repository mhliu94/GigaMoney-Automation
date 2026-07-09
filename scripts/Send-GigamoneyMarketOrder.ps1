param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9\.\-]+$')]
    [string]$Symbol,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]+(\.[0-9]+)?$')]
    [string]$Quantity,

    [ValidateSet('Buy', 'Sell')]
    [string]$Side = 'Buy',

    [string]$ConfigPath = '',

    [int]$MaxHomeBacks = 3,
    [int]$MaxWatchlistScrolls = 8,

    # Navigates to the ticket and verifies the fields, but does not enter values or submit.
    [switch]$DryRun,

    # Enters Quantity, then stops before pressing Submit.
    [switch]$NoSubmit
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
$script:FieldClearKeyEvents = (@('KEYCODE_MOVE_END') + (1..10 | ForEach-Object { 'KEYCODE_DEL' })) -join ' '
$script:DetailOpenDelayMs = 1000
$script:TicketOpenDelayMs = 1500
$script:SideButtonCenter = @{
    Buy  = [pscustomobject]@{ X = 724; Y = 2282 }
    Sell = [pscustomobject]@{ X = 940; Y = 2282 }
}
$script:LimitOrderTypeControlBounds = [pscustomobject]@{
    Left = 42; Top = 1710; Right = 1048; Bottom = 1763; CenterX = 545; CenterY = 1736
}
$script:MarketOrderTypeOptionBounds = [pscustomobject]@{
    Left = 53; Top = 1284; Right = 1027; Bottom = 1498; CenterX = 540; CenterY = 1391
}
$script:MarketQtyInputBounds = [pscustomobject]@{
    Left = 336; Top = 1981; Right = 860; Bottom = 2049; CenterX = 598; CenterY = 2015
}
$script:KeyboardSubmitButtonBounds = [pscustomobject]@{
    Left = 563; Top = 1493; Right = 904; Bottom = 1588; CenterX = 734; CenterY = 1540
}

New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null

function Write-Step([string]$Message) {
    Write-Host ("[{0:HH:mm:ss.fff}] {1}" -f (Get-Date), $Message)
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

function Test-OrderActionIdsPresent([xml]$Xml, [string[]]$ActionNames) {
    foreach ($actionName in $ActionNames) {
        $resourceId = Get-ResourceId $actionName
        $node = Find-UiNodeByResourceId $xml $resourceId
        if (-not $node) {
            return $false
        }
    }

    return $true
}

function Get-OrderResultByUiDump {
    $xml = Get-UiXml
    $statusNode = Find-UiNodeByResourceId $xml (Get-ResourceId 'tv_status')
    $statusText = if ($statusNode) { Get-NodeAttribute $statusNode 'text' } else { '' }
    if ($statusText -eq 'Canceled') {
        return $null
    }

    if (Test-OrderActionIdsPresent $xml @('tvModify', 'tvCancel', 'tvDuplicate', 'tvDetail')) {
        return 'Confirmed'
    }

    if ((Find-UiNodeByResourceId $xml (Get-ResourceId 'tv_execution_price')) -and
        (Find-UiNodeByResourceId $xml (Get-ResourceId 'tv_done_num'))) {
        return 'ExecutionReported'
    }

    return $null
}

function Get-ScreenshotOcr {
    Initialize-Ocr

    $png = Join-Path $script:WorkDir ("gigamoney-order-flow-{0}.png" -f ([guid]::NewGuid().ToString('N')))
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
            $words = foreach ($line in $result.Lines) {
                foreach ($word in $line.Words) {
                    [pscustomobject]@{
                        Text   = $word.Text
                        X      = [double]$word.BoundingRect.X
                        Y      = [double]$word.BoundingRect.Y
                        Width  = [double]$word.BoundingRect.Width
                        Height = [double]$word.BoundingRect.Height
                    }
                }
            }

            return [pscustomobject]@{
                Text  = $result.Text
                Words = @($words)
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

function Test-HomeOcrText([string]$Text) {
    return (
        $Text -match '\bWatchlist\b' -and
        $Text -match '\bMarket\b' -and
        $Text -match '\bFeed\b' -and
        $Text -match '\bPortfolio\b'
    )
}

function Test-TradePasswordOcrText([string]$Text) {
    return (($Text -replace '\s+', ' ') -match '(?i)\bEnter\s+Trade\s+Password\b')
}

function Handle-TradePasswordIfPresent {
    Start-Sleep -Milliseconds 300
    $ocr = Get-ScreenshotOcr
    if (-not (Test-TradePasswordOcrText $ocr.Text)) {
        return $false
    }

    Write-Step 'Trade password prompt detected; entering configured password.'
    $password = Get-ConfiguredTradePassword
    Invoke-AdbInput @('shell', 'input', 'text', (ConvertTo-AdbInputText $password))
    Start-Sleep -Milliseconds 3000
    return $true
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

function Restart-GigamoneyApp {
    Write-Step 'Closing and reopening Gigamoney.'
    Invoke-AdbInput @('shell', 'am', 'force-stop', $script:PackageName)
    Start-Sleep -Milliseconds 1000
    Invoke-AdbInput @('shell', 'monkey', '-p', $script:PackageName, '-c', 'android.intent.category.LAUNCHER', '1')
    Start-Sleep -Milliseconds 3500
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

function Find-UiNodeByResourceId([xml]$Xml, [string]$ResourceId) {
    return $Xml.SelectSingleNode("//node[@resource-id='$ResourceId']")
}

function Get-ResourceId([string]$Name) {
    return "${script:PackageName}:id/$Name"
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

function Ensure-Home {
    for ($attempt = 0; $attempt -le $MaxHomeBacks; $attempt++) {
        $ocr = Get-ScreenshotOcr
        if (Test-HomeOcrText $ocr.Text) {
            Write-Step "Home screen detected by OCR."
            return $ocr
        }

        if ($attempt -eq $MaxHomeBacks) {
            throw "Home screen was not detected after $MaxHomeBacks back presses. Last OCR text: $($ocr.Text)"
        }

        Write-Step "Home screen not detected; pressing Back ($($attempt + 1)/$MaxHomeBacks)."
        Press-Back
        Start-Sleep -Milliseconds 850
    }
}

function Select-WatchlistAll {
    $xml = Get-UiXml

    $watchlist = Find-UiNodeByText $xml 'Watchlist' -Exact -PreferBottom
    if ($watchlist) {
        Tap-Node $watchlist
        Start-Sleep -Milliseconds 450
    } else {
        Tap 108 2332
        Start-Sleep -Milliseconds 450
    }

    $xml = Get-UiXml
    $all = Find-UiNodeByText $xml 'ALL' -Exact -Where {
        param($Node)
        (Get-NodeAttribute $Node 'resource-id') -like '*tv_stock_list_name'
    }
    if ($all) {
        Tap-Node $all
        Start-Sleep -Milliseconds 350
    }
}

function Find-SymbolNode([xml]$Xml, [string]$TargetSymbol) {
    $symbolUpper = $TargetSymbol.ToUpperInvariant()

    $preferred = @($Xml.SelectNodes('//node') | Where-Object {
        (Get-NodeAttribute $_ 'text').ToUpperInvariant() -eq $symbolUpper -and
        (Get-NodeAttribute $_ 'resource-id') -like '*market_tv_market_item_name'
    })
    if ($preferred) {
        return $preferred | Sort-Object { (Convert-BoundsToRect (Get-NodeAttribute $_ 'bounds')).Top } | Select-Object -First 1
    }

    return Find-UiNodeByText $Xml $TargetSymbol -Exact
}

function Wait-ForSymbolDetail([string]$TargetSymbol) {
    Start-Sleep -Milliseconds $script:DetailOpenDelayMs
}

function Find-SymbolByOcrAndTap([string]$TargetSymbol, $Ocr = $null) {
    $ocr = if ($Ocr) { $Ocr } else { Get-ScreenshotOcr }
    $word = $ocr.Words | Where-Object { $_.Text.ToUpperInvariant() -eq $TargetSymbol.ToUpperInvariant() } |
        Sort-Object Y |
        Select-Object -First 1

    if (-not $word) {
        return $false
    }

    Tap ([int]($word.X + ($word.Width / 2))) ([int]($word.Y + ($word.Height / 2)))
    return $true
}

function Open-SymbolDetails {
    param(
        [string]$TargetSymbol,
        $HomeOcr = $null
    )

    if (Find-SymbolByOcrAndTap $TargetSymbol $HomeOcr) {
        Write-Step "Matched $TargetSymbol by OCR."
        Wait-ForSymbolDetail $TargetSymbol
        Write-Step "Opened $TargetSymbol detail page."
        return
    }

    Select-WatchlistAll

    for ($scroll = 0; $scroll -le $MaxWatchlistScrolls; $scroll++) {
        if (Find-SymbolByOcrAndTap $TargetSymbol) {
            Write-Step "Matched $TargetSymbol by OCR."
            Wait-ForSymbolDetail $TargetSymbol
            Write-Step "Opened $TargetSymbol detail page."
            return
        }

        $xml = Get-UiXml
        $node = Find-SymbolNode $xml $TargetSymbol
        if ($node) {
            Write-Step "Matched $TargetSymbol in the watchlist."
            Tap-Node $node
            Wait-ForSymbolDetail $TargetSymbol
            Write-Step "Opened $TargetSymbol detail page."
            return
        }

        if ($scroll -eq $MaxWatchlistScrolls) {
            throw "$TargetSymbol was not visible after $MaxWatchlistScrolls watchlist scrolls."
        }

        Swipe 540 1820 540 650 500
        Start-Sleep -Milliseconds 450
    }
}

function Get-TradeTicketNodes([xml]$Xml) {
    $priceContainer = Get-ResourceId 'deal_quick_price'
    $qtyContainer = Get-ResourceId 'deal_quick_qty'
    $inputId = Get-ResourceId 'et_input'
    $priceNode = $Xml.SelectSingleNode("//node[@resource-id='$priceContainer']//node[@resource-id='$inputId']")
    $qtyNode = $Xml.SelectSingleNode("//node[@resource-id='$qtyContainer']//node[@resource-id='$inputId']")
    $submitNode = Find-UiNodeByResourceId $Xml (Get-ResourceId 'btn_place_order')

    return [pscustomobject]@{
        Price  = $priceNode
        Qty    = $qtyNode
        Submit = $submitNode
    }
}

function Ensure-TradeTicketOpen {
    $sidePoint = $script:SideButtonCenter[$Side]
    if (-not $sidePoint) {
        throw "No recorded coordinate is available for side: $Side."
    }

    Write-Step "Opening $Side ticket."
    $tapStartedAt = [DateTime]::UtcNow
    Tap $sidePoint.X $sidePoint.Y

    $passwordHandled = Handle-TradePasswordIfPresent
    if (-not $passwordHandled) {
        $elapsedMs = [int](([DateTime]::UtcNow - $tapStartedAt).TotalMilliseconds)
        $remainingMs = $script:TicketOpenDelayMs - $elapsedMs
        if ($remainingMs -gt 0) {
            Start-Sleep -Milliseconds $remainingMs
        }
    }

    Write-Step 'Trade ticket opened.'
}

function Ensure-MarketOrderType {
    Write-Step 'Changing order type to Market.'
    Tap $script:LimitOrderTypeControlBounds.CenterX $script:LimitOrderTypeControlBounds.CenterY
    Start-Sleep -Milliseconds 500
    Tap $script:MarketOrderTypeOptionBounds.CenterX $script:MarketOrderTypeOptionBounds.CenterY
    Start-Sleep -Milliseconds 700
    Write-Step 'Order type is Market.'
}

function ConvertTo-AdbInputText([string]$Text) {
    return ($Text -replace '\\', '\\\\' -replace ' ', '%s' -replace '&', '\&' -replace '<', '\<' -replace '>', '\>' -replace '\(', '\(' -replace '\)', '\)')
}

function Set-TextAtPoint([int]$X, [int]$Y, [string]$Value, [string]$Name) {
    Write-Step "Entering $Name = $Value."
    $encodedValue = ConvertTo-AdbInputText $Value
    Invoke-AdbShell "input tap $X $Y; sleep 0.08; input keyevent $($script:FieldClearKeyEvents); input text $encodedValue"
    Start-Sleep -Milliseconds 150
}

function Set-TextField($Node, [string]$Value, [string]$Name) {
    $rect = Convert-BoundsToRect (Get-NodeAttribute $Node 'bounds')
    Set-TextAtPoint $rect.CenterX $rect.CenterY $Value $Name
}

function Fill-OrderTicket($TicketNodes = $null) {
    Set-TextAtPoint $script:MarketQtyInputBounds.CenterX $script:MarketQtyInputBounds.CenterY $Quantity 'Qty'
}

function Submit-OrderTicket {
    Write-Step 'Submitting order ticket.'
    Tap $script:KeyboardSubmitButtonBounds.CenterX $script:KeyboardSubmitButtonBounds.CenterY
}

function Wait-ForOrderResultByUiDump {
    $waits = @(2000, 1000, 1000)
    for ($attempt = 0; $attempt -lt $waits.Count; $attempt++) {
        Start-Sleep -Milliseconds $waits[$attempt]
        $result = Get-OrderResultByUiDump
        if ($result) {
            return $result
        }
    }

    return $null
}

function Dismiss-ResultPage {
    Write-Step 'Pressing Back to dismiss result page.'
    Press-Back
    Start-Sleep -Milliseconds 700
}

function Invoke-OrderAttempt([int]$AttemptNumber) {
    if ($AttemptNumber -gt 1) {
        Write-Step "Retrying Gigamoney market order flow (attempt $AttemptNumber/2)."
    }

    $homeOcr = Ensure-Home
    Open-SymbolDetails $Symbol $homeOcr
    $ticketNodes = Ensure-TradeTicketOpen
    Ensure-MarketOrderType

    if ($DryRun) {
        $nodes = if ($ticketNodes) { $ticketNodes } else { Get-TradeTicketNodes (Get-UiXml) }
        if (-not ($nodes.Qty -and $nodes.Submit)) {
            throw 'Dry run reached the market ticket, but the Qty and Submit controls were not both visible.'
        }

        Write-Step 'Dry run complete: market ticket is open and required controls are visible. No values were entered and no order was submitted.'
        return $true
    }

    Fill-OrderTicket $ticketNodes
    if ($NoSubmit) {
        Write-Step 'NoSubmit complete: quantity was entered, but Submit was not pressed.'
        return $true
    }

    Submit-OrderTicket
    $orderResult = Wait-ForOrderResultByUiDump
    if ($orderResult) {
        Write-Step "Order result detected: $orderResult."
        Dismiss-ResultPage
        return $true
    }

    Write-Step 'No confirmed or filled order result was detected.'
    return $false
}

Assert-Environment
$Symbol = $Symbol.ToUpperInvariant()

Write-Step "Starting Gigamoney market order flow: $Side $Quantity $Symbol."
if ($DryRun -or $NoSubmit) {
    Invoke-OrderAttempt 1 | Out-Null
    return
}

for ($attempt = 1; $attempt -le 2; $attempt++) {
    if (Invoke-OrderAttempt $attempt) {
        Write-Step 'Order flow complete.'
        return
    }

    Restart-GigamoneyApp
    if ($attempt -eq 2) {
        throw 'Market order submission was not confirmed after 2 attempts; Amend/Cancel/Duplicate/Details buttons were not detected.'
    }
}
