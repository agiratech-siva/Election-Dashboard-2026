$html = Get-Content -Raw "C:\workspace\busoft\eci\statewise_all.html"
$flat = $html -replace '\s+', ' '

$rowPat = "<tr><td align='left'>([^<]+)</td><td align='right'>(\d+)</td>(.*?)<td align='right'>(\d+)</td>\s*<td align='right'>(\d+/\d+)</td>\s*<td align='left'>([^<]+)</td></tr>"
$rows = [regex]::Matches($flat, $rowPat, 'Singleline')
Write-Host "Rows matched: $($rows.Count)"

$results = @()
foreach ($r in $rows) {
  $name   = $r.Groups[1].Value.Trim()
  $no     = [int]$r.Groups[2].Value
  $mid    = $r.Groups[3].Value
  $margin = [int]$r.Groups[4].Value
  $round  = $r.Groups[5].Value
  $status = $r.Groups[6].Value.Trim()

  # leading candidate: first <td align='left'>X</td> in mid
  $lc = [regex]::Match($mid, "<td align='left'>([^<]+)</td>")
  $leadCand = if ($lc.Success) { $lc.Groups[1].Value.Trim() } else { '' }

  # leading party: first <table><tbody><tr><td align='left'>X</td>
  $lp = [regex]::Match($mid, "<table><tbody><tr><td align='left'>([^<]+)</td>")
  $leadParty = if ($lp.Success) { $lp.Groups[1].Value.Trim() } else { '' }

  # trailing candidate: <td align='left'>X</td><td><table>
  $tc = [regex]::Match($mid, "<td align='left'>([^<]+)</td>\s*<td>\s*<table><tbody><tr><td align='left'>([^<]+)</td>")
  $trailCand  = if ($tc.Success) { $tc.Groups[1].Value.Trim() } else { '' }
  $trailParty = if ($tc.Success) { $tc.Groups[2].Value.Trim() } else { '' }

  $results += [pscustomobject]@{
    name=$name; no=$no
    leadCand=$leadCand; leadParty=$leadParty
    trailCand=$trailCand; trailParty=$trailParty
    margin=$margin; round=$round; status=$status
  }
}

Write-Host "`nClosest 12 by margin:"
$results | Sort-Object margin | Select-Object -First 12 | Format-Table no, name, margin, leadParty, trailParty -AutoSize

$results | ConvertTo-Json -Depth 4 -Compress | Out-File -FilePath "C:\workspace\busoft\eci\seats.json" -Encoding utf8
Write-Host "`nWrote seats.json with $($results.Count) rows"
