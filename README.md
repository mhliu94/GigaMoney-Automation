# GigaMoney Automation

This project automates Gigamoney in an Android emulator. The existing scripts can place one market or limit order, run a limit fill-or-kill flow, cancel every open order, or read holdings.

## Long-running KTrader listener

`scripts\Start-GigamoneyTradingRunner.ps1` connects this machine to the KTrader Kafka command and account-details topics. It handles:

- `MARKET_ORDER` with `qty_shares`
- `LIMIT_ORDER`
- `LIMIT_ORDER_FOK` (and limit commands marked with `time_in_force: FOK` or `cancel_unfilled: true`)
- `CANCEL_OPEN_ORDERS`, always as a request to cancel **all** Gigamoney orders even if KTrader includes a symbol
- `SET_TRADING_ENABLED`

KTrader modes E and F publish `LIMIT_ORDER_FOK`, so those commands use the existing `-Kill` flow. Commands for other account IDs and unsupported KTrader command types are ignored. Orders and holdings queries are serialized so two processes never operate the emulator concurrently.

Market orders expressed only as `notional_usd` are rejected because the Gigamoney market-ticket automation accepts share quantity. Configure the KTrader order with shares for this account.

### Configure

Copy `config\gigamoney.config.example.json` to `config\gigamoney.config.json`, then set:

- `gigamoney.tradePassword`: the Gigamoney trading password
- `gigamoney.accountId`: the exact string ID used for this account in KTrader's trading-accounts config
- `gigamoney.accountNumId`: the matching KTrader numeric account ID, or `null` if the UI should fill it from its account metadata
- Kafka topic names if they differ from `trading-commands` and `account-details`

The example points to `45.32.121.19:9092`, publishes holdings every 120 seconds, starts from new Kafka commands (`latest`), and refuses commands more than five minutes old.

Use a unique `kafka.consumerGroupId` for this Gigamoney listener. It must not share a consumer group with a different broker or account listener.

### Install the Kafka client and start in the background

The first start can install the pinned Confluent .NET Kafka client from NuGet into the ignored `work\kafka-client` directory:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-GigamoneyTradingRunner.ps1 -InstallKafkaClient
```

The start script launches a hidden background process and then returns to the prompt. Later starts do not need the install flag:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-GigamoneyTradingRunner.ps1
```

Starting it again is safe: if the recorded runner process is still active, it reports the existing PID instead of starting a duplicate.

Check its status and show the latest activity:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Get-GigamoneyTradingRunnerStatus.ps1
```

Request a clean stop. If an emulator operation is active, this waits for it to finish before stopping:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Stop-GigamoneyTradingRunner.ps1
```

Only when an immediate termination is necessary, use `-Force`; this can interrupt an order that is in progress:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Stop-GigamoneyTradingRunner.ps1 -Force
```

Runtime logs are written to `logs\gigamoney-runner.err.log` and `logs\gigamoney-runner.out.log`. The PID record and graceful-stop signal are stored under the ignored `work\` directory.

The runner publishes one compact holdings snapshot at startup and then every two minutes to `kafka.accountDetailsTopic`. The payload uses KTrader's exact `AccountSnapshot` keys: `account_id`, `account_num_id`, `cash`, `cash_by_currency`, `positions`, `ts`, and `trading_enabled`; positions use `symbol`, `qty`, and `avg_price`. It does not include portfolio overview or market-summary branches. Additional Gigamoney position data keeps its original keys unchanged: `marketPrice`, `marketValue`, `dailyPL`, and `dailyPLPercent`.

At startup and immediately before every holdings or order operation, the runner checks Android's focused/resumed activity. If Gigamoney is stopped or in the background, it launches or brings `lb.whale.hkwinner.android` to the foreground and waits up to `gigamoney.foregroundLaunchTimeoutSeconds` for confirmation. The holdings, market, limit, and cancel-all scripts also call the shared foreground helper at the start of their landing-page/back-button flow, so direct script runs have the same protection.

Kafka offsets are committed after a command succeeds or is intentionally ignored. Failed commands are also committed by default and logged before the runner continues, because a UI automation failure can have an indeterminate trading outcome and replaying it could duplicate an order. Set `kafka.commitFailedCommands` to `false` only if stopping with the failed offset uncommitted is explicitly preferred.

The background runner does not accept local order parameters. Every market, limit, fill-or-kill, cancel-all, and trading-status command is received from `kafka.commandTopic`; the one-shot scripts are internal execution helpers.

### Local verification

The routing and holdings conversion checks do not connect to Kafka, ADB, or Gigamoney:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-GigamoneyTradingRunner.ps1 -SelfTest
```

## One-shot scripts

- `scripts\Send-GigamoneyMarketOrder.ps1`
- `scripts\Send-GigamoneyLimitOrder.ps1` (`-Kill` enables fill-or-kill behavior)
- `scripts\Cancel-GigamoneyAllOrders.ps1`
- `scripts\Get-GigamoneyHoldings.ps1`

See `docs\gigamoney-order-flow-conversation.md` for emulator coordinates, UI identifiers, and safe dry-run examples.
