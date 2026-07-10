param(
    [string]$ConfigPath = '',
    [int]$MaxHomeBacks = 3,
    [int]$MaxPortfolioScrolls = 8,
    [int]$MaxCancelAttempts = 50,
    [switch]$DryRun
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

. (Join-Path $script:ScriptRoot 'Gigamoney-AppForeground.ps1')
$script:PortfolioBottomTabCenter = [pscustomobject]@{ X = 756; Y = 2332 }
$script:PortfolioTopTabCenter = [pscustomobject]@{ X = 124; Y = 268 }
$script:OrdersTopTabCenter = [pscustomobject]@{ X = 368; Y = 268 }
$script:InProgressTabMiddleRight = [pscustomobject]@{ X = 433; Y = 371 }
$script:TopOrderTileCenter = [pscustomobject]@{ X = 540; Y = 605 }
$script:TopOrderCancelButtonCenter = [pscustomobject]@{ X = 519; Y = 767 }
$script:CancelConfirmButtonCenter = [pscustomobject]@{ X = 792; Y = 2282 }

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

    $png = Join-Path $script:WorkDir ("gigamoney-cancel-orders-{0}.png" -f ([guid]::NewGuid().ToString('N')))
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

function ConvertTo-AdbInputText([string]$Text) {
    return ($Text -replace '\\', '\\\\' -replace ' ', '%s' -replace '&', '\&' -replace '<', '\<' -replace '>', '\>' -replace '\(', '\(' -replace '\)', '\)')
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

function Handle-TradePasswordPromptIfPresent([int]$TimeoutMs = 1500, [int]$PollMs = 200) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    do {
        $xml = Get-UiXml
        $passwordPrompt = Get-TradePasswordPromptMarker $xml
        if ($passwordPrompt) {
            Enter-ConfiguredTradePassword
            Start-Sleep -Milliseconds 3000
            return $true
        }

        if (Test-OrdersPage $xml) {
            return $false
        }

        Start-Sleep -Milliseconds $PollMs
    } while ([DateTime]::UtcNow -lt $deadline)

    return $false
}

function Get-ChildTextByResourceName($Node, [string]$Name) {
    if (-not $Node) {
        return ''
    }

    $resourceId = Get-ResourceId $Name
    $child = $Node.SelectSingleNode(".//node[@resource-id='$resourceId']")
    if (-not $child) {
        return ''
    }

    return Get-NodeAttribute $child 'text'
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

function Get-PortfolioPageMarker([xml]$Xml) {
    $markerNames = @(
        'viewpager_fund',
        'recycle_view_fund_dist',
        'card_portfolio_view',
        'wealth_stock_hold_item_view',
        'wealth_rv_order',
        'view_order_filter',
        'wealth_refresh_layout_order'
    )
    foreach ($name in $markerNames) {
        $node = Find-UiNodeByResourceId $Xml (Get-ResourceId $name)
        if ($node) {
            return $node
        }
    }

    return $null
}

function Test-OrdersPage([xml]$Xml) {
    return [bool](
        (Find-UiNodeByResourceId $Xml (Get-ResourceId 'wealth_rv_order')) -or
        (Find-UiNodeByResourceId $Xml (Get-ResourceId 'view_order_filter')) -or
        (Find-UiNodeByResourceId $Xml (Get-ResourceId 'wealth_refresh_layout_order'))
    )
}

function Open-Portfolio {
    Write-Step 'Opening Portfolio.'
    Tap $script:PortfolioBottomTabCenter.X $script:PortfolioBottomTabCenter.Y
    Start-Sleep -Milliseconds 500
}

function Scroll-PortfolioToBottom {
    Write-Step 'Scrolling Portfolio to bottom.'
    for ($attempt = 0; $attempt -lt $MaxPortfolioScrolls; $attempt++) {
        Swipe 540 1212 540 420 120
        Start-Sleep -Milliseconds 90
    }
}

function Open-OrdersPage {
    Scroll-PortfolioToBottom
    Write-Step 'Opening Orders.'
    Tap $script:OrdersTopTabCenter.X $script:OrdersTopTabCenter.Y
    Start-Sleep -Milliseconds 180
}

function Open-InProgressOrders {
    Open-Portfolio
    Open-OrdersPage

    Write-Step 'Opening In progress orders.'
    Tap $script:InProgressTabMiddleRight.X $script:InProgressTabMiddleRight.Y

    Start-Sleep -Milliseconds 250
    $xml = Get-UiXml
    $passwordPrompt = Get-TradePasswordPromptMarker $xml
    if ($passwordPrompt) {
        Enter-ConfiguredTradePassword
        Start-Sleep -Milliseconds 3000
        Open-OrdersPage

        Write-Step 'Opening In progress orders.'
        Tap $script:InProgressTabMiddleRight.X $script:InProgressTabMiddleRight.Y
        Start-Sleep -Milliseconds 250
        $xml = Get-UiXml
    }

    if (Test-OrdersPage $xml) {
        return $xml
    }

    $result = Wait-ForUiNode {
        param($CandidateXml)
        if (Test-OrdersPage $CandidateXml) {
            return Get-PortfolioPageMarker $CandidateXml
        }
        return $null
    } -TimeoutMs 3000

    if (-not $result) {
        throw 'In progress orders did not open.'
    }

    return $result.Xml
}

function Get-InProgressOrderRows([xml]$Xml) {
    $rows = @($Xml.SelectNodes("//node[@resource-id='$(Get-ResourceId 'cl_order')']") | Where-Object {
        $rect = Convert-BoundsToRect (Get-NodeAttribute $_ 'bounds')
        if ($rect.Top -lt 500 -or $rect.Top -gt 2100) {
            return $false
        }

        $name = Get-ChildTextByResourceName $_ 'wealth_item_order_normal_tv_name'
        $code = Get-ChildTextByResourceName $_ 'wealth_item_tv_code'
        if (-not ($name -or $code)) {
            return $false
        }

        $status = Get-ChildTextByResourceName $_ 'wealth_item_order_normal_tv_status'
        if ($status -match '^(Canceled|Cancelled|Rejected|Filled)$') {
            return $false
        }

        return $true
    })

    return @($rows | Sort-Object { (Convert-BoundsToRect (Get-NodeAttribute $_ 'bounds')).Top })
}

function Get-OrderSummary($Row) {
    return [pscustomobject][ordered]@{
        name       = Get-ChildTextByResourceName $Row 'wealth_item_order_normal_tv_name'
        market     = Get-ChildTextByResourceName $Row 'wealth_item_tv_market'
        symbol     = Get-ChildTextByResourceName $Row 'wealth_item_tv_code'
        side       = Get-ChildTextByResourceName $Row 'wealth_item_order_normal_tv_action'
        status     = Get-ChildTextByResourceName $Row 'wealth_item_order_normal_tv_status'
        price      = Get-ChildTextByResourceName $Row 'wealth_item_order_normal_tv_price'
        latest     = Get-ChildTextByResourceName $Row 'tv_price'
        quantity   = Get-ChildTextByResourceName $Row 'wealth_item_order_normal_tv_quantity'
        filledQty  = Get-ChildTextByResourceName $Row 'wealth_item_order_normal_tv_executed_quantity'
    }
}

function Format-OrderForLog($Order) {
    $parts = @()
    if ($Order.side) { $parts += $Order.side }
    if ($Order.symbol) { $parts += $Order.symbol }
    if ($Order.quantity) { $parts += "qty $($Order.quantity)" }
    if ($Order.price) { $parts += "@ $($Order.price)" }
    if ($Order.status) { $parts += "($($Order.status))" }
    if (-not $parts) {
        return 'top in-progress order'
    }

    return ($parts -join ' ')
}

function Get-FirstCancelActionNode([xml]$Xml) {
    $nodes = @($Xml.SelectNodes("//node[@resource-id='$(Get-ResourceId 'tvCancel')']") | Where-Object {
        $rect = Convert-BoundsToRect (Get-NodeAttribute $_ 'bounds')
        return ($rect.Top -ge 500 -and $rect.Top -lt 2100)
    })

    if (-not $nodes) {
        return $null
    }

    return $nodes | Sort-Object { (Convert-BoundsToRect (Get-NodeAttribute $_ 'bounds')).Top } | Select-Object -First 1
}

function Get-CancelConfirmButton([xml]$Xml) {
    $node = Find-UiNodeByResourceId $Xml (Get-ResourceId 'common_rb_right')
    if ($node) {
        return $node
    }

    $confirmTexts = @('Confirm', 'OK', 'Yes')
    foreach ($text in $confirmTexts) {
        $node = Find-UiNodeByText $Xml $text -Exact -Where {
            param($Candidate)
            $rect = Convert-BoundsToRect (Get-NodeAttribute $Candidate 'bounds')
            return $rect.Top -gt 1500
        }
        if ($node) {
            return $node
        }
    }

    return $null
}

function Confirm-CancelAction {
    Start-Sleep -Milliseconds 700
    Write-Step 'Confirming cancel.'
    Tap $script:CancelConfirmButtonCenter.X $script:CancelConfirmButtonCenter.Y
    Start-Sleep -Milliseconds 2000
}

function Get-OrdersXmlAfterCancel {
    $xml = Get-UiXml
    $passwordPrompt = Get-TradePasswordPromptMarker $xml
    if ($passwordPrompt) {
        Enter-ConfiguredTradePassword
        Start-Sleep -Milliseconds 3000
        $xml = Get-UiXml
    }

    if (Test-OrdersPage $xml) {
        return $xml
    }

    Write-Step 'Returning from canceled order detail to Orders.'
    Press-Back
    Start-Sleep -Milliseconds 450
    $xml = Get-UiXml
    if (Test-OrdersPage $xml) {
        return $xml
    }

    $result = Wait-ForUiNode {
        param($CandidateXml)
        if (Test-OrdersPage $CandidateXml) {
            return Get-PortfolioPageMarker $CandidateXml
        }
        return $null
    } -TimeoutMs 3000

    if (-not $result) {
        throw 'Orders page did not remain visible after cancel.'
    }

    return $result.Xml
}

function Cancel-FirstInProgressOrder([xml]$OrdersXml) {
    $rows = @(Get-InProgressOrderRows $OrdersXml)
    if (-not $rows) {
        return $null
    }

    $row = $rows[0]
    $order = Get-OrderSummary $row

    Write-Step ("Opening {0}." -f (Format-OrderForLog $order))
    if (-not $DryRun) {
        Tap $script:TopOrderTileCenter.X $script:TopOrderTileCenter.Y
        Start-Sleep -Milliseconds 300
    }

    Write-Step ("Canceling {0}." -f (Format-OrderForLog $order))
    if (-not $DryRun) {
        Tap $script:TopOrderCancelButtonCenter.X $script:TopOrderCancelButtonCenter.Y
        Confirm-CancelAction
    }

    return $order
}

function Return-ToPortfolioTab([switch]$WaitForCancelNotification) {
    Write-Step 'Returning Orders tab to Portfolio.'
    if ($WaitForCancelNotification) {
        Start-Sleep -Milliseconds 2500
    }

    Tap $script:PortfolioTopTabCenter.X $script:PortfolioTopTabCenter.Y
    Start-Sleep -Milliseconds 500
}

Assert-Environment
Write-Step 'Starting Gigamoney cancel-all-orders flow.'
Ensure-Home

$canceledOrders = @()
$remainingOrders = 0
$ordersXml = Open-InProgressOrders

for ($attempt = 1; $attempt -le $MaxCancelAttempts; $attempt++) {
    $rows = @(Get-InProgressOrderRows $ordersXml)
    $remainingOrders = $rows.Count

    if ($remainingOrders -eq 0) {
        Write-Step 'No in-progress orders remain.'
        break
    }

    if ($DryRun) {
        Write-Step ("Dry run: {0} in-progress order(s) would be canceled." -f $remainingOrders)
        break
    }

    $order = Cancel-FirstInProgressOrder $ordersXml
    if ($order) {
        $canceledOrders += $order
    }

    $ordersXml = Get-OrdersXmlAfterCancel
}

if (-not $DryRun -and $remainingOrders -gt 0 -and $canceledOrders.Count -ge $MaxCancelAttempts) {
    $remainingOrders = @(Get-InProgressOrderRows $ordersXml).Count
    if ($remainingOrders -gt 0) {
        throw "Stopped after MaxCancelAttempts=$MaxCancelAttempts with orders still in progress."
    }
}

Return-ToPortfolioTab -WaitForCancelNotification:($canceledOrders.Count -gt 0)
Write-Step ("Cancel-all-orders flow complete; canceled {0} order(s)." -f $canceledOrders.Count)

[pscustomobject][ordered]@{
    completedAt       = (Get-Date).ToString('o')
    dryRun            = [bool]$DryRun
    canceledCount     = $canceledOrders.Count
    remainingDetected = $remainingOrders
    canceledOrders    = @($canceledOrders)
} | ConvertTo-Json -Depth 6
