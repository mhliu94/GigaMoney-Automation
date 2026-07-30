#requires -Version 5.1

param(
    [string]$ConfigPath = '',
    [switch]$InstallKafkaClient,
    [switch]$SelfTest,

    # Used only by the hidden child process created by this script.
    [switch]$Foreground
)

$ErrorActionPreference = 'Stop'

$script:ScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Parent $PSCommandPath
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
$script:ProjectRoot = Split-Path -Parent $script:ScriptRoot
$script:RunnerScriptPath = $PSCommandPath
$script:ConfigPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    Join-Path $script:ProjectRoot 'config\gigamoney.config.json'
} elseif ([System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath
} else {
    Join-Path $script:ProjectRoot $ConfigPath
}
$script:StatePath = Join-Path $script:ProjectRoot 'work\gigamoney-runner-state.json'
$script:WorkDir = Join-Path $script:ProjectRoot 'work'
$script:LogDir = Join-Path $script:ProjectRoot 'logs'
$script:PidPath = Join-Path $script:WorkDir 'gigamoney-runner.pid.json'
$script:StopRequestPath = Join-Path $script:WorkDir 'gigamoney-runner.stop'
$script:StdOutLogPath = Join-Path $script:LogDir 'gigamoney-runner.out.log'
$script:StdErrLogPath = Join-Path $script:LogDir 'gigamoney-runner.err.log'
$script:PowerShellExe = (Get-Process -Id $PID).Path
$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
$script:Adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$script:GigamoneyPackageName = 'lb.whale.hkwinner.android'
$script:AppLaunchTimeoutSeconds = 15

function Write-RunnerLog([string]$Message, [string]$Level = 'INFO') {
    [Console]::Error.WriteLine(('{0:o} {1} {2}' -f [DateTimeOffset]::UtcNow, $Level, $Message))
}

function Read-RunnerPidRecord {
    if (-not (Test-Path -LiteralPath $script:PidPath)) {
        return $null
    }
    try {
        $raw = (Get-Content -LiteralPath $script:PidPath -Raw).Trim()
        if ($raw.StartsWith('{')) {
            return ($raw | ConvertFrom-Json)
        }
        $legacyPid = 0
        if ([int]::TryParse($raw, [ref]$legacyPid)) {
            return [pscustomobject]@{ processId = $legacyPid; startedAt = $null; scriptPath = $null }
        }
    } catch {
        return $null
    }
    return $null
}

function Get-LiveRunnerProcess {
    $record = Read-RunnerPidRecord
    if (-not $record) {
        return $null
    }
    $processId = [int]$record.processId
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (-not $process) {
        return $null
    }
    try {
        $details = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
        if (-not $details.CommandLine -or $details.CommandLine -notmatch 'Start-GigamoneyTradingRunner\.ps1') {
            return $null
        }
    } catch {
        # The PID record and live PowerShell process are still useful when CIM is unavailable.
        if ($process.ProcessName -notmatch 'powershell|pwsh') {
            return $null
        }
    }
    return $process
}

function Write-RunnerPidRecord {
    New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null
    [ordered]@{
        processId = $PID
        startedAt = [DateTimeOffset]::UtcNow.ToString('o')
        scriptPath = $script:RunnerScriptPath
        configPath = $script:ConfigPath
    } | ConvertTo-Json | Set-Content -LiteralPath $script:PidPath -Encoding UTF8
}

function Remove-RunnerControlFilesIfOwned {
    $record = Read-RunnerPidRecord
    if ($record -and [int]$record.processId -eq $PID -and (Test-Path -LiteralPath $script:PidPath)) {
        Remove-Item -LiteralPath $script:PidPath -Force
    }
    if (Test-Path -LiteralPath $script:StopRequestPath) {
        Remove-Item -LiteralPath $script:StopRequestPath -Force
    }
}

function Start-BackgroundRunner {
    $existing = Get-LiveRunnerProcess
    if ($existing) {
        Write-Host "Gigamoney trading runner is already running in the background (PID $($existing.Id))."
        Write-Host "Check it with: .\scripts\Get-GigamoneyTradingRunnerStatus.ps1"
        return
    }

    New-Item -ItemType Directory -Force -Path $script:WorkDir, $script:LogDir | Out-Null
    foreach ($stalePath in @($script:PidPath, $script:StopRequestPath)) {
        if (Test-Path -LiteralPath $stalePath) {
            Remove-Item -LiteralPath $stalePath -Force
        }
    }

    $argumentLine = "-NoProfile -ExecutionPolicy Bypass -File `"$script:RunnerScriptPath`" -Foreground -ConfigPath `"$script:ConfigPath`""
    if ($InstallKafkaClient) {
        $argumentLine += ' -InstallKafkaClient'
    }

    $process = Start-Process -FilePath $script:PowerShellExe `
        -ArgumentList $argumentLine `
        -WindowStyle Hidden `
        -RedirectStandardOutput $script:StdOutLogPath `
        -RedirectStandardError $script:StdErrLogPath `
        -PassThru

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if ($process.HasExited -or (Test-Path -LiteralPath $script:PidPath)) {
            break
        }
        Start-Sleep -Milliseconds 100
        $process.Refresh()
    }

    if ($process.HasExited) {
        $lastError = if (Test-Path -LiteralPath $script:StdErrLogPath) {
            (Get-Content -LiteralPath $script:StdErrLogPath -Tail 10) -join [Environment]::NewLine
        } else {
            '<no error log was created>'
        }
        throw "Gigamoney trading runner exited during startup with code $($process.ExitCode).`n$lastError"
    }

    Write-Host "Gigamoney trading runner started in the background (PID $($process.Id))."
    Write-Host "Status: .\scripts\Get-GigamoneyTradingRunnerStatus.ps1"
    Write-Host "Stop:   .\scripts\Stop-GigamoneyTradingRunner.ps1"
    Write-Host "Log:    $script:StdErrLogPath"
}

function Get-RequiredString($Object, [string]$PropertyPath) {
    $value = $Object
    foreach ($segment in $PropertyPath.Split('.')) {
        if ($null -eq $value) {
            break
        }
        $value = $value.$segment
    }
    $text = [string]$value
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "Required config value is empty: $PropertyPath"
    }
    return $text.Trim()
}

function Get-ConfigValue($Object, [string]$PropertyPath, $DefaultValue) {
    $value = $Object
    foreach ($segment in $PropertyPath.Split('.')) {
        if ($null -eq $value -or -not ($value.PSObject.Properties.Name -contains $segment)) {
            return $DefaultValue
        }
        $value = $value.$segment
    }
    if ($null -eq $value) {
        return $DefaultValue
    }
    return $value
}

function Read-RunnerConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "Gigamoney config file was not found: $script:ConfigPath. Copy config\gigamoney.config.example.json to config\gigamoney.config.json and set gigamoney.accountId."
    }

    try {
        $config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json
    } catch {
        throw "Could not read Gigamoney config file: $script:ConfigPath. $($_.Exception.Message)"
    }

    Get-RequiredString $config 'gigamoney.accountId' | Out-Null
    Get-RequiredString $config 'kafka.bootstrapServers' | Out-Null
    Get-RequiredString $config 'kafka.commandTopic' | Out-Null
    Get-RequiredString $config 'kafka.accountDetailsTopic' | Out-Null
    Get-RequiredString $config 'kafka.consumerGroupId' | Out-Null
    return $config
}

function Resolve-KafkaClientPath($Config) {
    $configuredPath = [string](Get-ConfigValue $Config 'kafka.clientPath' '')
    if ([string]::IsNullOrWhiteSpace($configuredPath)) {
        return (Join-Path $script:ProjectRoot 'work\kafka-client')
    }
    if ([System.IO.Path]::IsPathRooted($configuredPath)) {
        return $configuredPath
    }
    return (Join-Path $script:ProjectRoot $configuredPath)
}

function Find-PackageFile([string]$Root, [string]$PackageName, [string[]]$RelativeCandidates) {
    $packageDir = Get-ChildItem -LiteralPath (Join-Path $Root 'packages') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$($PackageName.ToLowerInvariant()).*" } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $packageDir) {
        return $null
    }
    foreach ($candidate in $RelativeCandidates) {
        $path = Join-Path $packageDir.FullName $candidate
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }
    return $null
}

function Initialize-KafkaClient($Config) {
    $clientRoot = Resolve-KafkaClientPath $Config
    $clientVersion = [string](Get-ConfigValue $Config 'kafka.clientVersion' '2.15.0')
    $confluentDll = Find-PackageFile $clientRoot 'confluent.kafka' @('lib\net462\Confluent.Kafka.dll', 'lib\netstandard2.0\Confluent.Kafka.dll')

    if (-not $confluentDll -and $InstallKafkaClient) {
        Write-RunnerLog "Installing Confluent.Kafka $clientVersion into $clientRoot."
        & (Join-Path $script:ScriptRoot 'Install-GigamoneyKafkaClient.ps1') -DestinationPath $clientRoot -ConfluentKafkaVersion $clientVersion
        $confluentDll = Find-PackageFile $clientRoot 'confluent.kafka' @('lib\net462\Confluent.Kafka.dll', 'lib\netstandard2.0\Confluent.Kafka.dll')
    }

    if (-not $confluentDll) {
        throw "Confluent.Kafka is not installed under $clientRoot. Run this script once with -InstallKafkaClient."
    }

    $architecture = if ([Environment]::Is64BitProcess) { 'win-x64' } else { 'win-x86' }
    $nativeDll = Find-PackageFile $clientRoot 'librdkafka.redist' @("runtimes\$architecture\native\librdkafka.dll")
    if (-not $nativeDll) {
        throw "librdkafka.dll for $architecture was not found under $clientRoot. Re-run with -InstallKafkaClient."
    }
    $nativeDir = Split-Path -Parent $nativeDll
    if (($env:PATH -split ';') -notcontains $nativeDir) {
        $env:PATH = "$nativeDir;$env:PATH"
    }

    $assemblies = @(
        @{ Package = 'system.runtime.compilerservices.unsafe'; Files = @('lib\net462\System.Runtime.CompilerServices.Unsafe.dll', 'lib\net461\System.Runtime.CompilerServices.Unsafe.dll', 'lib\netstandard2.0\System.Runtime.CompilerServices.Unsafe.dll') },
        @{ Package = 'system.buffers'; Files = @('lib\net462\System.Buffers.dll', 'lib\net461\System.Buffers.dll', 'lib\netstandard2.0\System.Buffers.dll') },
        @{ Package = 'system.numerics.vectors'; Files = @('lib\net462\System.Numerics.Vectors.dll', 'lib\net46\System.Numerics.Vectors.dll', 'lib\netstandard2.0\System.Numerics.Vectors.dll') },
        @{ Package = 'system.memory'; Files = @('lib\net462\System.Memory.dll', 'lib\net461\System.Memory.dll', 'lib\netstandard2.0\System.Memory.dll') }
    )
    foreach ($assembly in $assemblies) {
        $path = Find-PackageFile $clientRoot $assembly.Package $assembly.Files
        if ($path) {
            [Reflection.Assembly]::LoadFrom($path) | Out-Null
        }
    }
    [Reflection.Assembly]::LoadFrom($confluentDll) | Out-Null
    [Confluent.Kafka.Library]::Load($nativeDll) | Out-Null
    Write-RunnerLog "Loaded Kafka client from $confluentDll."
}

function ConvertTo-PositiveNumberString($Value, [string]$FieldName) {
    $number = 0.0
    $styles = [System.Globalization.NumberStyles]::Float -bor [System.Globalization.NumberStyles]::AllowThousands
    if (-not [double]::TryParse([string]$Value, $styles, $script:InvariantCulture, [ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -le 0) {
        throw "$FieldName must be a positive number. Received: $Value"
    }
    return $number.ToString('0.############################', $script:InvariantCulture)
}

function Get-NormalizedSide($Command) {
    $side = ([string]$Command.side).Trim().ToUpperInvariant()
    if ($side -notin @('BUY', 'SELL')) {
        throw "Order has invalid side: $($Command.side)"
    }
    if ($side -eq 'BUY') {
        return 'Buy'
    }
    return 'Sell'
}

function Get-NormalizedSymbol($Command) {
    $symbol = ([string]$Command.symbol).Trim().ToUpperInvariant()
    if ($symbol -notmatch '^[A-Z0-9\.\-]+$') {
        throw "Order has invalid symbol: $($Command.symbol)"
    }
    return $symbol
}

function Resolve-TradingHelperPath([string]$FileName) {
    return (Join-Path $script:ScriptRoot $FileName)
}

function Get-CommandExecutionPlan($Command) {
    $type = ([string]$Command.type).Trim().ToUpperInvariant()
    switch ($type) {
        'MARKET_ORDER' {
            if ($null -ne $Command.notional_usd -and $null -ne $Command.qty_shares) {
                throw 'Market order cannot contain both qty_shares and notional_usd.'
            }
            if ($null -ne $Command.notional_usd -and $null -eq $Command.qty_shares) {
                throw 'Gigamoney market orders require qty_shares; the Gigamoney ticket automation cannot enter notional_usd.'
            }
            if ($null -eq $Command.qty_shares) {
                throw 'Market order requires qty_shares.'
            }
            return [pscustomobject]@{
                Kind = 'Script'
                Name = 'market order'
                ScriptPath = (Resolve-TradingHelperPath 'Send-GigamoneyMarketOrder.ps1')
                Arguments = @('-Symbol', (Get-NormalizedSymbol $Command), '-Quantity', (ConvertTo-PositiveNumberString $Command.qty_shares 'qty_shares'), '-Side', (Get-NormalizedSide $Command), '-ConfigPath', $script:ConfigPath)
            }
        }
        'LIMIT_ORDER' {
            if (([string]$Command.time_in_force).Trim().ToUpperInvariant() -eq 'FOK' -or $Command.cancel_unfilled -eq $true) {
                return [pscustomobject]@{
                    Kind = 'Script'
                    Name = 'fill-or-kill limit order'
                    ScriptPath = (Resolve-TradingHelperPath 'Send-GigamoneyLimitOrder.ps1')
                    Arguments = @('-Symbol', (Get-NormalizedSymbol $Command), '-Price', (ConvertTo-PositiveNumberString $Command.limit_price 'limit_price'), '-Quantity', (ConvertTo-PositiveNumberString $Command.qty_shares 'qty_shares'), '-Side', (Get-NormalizedSide $Command), '-ConfigPath', $script:ConfigPath, '-Kill')
                }
            }
            return [pscustomobject]@{
                Kind = 'Script'
                Name = 'limit order'
                ScriptPath = (Resolve-TradingHelperPath 'Send-GigamoneyLimitOrder.ps1')
                Arguments = @('-Symbol', (Get-NormalizedSymbol $Command), '-Price', (ConvertTo-PositiveNumberString $Command.limit_price 'limit_price'), '-Quantity', (ConvertTo-PositiveNumberString $Command.qty_shares 'qty_shares'), '-Side', (Get-NormalizedSide $Command), '-ConfigPath', $script:ConfigPath)
            }
        }
        'LIMIT_ORDER_FOK' {
            return [pscustomobject]@{
                Kind = 'Script'
                Name = 'fill-or-kill limit order'
                ScriptPath = (Resolve-TradingHelperPath 'Send-GigamoneyLimitOrder.ps1')
                Arguments = @('-Symbol', (Get-NormalizedSymbol $Command), '-Price', (ConvertTo-PositiveNumberString $Command.limit_price 'limit_price'), '-Quantity', (ConvertTo-PositiveNumberString $Command.qty_shares 'qty_shares'), '-Side', (Get-NormalizedSide $Command), '-ConfigPath', $script:ConfigPath, '-Kill')
            }
        }
        'CANCEL_OPEN_ORDERS' {
            return [pscustomobject]@{
                Kind = 'Script'
                Name = 'cancel all orders'
                ScriptPath = (Join-Path $script:ScriptRoot 'Cancel-GigamoneyAllOrders.ps1')
                Arguments = @('-ConfigPath', $script:ConfigPath)
            }
        }
        'SET_TRADING_ENABLED' {
            return [pscustomobject]@{ Kind = 'TradingState'; Enabled = (ConvertTo-BooleanValue $Command.trading_enabled 'trading_enabled'); Name = 'trading status change' }
        }
        default {
            return [pscustomobject]@{ Kind = 'Ignore'; Name = $type }
        }
    }
}

function ConvertTo-BooleanValue($Value, [string]$FieldName) {
    if ($Value -is [bool]) {
        return [bool]$Value
    }
    switch (([string]$Value).Trim().ToLowerInvariant()) {
        { $_ -in @('1', 'true', 'yes', 'on', 'enabled') } { return $true }
        { $_ -in @('0', 'false', 'no', 'off', 'disabled') } { return $false }
        default { throw "$FieldName must be a boolean. Received: $Value" }
    }
}

function Test-GigamoneyForegroundOutput([string[]]$WindowOutput, [string[]]$ActivityOutput) {
    $focusLines = @($WindowOutput | Where-Object { $_ -match 'mCurrentFocus|mFocusedApp' })
    $resumedLines = @($ActivityOutput | Where-Object { $_ -match 'mResumedActivity|topResumedActivity' })
    $foregroundText = (@($focusLines) + @($resumedLines)) -join "`n"
    return ($foregroundText -match [regex]::Escape($script:GigamoneyPackageName))
}

function Test-GigamoneyAppForeground {
    $windowOutput = @(& $script:Adb shell dumpsys window windows 2>$null)
    $activityOutput = @(& $script:Adb shell dumpsys activity activities 2>$null)
    return (Test-GigamoneyForegroundOutput $windowOutput $activityOutput)
}

function Ensure-GigamoneyAppForeground {
    if (-not (Test-Path -LiteralPath $script:Adb)) {
        throw "adb was not found at $script:Adb"
    }

    $devices = @(& $script:Adb devices 2>$null)
    if (($devices -join "`n") -notmatch "`tdevice") {
        throw 'No attached adb device/emulator is available.'
    }

    if (Test-GigamoneyAppForeground) {
        return
    }

    Write-RunnerLog 'Gigamoney is not in the foreground; bringing the app forward.'
    & $script:Adb shell monkey -p $script:GigamoneyPackageName -c android.intent.category.LAUNCHER 1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not launch Gigamoney package $script:GigamoneyPackageName with adb."
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($script:AppLaunchTimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        if (Test-GigamoneyAppForeground) {
            Write-RunnerLog 'Gigamoney is now running in the foreground.'
            return
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "Gigamoney did not reach the foreground within $($script:AppLaunchTimeoutSeconds) seconds after launch."
}

function Test-CommandIsStale($Command, [double]$MaxAgeSeconds) {
    if ($MaxAgeSeconds -le 0) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace([string]$Command.ts)) {
        return $true
    }
    $issuedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Command.ts, $script:InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$issuedAt)) {
        return $true
    }
    return (([DateTimeOffset]::UtcNow - $issuedAt.ToUniversalTime()).TotalSeconds -gt $MaxAgeSeconds)
}

function Invoke-ChildScript([string]$Path, [string[]]$Arguments, [switch]$CaptureOutput) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Trading helper script was not found: $Path"
    }
    $output = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments
    $exitCode = $LASTEXITCODE
    if (-not $CaptureOutput) {
        foreach ($line in @($output)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                Write-RunnerLog ([string]$line)
            }
        }
    }
    if ($exitCode -ne 0) {
        throw "Trading helper failed with exit code $exitCode`: $Path"
    }
    if ($CaptureOutput) {
        return ($output -join "`n")
    }
}

function ConvertTo-NullableDouble($Value) {
    if ($null -eq $Value) {
        return $null
    }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text) -or $text -in @('-', '--', 'N/A')) {
        return $null
    }
    $negative = $text.StartsWith('(') -and $text.EndsWith(')')
    $clean = [regex]::Replace($text, '[^0-9\.\-]', '')
    $number = 0.0
    if (-not [double]::TryParse($clean, [System.Globalization.NumberStyles]::Float, $script:InvariantCulture, [ref]$number)) {
        return $null
    }
    if ($negative) {
        $number = -[math]::Abs($number)
    }
    return [double]$number
}

function ConvertTo-KTraderSnapshot($Holdings, $Config, [bool]$TradingEnabled) {
    $cashByCurrency = [ordered]@{}
    foreach ($balance in @($Holdings.cash.balances)) {
        $currency = ([string]$balance.currency).Trim().ToUpperInvariant()
        $amount = ConvertTo-NullableDouble $balance.balance
        if ($currency -match '^[A-Z]{3}$' -and $null -ne $amount) {
            $cashByCurrency[$currency] = $amount
        }
    }

    $cash = if ($cashByCurrency.Contains('USD')) {
        [double]$cashByCurrency['USD']
    } else {
        $totalUsd = ConvertTo-NullableDouble $Holdings.cash.totalUsd
        if ($null -ne $totalUsd) {
            [double]$totalUsd
        } else {
            $overviewCash = ConvertTo-NullableDouble $Holdings.portfolio.overview.cash
            if ($null -ne $overviewCash) { [double]$overviewCash } else { 0.0 }
        }
    }

    $rawPositions = if ($Holdings.PSObject.Properties.Name -contains 'positions') {
        @($Holdings.positions)
    } else {
        # Backward compatibility with holdings output produced before the compact payload change.
        @($Holdings.portfolio.positions)
    }

    $positions = @()
    foreach ($position in $rawPositions) {
        $symbol = ([string]$position.symbol).Trim().ToUpperInvariant()
        $qty = ConvertTo-NullableDouble $position.quantity
        if ([string]::IsNullOrWhiteSpace($symbol) -or $null -eq $qty -or $qty -eq 0) {
            continue
        }
        $mappedPosition = [ordered]@{
            symbol = $symbol
            qty = [double]$qty
            avg_price = ConvertTo-NullableDouble $position.cost
        }
        $optionalFields = [ordered]@{
            marketPrice = ConvertTo-NullableDouble $position.marketPrice
            marketValue = ConvertTo-NullableDouble $position.marketValue
            dailyPL = ConvertTo-NullableDouble $position.dailyPL
            dailyPLPercent = ConvertTo-NullableDouble $position.dailyPLPercent
        }
        foreach ($fieldName in $optionalFields.Keys) {
            if ($null -ne $optionalFields[$fieldName]) {
                $mappedPosition[$fieldName] = [double]$optionalFields[$fieldName]
            }
        }
        $positions += $mappedPosition
    }

    $timestamp = [DateTimeOffset]::UtcNow.ToString('o')
    $queriedAt = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Holdings.queriedAt, [ref]$queriedAt)) {
        $timestamp = $queriedAt.ToUniversalTime().ToString('o')
    }

    return [ordered]@{
        account_id = Get-RequiredString $Config 'gigamoney.accountId'
        account_num_id = Get-ConfigValue $Config 'gigamoney.accountNumId' $null
        cash = $cash
        cash_by_currency = $cashByCurrency
        positions = $positions
        ts = $timestamp
        trading_enabled = $TradingEnabled
    }
}

function Get-TradingEnabled($Config) {
    if (Test-Path -LiteralPath $script:StatePath) {
        try {
            $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
            return [bool]$state.tradingEnabled
        } catch {
            Write-RunnerLog "Ignoring unreadable trading state file $script:StatePath`: $($_.Exception.Message)" 'WARN'
        }
    }
    return [bool](Get-ConfigValue $Config 'gigamoney.tradingEnabledDefault' $true)
}

function Set-TradingEnabled([bool]$Enabled) {
    $stateDir = Split-Path -Parent $script:StatePath
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    [ordered]@{ tradingEnabled = $Enabled; updatedAt = [DateTimeOffset]::UtcNow.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
}

function New-KafkaConsumer($Config) {
    $consumerConfig = New-Object Confluent.Kafka.ConsumerConfig
    $consumerConfig.BootstrapServers = Get-RequiredString $Config 'kafka.bootstrapServers'
    $consumerConfig.GroupId = Get-RequiredString $Config 'kafka.consumerGroupId'
    $consumerConfig.EnableAutoCommit = $false
    $consumerConfig.AutoOffsetReset = if (([string](Get-ConfigValue $Config 'kafka.autoOffsetReset' 'latest')).ToLowerInvariant() -eq 'earliest') {
        [Confluent.Kafka.AutoOffsetReset]::Earliest
    } else {
        [Confluent.Kafka.AutoOffsetReset]::Latest
    }
    $consumerConfig.MaxPollIntervalMs = [int](Get-ConfigValue $Config 'kafka.maxPollIntervalMilliseconds' 900000)
    $consumerConfig.SessionTimeoutMs = 10000
    return ([Confluent.Kafka.ConsumerBuilder[Confluent.Kafka.Ignore,string]]::new($consumerConfig).Build())
}

function New-KafkaProducer($Config) {
    $producerConfig = New-Object Confluent.Kafka.ProducerConfig
    $producerConfig.BootstrapServers = Get-RequiredString $Config 'kafka.bootstrapServers'
    $producerConfig.Acks = [Confluent.Kafka.Acks]::All
    $producerConfig.EnableIdempotence = $true
    $producerConfig.LingerMs = 5
    return ([Confluent.Kafka.ProducerBuilder[string,string]]::new($producerConfig).Build())
}

function Publish-Holdings($Producer, $Config, [bool]$TradingEnabled) {
    Write-RunnerLog 'Querying Gigamoney holdings for Kafka account snapshot.'
    $raw = Invoke-ChildScript -Path (Join-Path $script:ScriptRoot 'Get-GigamoneyHoldings.ps1') -Arguments @('-ConfigPath', $script:ConfigPath) -CaptureOutput
    try {
        $holdings = $raw | ConvertFrom-Json
    } catch {
        throw "Holdings helper did not return valid JSON. $($_.Exception.Message)"
    }
    $snapshot = ConvertTo-KTraderSnapshot $holdings $Config $TradingEnabled
    $message = [Confluent.Kafka.Message[string,string]]::new()
    # Other account-details publishers use a null Kafka key; routing is carried by account_id in JSON.
    $message.Key = $null
    $message.Value = $snapshot | ConvertTo-Json -Depth 8 -Compress
    $topic = Get-RequiredString $Config 'kafka.accountDetailsTopic'
    # PowerShell cannot resolve Confluent.Kafka's two-argument overload reliably.
    $Producer.ProduceAsync($topic, $message, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    Write-RunnerLog "Published holdings account_id=$($snapshot.account_id) positions=$(@($snapshot.positions).Count) topic=$topic."
}

function Invoke-SelfTest {
    $oldConfigPath = $script:ConfigPath
    $script:ConfigPath = 'C:\test\gigamoney.config.json'
    try {
        $market = Get-CommandExecutionPlan ([pscustomobject]@{ type = 'MARKET_ORDER'; symbol = 'bili'; side = 'BUY'; qty_shares = 2 })
        if ($market.ScriptPath -notlike '*Send-GigamoneyMarketOrder.ps1' -or $market.Arguments -notcontains '2') { throw 'market routing failed' }

        $limit = Get-CommandExecutionPlan ([pscustomobject]@{ type = 'LIMIT_ORDER'; symbol = 'BILI'; side = 'SELL'; qty_shares = 3; limit_price = 17.38 })
        if ($limit.ScriptPath -notlike '*Send-GigamoneyLimitOrder.ps1' -or $limit.Arguments -contains '-Kill') { throw 'limit routing failed' }

        $fok = Get-CommandExecutionPlan ([pscustomobject]@{ type = 'LIMIT_ORDER_FOK'; symbol = 'BILI'; side = 'BUY'; qty_shares = 4; limit_price = 17.4 })
        if ($fok.Arguments -notcontains '-Kill') { throw 'FOK routing failed' }

        $fokAlias = Get-CommandExecutionPlan ([pscustomobject]@{ type = 'LIMIT_ORDER'; time_in_force = 'FOK'; symbol = 'BILI'; side = 'BUY'; qty_shares = 4; limit_price = 17.4 })
        if ($fokAlias.Arguments -notcontains '-Kill') { throw 'FOK alias routing failed' }

        $cancel = Get-CommandExecutionPlan ([pscustomobject]@{ type = 'CANCEL_OPEN_ORDERS'; account_id = 'A'; symbol = 'BILI' })
        if ($cancel.ScriptPath -notlike '*Cancel-GigamoneyAllOrders.ps1' -or $cancel.Arguments -contains 'BILI') { throw 'cancel-all routing failed' }

        $notionalFailed = $false
        try { Get-CommandExecutionPlan ([pscustomobject]@{ type = 'MARKET_ORDER'; symbol = 'BILI'; side = 'BUY'; notional_usd = 100 }) | Out-Null } catch { $notionalFailed = $true }
        if (-not $notionalFailed) { throw 'notional market order guard failed' }

        $config = [pscustomobject]@{ gigamoney = [pscustomobject]@{ accountId = 'GIGA-A'; accountNumId = 7 } }
        $holdings = [pscustomobject]@{
            queriedAt = '2026-07-10T12:00:00Z'
            cash = [pscustomobject]@{ balances = @([pscustomobject]@{ currency = 'USD'; balance = '$1,234.50' }) }
            positions = @([pscustomobject]@{
                symbol = 'bili'
                quantity = '12.5'
                cost = '$17.25'
                marketPrice = '$18.50'
                marketValue = '$231.25'
                dailyPL = '$15.00'
                dailyPLPercent = '6.94%'
            })
        }
        $snapshot = ConvertTo-KTraderSnapshot $holdings $config $true
        if (
            $snapshot.cash -ne 1234.5 -or
            $snapshot.positions[0].qty -ne 12.5 -or
            $snapshot.positions[0].avg_price -ne 17.25 -or
            $snapshot.positions[0].marketPrice -ne 18.5 -or
            $snapshot.positions[0].marketValue -ne 231.25 -or
            $snapshot.positions[0].dailyPL -ne 15.0 -or
            $snapshot.positions[0].dailyPLPercent -ne 6.94
        ) { throw 'holdings conversion failed' }

        $snapshotJson = $snapshot | ConvertTo-Json -Depth 8 -Compress
        if ($snapshotJson -match 'overview|marketSummaries|portfolio') { throw 'holdings snapshot is not compact' }
        $snapshotObject = $snapshotJson | ConvertFrom-Json
        $requiredSnapshotKeys = @('account_id', 'account_num_id', 'cash', 'cash_by_currency', 'positions', 'ts', 'trading_enabled')
        foreach ($requiredKey in $requiredSnapshotKeys) {
            if ($snapshotObject.PSObject.Properties.Name -notcontains $requiredKey) {
                throw "holdings snapshot is missing required key: $requiredKey"
            }
        }
        $requiredPositionKeys = @('symbol', 'qty', 'avg_price', 'marketPrice', 'marketValue', 'dailyPL', 'dailyPLPercent')
        foreach ($requiredKey in $requiredPositionKeys) {
            if ($snapshotObject.positions[0].PSObject.Properties.Name -notcontains $requiredKey) {
                throw "holdings position is missing required key: $requiredKey"
            }
        }

        $state = Get-CommandExecutionPlan ([pscustomobject]@{ type = 'SET_TRADING_ENABLED'; trading_enabled = 'false' })
        if ($state.Enabled -ne $false) { throw 'trading state conversion failed' }

        $foregroundDetected = Test-GigamoneyForegroundOutput `
            @('mCurrentFocus=Window{123 u0 lb.whale.hkwinner.android/.MainActivity}') `
            @()
        if (-not $foregroundDetected) { throw 'Gigamoney foreground detection failed' }
        $backgroundOnly = Test-GigamoneyForegroundOutput `
            @('Window #2 Window{456 u0 lb.whale.hkwinner.android/.MainActivity}', 'mCurrentFocus=Window{789 u0 com.android.settings/.Settings}') `
            @('mResumedActivity: ActivityRecord{abc com.android.settings/.Settings}')
        if ($backgroundOnly) { throw 'Gigamoney background window was incorrectly treated as foreground' }

        if ($InstallKafkaClient) {
            $kafkaConfig = [pscustomobject]@{
                kafka = [pscustomobject]@{
                    bootstrapServers = 'localhost:9092'
                    consumerGroupId = 'gigamoney-self-test'
                    autoOffsetReset = 'latest'
                    maxPollIntervalMilliseconds = 900000
                    clientVersion = '2.15.0'
                    clientPath = ''
                }
            }
            Initialize-KafkaClient $kafkaConfig
            $consumer = New-KafkaConsumer $kafkaConfig
            $producer = New-KafkaProducer $kafkaConfig
            $produceAsyncOverload = $producer.GetType().GetMethods() | Where-Object {
                $_.Name -eq 'ProduceAsync' -and $_.GetParameters().Count -eq 3
            } | Select-Object -First 1
            if (-not $produceAsyncOverload) { throw 'Kafka producer is missing the required ProduceAsync overload' }
            $consumer.Dispose()
            $producer.Dispose()
            Write-Host 'Kafka client load and construction test passed.'
        }

        Write-Host 'Gigamoney trading runner self-test passed.'
    } finally {
        $script:ConfigPath = $oldConfigPath
    }
}

function Start-TradingRunner($Config) {
    Initialize-KafkaClient $Config
    $script:AppLaunchTimeoutSeconds = [int](Get-ConfigValue $Config 'gigamoney.foregroundLaunchTimeoutSeconds' 15)
    if ($script:AppLaunchTimeoutSeconds -le 0) {
        throw 'gigamoney.foregroundLaunchTimeoutSeconds must be positive.'
    }
    $accountId = Get-RequiredString $Config 'gigamoney.accountId'
    $commandTopic = Get-RequiredString $Config 'kafka.commandTopic'
    $pollSeconds = [double](Get-ConfigValue $Config 'kafka.pollTimeoutSeconds' 1)
    $holdingsInterval = [double](Get-ConfigValue $Config 'kafka.holdingsIntervalSeconds' 120)
    $maxCommandAge = [double](Get-ConfigValue $Config 'kafka.maxCommandAgeSeconds' 300)
    $commitFailedCommands = ConvertTo-BooleanValue (Get-ConfigValue $Config 'kafka.commitFailedCommands' $true) 'kafka.commitFailedCommands'
    if ($pollSeconds -le 0 -or $holdingsInterval -le 0) {
        throw 'kafka.pollTimeoutSeconds and kafka.holdingsIntervalSeconds must be positive.'
    }

    $consumer = $null
    $producer = $null
    try {
        $consumer = New-KafkaConsumer $Config
        $producer = New-KafkaProducer $Config
        $consumer.Subscribe($commandTopic)
        $tradingEnabled = Get-TradingEnabled $Config
        $nextHoldingsAt = [DateTimeOffset]::UtcNow
        Write-RunnerLog "Started Gigamoney runner account_id=$accountId command_topic=$commandTopic holdings_interval_seconds=$holdingsInterval trading_enabled=$tradingEnabled."

        while ($true) {
            if (Test-Path -LiteralPath $script:StopRequestPath) {
                Write-RunnerLog 'A stop was requested; shutting down after the current operation.'
                break
            }

            $now = [DateTimeOffset]::UtcNow
            if ($now -ge $nextHoldingsAt) {
                try {
                    Publish-Holdings $producer $Config $tradingEnabled
                } catch {
                    Write-RunnerLog "Holdings publish failed: $($_.Exception.Message)" 'ERROR'
                }
                do {
                    $nextHoldingsAt = $nextHoldingsAt.AddSeconds($holdingsInterval)
                } while ($nextHoldingsAt -le [DateTimeOffset]::UtcNow)
            }

            $result = $consumer.Consume([TimeSpan]::FromSeconds($pollSeconds))
            if ($null -eq $result -or $result.IsPartitionEOF) {
                continue
            }

            $commandId = '<unparsed>'
            try {
                $command = $result.Message.Value | ConvertFrom-Json
                $commandId = if ([string]::IsNullOrWhiteSpace([string]$command.command_id)) { '<missing>' } else { [string]$command.command_id }
                $targetAccount = ([string]$command.account_id).Trim()
                if ($targetAccount -ne $accountId) {
                    $consumer.Commit($result) | Out-Null
                    continue
                }

                if (Test-CommandIsStale $command $maxCommandAge) {
                    Write-RunnerLog "Ignoring stale or invalid-timestamp command command_id=$commandId type=$($command.type)." 'WARN'
                    $consumer.Commit($result) | Out-Null
                    continue
                }

                $plan = Get-CommandExecutionPlan $command
                if ($plan.Kind -eq 'Ignore') {
                    Write-RunnerLog "Ignoring unsupported command command_id=$commandId type=$($command.type)."
                    $consumer.Commit($result) | Out-Null
                    continue
                }

                if ($plan.Kind -eq 'TradingState') {
                    $tradingEnabled = [bool]$plan.Enabled
                    Set-TradingEnabled $tradingEnabled
                    Write-RunnerLog "Set trading_enabled=$tradingEnabled command_id=$commandId."
                    $consumer.Commit($result) | Out-Null
                    continue
                }

                $isCancel = (([string]$command.type).Trim().ToUpperInvariant() -eq 'CANCEL_OPEN_ORDERS')
                if (-not $isCancel -and -not $tradingEnabled) {
                    Write-RunnerLog "Ignoring order because trading is disabled command_id=$commandId type=$($command.type)." 'WARN'
                    $consumer.Commit($result) | Out-Null
                    continue
                }

                Write-RunnerLog "Executing $($plan.Name) command_id=$commandId."
                Invoke-ChildScript -Path $plan.ScriptPath -Arguments $plan.Arguments
                $consumer.Commit($result) | Out-Null
                Write-RunnerLog "Completed $($plan.Name) command_id=$commandId and committed its Kafka offset."
            } catch {
                $failureMessage = "Command processing failed at topic=$($result.Topic) partition=$($result.Partition.Value) offset=$($result.Offset.Value): $($_.Exception.Message)"
                Write-RunnerLog $failureMessage 'ERROR'
                if (-not $commitFailedCommands) {
                    Write-RunnerLog 'kafka.commitFailedCommands is false; leaving the offset uncommitted and stopping for operator review.' 'ERROR'
                    throw
                }

                try {
                    $consumer.Commit($result) | Out-Null
                } catch {
                    Write-RunnerLog "Could not commit the failed command offset; stopping to avoid losing Kafka position: $($_.Exception.Message)" 'ERROR'
                    throw
                }
                Write-RunnerLog "Committed failed command_id=$commandId to prevent an unsafe replay; continuing to consume Kafka commands." 'WARN'
                continue
            }
        }
    } finally {
        if ($consumer) {
            try { $consumer.Close() } catch { }
            $consumer.Dispose()
        }
        if ($producer) {
            try { $producer.Flush([TimeSpan]::FromSeconds(5)) | Out-Null } catch { }
            $producer.Dispose()
        }
        Write-RunnerLog 'Gigamoney trading runner stopped.'
    }
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

$config = Read-RunnerConfig
if (-not $Foreground) {
    Start-BackgroundRunner
    exit 0
}

if (Test-Path -LiteralPath $script:StopRequestPath) {
    Remove-Item -LiteralPath $script:StopRequestPath -Force
}
Write-RunnerPidRecord
try {
    Start-TradingRunner $config
} finally {
    Remove-RunnerControlFilesIfOwned
}
