# Makes the install package for one shop PC without Intune: a folder with the backup + upload scripts and the shop's
# "Upload settings.json" (shop name + a Dropbox upload key). Copy that folder to the shop PC (e.g. USB stick) and run
# "Install backup on shop PC.cmd" there.
#
# Once beforehand, on https://www.dropbox.com/developers/apps (signed in with the BOSS Dropbox account):
#   Create app > Scoped access > App folder > a name such as "HA Dispenser Backups".
#   Permissions tab: tick files.content.write > Submit. Settings tab: copy the App key.
# The upload key this script asks for only gets files.content.write (upload, no reading or listing) and only in
# Dropbox\Apps\<app name>. Uploads land in Dropbox\Apps\<app name>\<shop>\.
#
# The package holds the upload key: don't save it in the GitHub folder of this tool (that is public).
param(
  [string]$AppKey = '',
  [string]$Shop = '',
  [string]$OutDir = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Dropbox upload packages')
)
$ErrorActionPreference = 'Stop'
$files = 'Backup DeviceDriverDatabase.bat', 'Upload DeviceDriverDatabase.ps1', 'Install backup on shop PC.cmd', 'Install backup on shop PC.ps1'

function ConvertTo-Base64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }

try {
  foreach ($f in $files) { if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $f))) { throw "'$f' is missing next to this script." } }
  if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

  # The app key isn't secret; remember it for the next shop
  $keyFile = Join-Path $OutDir 'Dropbox app key.txt'
  if (-not $AppKey -and (Test-Path -LiteralPath $keyFile)) { $AppKey = (Get-Content -LiteralPath $keyFile -TotalCount 1).Trim() }
  if (-not $AppKey) { $AppKey = (Read-Host 'Dropbox app key (Settings tab of the app on dropbox.com/developers)').Trim() }
  if ($AppKey -notmatch '^[A-Za-z0-9]+$') { throw "'$AppKey' doesn't look like a Dropbox app key." }
  Set-Content -LiteralPath $keyFile -Value $AppKey

  if (-not $Shop) { $Shop = (Read-Host 'Shop name (the shop''s folder name on the file share)').Trim() }
  if ($Shop -notmatch '^[^\\/:*?"<>|]+$' -or $Shop -match '^\.+$') { throw "'$Shop' can't be used as a shop name (no \ / : * ? `" < > |)." }

  # ---- Dropbox sign-in with PKCE, so the shop PC never needs the app secret ----
  $rnd = [byte[]]::new(48); [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rnd)
  $verifier = ConvertTo-Base64Url $rnd
  $challenge = ConvertTo-Base64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
  $authUrl = 'https://www.dropbox.com/oauth2/authorize?client_id={0}&response_type=code&token_access_type=offline&scope=files.content.write&code_challenge={1}&code_challenge_method=S256' -f $AppKey, $challenge
  Write-Host ''
  Write-Host 'The browser opens Dropbox. Sign in with the BOSS Dropbox account, click Allow and copy the code it shows.'
  Write-Host "(If no browser opens: $authUrl)"
  Start-Process $authUrl
  $code = (Read-Host 'Paste the code here').Trim()
  if (-not $code) { throw 'No code entered.' }

  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  try {
    $tok = Invoke-RestMethod -Method Post -Uri 'https://api.dropboxapi.com/oauth2/token' -ContentType 'application/x-www-form-urlencoded' -Body @{
      grant_type = 'authorization_code'; code = $code; client_id = $AppKey; code_verifier = $verifier
    }
  }
  catch { throw "Dropbox refused the code ($($_.ErrorDetails.Message)). Run this again and paste the new code right away." }
  if (-not $tok.refresh_token) { throw 'Dropbox gave no upload key (refresh token).' }
  if ($tok.scope -and $tok.scope -notmatch 'files\.content\.write') { throw 'The key lacks files.content.write: tick it on the Permissions tab of the app, then run this again.' }

  # ---- The package ----
  $pkg = Join-Path $OutDir $Shop
  if (-not (Test-Path -LiteralPath $pkg)) { New-Item -ItemType Directory -Path $pkg | Out-Null }
  foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination $pkg -Force }
  $settings = Join-Path $pkg 'Upload settings.json'
  $json = ConvertTo-Json -InputObject ([ordered]@{ shop = $Shop; app_key = $AppKey; refresh_token = $tok.refresh_token })
  [IO.File]::WriteAllText($settings, $json, [Text.UTF8Encoding]::new($false))
  Write-Host ''
  Write-Host "Package ready: $pkg" -ForegroundColor Green

  # ---- Optional test: a tiny file through the real upload script ----
  $answer = Read-Host "Test the key now? It uploads a small test zip to Dropbox\Apps\<app>\$Shop (Y/N)"
  if ($answer -match '^[YyJj]') {
    $test = Join-Path $env:TEMP 'Connection test.txt'
    Set-Content -LiteralPath $test -Value "Upload test from $env:COMPUTERNAME at $(Get-Date -Format s)"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pkg 'Upload DeviceDriverDatabase.ps1') -Source $test -Settings $settings -Log (Join-Path $env:TEMP 'Dropbox upload test.log')
    if ($LASTEXITCODE -eq 0) { Write-Host 'Test OK. You can delete the test zip in Dropbox.' -ForegroundColor Green } else { Write-Host 'Test failed, see above.' -ForegroundColor Red }
    Remove-Item -LiteralPath $test -Force -ErrorAction SilentlyContinue
  }
  Start-Process explorer.exe $pkg
}
catch {
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
