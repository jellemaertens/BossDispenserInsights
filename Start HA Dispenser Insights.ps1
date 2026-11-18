# Starts HA Dispenser Insights through a small local helper.
# The dispenser software (it_pos_app.exe) keeps DeviceDriverDatabase.mdf locked while it runs, and a
# browser page can't see or stop Windows processes. This script serves the page on 127.0.0.1 and, when
# the page is about to open a .mdf file, checks whether it_pos_app.exe is running and closes it.
# It also lets the page list and read the backup copies on the file share (one folder per dispenser PC),
# and keeps the "contacted" ticks of the shop alerts in one file on the share, so the whole team sees them.
# Keep the window open while you use the page; closing it stops the helper.
param(
  [string]$Page = 'HA Dispenser Insights 7.0.html',
  [int]$Port = 8765,
  [string]$ProcessName = 'it_pos_app',
  [string]$SharePath = '\\stbosspaintsmymxddbp.file.core.windows.net\devicedriverdatabase',
  [string]$ContactsFile = '',
  [switch]$NoBrowser
)
$DbFile = 'DeviceDriverDatabase.mdf'
$ErrorActionPreference = 'Stop'
# In the root of the share, next to the shop folders (the shop list only looks at folders)
if (-not $ContactsFile -and $SharePath) { $ContactsFile = Join-Path $SharePath 'HA Dispenser Insights contacts.json' }

$pagePath = Join-Path $PSScriptRoot $Page
if (-not (Test-Path -LiteralPath $pagePath)) { throw "Can't find '$Page' next to this script." }

# Only the page served below gets this token, so other websites can't ask the helper to close the app.
$token = [guid]::NewGuid().ToString('N')

$listener = $null
foreach ($p in $Port..($Port + 20)) {
  try { $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $p); $listener.Start(); $Port = $p; break }
  catch { $listener = $null }
}
if (-not $listener) { throw "No free port between $Port and $($Port + 20)." }
$allowedHosts = @("127.0.0.1:$Port", "localhost:$Port")

function Stop-PosApp {
  $procs = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
  if ($procs.Count -eq 0) { return @{ running = $false; closed = $false } }
  Write-Host "$(Get-Date -Format HH:mm:ss)  $ProcessName.exe is running, closing it..."
  # Ask it to close normally first, then force it so the database file is released.
  foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch {} }
  foreach ($p in $procs) { try { [void]$p.WaitForExit(1500) } catch {} }
  $left = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
  if ($left.Count -gt 0) {
    try { $left | Stop-Process -Force -ErrorAction Stop }
    catch { return @{ running = $true; closed = $false; error = "Couldn't close $ProcessName.exe ($($_.Exception.Message)). Close the dispenser software yourself and try again." } }
    foreach ($p in $left) { try { [void]$p.WaitForExit(2000) } catch {} }
  }
  if (@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0) {
    return @{ running = $true; closed = $false; error = "$ProcessName.exe is still running. Close the dispenser software yourself and try again." }
  }
  Write-Host "$(Get-Date -Format HH:mm:ss)  $ProcessName.exe closed."
  return @{ running = $true; closed = $true }
}

# Folders on the share that hold a DeviceDriverDatabase.mdf
function Get-ShareList {
  if (-not $SharePath) { return @{ error = 'No file share is set up in the start script.' } }
  try {
    $items = foreach ($d in Get-ChildItem -LiteralPath $SharePath -Directory -ErrorAction Stop) {
      $f = Get-Item -LiteralPath (Join-Path $d.FullName $DbFile) -ErrorAction SilentlyContinue
      if ($f) { [ordered]@{ name = $d.Name; size = $f.Length; ts = [DateTimeOffset]::new($f.LastWriteTimeUtc).ToUnixTimeMilliseconds() } }
    }
    return @{ items = @($items) }
  }
  catch { return @{ error = "Can't open $SharePath ($($_.Exception.Message))." } }
}

# The .mdf of one share folder; only plain folder names, so a request can't climb out of the share.
function Get-ShareFile([string]$name) {
  if (-not $SharePath -or $name -notmatch '^[^\\/:*?"<>|]+$' -or $name -match '^\.+$') { return $null }
  $p = Join-Path (Join-Path $SharePath $name) $DbFile
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  Write-Host "$(Get-Date -Format HH:mm:ss)  Reading $name\$DbFile from the share..."
  # ReadWrite sharing so a backup that is writing the file at that moment doesn't block reading
  $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
  # The leading comma returns the byte[] as one object; without it PowerShell unrolls it byte by byte (very slow).
  try { $ms = [IO.MemoryStream]::new(); $fs.CopyTo($ms); return , $ms.ToArray() }
  finally { $fs.Dispose() }
}

# Contacted shops: { "<shop folder>": { "t": <ms since 1970>, "by": "<Windows user>" } }
function ConvertTo-ContactMap([string]$text) {
  $map = [ordered]@{}
  if ($text.Trim()) { foreach ($p in ($text | ConvertFrom-Json).PSObject.Properties) { $map[$p.Name] = $p.Value } }
  return $map
}
# Opens the contacts file, retrying while a colleague's helper is writing it
function Open-Contacts([string]$mode, [string]$access, [string]$share) {
  for ($i = 0; $i -lt 20; $i++) {
    try { return [IO.File]::Open($ContactsFile, $mode, $access, $share) }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { throw }
    catch [IO.IOException] { Start-Sleep -Milliseconds 150 }
  }
  throw 'The contacts file on the share is in use. Try again in a moment.'
}
function Get-Contacts {
  if (-not $ContactsFile) { throw 'No file share is set up in the start script.' }
  $fs = Open-Contacts 'Open' 'Read' 'Read'
  if (-not $fs) { return [ordered]@{} }
  try { $sr = [IO.StreamReader]::new($fs, [Text.UTF8Encoding]::new($false)); return ConvertTo-ContactMap $sr.ReadToEnd() }
  finally { $fs.Dispose() }
}
# Changes one shop only, under an exclusive lock, so two people ticking at once don't overwrite each other
function Set-Contact([string]$name, [bool]$on, [long]$at = 0) {
  if (-not $ContactsFile) { throw 'No file share is set up in the start script.' }
  $fs = Open-Contacts 'OpenOrCreate' 'ReadWrite' 'None'
  try {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $sr = [IO.StreamReader]::new($fs, $utf8, $false, 4096, $true)
    $map = ConvertTo-ContactMap $sr.ReadToEnd()
    # $at: an earlier contact time (ms) when a tick kept in the browser moves to the share; never in the future
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($on) { $map[$name] = [ordered]@{ t = $(if ($at -gt 0 -and $at -lt $now) { $at } else { $now }); by = $env:USERNAME } }
    else { $map.Remove($name) }
    $bytes = $utf8.GetBytes((ConvertTo-Json -InputObject $map -Compress -Depth 4))
    $fs.SetLength(0); $fs.Write($bytes, 0, $bytes.Length)
    Write-Host "$(Get-Date -Format HH:mm:ss)  $name marked as $(if ($on) { 'contacted' } else { 'not contacted' })."
    return $map
  }
  finally { $fs.Dispose() }
}

function Send-Response($stream, [int]$code, [string]$type, [byte[]]$body) {
  $reason = @{ 200 = 'OK'; 403 = 'Forbidden'; 404 = 'Not Found'; 500 = 'Internal Server Error' }[$code]
  $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $code $reason`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n")
  $stream.Write($head, 0, $head.Length)
  $stream.Write($body, 0, $body.Length)
}

function Invoke-Request($client) {
  $stream = $client.GetStream()
  $stream.ReadTimeout = 5000
  $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
  $first = $reader.ReadLine()
  if (-not $first) { return }
  $method, $target = $first.Split(' ')[0, 1]
  $path, $query = $target.Split('?', 2)
  $q = @{}
  if ($query) { foreach ($kv in $query.Split('&')) { $k, $v = $kv.Split('=', 2); $q[[Uri]::UnescapeDataString($k)] = [Uri]::UnescapeDataString(($v -replace '\+', ' ')) } }
  $headers = @{}
  while ($line = $reader.ReadLine()) {
    $i = $line.IndexOf(':')
    if ($i -gt 0) { $headers[$line.Substring(0, $i).Trim().ToLower()] = $line.Substring($i + 1).Trim() }
  }
  $utf8 = [Text.UTF8Encoding]::new($false)

  # Refuse requests that arrive under another host name (DNS rebinding).
  if ($allowedHosts -notcontains $headers['host']) { Send-Response $stream 403 'text/plain' $utf8.GetBytes('Forbidden'); return }

  if ($method -eq 'GET' -and $path -eq '/') {
    $html = [IO.File]::ReadAllText($pagePath, $utf8)
    $share = ConvertTo-Json ([string]$SharePath) -Compress
    $html = $html.Replace('<meta charset="utf-8">', "<meta charset=`"utf-8`">`n<script>window.POS_HELPER = { token: '$token', share: $share };</script>")
    Send-Response $stream 200 'text/html; charset=utf-8' $utf8.GetBytes($html)
  }
  elseif ($headers['x-helper-token'] -ne $token) { Send-Response $stream 403 'text/plain' $utf8.GetBytes('Forbidden') }
  elseif ($method -eq 'POST' -and $path -eq '/pos/stop') {
    $result = Stop-PosApp
    Send-Response $stream 200 'application/json' $utf8.GetBytes(($result | ConvertTo-Json -Compress))
  }
  elseif ($method -eq 'GET' -and $path -eq '/share/list') {
    Send-Response $stream 200 'application/json' $utf8.GetBytes((Get-ShareList | ConvertTo-Json -Compress -Depth 4))
  }
  elseif ($method -eq 'GET' -and $path -eq '/share/file') {
    try { $bytes = Get-ShareFile $q['m'] }
    catch { Send-Response $stream 500 'text/plain' $utf8.GetBytes("Couldn't read the file ($($_.Exception.Message))."); return }
    if ($null -eq $bytes) { Send-Response $stream 404 'text/plain' $utf8.GetBytes("There is no $DbFile in that folder."); return }
    Send-Response $stream 200 'application/octet-stream' $bytes
  }
  elseif ($path -eq '/contacts' -and ($method -eq 'GET' -or $method -eq 'POST')) {
    $name = $q['m']
    try {
      if ($method -eq 'GET') { $res = @{ items = Get-Contacts } }
      elseif ($name -notmatch '^[^\\/:*?"<>|]+$' -or $name -match '^\.+$') { $res = @{ error = 'That is not a shop folder name.' } }
      else { $res = @{ items = Set-Contact $name ($q['on'] -eq '1') $(if ($q['t'] -match '^\d{1,15}$') { [long]$q['t'] } else { 0 }) } }
    }
    catch { $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }; $res = @{ error = "Couldn't use the contacts file on the share ($($ex.Message))" } }
    Send-Response $stream 200 'application/json' $utf8.GetBytes((ConvertTo-Json -InputObject $res -Compress -Depth 5))
  }
  else { Send-Response $stream 404 'text/plain' $utf8.GetBytes('Not found') }
}

$url = "http://127.0.0.1:$Port/"
$Host.UI.RawUI.WindowTitle = 'HA Dispenser Insights helper'
Write-Host "HA Dispenser Insights is running at $url"
Write-Host 'Keep this window open while you use the page. Close it to stop.'
if (-not $NoBrowser) { Start-Process $url }

try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try { Invoke-Request $client }
    catch { Write-Warning $_.Exception.Message }
    finally { $client.Close() }
  }
}
finally { $listener.Stop() }
