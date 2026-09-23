[CmdletBinding()]
param(
  [ValidateRange(1, 30)]
  [int]$WindowDays = 7,
  [ValidateRange(1, 5000)]
  [int]$MaxEventsPerLog = 1000,
  [switch]$AsObject,
  [switch]$LibraryOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-EventHealthProviderName {
  param($EventRecord)
  try { return [string]$EventRecord.ProviderName } catch { return '' }
}

function Get-EventHealthField {
  param($EventRecord, [string]$Name)
  try { return [string]$EventRecord.$Name } catch { return '' }
}

function Get-EventHealthUtc {
  param($EventRecord)
  try {
    $time = $EventRecord.TimeCreated
    if ($null -eq $time) { return $null }
    return ([DateTime]$time).ToUniversalTime().ToString('o')
  } catch { return $null }
}

function Get-EventHealthCoverage {
  param([int]$Count, [int]$Limit, [string]$AttemptedAtUtc, [string]$Reason)
  $status = if ($Reason) { 'UNKNOWN' } elseif ($Count -ge $Limit) { 'DEGRADED' } else { 'OK' }
  $coverageReason = if ($Reason) { $Reason } elseif ($Count -ge $Limit) { "Read limit reached ($Limit newest events); matching counts may be partial." } else { $null }
  return [pscustomobject]@{ status = $status; attemptedAtUtc = $AttemptedAtUtc; count = if ($Reason) { $null } else { $Count }; limit = $Limit; reason = $coverageReason }
}

function Get-EventHealthCategoryName {
  param($EventRecord, [string]$LogName)
  $provider = Get-EventHealthProviderName $EventRecord
  $id = 0
  try { $id = [int]$EventRecord.Id } catch { return $null }
  if ($LogName -eq 'System') {
    if ($id -in @(129, 153) -and $provider -match '(?i)(disk|stor|nvme|iastor|scsiport)') { return 'storage' }
    if ($provider -match '(?i)WHEA-Logger' -and $id -in @(1, 17, 18, 19, 20, 46, 47)) { return 'whea' }
    if (($provider -match '(?i)Kernel-Power' -and $id -eq 41) -or ($provider -match '(?i)^EventLog$' -and $id -eq 6008)) { return 'unexpectedShutdown' }
    if ($provider -match '(?i)Resource-Exhaustion-Detector' -and $id -eq 2004) { return 'resourceExhaustion' }
    if (($provider -match '(?i)^Display$' -and $id -eq 4101) -or ($id -eq 4101 -and $provider -match '(?i)(nvlddmkm|amdkmdag|igfx)')) { return 'displayReset' }
  }
  if ($LogName -eq 'Application') {
    if (($provider -match '(?i)^Application Error$' -and $id -eq 1000) -or
        ($provider -match '(?i)^Application Hang$' -and $id -eq 1002)) { return 'applicationFault' }
  }
  return $null
}

function Get-EventHealthSummary {
  param($EventRecord)
  $recordId = $null
  try { $recordId = [long]$EventRecord.RecordId } catch { }
  $level = $null
  try { $level = [int]$EventRecord.Level } catch { }
  $eventId = $null
  try { $eventId = [int]$EventRecord.Id } catch { }
  return [pscustomobject]@{
    timeUtc = Get-EventHealthUtc $EventRecord
    logName = Get-EventHealthField $EventRecord 'LogName'
    provider = Get-EventHealthProviderName $EventRecord
    id = $eventId
    level = $level
    recordId = $recordId
  }
}

function Get-EventHealthSnapshot {
  [CmdletBinding()]
  param(
    [ValidateRange(1, 30)][int]$WindowDays = 7,
    [ValidateRange(1, 5000)][int]$MaxEventsPerLog = 1000,
    [object[]]$SystemEvents,
    [object[]]$ApplicationEvents,
    [string]$SystemError,
    [string]$ApplicationError,
    [switch]$UseFixture
  )

  $windowStart = [DateTime]::UtcNow.AddDays(-$WindowDays)
  $capturedAt = [DateTime]::UtcNow.ToString('o')
  $logSpecs = @(
    [pscustomobject]@{ name = 'System'; events = $SystemEvents; error = $SystemError; ids = @(1,17,18,19,20,41,46,47,129,153,2004,4101,6008) },
    [pscustomobject]@{ name = 'Application'; events = $ApplicationEvents; error = $ApplicationError; ids = @(1000,1002) }
  )
  $logResults = @{}
  foreach ($spec in $logSpecs) {
    $attempted = [DateTime]::UtcNow.ToString('o')
    $errorText = [string]$spec.error
    $events = @()
    if ($UseFixture) {
      $events = @($spec.events | Where-Object {
        try { $null -ne $_.TimeCreated -and ([DateTime]$_.TimeCreated).ToUniversalTime() -ge $windowStart } catch { $false }
      } | Select-Object -First $MaxEventsPerLog)
    } elseif (-not $errorText) {
      try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = $spec.name; StartTime = $windowStart; Id = $spec.ids } -MaxEvents $MaxEventsPerLog -ErrorAction Stop)
      } catch {
        if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') { $events = @() }
        else { $errorText = $_.Exception.Message }
      }
    }
    $logResults[$spec.name] = [pscustomobject]@{
      events = @($events)
      coverage = Get-EventHealthCoverage -Count $events.Count -Limit $MaxEventsPerLog -AttemptedAtUtc $attempted -Reason $errorText
    }
  }

  $categoryLogs = [ordered]@{
    storage = @('System'); whea = @('System'); unexpectedShutdown = @('System')
    resourceExhaustion = @('System'); displayReset = @('System'); applicationFault = @('Application')
  }
  $categories = [ordered]@{}
  foreach ($category in $categoryLogs.Keys) {
    $matched = @()
    foreach ($logName in $categoryLogs[$category]) {
      foreach ($event in @($logResults[$logName].events)) {
        if ((Get-EventHealthCategoryName -EventRecord $event -LogName $logName) -eq $category) { $matched += $event }
      }
    }
    $latest = $null
    if ($matched.Count -gt 0) {
      $latestEvent = $matched | Sort-Object { Get-EventHealthUtc $_ } -Descending | Select-Object -First 1
      $latest = Get-EventHealthSummary $latestEvent
    }
    $coverageStates = @($categoryLogs[$category] | ForEach-Object { [string]$logResults[$_].coverage.status })
    $categoryCoverage = if ($coverageStates -contains 'UNKNOWN') { 'UNKNOWN' } elseif ($coverageStates -contains 'DEGRADED') { 'DEGRADED' } else { 'OK' }
    $categories[$category] = [pscustomobject]@{ count = if ($categoryCoverage -eq 'UNKNOWN') { $null } else { $matched.Count }; latest = $latest; coverage = $categoryCoverage }
  }
  return [pscustomobject]@{
    schemaVersion = 1
    capturedAtUtc = $capturedAt
    windowStartUtc = $windowStart.ToString('o')
    windowDays = $WindowDays
    categories = [pscustomobject]$categories
    coverage = [pscustomobject]@{ System = $logResults.System.coverage; Application = $logResults.Application.coverage }
  }
}

if (-not $LibraryOnly) {
  $snapshot = Get-EventHealthSnapshot -WindowDays $WindowDays -MaxEventsPerLog $MaxEventsPerLog
  if ($AsObject) { $snapshot } else { ConvertTo-Json -InputObject $snapshot -Depth 8 -Compress }
}
