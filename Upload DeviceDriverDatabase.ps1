# Sends the backup copy of DeviceDriverDatabase.mdf from a shop PC to BOSS, for PCs that can't reach the file share.
# It zips the copy and uploads it over HTTPS (port 443) into an Azure Blob container ("inbox"), with a link (SAS)
# that may only CREATE new files: the shop PC can't read, list, overwrite or delete anything in that container.
# At BOSS the zips are taken from the inbox and put in the shop's folder on the file share.
#
# Settings: "Upload settings.json" next to this script (see "Upload settings.example.json"):
#   { "shop": "<shop folder name>", "url": "https://<account>.blob.core.windows.net/<container>?<SAS with only c>" }
# Each upload becomes <container>/<shop>/<yyyy-MM-dd_HHmmss>_DeviceDriverDatabase.zip
#
# "Backup DeviceDriverDatabase.bat" runs this after each backup when "Upload settings.json" is next to it.
# Exit code 0 = uploaded, 1 = failed (the reason is in the log).
param(
  [string]$Source = 'C:\My-Mx files\DeviceDriverDatabase.mdf',
  [string]$Settings = (Join-Path $PSScriptRoot 'Upload settings.json'),
  [string]$Log = 'C:\My-Mx files\backup_log.txt'
)
$ErrorActionPreference = 'Stop'

function Write-Log([string]$text) {
  $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $text"
  Write-Host $line
  if ($Log) { try { Add-Content -LiteralPath $Log -Value $line } catch {} }
}

# Uploads a file as a new block blob in one request; returns $null when it worked, else the reason.
function Send-Blob([string]$uri, [string]$path) {
  $fs = [IO.File]::OpenRead($path)
  try {
    $req = [Net.HttpWebRequest]::Create($uri)
    $req.Method = 'PUT'
    $req.ContentType = 'application/zip'
    $req.ContentLength = $fs.Length
    $req.Headers.Add('x-ms-blob-type', 'BlockBlob')
    $req.Headers.Add('x-ms-version', '2021-08-06')
    # Stream the file instead of holding it in memory, and allow slow shop connections plenty of time
    $req.AllowWriteStreamBuffering = $false
    $req.Timeout = 30 * 60 * 1000
    $req.ReadWriteTimeout = 30 * 60 * 1000
    $rs = $req.GetRequestStream()
    try { $fs.CopyTo($rs, 1MB) } finally { $rs.Close() }
    $req.GetResponse().Close()
    return $null
  }
  catch [Net.WebException] {
    $resp = $_.Exception.Response
    if (-not $resp) { return $_.Exception.Message }
    $code = [int]$resp.StatusCode
    $body = try { ([IO.StreamReader]::new($resp.GetResponseStream())).ReadToEnd() } catch { '' }
    $resp.Close()
    # The blob is already there: an earlier attempt got through but its answer was lost
    if ($code -eq 409 -and $body -match 'BlobAlreadyExists') { return $null }
    $err = if ($body -match '<Code>([^<]+)</Code>') { $Matches[1] } else { $resp.StatusDescription }
    if ($code -eq 403) { return "access refused ($err): the upload link has expired or was revoked; ask BOSS for a new one" }
    return "HTTP $code ($err)"
  }
  finally { $fs.Dispose() }
}

$zip = $null
try {
  # ---- Settings ----
  if (-not (Test-Path -LiteralPath $Settings)) { throw "No settings file '$Settings'." }
  $cfg = [IO.File]::ReadAllText($Settings, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
  $shop = "$($cfg.shop)".Trim()
  $url = "$($cfg.url)".Trim()
  if (-not $shop) { $shop = $env:COMPUTERNAME }
  if ($shop -notmatch '^[^\\/:*?"<>|]+$' -or $shop -match '^\.+$') { throw "'$shop' can't be used as a shop name (no \ / : * ? `" < > |)." }
  $base, $sas = $url.Split('?', 2)
  $u = $null
  if (-not [Uri]::TryCreate($base, 'Absolute', [ref]$u) -or -not $sas -or $sas -notmatch '(^|&)sig=') { throw 'The "url" in the settings is not an upload link (https://...?...&sig=...).' }
  if ($u.Scheme -ne 'https' -and -not $u.IsLoopback) { throw 'The upload link must start with https://.' }

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
  $name = '{0}_{1}' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'), ([IO.Path]::ChangeExtension($src.Name, '.zip'))
  $uri = '{0}/{1}/{2}?{3}' -f $base.TrimEnd('/'), [Uri]::EscapeDataString($shop), [Uri]::EscapeDataString($name), $sas
  Write-Log "Uploading as $shop/$name to $($u.Host)..."
  $err = $null
  for ($try = 1; $try -le 3; $try++) {
    $err = Send-Blob $uri $zip
    if (-not $err -or $err -like 'access refused*') { break }
    Write-Log "Attempt $try failed: $err"
    if ($try -lt 3) { Start-Sleep -Seconds (30 * $try) }
  }
  if ($err) { throw "Upload failed: $err" }
  Write-Log 'Upload completed.'
  exit 0
}
catch {
  Write-Log "ERROR: $($_.Exception.Message)"
  exit 1
}
finally {
  if ($zip -and (Test-Path -LiteralPath $zip)) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
}
