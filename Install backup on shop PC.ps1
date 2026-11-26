# Sets up the daily backup + upload on a shop PC that isn't managed by Intune.
# "New Dropbox upload package.cmd" makes a folder per shop with all files this needs (the backup + upload scripts and the
# shop's Upload settings.json). Copy it to the shop PC (e.g. USB stick) and run "Install backup on shop PC.cmd" there,
# signed in as the user who works with the dispenser software.
# It copies them to C:\My-Mx files and adds a daily task "Backup DeviceDriverDatabase" for this user. When the PC is off
# at that time, the task runs as soon as the PC is on again.
param(
  [string]$Dest = 'C:\My-Mx files',
  [string]$At = '',
  [string]$TaskName = 'Backup DeviceDriverDatabase'
)
$ErrorActionPreference = 'Stop'
$files = 'Backup DeviceDriverDatabase.bat', 'Upload DeviceDriverDatabase.ps1', 'Upload settings.json'

try {
  foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $f))) { throw "'$f' is missing next to this script." }
  }
  # Check the settings before anything is installed
  $cfg = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Upload settings.json'), [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
  if (-not "$($cfg.shop)".Trim()) { throw 'Fill in "shop" in Upload settings.json.' }
  if (-not "$($cfg.app_key)".Trim() -or -not "$($cfg.refresh_token)".Trim()) { throw 'Upload settings.json has no Dropbox upload key; make the package with "New Dropbox upload package.cmd".' }
  Write-Host "Shop: $($cfg.shop)"

  if (-not $At) { $At = Read-Host 'Time of the daily backup, HH:mm (Enter = 07:30)' }
  if (-not $At) { $At = '07:30' }
  if ($At -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { throw "'$At' is not a time like 07:30." }

  if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest | Out-Null }
  foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination $Dest -Force }
  Write-Host "Files copied to $Dest."

  $action = New-ScheduledTaskAction -Execute (Join-Path $Dest 'Backup DeviceDriverDatabase.bat') -WorkingDirectory $Dest
  $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($At.PadLeft(5, '0'), 'HH:mm', $null))
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
  # Runs as this user, on the desktop, so the dispenser software comes back where the user can see it
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
  Write-Host "Task '$TaskName' runs every day at $At for $env:USERNAME."

  $answer = Read-Host 'Run a backup + upload now as a test? It closes the dispenser software for a moment (Y/N)'
  if ($answer -match '^[YyJj]') {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Started. The result is in $Dest\backup_log.txt."
  }
}
catch {
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
