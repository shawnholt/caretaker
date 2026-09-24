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
$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $projectRoot 'config\caretaker.json'
$manifest = $null
$freshnessLimitMinutes = 45
try {
  if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $manifest = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $interval = [int]$manifest.deployment.checkIntervalMinutes
    if ($interval -gt 0) { $freshnessLimitMinutes = [Math]::Max(15, $interval * 3) }
  }
} catch { $manifest = $null }
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

function Get-DisplayZoneLabel([DateTimeOffset]$Value, [TimeZoneInfo]$Zone) {
  if ($Zone.Id -in @('Eastern Standard Time', 'America/New_York')) {
    if ($Zone.IsDaylightSavingTime($Value)) { return 'EDT' }
    return 'EST'
  }
  return $Value.ToString('zzz')
}

function Format-HelpButton([string]$Label, [string]$Text) {
  $id = 'help-' + [Guid]::NewGuid().ToString('N')
  return ('<span class="help-wrap"><button type="button" class="help" aria-label="Help: {0}" aria-controls="{1}" aria-describedby="{1}" aria-expanded="false">?</button><span class="help-tip" id="{1}" role="tooltip" hidden>{2}</span></span>' -f (Html $Label), $id, (Html $Text))
}

$displayZone = [TimeZoneInfo]::Local
$capturedLabel = 'UNKNOWN'
$capturedLocalLabel = 'UNKNOWN'
$freshness = 'UNKNOWN'
$freshnessDetail = 'Snapshot time unavailable.'
$capturedAt = $null
$capturedValue = if ($snapshot) { Read-Coverage $snapshot 'capturedAtUtc' } else { $null }
if ($capturedValue) {
  try {
    $capturedAt = [DateTimeOffset]::Parse([string]$capturedValue).ToUniversalTime()
    $age = [DateTimeOffset]::UtcNow - $capturedAt
    $ageMinutes = [Math]::Max(0, [Math]::Round($age.TotalMinutes, 1))
    if ($age.TotalMinutes -lt -5) {
      $freshness = 'UNKNOWN'
      $freshnessDetail = 'Snapshot time is in the future.'
    } elseif ($ageMinutes -le $freshnessLimitMinutes) {
      $freshness = 'FRESH'
      $freshnessDetail = ("{0} min old; within checker window." -f $ageMinutes)
    } else {
      $freshness = 'STALE'
      $freshnessDetail = ("{0} min old; outside checker window." -f $ageMinutes)
    }
    $capturedLabel = $capturedAt.ToString('yyyy-MM-dd HH:mm:ss UTC')
    $local = [TimeZoneInfo]::ConvertTime($capturedAt, $displayZone)
    $capturedLocalLabel = $local.ToString('MMM d, yyyy h:mm tt') + ' ' + (Get-DisplayZoneLabel $local $displayZone)
  } catch {
    $freshness = 'UNKNOWN'
    $freshnessDetail = 'Snapshot time is invalid.'
  }
}

$attentionCount = 'UNKNOWN'
$attentionDetail = 'Alert state unavailable.'
$alertKeys = @{}
try {
  $alertPath = Join-Path $EvidenceRoot 'alert-state.json'
  if (Test-Path -LiteralPath $alertPath -PathType Leaf) {
    $alertState = Get-Content -LiteralPath $alertPath -Raw | ConvertFrom-Json
    $active = @($alertState.active)
    $attentionCount = [string]$active.Count
    $attentionDetail = if ($active.Count -eq 0) { 'No open review items.' } else { 'Open items from saved alert state.' }
    foreach ($entry in $active) { if ($entry.id) { $alertKeys[[string]$entry.id] = $true } }
  }
} catch {
  $attentionCount = 'UNKNOWN'
  $attentionDetail = 'Alert state could not be read.'
}

$recentChangeHtml = '<p class="muted empty">UNKNOWN - no change journal is available.</p>'
try {
  $changesPath = Join-Path $EvidenceRoot 'changes.jsonl'
  if (Test-Path -LiteralPath $changesPath -PathType Leaf) {
    $lines = @(Get-Content -LiteralPath $changesPath -ErrorAction Stop)
    $tail = @($lines | Select-Object -Last 5)
    if ($tail.Count -eq 0) {
      $recentChangeHtml = '<p class="muted empty">No recorded changes yet.</p>'
    } else {
      $rows = foreach ($line in $tail) {
        $row = $line | ConvertFrom-Json
        $when = Html ([string]$row.atUtc)
        $module = Html ([string]$row.module)
        $change = Html ([string]$row.change)
        $key = Html ([string]$row.key)
        "<tr><td>$when</td><td>$module</td><td>$change</td><td>$key</td></tr>"
      }
      $recentChangeHtml = '<div class="table-wrap"><table><thead><tr><th>When (UTC)</th><th>Module</th><th>Change</th><th>Key</th></tr></thead><tbody>' + ($rows -join '') + '</tbody></table></div>'
    }
  }
} catch {
  $recentChangeHtml = '<p class="muted empty">Change journal could not be read.</p>'
}

$coverageNames = @('processes', 'tcpListeners', 'udpEndpoints', 'services', 'tasks', 'startup')
$moduleDescriptions = @{
  processes = 'Process identities and working-set memory sampled at capture time.'
  tcpListeners = 'Saved TCP listening endpoints and their attributed process, when available.'
  udpEndpoints = 'Saved UDP endpoints and their attributed process, when available.'
  services = 'Windows service name, display name, state, and start mode.'
  tasks = 'Scheduled task name, state, enabled state, and action/trigger counts; command details are omitted.'
  startup = 'Startup entry name and location; command details are omitted.'
}
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
  $target = if ($name -eq 'processes') { '#processes' } elseif ($name -eq 'tcpListeners') { '#listeners' } else { '#records-' + $name }
  $help = Format-HelpButton $name ($moduleDescriptions[$name] + ' OK means collected successfully; DEGRADED means partial coverage; UNKNOWN means evidence is unavailable or insufficient.')
  '<tr><th><a href="{0}">{1}</a>{2}</th><td><span class="state state-{3}">{4}</span></td><td class="count">{5}</td></tr>' -f $target, (Html $name), $help, (Html $state.ToLowerInvariant()), (Html $state), (Html $countLabel)
}

$processRows = @()
$listenerRows = @()
$observed = $null
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
  '<tr><td colspan="3" class="muted">UNKNOWN - no process memory rows are available.</td></tr>'
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

function Test-ListenerApprovedRow($Listener, $DesiredListeners) {
  if (-not $DesiredListeners) { return $false }
  $proc = Read-Coverage $Listener 'process'
  $path = Read-Coverage $proc 'executablePath'
  foreach ($expected in @($DesiredListeners)) {
    if ([string]::IsNullOrWhiteSpace([string]$expected.executablePath)) { continue }
    if (-not $path) { continue }
    if ([string]$expected.executablePath -ieq [string]$path -and
        [string]$expected.protocol -ieq [string](Read-Coverage $Listener 'protocol') -and
        [int]$expected.localPort -eq [int](Read-Coverage $Listener 'localPort') -and
        [string]$expected.localAddress -ieq [string](Read-Coverage $Listener 'localAddress')) { return $true }
  }
  return $false
}

$desiredListeners = @()
if ($manifest -and $manifest.desired -and $manifest.desired.listeners) { $desiredListeners = @($manifest.desired.listeners) }
$tcpCoverageStatus = 'UNKNOWN'
if ($snapshot) {
  $tcpCov = Read-Coverage (Read-Coverage $snapshot 'coverage') 'tcpListeners'
  if ($tcpCov) { $tcpCoverageStatus = [string](Read-Coverage $tcpCov 'status') }
}

$listenerHtml = if ($listenerRows.Count -eq 0) {
  '<tr><td colspan="4" class="muted">No TCP listener rows are available in this snapshot.</td></tr>'
} else {
  foreach ($listener in ($listenerRows | Sort-Object { [string](Read-Coverage $_ 'protocol') }, { [int](Read-Coverage $_ 'localPort') } | Select-Object -First 12)) {
    $endpoint = '{0}:{1}' -f [string](Read-Coverage $listener 'localAddress'), [string](Read-Coverage $listener 'localPort')
    $owner = 'UNKNOWN'
    $listenerProcess = Read-Coverage $listener 'process'
    $listenerProcessName = Read-Coverage $listenerProcess 'name'
    if ($listenerProcessName) { $owner = [string]$listenerProcessName }
    $key = ('TCP|{0}|{1}' -f ([string](Read-Coverage $listener 'localAddress')).ToLowerInvariant(), [int](Read-Coverage $listener 'localPort'))
    $alertId = 'unreviewed-listener:' + $key
    $review = 'UNKNOWN'
    if ($tcpCoverageStatus -eq 'DEGRADED') {
      $review = 'UNKNOWN (partial TCP coverage)'
    } elseif ($tcpCoverageStatus -ne 'OK') {
      $review = 'UNKNOWN (TCP coverage unavailable)'
    } elseif (Test-ListenerApprovedRow $listener $desiredListeners) {
      $review = 'Expected (manifest-approved)'
    } elseif ($alertKeys.ContainsKey($alertId)) {
      $review = 'Needs review (open alert)'
    } else {
      $review = 'Observed; not manifest-approved'
    }
    '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td></tr>' -f (Html ([string](Read-Coverage $listener 'protocol'))), (Html $endpoint), (Html $owner), (Html $review)
  }
}

function Build-RecordPanel([string]$Id, [string]$Title, [string]$Description, [object[]]$Rows, [string[]]$Headers, [scriptblock]$Cells, [int]$Limit = 20) {
  if ($Rows.Count -eq 0) { $body = '<p class="muted empty">UNKNOWN - no saved records are available.</p>' }
  else {
    $head = '<tr>' + (($Headers | ForEach-Object { '<th>{0}</th>' -f (Html $_) }) -join '') + '</tr>'
    $displayRows = foreach ($row in ($Rows | Select-Object -First $Limit)) { '<tr>' + (& $Cells $row) + '</tr>' }
    $body = '<div class="table-wrap"><table><thead>' + $head + '</thead><tbody>' + ($displayRows -join '') + '</tbody></table></div>'
    if ($Rows.Count -gt $Limit) { $Description += (' Showing the first {0} of {1} saved rows.' -f $Limit, $Rows.Count) }
  }
  '<section class="panel" id="records-{0}"><div class="panel-head"><h3>{1}</h3><span class="panel-kicker">{2} saved rows</span></div><p class="panel-copy">{3}</p>{4}</section>' -f $Id, (Html $Title), $Rows.Count, (Html $Description), $body
}

$moduleRecordsHtml = @(
  (Build-RecordPanel 'udpEndpoints' 'UDP endpoints' 'Saved local endpoint and process name; attribution may be unavailable.' @(Get-ObservedRows $observed 'udpEndpoints') @('Endpoint', 'Process') { param($r) '<td>{0}:{1}</td><td>{2}</td>' -f (Html ([string](Read-Coverage $r 'localAddress'))), (Html ([string](Read-Coverage $r 'localPort'))), (Html ([string](Read-Coverage (Read-Coverage $r 'process') 'name'))) })
  (Build-RecordPanel 'services' 'Services' 'Service display name, state, and start mode.' @(Get-ObservedRows $observed 'services') @('Service', 'State', 'Start mode') { param($r) '<td>{0}</td><td>{1}</td><td>{2}</td>' -f (Html ([string](Read-Coverage $r 'displayName'))), (Html ([string](Read-Coverage $r 'state'))), (Html ([string](Read-Coverage $r 'startMode'))) })
  (Build-RecordPanel 'tasks' 'Scheduled tasks' 'Task name, state, and enabled state; action details are omitted.' @(Get-ObservedRows $observed 'tasks') @('Task', 'State', 'Enabled') { param($r) '<td>{0}</td><td>{1}</td><td>{2}</td>' -f (Html ([string](Read-Coverage $r 'name'))), (Html ([string](Read-Coverage $r 'state'))), (Html ([string](Read-Coverage $r 'enabled'))) })
  (Build-RecordPanel 'startup' 'Startup entries' 'Entry name and location; command details are omitted.' @(Get-ObservedRows $observed 'startup') @('Entry', 'Location') { param($r) '<td>{0}</td><td>{1}</td>' -f (Html ([string](Read-Coverage $r 'name'))), (Html ([string](Read-Coverage $r 'location'))) })
)

$problemHtml = if ($snapshotProblem) { '<p class="notice">{0}</p>' -f (Html $snapshotProblem) } else { '' }
$freshnessClass = if ($freshness -eq 'FRESH') { 'fresh' } elseif ($freshness -eq 'STALE') { 'stale' } else { 'unknown' }
$capturedSafe = Html $capturedLocalLabel
$capturedUtcSafe = Html $capturedLabel
$freshnessSafe = Html $freshness
$freshnessDetailSafe = Html $freshnessDetail
$attentionSafe = Html $attentionCount
$attentionDetailSafe = Html $attentionDetail
$tcpCountSafe = Html $tcpCount
$coverageSummary = '{0} of {1} modules collected OK' -f $coverageOkCount, $coverageNames.Count
$coverageSummarySafe = Html $coverageSummary
$helpFreshness = Format-HelpButton 'Freshness' ("FRESH means the saved snapshot is no older than {0} minutes (three checker intervals, with a 15-minute minimum). This static page calculates freshness when generated." -f $freshnessLimitMinutes)
$helpCoverage = Format-HelpButton 'Coverage' 'Counts inventory modules whose collection reported OK for this snapshot. OK means collection succeeded; it does not mean a health check passed or that Goliath is healthy. Select a module name to view saved records.'
$helpAttention = Format-HelpButton 'Needs attention' 'Open review items from saved alert state. This count is not a machine health score. Personal review/snooze decisions live in the manifest; snooze only suppresses re-nag.'
$helpCaptured = Format-HelpButton 'Captured time' 'Local time for readability; UTC is kept in saved evidence and shown below.'
$helpMemory = Format-HelpButton 'Working set memory' 'Memory held by each process at the snapshot capture time. The table shows the top 10 rows; this is not an average, peak, or cumulative measure over an interval.'
$helpListeners = Format-HelpButton 'TCP listener review' 'Expected requires complete coverage and an exact manifest match for protocol, address, port, and executable path. Needs review requires an open saved alert after complete coverage. Other rows are observations without a health or reachability verdict.'
$html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Goliath Caretaker - Snapshot dashboard</title>
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
    .metric-label { display:inline-flex; align-items:center; gap:6px; }
    .help-wrap { position:relative; display:inline-flex; vertical-align:middle; }
    button.help { width:18px; height:18px; padding:0; border:1px solid #3a4f68; border-radius:999px; background:#152235; color:#9ec9ff; font-size:11px; font-weight:700; line-height:1; cursor:pointer; }
    button.help:focus { outline:2px solid #31b8ff; outline-offset:2px; }
    .help-tip { position:absolute; z-index:5; left:22px; top:0; width:min(300px,70vw); padding:9px 11px; border:1px solid #3a4f68; border-radius:8px; color:#dce8f6; background:#101b2b; box-shadow:0 8px 24px #0008; font-size:11px; font-weight:400; letter-spacing:normal; line-height:1.5; text-transform:none; }
    th a { color:inherit; text-decoration:underline; text-decoration-color:#536983; text-underline-offset:3px; }
    h3 { margin:0; font-size:13px; font-weight:650; }
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
      <div class="brand"><span class="brand-mark" aria-hidden="true">&#9670;</span><div><strong>Goliath Caretaker</strong><small>Local workstation view</small></div></div>
      <nav aria-label="Dashboard sections"><a href="#overview">Overview</a><a href="#attention">Needs attention</a><a href="#coverage">Coverage</a><a href="#processes">Processes</a><a href="#listeners">Listeners</a><a href="#changes">Recent changes</a></nav>
      <div class="side-note"><b>Ask Caretaker</b><span>Run <code>node scripts\chat-server.js</code> for on-demand chat with live read-only checks. Stop chat or close the tab when finished.</span></div>
      <div class="side-note"><b>Evidence mode</b><span>Saved snapshot only<br>Generated on demand<br>No live polling on this page</span></div>
    </aside>
    <main>
      <header class="topline" id="overview"><div><h1>System snapshot</h1><p class="subtitle muted">A compact view of the latest saved inventory. This page does not poll Windows or claim live status.</p></div><span class="snapshot-badge">SAVED EVIDENCE</span></header>
      $problemHtml
      <section class="metrics" aria-label="Snapshot summary">
        <article class="metric"><span class="metric-label">Captured (local)$helpCaptured</span><strong class="metric-value">$capturedSafe</strong><span class="metric-detail">UTC evidence: $capturedUtcSafe</span></article>
        <article class="metric"><span class="metric-label">Freshness when generated$helpFreshness</span><strong class="metric-value $freshnessClass">$freshnessSafe</strong><span class="metric-detail">$freshnessDetailSafe</span></article>
        <article class="metric" id="attention"><span class="metric-label">Needs attention$helpAttention</span><strong class="metric-value">$attentionSafe</strong><span class="metric-detail">$attentionDetailSafe</span></article>
        <article class="metric"><span class="metric-label">Inventory modules collected OK$helpCoverage</span><strong class="metric-value">$coverageOkCount of $($coverageNames.Count)</strong><span class="metric-detail">$coverageSummarySafe</span></article>
      </section>
      <div class="content-grid">
        <div class="stack">
          <section class="panel" id="coverage"><div class="panel-head"><h2>Inventory coverage</h2><span class="panel-kicker">Snapshot modules</span></div><p class="panel-copy">Select a module to open its saved records. OK means collected; DEGRADED means partial collection; UNKNOWN means evidence was unavailable or insufficient. None is a health verdict.</p><div class="table-wrap"><table><thead><tr><th>Module</th><th>Collection</th><th>Rows</th></tr></thead><tbody>
            $($coverageHtml -join "`n            ")
          </tbody></table></div></section>
          <section class="panel" id="processes"><div class="panel-head"><h2>Memory at capture (working set)$helpMemory</h2><span class="panel-kicker">Top 10 saved rows</span></div><p class="panel-copy">Single-point memory sample from the saved snapshot, not cumulative CPU or interval totals. Paths and command lines are omitted.</p><div class="table-wrap"><table><thead><tr><th>Process</th><th>PID</th><th>Working set</th></tr></thead><tbody>
            $($processHtml -join "`n            ")
          </tbody></table></div></section>
        </div>
        <div class="stack">
          <section class="panel" id="listeners"><div class="panel-head"><h2>TCP listeners$helpListeners</h2><span class="panel-kicker">$tcpCountSafe saved rows (showing up to 12)</span></div><p class="panel-copy">Rule: Expected requires complete TCP coverage and an exact protocol, address, port, and executable-path match in the manifest. Needs review means complete coverage plus an open saved alert. Otherwise the row is only observed or UNKNOWN. A count or bind address alone is not an issue verdict and does not prove external reachability.</p><div class="table-wrap"><table><thead><tr><th>Protocol</th><th>Local endpoint</th><th>Process</th><th>Review</th></tr></thead><tbody>
            $($listenerHtml -join "`n            ")
          </tbody></table></div></section>
          <section class="panel" id="changes"><div class="panel-head"><h2>Recent changes</h2><span class="panel-kicker">Last 5 journal rows</span></div><p class="panel-copy">Append-only drift journal from saved evidence; modules with incomplete coverage are omitted from change detection.</p>
            $recentChangeHtml
          </section>
          $($moduleRecordsHtml -join "`n          ")
          <section class="panel"><div class="panel-head"><h2>Reading this report</h2><span class="panel-kicker">Evidence limits</span></div><p class="panel-copy">Freshness uses the same checker window as <code>caretaker.ps1 status</code>. DEGRADED means inventory was partial; UNKNOWN means evidence was unavailable or insufficient. Neither missing data nor a recent timestamp establishes health.</p><p class="panel-copy">Regenerate after <code>caretaker.ps1 snapshot</code> when updated evidence is needed.</p></section>
        </div>
      </div>
      <footer>Local static report | No always-on service | No process command lines included</footer>
    </main>
  </div>
  <script>
    document.querySelectorAll('button.help').forEach(function(button) {
      var tip = document.getElementById(button.getAttribute('aria-controls'));
      function setOpen(open) {
        button.setAttribute('aria-expanded', String(open));
        tip.hidden = !open;
      }
      button.addEventListener('click', function() {
        setOpen(true);
      });
      button.addEventListener('focus', function() { setOpen(true); });
      button.addEventListener('blur', function() { setOpen(false); });
      button.addEventListener('mouseenter', function() { setOpen(true); });
      button.addEventListener('mouseleave', function() {
        if (document.activeElement !== button) { setOpen(false); }
      });
      button.addEventListener('keydown', function(event) {
        if (event.key === 'Escape') {
          setOpen(false);
        }
      });
    });
  </script>
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
