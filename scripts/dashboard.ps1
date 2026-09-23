[CmdletBinding()]
param(
  [string]$EvidenceRoot,
  [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $EvidenceRoot) {
  $projectRoot = Split-Path -Parent $PSScriptRoot
  $EvidenceRoot = Join-Path $projectRoot 'evidence'
}
if (-not $OutputPath) { $OutputPath = Join-Path $EvidenceRoot 'dashboard.html' }

$snapshotPath = Join-Path $EvidenceRoot 'snapshot.json'
$snapshot = $null
$snapshotProblem = $null
try {
  if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
    $snapshotProblem = 'Snapshot file is missing.'
  } else {
    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json
  }
} catch {
  $snapshot = $null
  $snapshotProblem = 'Snapshot file could not be read or parsed.'
}

function Html([object]$Value) {
  if ($null -eq $Value) { return '' }
  return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Read-Coverage([object]$Source, [string]$Name) {
  if ($null -eq $Source) { return $null }
  $property = $Source.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Get-ObservedRows([object]$Source, [string]$Name) {
  if ($null -eq $Source) { return @() }
  $property = $Source.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return @() }
  return @($property.Value)
}

$capturedLabel = 'UNKNOWN'
$freshness = 'UNKNOWN — snapshot time unavailable.'
$capturedAt = $null
$capturedValue = if ($snapshot) { Read-Coverage $snapshot 'capturedAtUtc' } else { $null }
if ($capturedValue) {
  try {
    $capturedAt = [DateTimeOffset]::Parse([string]$capturedValue).ToUniversalTime()
    $age = [DateTimeOffset]::UtcNow - $capturedAt
    if ($age.TotalMinutes -lt -5) {
      $freshness = 'UNKNOWN — snapshot time is in the future.'
    } elseif ($age.TotalMinutes -le 30) {
      $freshness = ('FRESH — captured {0:N0} minutes ago; scheduled cadence is 15 minutes.' -f [Math]::Max(0, $age.TotalMinutes))
    } elseif ($age.TotalHours -le 24) {
      $freshness = ('STALE — captured {0:N1} hours ago.' -f $age.TotalHours)
    } else {
      $freshness = ('STALE — captured {0:N1} days ago.' -f $age.TotalDays)
    }
    $capturedLabel = $capturedAt.ToString('yyyy-MM-dd HH:mm:ss UTC')
  } catch {
    $freshness = 'UNKNOWN — snapshot time is invalid.'
  }
}

$coverageNames = @('processes', 'tcpListeners', 'udpEndpoints', 'services', 'tasks', 'startup')
$coverageOkCount = 0
$coverageKnownCount = 0
$coverageHtml = foreach ($name in $coverageNames) {
  $coverage = if ($snapshot) { Read-Coverage $snapshot 'coverage' } else { $null }
  $entry = Read-Coverage $coverage $name
  $state = 'UNKNOWN'
  $countLabel = 'count unknown'
  if ($entry) {
    $entryStatus = Read-Coverage $entry 'status'
    $entryCount = Read-Coverage $entry 'count'
    if ($entryStatus -in @('OK', 'DEGRADED', 'UNKNOWN')) {
      $state = [string]$entryStatus
      if ($state -ne 'UNKNOWN') { $coverageKnownCount++ }
      if ($state -eq 'OK') { $coverageOkCount++ }
    }
    if ($null -ne $entryCount -and [string]$entryCount -match '^\d+$') { $countLabel = [string]$entryCount }
  }
  '<tr><th>{0}</th><td><span class="state state-{1}">{2}</span></td><td class="count">{3}</td></tr>' -f (Html $name), (Html $state.ToLowerInvariant()), (Html $state), (Html $countLabel)
}

$processRows = @()
$listenerRows = @()
$tcpCount = 'UNKNOWN'
if ($snapshot) {
  $observed = Read-Coverage $snapshot 'observed'
  $processRows = @(Get-ObservedRows $observed 'processes' | Where-Object { $_ -and $null -ne (Read-Coverage $_ 'workingSetBytes') } |
    Sort-Object { [long](Read-Coverage $_ 'workingSetBytes') } -Descending | Select-Object -First 10)
  $listenerRows = @(Get-ObservedRows $observed 'tcpListeners')
  $coverage = Read-Coverage $snapshot 'coverage'
  $tcpCoverage = Read-Coverage $coverage 'tcpListeners'
  if ($tcpCoverage -and (Read-Coverage $tcpCoverage 'status') -in @('OK', 'DEGRADED')) { $tcpCount = [string]$listenerRows.Count }
}

$processHtml = if ($processRows.Count -eq 0) {
  '<tr><td colspan="3" class="muted">UNKNOWN — no process memory rows are available.</td></tr>'
} else {
  foreach ($process in $processRows) {
    $processName = Read-Coverage $process 'name'
    $processId = Read-Coverage $process 'pid'
    $workingSetBytes = Read-Coverage $process 'workingSetBytes'
    $name = if ($processName) { [string]$processName } else { 'UNKNOWN' }
    $pidLabel = if ($null -ne $processId) { [string]$processId } else { 'UNKNOWN' }
    $memoryMiB = [Math]::Round(([double]$workingSetBytes / 1MB), 1)
    '<tr><td>{0}</td><td>{1}</td><td>{2:N1} MiB</td></tr>' -f (Html $name), (Html $pidLabel), $memoryMiB
  }
}

$listenerHtml = if ($listenerRows.Count -eq 0) {
  '<tr><td colspan="3" class="muted">No TCP listeners in the saved snapshot, or coverage is unavailable.</td></tr>'
} else {
  foreach ($listener in ($listenerRows | Sort-Object { [string](Read-Coverage $_ 'protocol') }, { [int](Read-Coverage $_ 'localPort') } | Select-Object -First 12)) {
    $endpoint = '{0}:{1}' -f [string](Read-Coverage $listener 'localAddress'), [string](Read-Coverage $listener 'localPort')
    $owner = 'UNKNOWN'
    $listenerProcess = Read-Coverage $listener 'process'
    $listenerProcessName = Read-Coverage $listenerProcess 'name'
    if ($listenerProcessName) { $owner = [string]$listenerProcessName }
    '<tr><td>{0}</td><td>{1}</td><td>{2}</td></tr>' -f (Html ([string](Read-Coverage $listener 'protocol'))), (Html $endpoint), (Html $owner)
  }
}

$problemHtml = if ($snapshotProblem) { '<p class="notice">{0}</p>' -f (Html $snapshotProblem) } else { '' }
$freshnessClass = if ($freshness.StartsWith('FRESH')) { 'fresh' } elseif ($freshness.StartsWith('STALE')) { 'stale' } else { 'unknown' }
$capturedSafe = Html $capturedLabel
$freshnessSafe = Html $freshness
$tcpCountSafe = Html $tcpCount
$coverageSummary = '{0} / {1} modules reported a known state' -f $coverageKnownCount, $coverageNames.Count
$coverageSummarySafe = Html $coverageSummary
$html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Goliath Caretaker — Snapshot dashboard</title>
  <style>
    :root { color-scheme: dark; font-family: "Segoe UI", sans-serif; background:#0b1220; color:#e6edf7; }
    * { box-sizing:border-box; }
    body { margin:0; min-height:100vh; background:radial-gradient(ellipse at 70% -20%,#172b43 0,transparent 52%),#0b1220; }
    .shell { min-height:100vh; display:grid; grid-template-columns:220px minmax(0,1fr); }
    aside { display:flex; flex-direction:column; gap:22px; padding:24px 16px; border-right:1px solid #233148; background:rgba(10,17,29,.84); }
    .brand { display:flex; align-items:center; gap:11px; padding:0 8px 18px; border-bottom:1px solid #202d41; }
    .brand-mark { display:grid; place-items:center; width:36px; height:36px; border-radius:11px; color:#66c7ff; background:#102846; font-size:19px; }
    .brand strong { display:block; font-size:14px; letter-spacing:.02em; } .brand small { color:#8fa2bc; font-size:11px; }
    nav { display:grid; gap:5px; } nav a { padding:10px 12px; border-radius:8px; color:#aebed2; text-decoration:none; font-size:13px; }
    nav a:first-child, nav a:hover { color:#eaf5ff; background:#16283e; box-shadow:inset 2px 0 #31b8ff; }
    .side-note { margin-top:auto; border:1px solid #293951; border-radius:11px; padding:14px; background:#101b2b; }
    .side-note b { display:block; margin-bottom:7px; font-size:12px; } .side-note span { color:#a7b8cd; font-size:11px; line-height:1.55; }
    main { min-width:0; width:min(1420px,100%); margin:0 auto; padding:30px clamp(18px,3vw,44px) 40px; }
    .topline { display:flex; align-items:flex-start; justify-content:space-between; gap:20px; margin-bottom:24px; }
    h1 { margin:0 0 6px; font-size:26px; font-weight:650; letter-spacing:-.025em; } .muted { color:#91a2b8; }
    .subtitle { margin:0; font-size:13px; line-height:1.5; } .snapshot-badge { flex:none; border:1px solid #274763; border-radius:999px; padding:7px 11px; color:#8bd5ff; background:#10243a; font-size:11px; }
    .notice { margin:0 0 18px; padding:11px 14px; border:1px solid #755b2b; border-radius:9px; color:#f4cd7d; background:#2a2316; font-size:13px; }
    .metrics { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:13px; margin-bottom:18px; }
    .metric,.panel { border:1px solid #26364d; border-radius:12px; background:linear-gradient(145deg,rgba(22,34,51,.96),rgba(15,25,39,.97)); box-shadow:0 8px 28px rgba(0,0,0,.12); }
    .metric { min-height:116px; padding:16px 17px; } .metric-label { color:#91a5bf; font-size:11px; font-weight:600; letter-spacing:.08em; text-transform:uppercase; }
    .metric-value { display:block; margin:11px 0 4px; font-size:21px; font-weight:650; overflow-wrap:anywhere; }
    .metric-detail { color:#91a2b8; font-size:11px; line-height:1.4; } .fresh { color:#68d6a0; } .stale { color:#f3c46b; } .unknown { color:#f0bd61; }
    .content-grid { display:grid; grid-template-columns:minmax(0,1.08fr) minmax(0,.92fr); gap:15px; align-items:start; }
    .stack { display:grid; gap:15px; min-width:0; } .panel { padding:17px; min-width:0; }
    .panel-head { display:flex; align-items:baseline; justify-content:space-between; gap:10px; margin-bottom:5px; }
    h2 { margin:0; font-size:15px; font-weight:650; } .panel-kicker { color:#8497af; font-size:11px; }
    .panel-copy { margin:6px 0 12px; color:#91a2b8; font-size:11px; line-height:1.5; }
    table { width:100%; border-collapse:collapse; font-size:12px; }
    th,td { text-align:left; padding:10px 9px; border-bottom:1px solid #243247; vertical-align:middle; }
    th { color:#8fa2ba; font-size:10px; font-weight:600; letter-spacing:.07em; text-transform:uppercase; }
    tbody tr:last-child th, tbody tr:last-child td { border-bottom:0; } .count { color:#bac8d9; font-variant-numeric:tabular-nums; }
    .state { display:inline-flex; min-width:76px; justify-content:center; padding:4px 8px; border-radius:999px; font-size:10px; font-weight:650; letter-spacing:.03em; }
    .state-ok { color:#75dfad; background:#133428; } .state-degraded { color:#ffd27a; background:#392e19; } .state-unknown { color:#f0bd61; background:#342b1a; }
    .table-wrap { overflow-x:auto; } .empty { color:#91a2b8; padding:14px 9px; }
    footer { margin-top:18px; border-top:1px solid #243247; padding-top:14px; color:#8597af; font-size:11px; line-height:1.6; }
    @media(max-width:900px) { .shell { grid-template-columns:1fr; } aside { padding:13px 16px; border-right:0; border-bottom:1px solid #233148; } .brand { padding-bottom:11px; } nav { grid-template-columns:repeat(4,minmax(0,1fr)); } nav a { text-align:center; padding:8px 5px; } .side-note { display:none; } }
    @media(max-width:680px) { main { padding-top:22px; } .topline { flex-direction:column; } .metrics { grid-template-columns:repeat(2,minmax(0,1fr)); } .content-grid { grid-template-columns:1fr; } nav { grid-template-columns:repeat(3,minmax(0,1fr)); } }
    @media(max-width:390px) { .metrics { grid-template-columns:1fr; } }
  </style>
</head>
<body>
  <div class="shell">
    <aside>
      <div class="brand"><span class="brand-mark" aria-hidden="true">◆</span><div><strong>Goliath Caretaker</strong><small>Local workstation view</small></div></div>
      <nav aria-label="Dashboard sections"><a href="#overview">Overview</a><a href="#coverage">Coverage</a><a href="#processes">Processes</a><a href="#listeners">Listeners</a></nav>
      <div class="side-note"><b>Evidence mode</b><span>Saved snapshot only<br>Generated on demand<br>No live polling or chat</span></div>
    </aside>
    <main>
      <header class="topline" id="overview"><div><h1>System snapshot</h1><p class="subtitle muted">A compact view of the latest saved inventory. This page does not poll Windows or claim live status.</p></div><span class="snapshot-badge">SAVED EVIDENCE</span></header>
      $problemHtml
      <section class="metrics" aria-label="Snapshot summary">
        <article class="metric"><span class="metric-label">Captured at</span><strong class="metric-value">$capturedSafe</strong><span class="metric-detail">Timestamp from saved snapshot</span></article>
        <article class="metric"><span class="metric-label">Freshness when generated</span><strong class="metric-value $freshnessClass">$freshnessSafe</strong><span class="metric-detail">Based on snapshot timestamp at page generation</span></article>
        <article class="metric"><span class="metric-label">TCP listeners</span><strong class="metric-value">$tcpCountSafe</strong><span class="metric-detail">Saved rows; coverage may be partial</span></article>
        <article class="metric"><span class="metric-label">Coverage</span><strong class="metric-value">$coverageOkCount / $($coverageNames.Count) OK</strong><span class="metric-detail">$coverageSummarySafe</span></article>
      </section>
      <div class="content-grid">
        <div class="stack">
          <section class="panel" id="coverage"><div class="panel-head"><h2>Inventory coverage</h2><span class="panel-kicker">Snapshot modules</span></div><p class="panel-copy">Each state describes collection coverage for this snapshot; OK does not certify overall machine health.</p><div class="table-wrap"><table><thead><tr><th>Module</th><th>State</th><th>Rows</th></tr></thead><tbody>
            $($coverageHtml -join "`n            ")
          </tbody></table></div></section>
          <section class="panel" id="processes"><div class="panel-head"><h2>Largest working sets</h2><span class="panel-kicker">Top 10 saved rows</span></div><p class="panel-copy">Sorted by observed working set. Paths and command lines are omitted.</p><div class="table-wrap"><table><thead><tr><th>Process</th><th>PID</th><th>Working set</th></tr></thead><tbody>
            $($processHtml -join "`n            ")
          </tbody></table></div></section>
        </div>
        <div class="stack">
          <section class="panel" id="listeners"><div class="panel-head"><h2>TCP listener sample</h2><span class="panel-kicker">Up to 12 rows</span></div><p class="panel-copy">Local bind details from the saved snapshot. A bind address alone does not prove external reachability.</p><div class="table-wrap"><table><thead><tr><th>Protocol</th><th>Local endpoint</th><th>Process</th></tr></thead><tbody>
            $($listenerHtml -join "`n            ")
          </tbody></table></div></section>
          <section class="panel"><div class="panel-head"><h2>Reading this report</h2><span class="panel-kicker">Evidence limits</span></div><p class="panel-copy">Freshness reflects the saved capture time. DEGRADED means inventory was partial; UNKNOWN means evidence was unavailable or insufficient. Neither missing data nor a recent timestamp establishes health.</p><p class="panel-copy">Create a new report after an on-demand caretaker snapshot when updated evidence is needed.</p></section>
        </div>
      </div>
      <footer>Local static report · No always-on service · No process command lines included</footer>
    </main>
  </div>
</body>
</html>
"@

$fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = [System.IO.Path]::GetDirectoryName($fullOutputPath)
[System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$tempPath = Join-Path $outputDirectory ('.dashboard-' + [Guid]::NewGuid().ToString('N') + '.tmp')
$backupPath = Join-Path $outputDirectory ('.dashboard-' + [Guid]::NewGuid().ToString('N') + '.bak')
$encoding = New-Object System.Text.UTF8Encoding($false)
try {
  [System.IO.File]::WriteAllText($tempPath, $html, $encoding)
  if ([System.IO.File]::Exists($fullOutputPath)) {
    [System.IO.File]::Replace($tempPath, $fullOutputPath, $backupPath)
  } else {
    [System.IO.File]::Move($tempPath, $fullOutputPath)
  }
} finally {
  if ([System.IO.File]::Exists($tempPath)) { [System.IO.File]::Delete($tempPath) }
  if ([System.IO.File]::Exists($backupPath)) { [System.IO.File]::Delete($backupPath) }
}

Write-Output ("Dashboard written: {0}" -f $fullOutputPath)
