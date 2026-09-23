[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
  [ValidateSet('Plan', 'Apply')]
  [string]$Action = 'Plan',
  [string]$EvidenceRoot,
  [switch]$FixtureMode,
  [int]$FixtureBudgetMiB = 0
)

$ErrorActionPreference = 'Stop'
$script:ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:ManifestPath = Join-Path $script:ProjectRoot 'config\caretaker.json'
$script:LogPath = Join-Path $script:ProjectRoot 'diag_log.txt'
$script:ChangeLogPath = Join-Path $script:ProjectRoot 'change_log.txt'
$script:Config = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
$script:AllowedFiles = @('changes.jsonl','outbox.jsonl','snapshot.json','alert-state.json','last-attempt.json','active-lease.json','retention-state.json')

if ($FixtureMode) {
  if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { throw '-FixtureMode requires -EvidenceRoot under tests/fixtures.' }
  $fixtureRoot = [System.IO.Path]::GetFullPath($EvidenceRoot)
  $fixturesBase = [System.IO.Path]::GetFullPath((Join-Path $script:ProjectRoot 'tests\fixtures')) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $fixtureRoot.StartsWith($fixturesBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture path must remain under tests/fixtures.' }
  $script:EvidenceRoot = $fixtureRoot
  $script:LogPath = Join-Path $fixtureRoot 'retention-test.log'
  $script:ChangeLogPath = Join-Path $fixtureRoot 'retention-test-changes.log'
  if ($FixtureBudgetMiB -gt 0) { $script:BudgetMiB = $FixtureBudgetMiB } else { $script:BudgetMiB = [int]$script:Config.deployment.storageBudgetMiB }
} else {
  if ($EvidenceRoot) { throw 'A custom EvidenceRoot is accepted only with -FixtureMode.' }
  if ($FixtureBudgetMiB -ne 0) { throw 'FixtureBudgetMiB is accepted only with -FixtureMode.' }
  $script:EvidenceRoot = Join-Path $script:ProjectRoot 'evidence'
  $script:BudgetMiB = [int]$script:Config.deployment.storageBudgetMiB
}

function Write-RetentionLog {
  param([string]$Label, [string]$Command, [string]$Reason, [string]$Output)
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
  Add-Content -LiteralPath $script:LogPath -Value "`r`n[$stamp] $Label`r`nCOMMAND: $Command`r`nREASON: $Reason`r`nOUTPUT:`r`n$Output"
}

function Get-RetentionData {
  $now = [DateTimeOffset]::UtcNow
  $days = [int]$script:Config.deployment.retentionDays
  $cutoff = $now.AddDays(-$days)
  $changesPath = Join-Path $script:EvidenceRoot 'changes.jsonl'
  $changeLines = @()
  if (Test-Path -LiteralPath $changesPath -PathType Leaf) { $changeLines = @(Get-Content -LiteralPath $changesPath) }
  $removeIndexes = [System.Collections.Generic.List[int]]::new()
  $lastApplied = $null
  $markerUnknown = $false
  $markerState = $null
  $statePath = Join-Path $script:EvidenceRoot 'retention-state.json'
  if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
      $marker = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -ErrorAction Stop
      $parsedLast = [DateTimeOffset]::MinValue
      if (-not $marker.lastAppliedUtc -or -not [DateTimeOffset]::TryParse([string]$marker.lastAppliedUtc, [ref]$parsedLast)) { $markerUnknown = $true } else { $lastApplied = $parsedLast }
      $markerState = [string]$marker.state
    } catch { $markerUnknown = $true }
  }
  $malformed = 0
  for ($i=0; $i -lt $changeLines.Count; $i++) {
    try {
      $entry = $changeLines[$i] | ConvertFrom-Json -ErrorAction Stop
      $eventTime = [DateTimeOffset]::MinValue
      if (-not $entry.atUtc -or -not [DateTimeOffset]::TryParse([string]$entry.atUtc, [ref]$eventTime)) { $malformed++; continue }
      if ($eventTime -lt $cutoff) { $removeIndexes.Add($i) }
    } catch { $malformed++ }
  }

  $runtimeBytes = [long]0
  $fileBytes = @{}
  foreach ($name in $script:AllowedFiles) {
    $path = Join-Path $script:EvidenceRoot $name
    $size = if (Test-Path -LiteralPath $path -PathType Leaf) { (Get-Item -LiteralPath $path).Length } else { 0L }
    $fileBytes[$name] = [long]$size
    $runtimeBytes += [long]$size
  }
  $collectorReserveBytes = if ([bool]$script:Config.deployment.collectorEnabled -or [bool]$script:Config.deployment.perfmon.enabled) { [long]$script:Config.deployment.perfmon.circularMaxMiB * 1MB } else { [long]0 }
  $budgetBytes = [long]$script:BudgetMiB * 1MB
  $totalBytes = $runtimeBytes + $collectorReserveBytes
  $alertPath = Join-Path $script:EvidenceRoot 'alert-state.json'
  $activeAlerts = 0
  $alertStateUnknown = $false
  if (Test-Path -LiteralPath $alertPath -PathType Leaf) {
    try { $activeAlerts = @((Get-Content -LiteralPath $alertPath -Raw | ConvertFrom-Json -ErrorAction Stop).active).Count } catch { $alertStateUnknown = $true }
  }
  [pscustomobject]@{
    nowUtc = $now; cutoffUtc = $cutoff; lastAppliedUtc = $lastApplied; retentionDays = $days
    changesPath = $changesPath; changeLines = $changeLines; removeIndexes = @($removeIndexes)
    malformedChangeRows = $malformed; runtimeBytes = $runtimeBytes; collectorReserveBytes = $collectorReserveBytes
    totalBytes = $totalBytes; budgetBytes = $budgetBytes; fileBytes = $fileBytes
    activeAlertCount = $activeAlerts; alertStateUnknown = $alertStateUnknown
    markerUnknown = $markerUnknown; markerPath = $statePath; markerState = $markerState
    state = if ($markerUnknown) { 'UNKNOWN' } elseif ($totalBytes -gt $budgetBytes) { 'OVER_BUDGET' } else { 'OK' }
  }
}

function Get-Summary {
  param($Data, [string]$ActionName, [int]$RemovedRows = 0)
  $lastApplied = $Data.lastAppliedUtc
  [pscustomobject]@{
    schemaVersion = 1
    action = $ActionName
    command = "powershell.exe -NoProfile -File .\scripts\retention.ps1 -Action $ActionName"
    state = $Data.state
    exitCode = if ($Data.state -eq 'OVER_BUDGET') { 2 } elseif ($Data.state -eq 'UNKNOWN') { 3 } else { 0 }
    atUtc = $Data.nowUtc.ToString('o')
    lastAppliedUtc = if ($lastApplied) { $lastApplied.ToString('o') } else { $null }
    nextDueUtc = if ($lastApplied) { $lastApplied.AddHours([int]$script:Config.deployment.retentionRunIntervalHours).ToString('o') } else { $null }
    retentionDays = $Data.retentionDays
    cutoffUtc = $Data.cutoffUtc.ToString('o')
    changeRowsEligible = $Data.removeIndexes.Count
    changeRowsRemoved = $RemovedRows
    malformedChangeRowsPreserved = $Data.malformedChangeRows
    activeAlertsPreserved = $Data.activeAlertCount
    alertStateUnknown = $Data.alertStateUnknown
    runtimeBytes = $Data.runtimeBytes
    reservedCollectorBytes = $Data.collectorReserveBytes
    totalBytes = $Data.totalBytes
    budgetBytes = $Data.budgetBytes
    fileBytes = $Data.fileBytes
    retentionMarkerPath = $Data.markerPath
    retentionMarkerUnknown = $Data.markerUnknown
    allowHeavyCollection = ($Data.state -eq 'OK')
    managedFiles = $script:AllowedFiles
  }
}

function Write-RetentionState {
  param([DateTimeOffset]$AppliedAt, [string]$State, [int]$RemovedRows)
  $statePath = Join-Path $script:EvidenceRoot 'retention-state.json'
  $tempPath = $statePath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
  $record = [pscustomobject]@{
    schemaVersion = 1
    lastAppliedUtc = $AppliedAt.ToString('o')
    nextDueUtc = $AppliedAt.AddHours([int]$script:Config.deployment.retentionRunIntervalHours).ToString('o')
    retentionDays = [int]$script:Config.deployment.retentionDays
    state = $State
    changeRowsRemoved = $RemovedRows
  }
  try {
    [System.IO.File]::WriteAllText($tempPath, (ConvertTo-Json -InputObject $record -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tempPath -Destination $statePath -Force
  } finally { if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force } }
}

function Invoke-RetentionApply {
  $data = Get-RetentionData
  if ($data.markerUnknown) { throw 'retention-state.json is invalid; preserve it and review before Apply.' }
  if (-not $PSCmdlet.ShouldProcess($script:EvidenceRoot, 'Trim only expired valid rows from changes.jsonl')) {
    return Get-Summary -Data $data -ActionName 'Apply' -RemovedRows 0
  }
  $removed = $data.removeIndexes.Count
  if ($removed -gt 0) {
    $removeSet = @{}; foreach ($index in $data.removeIndexes) { $removeSet[[int]$index] = $true }
    $kept = [System.Collections.Generic.List[string]]::new()
    for ($i=0; $i -lt $data.changeLines.Count; $i++) { if (-not $removeSet.ContainsKey($i)) { $kept.Add([string]$data.changeLines[$i]) } }
    $tempPath = $data.changesPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
      [System.IO.File]::WriteAllText($tempPath, (($kept -join [Environment]::NewLine) + $(if ($kept.Count) { [Environment]::NewLine } else { '' })), (New-Object System.Text.UTF8Encoding($false)))
      Move-Item -LiteralPath $tempPath -Destination $data.changesPath -Force
    } finally { if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force } }
  }
  $after = Get-RetentionData
  Write-RetentionState -AppliedAt $data.nowUtc -State $after.state -RemovedRows $removed
  $after = Get-RetentionData
  if ($after.markerState -ne $after.state) {
    Write-RetentionState -AppliedAt $data.nowUtc -State $after.state -RemovedRows $removed
    $after = Get-RetentionData
  }
  $summary = Get-Summary -Data $after -ActionName 'Apply' -RemovedRows $removed
  $json = ConvertTo-Json -InputObject $summary -Depth 6
  Write-RetentionLog -Label 'Routine retention' -Command 'powershell.exe -NoProfile -File .\scripts\retention.ps1 -Action Apply' -Reason 'Trim only expired parseable changes.jsonl rows, write the due marker, preserve protected state, and report budget state.' -Output $json
  if (-not $FixtureMode) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
    Add-Content -LiteralPath $script:ChangeLogPath -Value "`r`n[$stamp] Routine evidence retention`r`nFILES/COMMANDS: scripts/retention.ps1 -Action Apply; evidence/changes.jsonl; evidence/retention-state.json`r`nOUTCOME: Removed $removed expired valid change rows; state=$($summary.state); other runtime evidence preserved.`r`nROLLBACK: Restore changes.jsonl and retention-state.json from a separately preserved copy if needed; this action creates no archive."
  }
  return $summary
}

try {
  if (-not (Test-Path -LiteralPath $script:EvidenceRoot -PathType Container)) {
    if ($Action -eq 'Apply' -and $PSCmdlet.ShouldProcess($script:EvidenceRoot, 'Create evidence directory for retention marker')) { New-Item -ItemType Directory -Path $script:EvidenceRoot -Force | Out-Null }
  }
  $summary = if ($Action -eq 'Apply') { Invoke-RetentionApply } else { Get-Summary -Data (Get-RetentionData) -ActionName 'Plan' }
  $json = ConvertTo-Json -InputObject $summary -Depth 6
  if ($Action -eq 'Plan') {
    Write-RetentionLog -Label 'Retention plan' -Command 'powershell.exe -NoProfile -File .\scripts\retention.ps1 -Action Plan' -Reason 'Read-only plan over named caretaker runtime files only.' -Output $json
  }
  Write-Output $json
  if ($summary.state -eq 'OVER_BUDGET') { exit 2 }
  if ($summary.state -eq 'UNKNOWN') { exit 3 }
} catch {
  $errorText = "retention.ps1 -Action $Action failed: $($_.Exception.Message)"
  Write-RetentionLog -Label 'Retention action failed' -Command "powershell.exe -NoProfile -File .\scripts\retention.ps1 -Action $Action" -Reason 'Retention action failed; only named routine evidence files are eligible.' -Output $errorText
  throw $errorText
}
