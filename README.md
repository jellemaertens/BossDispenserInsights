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
| `Upload DeviceDriverDatabase.ps1` | For shop PCs without Intune: zips the copy and uploads it over HTTPS to the BOSS Dropbox. |
| `New Dropbox upload package.cmd` / `.ps1` | Run at BOSS: makes the install folder for one shop, with its Dropbox upload key. |
| `Install backup on shop PC.cmd` / `.ps1` | Run on the shop PC: copies the files to `C:\My-Mx files` and adds a daily task. |
| `Upload settings.example.json` | What a shop's `Upload settings.json` looks like (shop name, app key, upload key). |

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

These PCs can't reach the file share, so after each backup they zip the copy and upload it over HTTPS (port 443) to
a BOSS Dropbox account. Each upload lands as
`Dropbox\Apps\<app name>\<shop>\<yyyy-MM-dd_HHmmss>_DeviceDriverDatabase.zip`; from there you put it in
`<share>\<shop>\DeviceDriverDatabase.mdf` (unzipped). Nothing extra is installed on the shop PC.

The upload key on a shop PC only has the Dropbox permission `files.content.write`, and only in the app's own folder:
it can't read or list files, and it never touches the rest of the Dropbox. No app secret is stored on the shop PC.

**Once, on [dropbox.com/developers/apps](https://www.dropbox.com/developers/apps)** (signed in with the BOSS Dropbox account)

1. **Create app** > **Scoped access** > **App folder** > a name such as `HA Dispenser Backups`.
2. **Permissions** tab: tick `files.content.write` > **Submit**.
3. **Settings** tab: copy the **App key**.

**Per shop, at BOSS**

1. Run `New Dropbox upload package.cmd`. It asks for the app key (once; it remembers it) and the shop name, opens
   Dropbox in the browser: click **Allow** and paste the code it shows.
2. It makes `Desktop\Dropbox upload packages\<shop>\` with everything the shop PC needs, and can upload a small test
   zip right away. That folder holds the shop's upload key: never put it in this repository (it is public;
   `Upload settings*.json` is in `.gitignore`).

**On the shop PC**

1. Copy that folder to the PC (e.g. USB stick) and, signed in as the user who works with the dispenser software, run
   `Install backup on shop PC.cmd`. It asks for the time of the daily backup and can run a test right away. If the PC
   is off at that time, the task runs as soon as it is on again.

The result of each run is in `C:\My-Mx files\backup_log.txt`. If a key is revoked, the log says so. To revoke all
upload keys at once, disconnect the app under **Connected apps** in the Dropbox account settings and make new packages.
