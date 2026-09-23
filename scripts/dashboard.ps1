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
$coverageHtml = foreach ($name in $coverageNames) {
  $coverage = if ($snapshot) { Read-Coverage $snapshot 'coverage' } else { $null }
  $entry = Read-Coverage $coverage $name
  $state = 'UNKNOWN'
  $countLabel = 'count unknown'
  if ($entry) {
    $entryStatus = Read-Coverage $entry 'status'
    $entryCount = Read-Coverage $entry 'count'
    if ($entryStatus -in @('OK', 'DEGRADED', 'UNKNOWN')) { $state = [string]$entryStatus }
    if ($null -ne $entryCount -and [string]$entryCount -match '^\d+$') { $countLabel = [string]$entryCount }
  }
  '<tr><th>{0}</th><td class="state-{1}">{2}</td><td>{3}</td></tr>' -f (Html $name), (Html $state.ToLowerInvariant()), (Html $state), (Html $countLabel)
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
$html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Goliath Caretaker dashboard</title>
  <style>
    :root { color-scheme: light dark; font-family: Segoe UI, sans-serif; }
    body { max-width: 1050px; margin: 2rem auto; padding: 0 1rem; }
    h1 { margin-bottom: .25rem; } .muted { opacity: .72; }
    .notice { padding: .8rem; border-left: 4px solid #d89b26; background: color-mix(in srgb, CanvasText 7%, Canvas); }
    .facts { display: flex; flex-wrap: wrap; gap: 1.5rem; margin: 1rem 0 1.5rem; }
    .facts strong { display: block; margin-bottom: .25rem; }
    table { width: 100%; border-collapse: collapse; margin: .5rem 0 1.75rem; }
    th, td { text-align: left; padding: .5rem .65rem; border-bottom: 1px solid color-mix(in srgb, CanvasText 18%, Canvas); }
    th { font-weight: 600; } .state-ok { color: #278344; } .state-degraded { color: #b66b00; } .state-unknown { color: #b66b00; }
    footer { margin-top: 2rem; font-size: .9rem; }
  </style>
</head>
<body>
  <h1>Goliath Caretaker</h1>
  <p class="muted">Saved snapshot report. This page does not poll Windows or claim live status.</p>
  $problemHtml
  <div class="facts">
    <div><strong>Captured</strong>$capturedLabel</div>
    <div><strong>Freshness</strong>$freshness</div>
    <div><strong>TCP listeners in snapshot</strong>$tcpCount</div>
  </div>
  <h2>Coverage</h2>
  <table><thead><tr><th>Module</th><th>State</th><th>Rows</th></tr></thead><tbody>
    $($coverageHtml -join "`n    ")
  </tbody></table>
  <h2>Top processes by working set</h2>
  <p class="muted">Top 10 from the saved process snapshot; executable paths and command lines are omitted.</p>
  <table><thead><tr><th>Process</th><th>PID</th><th>Working set</th></tr></thead><tbody>
    $($processHtml -join "`n    ")
  </tbody></table>
  <h2>TCP listener sample</h2>
  <p class="muted">At most 12 saved rows. Missing or partial coverage is not a clean bill of health.</p>
  <table><thead><tr><th>Protocol</th><th>Local endpoint</th><th>Process</th></tr></thead><tbody>
    $($listenerHtml -join "`n    ")
  </tbody></table>
  <footer>UNKNOWN means the snapshot did not provide enough evidence. DEGRADED means inventory was partial. Refresh with the caretaker's on-demand snapshot command.</footer>
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
