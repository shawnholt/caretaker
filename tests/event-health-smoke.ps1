$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\event-health.ps1') -LibraryOnly

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "FAIL: $Message" }
  Write-Output "PASS: $Message"
}

$now = [DateTime]::UtcNow
$systemEvents = @(
  [pscustomobject]@{ TimeCreated = $now.AddMinutes(-20); LogName = 'System'; ProviderName = 'storahci'; Id = 129; Level = 3; RecordId = 101 },
  [pscustomobject]@{ TimeCreated = $now.AddMinutes(-10); LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; Level = 1; RecordId = 102 },
  [pscustomobject]@{ TimeCreated = $now.AddMinutes(-5); LogName = 'System'; ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Detector'; Id = 2004; Level = 2; RecordId = 103 },
  [pscustomobject]@{ TimeCreated = $now.AddDays(-9); LogName = 'System'; ProviderName = 'storahci'; Id = 153; Level = 3; RecordId = 90 }
)
$applicationEvents = @(
  [pscustomobject]@{ TimeCreated = $now.AddMinutes(-3); LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; Level = 2; RecordId = 201 },
  [pscustomobject]@{ TimeCreated = $now.AddMinutes(-1); LogName = 'Application'; ProviderName = 'Application Hang'; Id = 1002; Level = 2; RecordId = 202 }
)

$snapshot = Get-EventHealthSnapshot -WindowDays 7 -MaxEventsPerLog 20 -SystemEvents $systemEvents -ApplicationEvents $applicationEvents -UseFixture
Assert-True ($snapshot.schemaVersion -eq 1) 'snapshot has a versioned JSON contract'
Assert-True ($snapshot.categories.storage.count -eq 1 -and $snapshot.categories.storage.latest.id -eq 129) 'storage summary counts selected 129/153 events within the time window'
Assert-True ($snapshot.categories.unexpectedShutdown.count -eq 1 -and $snapshot.categories.unexpectedShutdown.latest.provider -eq 'Microsoft-Windows-Kernel-Power') 'unexpected shutdown summary recognizes Kernel-Power 41'
Assert-True ($snapshot.categories.resourceExhaustion.count -eq 1) 'resource exhaustion summary recognizes event 2004'
Assert-True ($snapshot.categories.applicationFault.count -eq 2 -and $snapshot.categories.applicationFault.latest.id -eq 1002) 'application summary includes crash and hang events and returns the newest'
Assert-True ($snapshot.coverage.System.status -eq 'OK' -and $snapshot.coverage.Application.status -eq 'OK') 'successful under-cap queries report complete coverage'

$partial = Get-EventHealthSnapshot -WindowDays 7 -MaxEventsPerLog 2 -SystemEvents @($systemEvents[0], $systemEvents[1]) -ApplicationEvents $applicationEvents -UseFixture
Assert-True ($partial.coverage.System.status -eq 'DEGRADED' -and $partial.categories.storage.coverage -eq 'DEGRADED') 'reaching the per-log read cap marks matching counts partial'

$unknown = Get-EventHealthSnapshot -WindowDays 7 -MaxEventsPerLog 20 -SystemEvents @() -ApplicationEvents $applicationEvents -SystemError 'Access denied.' -UseFixture
Assert-True ($unknown.coverage.System.status -eq 'UNKNOWN' -and $null -eq $unknown.categories.whea.count -and $unknown.categories.whea.coverage -eq 'UNKNOWN') 'unavailable log coverage remains UNKNOWN instead of reporting zero'
