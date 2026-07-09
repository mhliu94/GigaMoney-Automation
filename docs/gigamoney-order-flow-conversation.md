# Gigamoney Order Flow Conversation Handoff

Created: 2026-07-09, America/New_York

This note captures the projectless Codex conversation that produced the
Gigamoney order scripts and local config file.

## Initial Timing Checks

The Android emulator was running with Gigamoney in the foreground. The first
task was to time:

1. Take an adb screenshot.
2. Extract all text from the screenshot using Windows OCR.
3. Delete the screenshot.
4. Repeat 3 times and average.

From the watchlist/home view:

| Run | Time |
| ---: | ---: |
| 1 | 1262.56 ms |
| 2 | 351.54 ms |
| 3 | 301.90 ms |

Average: 638.67 ms.

From the BILI detail view:

| Run | Time |
| ---: | ---: |
| 1 | 543.44 ms |
| 2 | 354.24 ms |
| 3 | 351.55 ms |

Average: 416.41 ms.

In both timing runs, screenshots were deleted afterward and verified to have no
remaining matching screenshot files.

## Requested Automation Flow

The requested order flow was:

1. Start from any Gigamoney screen.
2. Take a screenshot and OCR it.
3. Detect home only if extracted text contains all of:
   `Watchlist`, `Market`, `Feed`, and `Portfolio`.
4. If not on home, press Android Back and retry up to 3 times.
5. Once home is reached, reuse that OCR result to match the requested symbol
   immediately if it is visible in the watchlist.
6. If the symbol is not visible, click `Watchlist`/`ALL` and continue matching
   with OCR/UIAutomator plus ordinary list scrolling.
7. Open the stock detail page, wait 1 second for it to settle, then tap the
   recorded Buy/Sell button coordinate immediately.
8. Right after tapping Buy/Sell, take a screenshot and OCR it. If the OCR text
   contains `Enter Trade Password`, enter the configured trade password and wait
   3 seconds for the prompt to clear. Otherwise, continue into the normal
   1.5-second ticket-open wait.
9. Fill a limit order ticket for a given symbol, price, and quantity.
10. Price and Qty fields have fixed screen positions, but the implementation
   should prefer stable UIAutomator resource IDs when available.
11. Press Submit.
12. After Submit, wait 2 seconds, then use a UIAutomator dump of the result page
    to detect a successful order result. A live order result has all four action
    buttons: `Amend`, `Cancel`, `Duplicate`, and `Details`. Filled or partially
    filled result sheets are accepted as successful as soon as the filled price
    and done quantity fields are present.
13. If `-Kill`/`--kill` is set on the limit-order script, immediately cancel
    any remaining live order after successful submission. Fully filled orders
    are a no-op. Open or partially filled orders are canceled by tapping the
    result sheet's `Cancel` action, waiting 1 second, tapping the cancel
    confirmation button, handling any trade password prompt, waiting 3 seconds,
    and confirming `tv_status = Canceled`.
14. If neither submit result is detected, wait 1 second and check again; if still
    missing, wait another 1 second and check one final time.
15. If neither result is still detected, force-stop/reopen Gigamoney and retry
    the order once. If the second attempt also fails, force-stop/reopen
    Gigamoney and report failure.
16. Dismiss the result page after a confirmed submission or completed kill.

The symbol is assumed to already be present in the watchlist.

## Implementation Notes

The script uses:

- adb from `C:\Users\mhliu\AppData\Local\Android\Sdk\platform-tools\adb.exe`.
- Local config from `config\gigamoney.config.json`.
- Windows built-in OCR through WinRT APIs.
- `uiautomator dump` for stable widget IDs and bounds after the OCR home check.
- OCR after tapping Buy/Sell to detect an `Enter Trade Password` prompt.
- UIAutomator result detection by checking either live-order action buttons or
  execution/done-quantity fields.
- Temporary screenshots in `work/`, removed in `finally`.

The default config shape is:

```json
{
  "gigamoney": {
    "tradePassword": ""
  },
  "kafka": {
    "bootstrapServers": "",
    "commandTopic": "",
    "consumerGroupId": "gigamoney-order-runner"
  }
}
```

If a trade password prompt appears and `gigamoney.tradePassword` is empty, the
scripts stop with an explicit config error instead of continuing blindly.

Important Gigamoney UI IDs observed:

| Purpose | Resource ID |
| --- | --- |
| Stock detail title | `lb.whale.hkwinner.android:id/tv_stock_name_code` |
| Buy button | `lb.whale.hkwinner.android:id/tv_buy` |
| Sell button | `lb.whale.hkwinner.android:id/tv_sell` |
| Price container | `lb.whale.hkwinner.android:id/deal_quick_price` |
| Qty container | `lb.whale.hkwinner.android:id/deal_quick_qty` |
| Price/Qty input | `lb.whale.hkwinner.android:id/et_input` |
| Submit button | `lb.whale.hkwinner.android:id/btn_place_order` |
| Trade password cancel | `lb.whale.hkwinner.android:id/iv_cancel` |
| Trade password input | `lb.whale.hkwinner.android:id/et_pwd` |
| Cancel confirmation button | `lb.whale.hkwinner.android:id/common_rb_right` |
| Result status | `lb.whale.hkwinner.android:id/tv_status` |
| Confirmed Amend button | `lb.whale.hkwinner.android:id/tvModify` |
| Confirmed Cancel button | `lb.whale.hkwinner.android:id/tvCancel` |
| Confirmed Duplicate button | `lb.whale.hkwinner.android:id/tvDuplicate` |
| Confirmed Details button | `lb.whale.hkwinner.android:id/tvDetail` |
| Filled price | `lb.whale.hkwinner.android:id/tv_execution_price` |
| Filled quantity done | `lb.whale.hkwinner.android:id/tv_done_num` |

The emulator resolution during implementation was `1080x2424` with density
`420`.

Recorded stock-detail button centers used for fast ticket opening:

| Button | Center |
| --- | --- |
| Buy | `724,2282` |
| Sell | `940,2282` |

Recorded order-ticket input bounds used for fast field entry:

| Field | Bounds | Center |
| --- | --- | --- |
| Price before keyboard | `[336,1848][860,1916]` | `598,1882` |
| Qty after keyboard | `[336,1260][860,1328]` | `598,1294` |
| Submit after keyboard | `[563,1493][904,1588]` | `734,1540` |
| Cancel confirmation button | `[556,2224][1027,2340]` | `792,2282` |
| Limit order type control | `[42,1710][1048,1763]` | `545,1736` |
| Market order type option | `[53,1284][1027,1498]` | `540,1391` |
| Market Qty before keyboard | `[336,1981][860,2049]` | `598,2015` |

## Script Location

Project copy:

```powershell
C:\Users\mhliu\Documents\Projects\Giga-Money-Automation\scripts\Send-GigamoneyLimitOrder.ps1
C:\Users\mhliu\Documents\Projects\Giga-Money-Automation\scripts\Send-GigamoneyMarketOrder.ps1
C:\Users\mhliu\Documents\Projects\Giga-Money-Automation\config\gigamoney.config.json
C:\Users\mhliu\Documents\Projects\Giga-Money-Automation\config\gigamoney.config.example.json
```

Original projectless output copy:

```powershell
C:\Users\mhliu\Documents\Codex\2026-07-09\i-ha\outputs\Send-GigamoneyLimitOrder.ps1
```

## Safe Test Commands

Dry run, with no field entry and no submit:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mhliu\Documents\Projects\Giga-Money-Automation\scripts\Send-GigamoneyLimitOrder.ps1" -Symbol BILI -Price 17.38 -Quantity 0.0001 -DryRun
```

Field-entry test, stopping before Submit:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mhliu\Documents\Projects\Giga-Money-Automation\scripts\Send-GigamoneyLimitOrder.ps1" -Symbol BILI -Price 17.38 -Quantity 0.0001 -NoSubmit
```

Live order submission:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mhliu\Documents\Projects\Giga-Money-Automation\scripts\Send-GigamoneyLimitOrder.ps1" -Symbol BILI -Price 17.38 -Quantity 0.0001
```

Sell-side live order submission:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mhliu\Documents\Projects\Giga-Money-Automation\scripts\Send-GigamoneyLimitOrder.ps1" -Symbol BILI -Price 17.38 -Quantity 0.0001 -Side Sell
```

Limit fill-or-kill submission:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mhliu\Documents\Projects\Giga-Money-Automation\scripts\Send-GigamoneyLimitOrder.ps1" -Symbol BILI -Price 17.38 -Quantity 0.0001 -Kill
```

Market dry run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mhliu\Documents\Projects\Giga-Money-Automation\scripts\Send-GigamoneyMarketOrder.ps1" -Symbol BILI -Quantity 0.0001 -DryRun
```

Market field-entry test, stopping before Submit:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mhliu\Documents\Projects\Giga-Money-Automation\scripts\Send-GigamoneyMarketOrder.ps1" -Symbol BILI -Quantity 0.0001 -NoSubmit
```

Market live order submission:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mhliu\Documents\Projects\Giga-Money-Automation\scripts\Send-GigamoneyMarketOrder.ps1" -Symbol BILI -Quantity 0.0001
```

## Verification Performed

The script was tested with:

- `-DryRun`: reached the order ticket without entering values or submitting.
- `-NoSubmit`: entered `17.38` as Price and `0.0001` as Qty, then stopped before
  pressing Submit.
- Market `-DryRun`: reached the ticket, changed order type to `Market`, and
  verified Qty/Submit were visible without entering values or submitting.
- Market `-NoSubmit`: changed order type to `Market`, entered Qty only, and
  stopped before pressing Submit.
- The filled no-submit test ticket was closed afterward.
- Temporary screenshots matching `gigamoney-order-flow-*.png` were verified to
  be absent.

## Final Script Behavior

Parameters:

| Parameter | Meaning |
| --- | --- |
| `-Symbol` | Watchlist symbol to trade. Required. |
| `-Price` | Limit price. Required. |
| `-Quantity` | Order quantity. Required. |
| `-Side` | `Buy` or `Sell`; defaults to `Buy`. |
| `-ConfigPath` | Config JSON path; defaults to `config\gigamoney.config.json`. |
| `-MaxHomeBacks` | Back attempts while trying to reach home; defaults to `3`. |
| `-MaxWatchlistScrolls` | Watchlist scroll attempts; defaults to `8`. |
| `-DryRun` | Navigate to ticket only. No values entered. No submit. |
| `-NoSubmit` | Enter values, then stop before Submit. |
| `-Kill` / `--kill` | Limit-only fill-or-kill mode: submit, then cancel any unfilled remainder. |

For `Send-GigamoneyMarketOrder.ps1`, `-Price` is omitted and only `-Quantity`
is entered after changing the ticket order type from default `Limit` to
`Market`.

The script intentionally keeps the OCR home-screen check from the original
request, reuses that same OCR result for the first watchlist symbol match, and
waits 1 second after tapping the symbol before using recorded Buy/Sell
coordinates. Immediately after tapping Buy/Sell, it OCRs the screen for
`Enter Trade Password`; when present, it enters `gigamoney.tradePassword` from
the config file and waits 3 seconds for the prompt to clear. Otherwise, it waits
only the remainder of the normal 1.5-second ticket-open window. It clears fields with
10 delete keyevents and uses recorded Price-before-keyboard and
Qty-after-keyboard coordinates, then taps the recorded keyboard-open Submit
coordinate instead of doing UIAutomator dumps during ticket entry. After a live
submit, it verifies success with a UIAutomator dump after a 2-second wait, then
two 1-second retry checks. A result is successful when either the confirmed
order action buttons (`Amend`, `Cancel`, `Duplicate`, and `Details`) are present
or the result sheet exposes filled price and done quantity fields. If neither
result appears, it force-stops/reopens Gigamoney and retries once before
reporting failure. With `-Kill`/`--kill`, the limit script cancels any result
that still exposes a `Cancel` action unless the done quantity already satisfies
the requested quantity. After pressing `Cancel`, it waits 1 second, taps the
recorded cancel confirmation button, handles any trade password prompt, waits
3 seconds, and verifies `tv_status = Canceled`, then logs filled price and
filled quantity before dismissing the result sheet.

The market script follows the same navigation, submit, and confirmation flow,
but changes order type to `Market` via recorded coordinates and enters only Qty
using the recorded market Qty coordinate.
