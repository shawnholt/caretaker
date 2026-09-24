$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\lease.ps1')

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
  Write-Output "PASS: $Message"
}

function New-FixtureBackend {
  param($Fixture)
  return [pscustomobject]@{
    GetOwnerProcess = { param($pid) return [pscustomobject]@{ pid = [int]$pid; creationTimeUtc = '2026-09-23T12:00:00Z'; executablePath = 'C:\fixture\owner.exe'; parentPid = 10 } }.GetNewClosure()
    GetSession = { param($name)
      $Fixture.events += "GetSession:$name"
      if ($Fixture.session -and $Fixture.session.sessionName -eq $name) { return $Fixture.session }
      return [pscustomobject]@{ sessionName = $name; state = 'NOT_FOUND'; leaseId = $null; ownershipVerified = $false }
    }.GetNewClosure()
    ArmExpiry = { param($request)
      $Fixture.events += 'ArmExpiry'
      if ($Fixture.armFails) { return [pscustomobject]@{ armed = $false } }
      $Fixture.task = [pscustomobject]@{ exists = $true; taskName = $request.taskName; leaseId = $request.leaseId; enabled = $true; actionVerified = $true }
      return [pscustomobject]@{ armed = $true }
    }.GetNewClosure()
    GetExpiry = { param($request)
      $Fixture.events += 'GetExpiry'
      if ($Fixture.task -and $Fixture.task.taskName -eq $request.taskName -and $Fixture.task.leaseId -eq $request.leaseId) { return $Fixture.task }
      return [pscustomobject]@{ exists = $false; taskName = $request.taskName; leaseId = $request.leaseId; enabled = $false; actionVerified = $false }
    }.GetNewClosure()
    StartSession = { param($record)
      $Fixture.events += 'StartSession'
      if (-not $Fixture.task.enabled -or -not $Fixture.task.actionVerified) { throw 'expiry not armed' }
      $Fixture.session = [pscustomobject]@{ sessionName = $record.nativeSessionId; leaseId = $record.leaseId; state = 'RUNNING'; ownershipVerified = $true }
    }.GetNewClosure()
    StopSession = { param($record)
      $Fixture.events += 'StopSession'
      if ($Fixture.stopFails) { return }
      $Fixture.session = [pscustomobject]@{ sessionName = $record.nativeSessionId; leaseId = $record.leaseId; state = 'NOT_FOUND'; ownershipVerified = $true }
    }.GetNewClosure()
    RemoveExpiry = { param($record)
      $Fixture.events += 'RemoveExpiry'
      $Fixture.expiryRequestIncludesDeadline = -not [string]::IsNullOrWhiteSpace([string]$record.expiresAtUtc)
      if ($Fixture.removeFails) { throw 'fixture task removal failure' }
      $Fixture.task = [pscustomobject]@{ exists = $false; taskName = $record.expiryTaskName; leaseId = $record.leaseId; enabled = $false; actionVerified = $false }
    }.GetNewClosure()
  }
}

$evidenceRoot = Join-Path (Join-Path $PSScriptRoot '..') ('evidence/lease-smoke-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$statePath = Join-Path $evidenceRoot 'active-lease.json'
$manifest = [pscustomobject]@{
  deployment = [pscustomobject]@{ storageBudgetMiB = 1024 }
  leasePolicy = [pscustomobject]@{ captureLaunchEnabled = $false; requireIndependentExpiry = $true; maximumDurationSeconds = 300; expiryTaskName = 'GoliathCaretaker-LeaseExpiry-R1' }
}
$fixture = @{ events = @(); task = $null; session = $null; armFails = $false; stopFails = $false; removeFails = $false; expiryRequestIncludesDeadline = $false }
$backend = New-FixtureBackend $fixture

$utcCreation = Convert-LeaseCreationTimeToUtc -Value ([DateTime]::SpecifyKind([DateTime]'2026-09-23T12:00:00', [DateTimeKind]::Utc))
Assert-True ($utcCreation.ToString('o') -eq '2026-09-23T12:00:00.0000000Z') 'DateTime CIM creation values preserve UTC identity'
if ($IsWindows) {
  $dmtfCreation = Convert-LeaseCreationTimeToUtc -Value '20260923120000.000000-240'
  Assert-True ($dmtfCreation.ToString('o') -eq '2026-09-23T16:00:00.0000000Z') 'DMTF CIM creation strings convert their UTC offset correctly'
} else {
  Write-Output 'SKIP: DMTF CIM conversion requires Windows Management.'
}

$denied = $false
try {
  Start-CaretakerLease -Manifest $manifest -Backend $backend -StatePath $statePath -EvidenceRoot $evidenceRoot -Owner 'fixture' -Purpose 'fixture capture' -Target 'system-performance' -OutputPath (Join-Path $evidenceRoot 'capture.blg') -OutputLimitBytes 1048576 -DurationSeconds 10 -OwnerProcessId 42 | Out-Null
} catch { $denied = $_.Exception.Message -like '*disabled by the canonical manifest*' }
Assert-True $denied 'disabled manifest blocks launch before any backend operation'
Assert-True ($fixture.events.Count -eq 0) 'disabled launch performs no expiry or collector operation'

$manifest.leasePolicy.captureLaunchEnabled = $true
$fixture.armFails = $true
$armDenied = $false
$armStatePath = Join-Path $evidenceRoot 'arm-failed.json'
try {
  Start-CaretakerLease -Manifest $manifest -Backend $backend -StatePath $armStatePath -EvidenceRoot $evidenceRoot -Owner 'fixture' -Purpose 'fixture capture' -Target 'system-performance' -OutputPath (Join-Path $evidenceRoot 'capture.blg') -OutputLimitBytes 1048576 -DurationSeconds 10 -OwnerProcessId 42 | Out-Null
} catch { $armDenied = $_.Exception.Message -match 'proven armed' }
Assert-True $armDenied 'failed expiry arming refuses collector launch'
Assert-True (-not ($fixture.events -contains 'StartSession')) 'collector launch does not occur after expiry arm failure'
Assert-True ((Get-Content -LiteralPath $armStatePath -Raw | ConvertFrom-Json).cleanupStatus -eq 'EXPIRY_ARM_FAILED') 'failed expiry arm leaves a visible recovery record'

$fixture.events = @()
$fixture.armFails = $false
$record = Start-CaretakerLease -Manifest $manifest -Backend $backend -StatePath $statePath -EvidenceRoot $evidenceRoot -Owner 'fixture' -Purpose 'fixture capture' -Target 'system-performance' -OutputPath (Join-Path $evidenceRoot 'capture.blg') -OutputLimitBytes 1048576 -DurationSeconds 10 -OwnerProcessId 42
Assert-True ($record.cleanupStatus -eq 'RUNNING' -and $record.nativeSessionId -eq "GoliathCaretaker-Lease-$($record.leaseId)") 'launch records a unique exact native session'
Assert-True ([Array]::IndexOf($fixture.events, 'ArmExpiry') -lt [Array]::IndexOf($fixture.events, 'StartSession')) 'independent expiry is armed before native capture launch'

$wrongRejected = $false
try { Stop-CaretakerLease -StatePath $statePath -Backend $backend -LeaseId ([Guid]::NewGuid().ToString('N')) | Out-Null } catch { $wrongRejected = $_.Exception.Message -like '*Lease ID does not match*' }
Assert-True ($wrongRejected -and -not ($fixture.events -contains 'StopSession')) 'wrong lease identity never issues native stop'

$fixture.events = @()
$stopped = Stop-CaretakerLease -StatePath $statePath -Backend $backend -LeaseId $record.leaseId
Assert-True ($stopped.state -eq 'STOPPED' -and $stopped.lease.cleanupStatus -eq 'STOPPED') 'cleanup succeeds only after session and expiry removal verification'
Assert-True ($fixture.events -contains 'RemoveExpiry' -and $fixture.expiryRequestIncludesDeadline) 'only the exact lease expiry task with its recorded deadline is removed after native stop'

$fixture = @{ events = @(); task = $null; session = $null; armFails = $false; stopFails = $true; removeFails = $false; expiryRequestIncludesDeadline = $false }
$backend = New-FixtureBackend $fixture
$statePath2 = Join-Path $evidenceRoot 'failed-cleanup.json'
$fixture.armFails = $false
$record2 = Start-CaretakerLease -Manifest $manifest -Backend $backend -StatePath $statePath2 -EvidenceRoot $evidenceRoot -Owner 'fixture' -Purpose 'fixture capture' -Target 'system-performance' -OutputPath (Join-Path $evidenceRoot 'capture2.blg') -OutputLimitBytes 1048576 -DurationSeconds 10 -OwnerProcessId 42
$failed = Stop-CaretakerLease -StatePath $statePath2 -Backend $backend -LeaseId $record2.leaseId -VerificationAttempts 3
Assert-True ($failed.state -eq 'STOP_FAILED' -and $failed.lease.cleanupStatus -eq 'STOP_FAILED') 'unverified cleanup remains STOP_FAILED'
Assert-True (-not ($fixture.events -contains 'RemoveExpiry')) 'expiry task remains armed when cleanup cannot be proved'

$fixture = @{ events = @(); task = $null; session = $null; armFails = $false; stopFails = $false; removeFails = $false; expiryRequestIncludesDeadline = $false }
$backend = New-FixtureBackend $fixture
$statePath3 = Join-Path $evidenceRoot 'missing-expiry.json'
$record3 = Start-CaretakerLease -Manifest $manifest -Backend $backend -StatePath $statePath3 -EvidenceRoot $evidenceRoot -Owner 'fixture' -Purpose 'fixture capture' -Target 'system-performance' -OutputPath (Join-Path $evidenceRoot 'capture3.blg') -OutputLimitBytes 1048576 -DurationSeconds 10 -OwnerProcessId 42
$fixture.task = $null
$missingExpiry = Stop-CaretakerLease -StatePath $statePath3 -Backend $backend -LeaseId $record3.leaseId
Assert-True ($missingExpiry.state -eq 'STOPPED_EXPIRY_MISSING' -and $missingExpiry.lease.cleanupStatus -eq 'STOPPED_EXPIRY_MISSING') 'known GUID session still stops when its expiry task is already missing'

$fixture = @{ events = @(); task = $null; session = $null; armFails = $false; stopFails = $false; removeFails = $false; expiryRequestIncludesDeadline = $false }
$backend = New-FixtureBackend $fixture
$statePath4 = Join-Path $evidenceRoot 'changed-expiry.json'
$record4 = Start-CaretakerLease -Manifest $manifest -Backend $backend -StatePath $statePath4 -EvidenceRoot $evidenceRoot -Owner 'fixture' -Purpose 'fixture capture' -Target 'system-performance' -OutputPath (Join-Path $evidenceRoot 'capture4.blg') -OutputLimitBytes 1048576 -DurationSeconds 10 -OwnerProcessId 42
$fixture.task.actionVerified = $false
$changedExpiry = Stop-CaretakerLease -StatePath $statePath4 -Backend $backend -LeaseId $record4.leaseId
Assert-True ($changedExpiry.state -eq 'STOPPED_EXPIRY_UNKNOWN' -and -not ($fixture.events -contains 'RemoveExpiry')) 'changed task is preserved while the exact collector is still cleaned up'

$fixture = @{ events = @(); task = $null; session = $null; armFails = $false; stopFails = $false; removeFails = $true }
$backend = New-FixtureBackend $fixture
$statePath5 = Join-Path $evidenceRoot 'remove-failed-expiry.json'
$record5 = Start-CaretakerLease -Manifest $manifest -Backend $backend -StatePath $statePath5 -EvidenceRoot $evidenceRoot -Owner 'fixture' -Purpose 'fixture capture' -Target 'system-performance' -OutputPath (Join-Path $evidenceRoot 'capture5.blg') -OutputLimitBytes 1048576 -DurationSeconds 10 -OwnerProcessId 42
$removeFailed = Stop-CaretakerLease -StatePath $statePath5 -Backend $backend -LeaseId $record5.leaseId
Assert-True ($removeFailed.state -eq 'STOPPED_EXPIRY_REMOVE_FAILED' -and $removeFailed.lease.cleanupStatus -eq 'STOPPED_EXPIRY_REMOVE_FAILED') 'expiry removal failure is recorded after native collector stop'

Write-Output 'Lease fixture smoke checks passed.'
Remove-Item -LiteralPath $evidenceRoot -Recurse -Force
