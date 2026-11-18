# HA Dispenser Insights

Service analysis for Fluid Management HA180/HA480 dispensers. The page reads a copy of the dispenser's
`DeviceDriverDatabase.mdf` directly in the browser; no SQL Server or LocalDB is needed.

## Files

| File | What it does |
|---|---|
| `HA Dispenser Insights 7.0.html` | The current page. Older versions (1.0–6.0) are kept for reference. |
| `Start HA Dispenser Insights.cmd` | Start the tool with this. It runs the `.ps1` below. |
| `Start HA Dispenser Insights.ps1` | Small local helper on `127.0.0.1` that serves the page, closes `it_pos_app.exe` before a live `.mdf` is opened, reads the shop backups on the file share, and keeps the shared "contacted" ticks. Keep its window open while you use the page. |
| `Backup DeviceDriverDatabase.bat` | Scheduled task for each dispenser PC: closes `it_pos_app.exe`, copies `DeviceDriverDatabase.mdf` and `_Log.ldf`, and starts the app again. |

## Using it

1. Double-click `Start HA Dispenser Insights.cmd`. The browser opens the page.
2. The home page scans every shop backup on the file share:
   - **Pump filled less than 10% · all shops**: new Autodrive 2 "pump filled less than 10%" errors per shop, with a shared *Contacted* checkbox and CSV export.
   - **Travel · W1W · all shops**: piston & tube, piston or pump travel per shop, with the Autodrive 2 self-test steps, the weekly curve and CSV export.
3. **Open** on a shop, **Choose shop**, or **Open .mdf file** shows the full analysis of one machine: channel health, Autodrive 2, colorant levels, errors, usage and climate.

The file share path is set at the top of `Start HA Dispenser Insights.ps1` (`$SharePath`). The contacted
ticks are stored in `HA Dispenser Insights contacts.json` in the root of that share.
