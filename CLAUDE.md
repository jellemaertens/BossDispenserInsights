# HA Dispenser Insights

- This folder is a clone of https://github.com/jellemaertens/BossDispenserInsights (branch `main`).
  GitHub Pages publishes `main` as is, so every push updates the live site.
- A Stop hook in `.claude/settings.local.json` commits and pushes all changes at the end of each Claude turn.
  Don't commit or push by hand unless asked; leave nothing half-done at the end of a turn, because it gets published.
- The current page is `HA Dispenser Insights 7.0.html`. When a new version is made, also point `index.html`
  (both links) and `$Page` in `Start HA Dispenser Insights.ps1` at it.
- On GitHub Pages the page runs without the local helper: no closing of `it_pos_app.exe`, the share is read
  through the browser's folder picker, and contacted ticks stay in that browser. Keep that mode working.
