# Local proxy + parser for ECI Tamil Nadu (S22) results.
# Run: pwsh -ExecutionPolicy Bypass -File serve.ps1
# Then open http://localhost:8081/

$ErrorActionPreference = 'Stop'

$BASE = 'https://results.eci.gov.in/ResultAcGenMay2026'
$REFERER = "$BASE/partywiseresult-S22.htm"
$DASH_FILE = Join-Path $PSScriptRoot 'dashboard.html'
$CACHE_TTL = 45     # seconds
$LISTEN_URL = 'http://localhost:8081/'

$script:cache = $null
$script:cacheTime = [DateTime]::MinValue
$script:session = $null
$script:sessionTime = [DateTime]::MinValue

function Get-Headers {
  @{
    'User-Agent'                = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    'Accept'                    = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    'Accept-Language'           = 'en-US,en;q=0.9'
    'Sec-Fetch-Dest'            = 'document'
    'Sec-Fetch-Mode'            = 'navigate'
    'Sec-Fetch-Site'            = 'none'
    'Sec-Fetch-User'            = '?1'
    'Upgrade-Insecure-Requests' = '1'
  }
}

function Ensure-Session {
  $age = ([DateTime]::Now - $script:sessionTime).TotalMinutes
  if ($null -eq $script:session -or $age -gt 8) {
    Write-Host '[session] warming up...'
    $script:session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $null = Invoke-WebRequest -Uri $REFERER -Headers (Get-Headers) -WebSession $script:session -UseBasicParsing
    $script:sessionTime = [DateTime]::Now
  }
}

function Fetch-Url($url) {
  Ensure-Session
  $h = Get-Headers
  $h['Referer'] = $REFERER
  return (Invoke-WebRequest -Uri $url -Headers $h -WebSession $script:session -UseBasicParsing).Content
}

# ---------- parsers ----------

function Parse-PartyTotals($html) {
  $flat = $html -replace '\s+', ' '
  $rows = [regex]::Matches($flat, '<tr class="tr">\s*<td style="text-align:left">([^<]+)</td>\s*<td style="text-align:right">\s*(?:<a [^>]+>)?([0-9]+)(?:</a>)?\s*</td>\s*<td style="text-align:right">\s*(?:<a [^>]+>)?([0-9]+)(?:</a>)?\s*</td>\s*<td style="text-align:right">\s*(?:<a [^>]+>)?([0-9]+)(?:</a>)?\s*</td>', 'Singleline')
  $list = @()
  foreach ($m in $rows) {
    $full = $m.Groups[1].Value.Trim()
    $code = ''
    if ($full -match ' - ([A-Za-z0-9()]+)\s*$') { $code = $matches[1] }
    $list += [pscustomobject]@{
      name    = ($full -replace ' - [A-Za-z0-9()]+\s*$', '').Trim()
      code    = $code
      won     = [int]$m.Groups[2].Value
      leading = [int]$m.Groups[3].Value
      total   = [int]$m.Groups[4].Value
    }
  }
  return $list
}

function Parse-LastUpdated($html) {
  $m = [regex]::Match($html, 'Last Updated at\s*<span>([^<]+)</span>')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return ''
}

function Parse-Constituencies($html) {
  $flat = $html -replace '\s+', ' '
  $rowPat = "<tr[^>]*>\s*<td[^>]*align=['""]left['""][^>]*>([^<]+)</td>\s*<td[^>]*align=['""]right['""][^>]*>(\d+)</td>\s*(.*?)\s*<td[^>]*align=['""]right['""][^>]*>(\d+)</td>\s*<td[^>]*align=['""]right['""][^>]*>(\d+/\d+)</td>\s*<td[^>]*align=['""]left['""][^>]*>([^<]+)</td>\s*</tr>"
  $rows = [regex]::Matches($flat, $rowPat, 'Singleline')
  $out = @()
  foreach ($r in $rows) {
    $mid = $r.Groups[3].Value
    $lc = [regex]::Match($mid, "<td[^>]*align=['""]left['""][^>]*>([^<]+)</td>")
    $lp = [regex]::Match($mid, "<table[^>]*>.*?<td[^>]*align=['""]left['""][^>]*>([^<]+)</td>")
    $tc = [regex]::Match($mid, "<td[^>]*align=['""]left['""][^>]*>([^<]+)</td>\s*<td>\s*<table[^>]*>.*?<td[^>]*align=['""]left['""][^>]*>([^<]+)</td>")
    $out += [pscustomobject]@{
      name       = $r.Groups[1].Value.Trim()
      no         = [int]$r.Groups[2].Value
      leadCand   = $(if ($lc.Success) { $lc.Groups[1].Value.Trim() } else { '' })
      leadParty  = $(if ($lp.Success) { $lp.Groups[1].Value.Trim() } else { '' })
      trailCand  = $(if ($tc.Success) { $tc.Groups[1].Value.Trim() } else { '' })
      trailParty = $(if ($tc.Success) { $tc.Groups[2].Value.Trim() } else { '' })
      margin     = [int]$r.Groups[4].Value
      round      = $r.Groups[5].Value
      status     = $r.Groups[6].Value.Trim()
    }
  }
  return $out
}

# ---------- vote share (from chart js on partywise page) ----------
function Parse-VoteShare($html) {
  # second var xValues = [...] block has the pie chart
  $piMatch = [regex]::Match($html, "// Pi Charts.*?var xValues = \[(.*?)\];.*?var yValues = \[(.*?)\];", 'Singleline')
  if (-not $piMatch.Success) { return @() }
  $xRaw = $piMatch.Groups[1].Value
  $yRaw = $piMatch.Groups[2].Value
  $labels = [regex]::Matches($xRaw, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
  $vals = $yRaw.Split(',') | Where-Object { $_.Trim() -match '^\d+$' } | ForEach-Object { [int64]$_.Trim() }
  $share = @()
  for ($i = 0; $i -lt $labels.Count; $i++) {
    $lbl = $labels[$i]
    $code = $lbl; $pct = $null
    $m = [regex]::Match($lbl, '^(.+?)\{([0-9.]+)%\}$')
    if ($m.Success) { $code = $m.Groups[1].Value; $pct = [double]$m.Groups[2].Value }
    $share += [pscustomobject]@{ code = $code; percent = $pct; votes = $vals[$i] }
  }
  return $share
}

# ---------- aggregate fetch ----------

function Fetch-All {
  Write-Host '[fetch] starting...'
  $startMs = [DateTime]::Now

  $partyHtml = Fetch-Url "$BASE/partywiseresult-S22.htm"
  $totals = Parse-PartyTotals $partyHtml
  $lastUpd = Parse-LastUpdated $partyHtml
  $voteShare = Parse-VoteShare $partyHtml

  $allHtml = ''
  for ($i = 1; $i -le 12; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $allHtml += Fetch-Url "$BASE/statewiseS22$i.htm"
    }
    catch {
      # if a page errors, ignore and continue (some elections show fewer pages)
      Write-Host "[fetch] page $($i) error: $($_.Exception.Message)"
    }
  }
  $constits = Parse-Constituencies $allHtml

  $elapsed = ([DateTime]::Now - $startMs).TotalMilliseconds
  Write-Host "[fetch] done in $([int]$elapsed) ms — parties=$($totals.Count) constits=$($constits.Count) lastUpd=$lastUpd"

  return [pscustomobject]@{
    state          = 'Tamil Nadu'
    election       = 'General Election to Assembly Constituencies, May 2026'
    totalSeats     = 234
    majority       = 118
    lastUpdatedECI = $lastUpd
    fetchedAt      = (Get-Date).ToString('o')
    parties        = $totals
    constituencies = $constits
    voteShare      = $voteShare
  }
}

function Get-Data($force = $false) {
  $age = ([DateTime]::Now - $script:cacheTime).TotalSeconds
  if ($force -or $null -eq $script:cache -or $age -gt $CACHE_TTL) {
    try {
      $script:cache = Fetch-All
      $script:cacheTime = [DateTime]::Now
    }
    catch {
      Write-Host "[fetch] FAILED: $($_.Exception.Message)"
      # bust the session in case it expired
      $script:session = $null
      if ($null -eq $script:cache) { throw }
    }
  }
  return $script:cache
}

# ---------- HTTP server ----------

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($LISTEN_URL)
try {
  $listener.Start()
}
catch {
  Write-Host "Could not bind $LISTEN_URL — $_.Exception.Message"
  Write-Host "If you see 'Access is denied', try running as administrator OR change the port."
  exit 1
}

Write-Host ""
Write-Host "  ╔════════════════════════════════════════════════╗"
Write-Host "  ║  ECI Verdict 2026 — Tamil Nadu live dashboard  ║"
Write-Host "  ║  Open: http://localhost:8081/                  ║"
Write-Host "  ║  Press Ctrl+C to stop                          ║"
Write-Host "  ╚════════════════════════════════════════════════╝"
Write-Host ""

# warm cache once on startup so the first browser request is instant
try { $null = Get-Data } catch { Write-Host "Warm cache failed (will retry on first request)." }

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response
    $path = $req.Url.AbsolutePath
    Write-Host "[$([DateTime]::Now.ToString('HH:mm:ss'))] $($req.HttpMethod) $path"

    try {
      $res.Headers['Access-Control-Allow-Origin'] = '*'
      $res.Headers['Cache-Control'] = 'no-store'

      if ($path -eq '/' -or $path -eq '/dashboard.html') {
        $body = Get-Content -Raw $DASH_FILE
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $res.ContentType = 'text/html; charset=utf-8'
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
      }
      elseif ($path -eq '/api/data') {
        $data = Get-Data $false
        $age = [int]([DateTime]::Now - $script:cacheTime).TotalSeconds
        $res.Headers['X-Cache-Age'] = $age.ToString()
        $body = $data | ConvertTo-Json -Depth 10 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $res.ContentType = 'application/json; charset=utf-8'
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
      }
      elseif ($path -eq '/api/refresh') {
        $data = Get-Data $true
        $body = $data | ConvertTo-Json -Depth 10 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $res.ContentType = 'application/json; charset=utf-8'
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
      }
      else {
        $res.StatusCode = 404
        $body = '{"error":"not found"}'
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $res.ContentType = 'application/json'
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
      }
    }
    catch {
      $res.StatusCode = 500
      $errMsg = $_.Exception.Message
      $err = @{ error = "$errMsg" } | ConvertTo-Json
      $bytes = [Text.Encoding]::UTF8.GetBytes($err)
      try { $res.OutputStream.Write($bytes, 0, $bytes.Length) } catch {}
      Write-Host "[err] $errMsg"
    }
    finally {
      try { $res.OutputStream.Close() } catch {}
    }
  }
}
finally {
  $listener.Stop()
  $listener.Close()
}
