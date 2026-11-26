# HA Dispenser Insights

Service analysis for Fluid Management HA180/HA480 dispensers. The page reads a copy of the dispenser's
`DeviceDriverDatabase.mdf` directly in the browser; no SQL Server or LocalDB is needed.

**Online:** https://jellemaertens.github.io/BossDispenserInsights/ (GitHub Pages, updated on every push to `main`).
Online the page runs without the local helper: it can't close `it_pos_app.exe`, and Edge or Chrome asks once for the share
folder. *Contacted* ticks are still shared: the browser saves them in the share folder (it asks once for permission and
for your name). For the full version, start it with `Start HA Dispenser Insights.cmd`.

## Files

| File | What it does |
|---|---|
| `HA Dispenser Insights 7.0.html` | The current page. Older versions (1.0–6.0) are kept for reference. |
| `Start HA Dispenser Insights.cmd` | Start the tool with this. It runs the `.ps1` below. |
| `Start HA Dispenser Insights.ps1` | Small local helper on `127.0.0.1` that serves the page, closes `it_pos_app.exe` before a live `.mdf` is opened, reads the shop backups on the file share, and keeps the shared "contacted" ticks. Keep its window open while you use the page. |
| `Backup DeviceDriverDatabase.bat` | Scheduled task for each dispenser PC: closes `it_pos_app.exe`, copies `DeviceDriverDatabase.mdf` and `_Log.ldf`, and starts the app again. With an `Upload settings.json` next to it, it then uploads the copy (see below). |
| `Upload DeviceDriverDatabase.ps1` | For shop PCs without Intune: zips the copy and uploads it over HTTPS into an Azure Blob inbox. |
| `Install backup on shop PC.cmd` / `.ps1` | Sets up the backup + upload on such a shop PC: copies the files to `C:\My-Mx files` and adds a daily task. |
| `Upload settings.example.json` | Template for a shop's `Upload settings.json` (shop name + upload link). |

## Using it

1. Double-click `Start HA Dispenser Insights.cmd`. The browser opens the page.
2. The home page (**All shops** in the header) scans every shop backup on the file share. It has a tab per view, each with a CSV export, and one period filter (all data, 12 months, 90/30/7 days or your own dates) for all of them:
   - **Pump filled less than 10% · all shops**: new Autodrive 2 "pump filled less than 10%" errors per shop, with a shared *Contacted* checkbox.
   - **W1W travel**: piston & tube, piston or pump travel per shop, with the Autodrive 2 self-test steps and the weekly curve (another colorant can be chosen; the tab takes its name).
   - **Colorant older than 12 months · all shops**: canisters whose colorant is past an age limit (6–24 months), per colorant and per channel, with use per month and how long the canister takes to empty.
   - **Wear prediction · all shops**: every channel with a logged piston replacement, plus every W1W channel without one, with when its piston counter reaches the replacement point (by default the median travel technicians noted at earlier replacements), and the median estimated piston travel at the "4410 … mechanical wear" errors on W1W channels.
   - **Machine overview · all shops**: one block per shop, the shops needing attention first: channels to check, pump < 10% errors, errors per 1,000 tints, tints since the last brush clean, oldest colorant, canisters at minimum, next piston replacement and old backups.
   - **Shops**: the list of backups on the file share.
3. **Open** on a shop, **Choose shop**, or **Open .mdf file** shows the full analysis of one machine: channel health, Autodrive 2, colorants (levels, colorant age and refills), errors, usage, climate and brush maintenance.

The file share path is set at the top of `Start HA Dispenser Insights.ps1` (`$SharePath`). The contacted
ticks are stored in `HA Dispenser Insights contacts.json` in the root of that share.

## Shop PCs without Intune

These PCs can't reach the file share, so they send their backup to an Azure Blob container (the "inbox") over HTTPS
(port 443). The link they get may only **create** new files: a shop can't read, list, overwrite or delete anything
there. Each upload lands as `<container>/<shop>/<yyyy-MM-dd_HHmmss>_DeviceDriverDatabase.zip`; from there you move
it to `<share>\<shop>\DeviceDriverDatabase.mdf` (unzipped).

**Once, in the Azure portal**

1. In a storage account, add a container, e.g. `dispenser-inbox` (access level: private). The storage account must
   allow *storage account key access* (Settings > Configuration), otherwise these links don't work.
2. In the container, **Access policy** > **Add policy**: an identifier such as `shops-2026`, permission **Create** only,
   an expiry date (e.g. one year). Save.
3. In the container, **Shared access tokens**: choose that stored access policy and **Generate SAS token and URL**.
   Copy the **Blob SAS URL**. This is the upload link for the shops.
4. Optional: a *Lifecycle management* rule that deletes blobs in the inbox after e.g. 30 days.

To stop all links of a policy at once (a link leaked, a shop stops), delete or shorten that access policy. A container
can have 5 policies, so you can give groups of shops their own policy.

**Per shop PC**

1. Put these four files in one folder (e.g. on a USB stick): `Backup DeviceDriverDatabase.bat`,
   `Upload DeviceDriverDatabase.ps1`, `Install backup on shop PC.cmd`, `Install backup on shop PC.ps1`.
2. Add `Upload settings.json`, a copy of `Upload settings.example.json` with the shop's folder name and the upload link.
   Never put it in this repository (it is in `.gitignore`): the repository is public.
3. On the shop PC, signed in as the user who works with the dispenser software, run `Install backup on shop PC.cmd`.
   It asks for the time of the daily backup and can run a test right away. If the PC is off at that time, the task
   runs as soon as it is on again.

The result of each run is in `C:\My-Mx files\backup_log.txt`. When the link has expired or was revoked, the log says so.
