# Sends the backup copy of DeviceDriverDatabase.mdf from a shop PC to BOSS, for PCs that can't reach the file share.
# It zips the copy and uploads it over HTTPS (port 443) into the app folder of a BOSS Dropbox account
# (Dropbox\Apps\<app name>\<shop>\<yyyy-MM-dd_HHmmss>_DeviceDriverDatabase.zip). At BOSS the zips are taken from there
# and put in the shop's folder on the file share.
#
# Settings: "Upload settings.json" next to this script, made by "New Dropbox upload package.cmd":
#   { "shop": "<shop folder name>", "app_key": "<Dropbox app key>", "refresh_token": "<upload key>" }
# The upload key only has the Dropbox permission files.content.write, in the app folder only: it can't read or list files.
#
# "Backup DeviceDriverDatabase.bat" runs this after each backup when "Upload settings.json" is next to it.
# Exit code 0 = uploaded, 1 = failed (the reason is in the log).
param(
  [string]$Source = 'C:\My-Mx files\DeviceDriverDatabase.mdf',
  [string]$Settings = (Join-Path $PSScriptRoot 'Upload settings.json'),
  [string]$Log = 'C:\My-Mx files\backup_log.txt',
  # Only changed for tests
  [string]$TokenUrl = 'https://api.dropboxapi.com/oauth2/token',
  [string]$ContentUrl = 'https://content.dropboxapi.com/2/files',
  [int]$ChunkSize = 32MB
)
$ErrorActionPreference = 'Stop'

function Write-Log([string]$text) {
  $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $text"
  Write-Host $line
  if ($Log) { try { Add-Content -LiteralPath $Log -Value $line } catch {} }
}

# One HTTP request; returns @{ code = <status, 0 = no connection>; text = <answer> }
function Invoke-Http([string]$Url, [hashtable]$Headers, [string]$ContentType, [byte[]]$Body, [int]$Count = 0) {
  $req = [Net.HttpWebRequest]::Create($Url)
  $req.Method = 'POST'
  $req.Timeout = 10 * 60 * 1000
  $req.ReadWriteTimeout = 10 * 60 * 1000
  $req.AllowWriteStreamBuffering = $false
  if ($Headers) { foreach ($k in $Headers.Keys) { $req.Headers.Add($k, $Headers[$k]) } }
  if ($ContentType) { $req.ContentType = $ContentType }
  $req.ContentLength = $Count
  try {
    $rs = $req.GetRequestStream()
    try { if ($Count -gt 0) { $rs.Write($Body, 0, $Count) } } finally { $rs.Close() }
    $resp = $req.GetResponse()
  }
  catch [Net.WebException] {
    $resp = $_.Exception.Response
    if (-not $resp) { return @{ code = 0; text = $_.Exception.Message } }
  }
  try {
    $text = try { ([IO.StreamReader]::new($resp.GetResponseStream())).ReadToEnd() } catch { '' }
    return @{ code = [int]$resp.StatusCode; text = $text }
  }
  finally { $resp.Close() }
}

# JSON for the Dropbox-API-Arg header, which must be plain ASCII
function ConvertTo-ApiArg($obj) {
  $json = ConvertTo-Json -InputObject $obj -Compress -Depth 5
  return [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

# A short-lived access token from the upload key; $null + $script:fatal when the key itself is refused
function Get-AccessToken($cfg) {
  $body = [Text.Encoding]::ASCII.GetBytes(('grant_type=refresh_token&refresh_token={0}&client_id={1}' -f [Uri]::EscapeDataString($cfg.refresh_token), [Uri]::EscapeDataString($cfg.app_key)))
  $r = Invoke-Http $TokenUrl @{} 'application/x-www-form-urlencoded' $body $body.Length
  if ($r.code -eq 200) { return ($r.text | ConvertFrom-Json).access_token }
  if ($r.code -eq 400 -and $r.text -match 'invalid_grant|invalid_client') {
    $script:fatal = $true
    throw 'the upload key was refused by Dropbox (revoked, or the app was removed); make a new package with "New Dropbox upload package.cmd"'
  }
  throw "no access token from Dropbox (HTTP $($r.code) $($r.text))"
}

# Calls one Dropbox upload endpoint; returns the parsed answer or throws
function Invoke-Dropbox([string]$token, [string]$endpoint, $arg, [byte[]]$data, [int]$count = 0) {
  $h = @{ 'Authorization' = "Bearer $token"; 'Dropbox-API-Arg' = (ConvertTo-ApiArg $arg) }
  $r = Invoke-Http "$ContentUrl/$endpoint" $h 'application/octet-stream' $data $count
  if ($r.code -eq 200) { return $(if ($r.text) { $r.text | ConvertFrom-Json }) }
  if ($r.code -eq 401 -and $r.text -match 'missing_scope') {
    $script:fatal = $true
    throw 'the upload key lacks the Dropbox permission files.content.write; tick it in the app and make a new package'
  }
  if ($r.code -eq 0) { throw "no connection with Dropbox ($($r.text))" }
  throw "Dropbox $endpoint answered HTTP $($r.code) $($r.text)"
}

# Upload session: start, the file in chunks, finish (works for any size; a single upload stops at 150 MB)
function Send-ToDropbox($cfg, [string]$file, [string]$path) {
  $token = Get-AccessToken $cfg
  $session = (Invoke-Dropbox $token 'upload_session/start' @{ close = $false } $null 0).session_id
  $fs = [IO.File]::OpenRead($file)
  try {
    $buf = [byte[]]::new($ChunkSize)
    $offset = [long]0
    while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
      [void](Invoke-Dropbox $token 'upload_session/append_v2' @{ cursor = @{ session_id = $session; offset = $offset }; close = $false } $buf $n)
      $offset += $n
    }
  }
  finally { $fs.Dispose() }
  $commit = [ordered]@{ path = $path; mode = 'add'; autorename = $true; mute = $true }
  return Invoke-Dropbox $token 'upload_session/finish' @{ cursor = @{ session_id = $session; offset = $offset }; commit = $commit } $null 0
}

$zip = $null
try {
  # ---- Settings ----
  if (-not (Test-Path -LiteralPath $Settings)) { throw "No settings file '$Settings'." }
  $cfg = [IO.File]::ReadAllText($Settings, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
  $shop = "$($cfg.shop)".Trim()
  if (-not $shop) { $shop = $env:COMPUTERNAME }
  if ($shop -notmatch '^[^\\/:*?"<>|]+$' -or $shop -match '^\.+$') { throw "'$shop' can't be used as a shop name (no \ / : * ? `" < > |)." }
  if (-not "$($cfg.app_key)".Trim() -or -not "$($cfg.refresh_token)".Trim()) { throw 'The settings miss "app_key" or "refresh_token"; make them with "New Dropbox upload package.cmd".' }

  # ---- Zip the copy (a .mdf shrinks a lot, so the upload is much faster) ----
  if (-not (Test-Path -LiteralPath $Source)) { throw "There is no backup copy '$Source'." }
  $src = Get-Item -LiteralPath $Source
  Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
  $zip = Join-Path $env:TEMP "DeviceDriverDatabase_upload_$PID.zip"
  if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
  $archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
  # The entry keeps the file's own date
  try { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $src.FullName, $src.Name, 'Optimal') }
  finally { $archive.Dispose() }
  $zipSize = (Get-Item -LiteralPath $zip).Length
  Write-Log ("Zipped {0} ({1:N1} MB -> {2:N1} MB)." -f $src.Name, ($src.Length / 1MB), ($zipSize / 1MB))

  # ---- Upload ----
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $path = '/{0}/{1}_{2}' -f $shop, (Get-Date -Format 'yyyy-MM-dd_HHmmss'), [IO.Path]::ChangeExtension($src.Name, '.zip')
  Write-Log "Uploading to Dropbox as $path..."
  $script:fatal = $false
  $err = $null
  for ($try = 1; $try -le 3; $try++) {
    try { $meta = Send-ToDropbox $cfg $zip $path; $err = $null; break }
    catch { $err = $_.Exception.Message }
    if ($script:fatal) { break }
    Write-Log "Attempt $try failed: $err"
    if ($try -lt 3) { Start-Sleep -Seconds (30 * $try) }
  }
  if ($err) { throw "Upload failed: $err" }
  Write-Log "Upload completed$(if ($meta.path_display) { " ($($meta.path_display))" })."
  exit 0
}
catch {
  Write-Log "ERROR: $($_.Exception.Message)"
  exit 1
}
finally {
  if ($zip -and (Test-Path -LiteralPath $zip)) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
}
