$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\caretaker.ps1') -Action status -LibraryOnly

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "FAIL: $Message" }
  Write-Output "PASS: $Message"
}

$config = Get-Config
$snapshot = Read-JsonFile -Path $script:SnapshotPath
if ($null -eq $snapshot) { throw 'FAIL: snapshot has not been captured.' }

Assert-True ($config.desired.approvedWorkloads.Count -eq 0 -and $config.desired.listeners.Count -eq 0) 'canonical desired workload/listener lists remain empty'
Assert-True ($snapshot.desired.schemaVersion -eq $config.schemaVersion -and $snapshot.observed.processes.Count -gt 0) 'snapshot keeps manifest desired data separate from observed inventory'
Assert-True (-not ($snapshot.observed.processes[0].PSObject.Properties.Name -contains 'commandLine')) 'process command lines are not persisted'
Assert-True ($null -ne $snapshot.observed.services -and $null -ne $snapshot.observed.tasks -and $null -ne $snapshot.observed.startup) 'service, task, and startup inventories are present'

$left = [pscustomobject]@{ protocol = 'TCP'; localAddress = '127.0.0.1'; localPort = 54321; process = [pscustomobject]@{ pid = 10; creationTimeUtc = '2026-01-01T00:00:00Z' } }
$right = [pscustomobject]@{ protocol = 'TCP'; localAddress = '127.0.0.1'; localPort = 54321; process = [pscustomobject]@{ pid = 99; creationTimeUtc = '2026-02-01T00:00:00Z' } }
Assert-True ((Get-ListenerKey $left) -eq (Get-ListenerKey $right)) 'listener alert identity stays stable across process restarts'

$processBefore = [pscustomobject]@{ pid = 10; creationTimeUtc = '2026-01-01T00:00:00Z'; name = 'server.exe'; executablePath = 'C:\server.exe'; parentPid = 1; workingSetBytes = 1000 }
$processAfter = [pscustomobject]@{ pid = 10; creationTimeUtc = '2026-01-01T00:00:00Z'; name = 'server.exe'; executablePath = 'C:\server.exe'; parentPid = 1; workingSetBytes = 9000 }
$listenerBefore = [pscustomobject]@{ protocol = 'TCP'; localAddress = '127.0.0.1'; localPort = 65001; process = $processBefore }
$listenerAfter = [pscustomobject]@{ protocol = 'TCP'; localAddress = '127.0.0.1'; localPort = 65001; process = $processAfter }
$beforeDiff = ConvertTo-Json (Get-DiffSummary 'tcpListeners' $listenerBefore) -Depth 10 -Compress
$afterDiff = ConvertTo-Json (Get-DiffSummary 'tcpListeners' $listenerAfter) -Depth 10 -Compress
Assert-True ($beforeDiff -eq $afterDiff) 'listener diff summary ignores changing process memory counters'

$parentProcess = [pscustomobject]@{ pid = 1; parentPid = 0; creationTimeUtc = '2026-01-01T00:00:00Z' }
$childProcess = [pscustomobject]@{ pid = 2; parentPid = 1; creationTimeUtc = '2026-01-01T00:01:00Z' }
$futureParent = [pscustomobject]@{ pid = 3; parentPid = 2; creationTimeUtc = '2025-12-31T23:59:00Z' }
$resolvedProcesses = @(Add-ParentCreationTimes -Processes @($parentProcess, $childProcess, $futureParent))
Assert-True ($resolvedProcesses[1].parentCreationTimeUtc -eq $parentProcess.creationTimeUtc -and $null -eq $resolvedProcesses[2].parentCreationTimeUtc) 'parent creation time resolves only when the same-snapshot parent predates the child'

$startupBefore = [pscustomobject]@{ name = 'Updater'; location = 'Run'; user = 'User'; commandFingerprint = 'hash-one'; command = 'secret-before' }
$startupAfter = [pscustomobject]@{ name = 'Updater'; location = 'Run'; user = 'User'; commandFingerprint = 'hash-two'; command = 'secret-after' }
$startupDiffBefore = Get-DiffSummary 'startup' $startupBefore
$startupDiffAfter = Get-DiffSummary 'startup' $startupAfter
Assert-True ($startupDiffBefore.commandFingerprint -ne $startupDiffAfter.commandFingerprint -and -not ($startupDiffBefore.PSObject.Properties.Name -contains 'command')) 'startup target drift is hashed without persisting command text'

$legacyProcess = [pscustomobject]@{ pid = 30; creationTimeUtc = '2026-01-01T00:00:00Z'; name = 'legacy.exe'; executablePath = 'C:\legacy.exe'; parentPid = 1 }
$legacyTask = [pscustomobject]@{ name = 'LegacyTask'; path = '\'; enabled = $true; state = 'Ready' }
$legacyStartup = [pscustomobject]@{ name = 'LegacyStart'; location = 'Run'; user = 'User' }
Assert-True ($null -ne (Get-DiffSummary 'processes' $legacyProcess) -and $null -ne (Get-DiffSummary 'tasks' $legacyTask) -and $null -ne (Get-DiffSummary 'startup' $legacyStartup)) 'diff summaries accept pre-fingerprint snapshots with optional fields missing'
$attemptHealth = Get-AttemptHealth ([pscustomobject]@{ state = 'ERROR'; reason = 'fixture failure'; completedAtUtc = '2026-01-01T00:00:00Z' })
Assert-True ($attemptHealth.state -eq 'ERROR' -and $attemptHealth.detail -eq 'fixture failure') 'a failed latest attempt remains an error regardless of prior snapshot freshness'

$tcpFixture = [pscustomobject]@{ protocol = 'TCP'; localAddress = '127.0.0.1'; localPort = 65001; process = $processBefore }
$udpFixture = [pscustomobject]@{ protocol = 'UDP'; localAddress = '127.0.0.1'; localPort = 65002; process = $processBefore }
$inventory = [pscustomobject]@{
  items = [pscustomobject]@{ tcpListeners = @($tcpFixture); udpEndpoints = @($udpFixture); services = @(); tasks = @() }
  coverage = [pscustomobject]@{
    tcpListeners = [pscustomobject]@{ status = 'OK' }; udpEndpoints = [pscustomobject]@{ status = 'OK' }
    services = [pscustomobject]@{ status = 'OK' }; tasks = [pscustomobject]@{ status = 'OK' }
  }
}
$baseline = [pscustomobject]@{ observed = [pscustomobject]@{ tcpListeners = @(); udpEndpoints = @() } }
$baselineCandidates = Get-AlertCandidates -Inventory $inventory -Desired $config.desired -PreviousSnapshot $null
$afterBaselineCandidates = Get-AlertCandidates -Inventory $inventory -Desired $config.desired -PreviousSnapshot $baseline
Assert-True ($baselineCandidates.Count -eq 0) 'first snapshot establishes a listener baseline without alerting on existing endpoints'
Assert-True ($afterBaselineCandidates.Count -eq 1 -and $afterBaselineCandidates.Values[0].rule -eq 'unreviewed-listener') 'post-baseline TCP listeners alert; UDP endpoints remain drift-only'

$approved = [pscustomobject]@{ listeners = @([pscustomobject]@{ protocol = 'TCP'; localAddress = '127.0.0.1'; localPort = 65001; executablePath = 'C:\server.exe' }) }
Assert-True (Test-ListenerApproved -Listener $tcpFixture -Desired $approved) 'listener approval matches the declared executable identity'
$otherProcess = [pscustomobject]@{ pid = 20; creationTimeUtc = '2026-01-01T00:00:00Z'; name = 'other.exe'; executablePath = 'C:\other.exe'; parentPid = 1 }
$otherListener = [pscustomobject]@{ protocol = 'TCP'; localAddress = '127.0.0.1'; localPort = 65001; process = $otherProcess }
Assert-True (-not (Test-ListenerApproved -Listener $otherListener -Desired $approved)) 'a different executable cannot inherit listener approval by port alone'

if (Test-Path -LiteralPath $script:OutboxPath -PathType Leaf) {
  $events = @(Get-Content -LiteralPath $script:OutboxPath | ForEach-Object { $_ | ConvertFrom-Json })
  $opens = @($events | Where-Object { $_.event -eq 'open' })
  $duplicates = @($opens | Group-Object { $_.alert.id } | Where-Object { $_.Count -gt 1 })
  Assert-True ($duplicates.Count -eq 0) 'local alert outbox contains no duplicate open event for an alert identity'
}

$fixedNow = [DateTime]::Parse('2026-09-23T12:00:00Z').ToUniversalTime()
Assert-True (Test-RetentionDue -Marker $null -NowUtc $fixedNow) 'missing retention marker is due'
Assert-True (Test-RetentionDue -Marker ([pscustomobject]@{ nextDueUtc = '2026-09-23T11:59:59Z' }) -NowUtc $fixedNow) 'past retention deadline is due'
Assert-True (-not (Test-RetentionDue -Marker ([pscustomobject]@{ nextDueUtc = '2026-09-23T12:00:01Z' }) -NowUtc $fixedNow)) 'future retention deadline skips Apply'
Assert-True (-not (Test-RetentionDue -Marker ([pscustomobject]@{ nextDueUtc = 'not-a-time' }) -NowUtc $fixedNow)) 'invalid retention deadline does not trigger Apply'
$retentionMissing = [pscustomobject]@{ state = 'OK'; marker = 'MISSING' }
Assert-True ((Get-RetentionDoctorState -Retention $retentionMissing -Installed $false) -eq 'UNKNOWN') 'missing retention marker before install is unknown'
Assert-True ((Get-RetentionDoctorState -Retention $retentionMissing -Installed $true) -eq 'WARN') 'installed caretaker with no retention marker needs first tick'
$retentionCurrent = [pscustomobject]@{ state = 'OK'; marker = 'CURRENT' }
Assert-True ((Get-RetentionDoctorState -Retention $retentionCurrent -Installed $true) -eq 'PASS') 'current retention marker passes after tick'
Assert-True ((Get-LeaseStartDoctorState -CaptureLaunchEnabled $false -ExpiryTaskName '') -eq 'INFO') 'disabled on-demand capture is informational by policy'
