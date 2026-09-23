[CmdletBinding()]
param(
  [ValidateSet('Status','Start','Stop','Expiry')][string]$Action = 'Status',
  [string]$StatePath,
  [string]$LeaseId,
  [string]$Owner,
  [string]$Purpose,
  [string]$Target = 'system-performance',
  [string]$OutputPath,
  [long]$OutputLimitBytes = 536870912,
  [int]$DurationSeconds = 60,
  [int]$OwnerProcessId = $PID
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-LeaseUtcStamp { [DateTime]::UtcNow.ToString('o') }

function Convert-LeaseCreationTimeToUtc {
  param([Parameter(Mandatory = $true)]$Value)
  if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
  return [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$Value).ToUniversalTime()
}

function Assert-LeaseBackend {
  param([Parameter(Mandatory = $true)]$Backend)
  $required = @('GetOwnerProcess','GetSession','ArmExpiry','GetExpiry','StartSession','StopSession','RemoveExpiry')
  foreach ($name in $required) {
    if ($null -eq $Backend.PSObject.Properties[$name] -or $Backend.$name -isnot [scriptblock]) {
      throw "Lease backend is missing required operation: $name"
    }
  }
}

function Invoke-LeaseBackend {
  param([Parameter(Mandatory = $true)]$Backend, [Parameter(Mandatory = $true)][string]$Operation, [Parameter(Mandatory = $true)]$Argument)
  return (& $Backend.$Operation $Argument)
}

function Get-LeaseProcessIdentity {
  param([Parameter(Mandatory = $true)]$Backend, [Parameter(Mandatory = $true)][int]$ProcessId)
  $identity = Invoke-LeaseBackend -Backend $Backend -Operation 'GetOwnerProcess' -Argument $ProcessId
  if ($null -eq $identity -or [int]$identity.pid -ne $ProcessId -or [string]::IsNullOrWhiteSpace([string]$identity.creationTimeUtc) -or [string]::IsNullOrWhiteSpace([string]$identity.executablePath)) {
    throw 'Owner process identity is UNKNOWN or incomplete; lease launch refused.'
  }
  try { [void][DateTime]::Parse([string]$identity.creationTimeUtc).ToUniversalTime() } catch { throw 'Owner process creationTimeUtc is invalid; lease launch refused.' }
  return [pscustomobject]@{
    pid = $ProcessId
    creationTimeUtc = [DateTime]::Parse([string]$identity.creationTimeUtc).ToUniversalTime().ToString('o')
    executablePath = [string]$identity.executablePath
    parentPid = if ($null -ne $identity.PSObject.Properties['parentPid']) { $identity.parentPid } else { $null }
  }
}

function Assert-LeaseRecord {
  param($Record)
  $required = @('leaseId','owner','purpose','target','startedAtUtc','expiresAtUtc','outputPath','outputLimitBytes','nativeBackend','nativeSessionId','processInstance','cleanupMethod','expiryTaskName','expiryArmed','cleanupStatus')
  foreach ($name in $required) {
    if ($null -eq $Record.PSObject.Properties[$name]) { throw "Lease record missing required field: $name" }
  }
  if ([string]$Record.nativeBackend -ne 'logman' -or [string]$Record.nativeSessionId -notmatch '^GoliathCaretaker-Lease-[0-9a-f]{32}$') {
    throw 'Lease record has an unsupported or non-unique native session identity.'
  }
  if ([string]::IsNullOrWhiteSpace([string]$Record.expiryTaskName)) { throw 'Lease expiry task identity is empty.' }
}

function Write-LeaseRecord {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Record)
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  $tempPath = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
  try {
    $json = ConvertTo-Json -InputObject $Record -Depth 20
    [System.IO.File]::WriteAllText($tempPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
  } finally {
    if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force }
  }
}

function Read-LeaseRecord {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $record = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
  Assert-LeaseRecord -Record $record
  return $record
}

function Open-LeaseStateLock {
  param([Parameter(Mandatory = $true)][string]$StatePath)
  $parent = Split-Path -Parent $StatePath
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  $lockPath = $StatePath + '.lock'
  for ($attempt = 0; $attempt -lt 120; $attempt++) {
    try { return [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
    catch [System.IO.IOException] { Start-Sleep -Milliseconds 500 }
  }
  throw 'Lease state is busy; bounded lock wait expired.'
}

function Get-LeaseEvidenceUsage {
  param([Parameter(Mandatory = $true)][string]$EvidenceRoot)
  if (-not (Test-Path -LiteralPath $EvidenceRoot -PathType Container)) { return [long]0 }
  $total = [long]0
  $knownFiles = @('snapshot.json','alert-state.json','outbox.jsonl','changes.jsonl','last-attempt.json','active-lease.json','active-lease.json.lock')
  $files = @()
  foreach ($name in $knownFiles) {
    $path = Join-Path $EvidenceRoot $name
    if (Test-Path -LiteralPath $path -PathType Leaf) { $files += Get-Item -LiteralPath $path -ErrorAction Stop }
  }
  $files += @(Get-ChildItem -LiteralPath $EvidenceRoot -Filter '*.blg' -File -Force -ErrorAction Stop)
  foreach ($file in $files) { $total += [long]$file.Length }
  Add-LeaseCommandLog -Label 'lease evidence budget preflight' -Command "Get-Item known runtime files and Get-ChildItem -Filter *.blg -LiteralPath `"$EvidenceRoot`"" -Reason 'Sum known caretaker runtime files and direct PerfMon output files before approving a bounded capture.' -Output ("files=$($files.Count); bytes=$total")
  return $total
}

function Get-CaretakerLeaseStatus {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string]$StatePath, [Parameter(Mandatory = $true)]$Backend)
  Assert-LeaseBackend -Backend $Backend
  $record = Read-LeaseRecord -Path $StatePath
  if ($null -eq $record) { return [pscustomobject]@{ state = 'NONE'; lease = $null; detail = 'No lease record exists.' } }
  $observed = Invoke-LeaseBackend -Backend $Backend -Operation 'GetSession' -Argument ([string]$record.nativeSessionId)
  if ($null -eq $observed -or [string]$observed.sessionName -ne [string]$record.nativeSessionId) {
    return [pscustomobject]@{ state = 'UNKNOWN'; lease = $record; detail = 'Native session identity/ownership could not be proven.' }
  }
  if ([string]$observed.state -eq 'NOT_FOUND' -and [string]$record.cleanupStatus -in @('STOPPED','STOPPED_EXPIRY_MISSING')) {
    $expiryRequest = [pscustomobject]@{ taskName = [string]$record.expiryTaskName; leaseId = [string]$record.leaseId; expiresAtUtc = [string]$record.expiresAtUtc; statePath = [System.IO.Path]::GetFullPath($StatePath); scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath) }
    $expiry = Invoke-LeaseBackend -Backend $Backend -Operation 'GetExpiry' -Argument $expiryRequest
    if ($null -ne $expiry -and [string]$expiry.taskName -eq [string]$record.expiryTaskName -and -not [bool]$expiry.exists) {
      $state = if ([string]$record.cleanupStatus -eq 'STOPPED_EXPIRY_MISSING') { 'STOPPED_EXPIRY_MISSING' } else { 'STOPPED' }
      return [pscustomobject]@{ state = $state; lease = $record; detail = 'Stored cleanup proof and native absence are confirmed; the expiry task is absent.' }
    }
  }
  if ([string]$observed.leaseId -ne [string]$record.leaseId -or -not [bool]$observed.ownershipVerified) {
    return [pscustomobject]@{ state = 'UNKNOWN'; lease = $record; detail = 'Native session identity/ownership could not be proven.' }
  }
  $state = if ([string]$observed.state -eq 'RUNNING') { 'RUNNING' } elseif ([string]$observed.state -eq 'NOT_FOUND') { 'STOP_PENDING_CLEANUP' } elseif ([string]$observed.state -eq 'STOPPED') { 'STOP_PENDING_CLEANUP' } else { 'UNKNOWN' }
  return [pscustomobject]@{ state = $state; lease = $record; detail = "Exact native session reported $($observed.state)." }
}

function Start-CaretakerLease {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]$Manifest,
    [Parameter(Mandatory = $true)]$Backend,
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [Parameter(Mandatory = $true)][string]$Owner,
    [Parameter(Mandatory = $true)][string]$Purpose,
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][long]$OutputLimitBytes,
    [int]$DurationSeconds = 60,
    [int]$OwnerProcessId = $PID
  )
  Assert-LeaseBackend -Backend $Backend
  if (-not [bool]$Manifest.leasePolicy.captureLaunchEnabled) { throw 'Lease launch is disabled by the canonical manifest.' }
  if (-not [bool]$Manifest.leasePolicy.requireIndependentExpiry) { throw 'Independent expiry is required by policy but is not enabled.' }
  if ([string]::IsNullOrWhiteSpace([string]$Manifest.leasePolicy.expiryTaskName)) { throw 'Canonical manifest has no configured expiry task identity; lease launch refused.' }
  $leaseLock = Open-LeaseStateLock -StatePath $StatePath
  try {
  if ([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Purpose) -or [string]::IsNullOrWhiteSpace($Target)) { throw 'Owner, purpose, and target are mandatory.' }
  if ($Target -ne 'system-performance') { throw 'This Release 1 native backend supports only target=system-performance.' }
  $maxDuration = [int]$Manifest.leasePolicy.maximumDurationSeconds
  if ($DurationSeconds -lt 1 -or $DurationSeconds -gt $maxDuration) { throw "DurationSeconds must be from 1 through $maxDuration." }
  if ($OutputLimitBytes -lt 1048576 -or $OutputLimitBytes -gt 536870912) { throw 'OutputLimitBytes must be from 1048576 through 536870912 for native circular logman output.' }
  $evidenceUsedBytes = Get-LeaseEvidenceUsage -EvidenceRoot $EvidenceRoot
  $storageBudgetBytes = [long]$Manifest.deployment.storageBudgetMiB * 1048576
  if ($storageBudgetBytes -lt 1 -or ($evidenceUsedBytes + $OutputLimitBytes) -gt $storageBudgetBytes) { throw 'Evidence storage budget is exceeded or unknown; lease launch refused.' }
  $rootFull = [System.IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\') + '\'
  $outputFull = [System.IO.Path]::GetFullPath($OutputPath)
  if (-not $outputFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Parent $outputFull) -ine $rootFull.TrimEnd('\')) { throw 'Output path must be a direct file beneath the ignored evidence root.' }
  $stateFull = [System.IO.Path]::GetFullPath($StatePath)
  if (-not $stateFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'Lease state path must be beneath the ignored evidence root.' }
  $prior = Read-LeaseRecord -Path $stateFull
  if ($null -ne $prior -and [string]$prior.cleanupStatus -ne 'STOPPED') { throw 'An earlier lease is not verified stopped; new capture refused.' }
  if (Test-Path -LiteralPath $outputFull) { throw 'Output path already exists; lease launch will not overwrite evidence.' }
  $identity = Get-LeaseProcessIdentity -Backend $Backend -ProcessId $OwnerProcessId
  $leaseGuid = [Guid]::NewGuid().ToString('N')
  $sessionName = "GoliathCaretaker-Lease-$leaseGuid"
  $taskName = [string]$Manifest.leasePolicy.expiryTaskName
  $now = [DateTime]::UtcNow
  $record = [pscustomobject]@{
    schemaVersion = 1; leaseId = $leaseGuid; owner = $Owner; purpose = $Purpose; target = $Target
    startedAtUtc = $now.ToString('o'); expiresAtUtc = $now.AddSeconds($DurationSeconds).ToString('o')
    outputPath = $outputFull; outputLimitBytes = $OutputLimitBytes; nativeBackend = 'logman'; nativeSessionId = $sessionName
    processInstance = $identity; cleanupMethod = "logman stop $sessionName"; expiryTaskName = $taskName
    evidenceUsedBeforeBytes = $evidenceUsedBytes; evidenceBudgetBytes = $storageBudgetBytes
    expiryArmed = $false; cleanupStatus = 'PREPARING'
  }
  Assert-LeaseRecord -Record $record
  $existing = Invoke-LeaseBackend -Backend $Backend -Operation 'GetSession' -Argument $sessionName
  if ($null -eq $existing -or [string]$existing.state -ne 'NOT_FOUND') { throw 'Unique native session preflight is UNKNOWN or conflicting; lease launch refused.' }
  Write-LeaseRecord -Path $StatePath -Record $record
  $armRequest = [pscustomobject]@{ taskName = $taskName; leaseId = $leaseGuid; expiresAtUtc = $record.expiresAtUtc; statePath = [System.IO.Path]::GetFullPath($StatePath); scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath); cleanupMethod = $record.cleanupMethod }
  try {
    $armResult = Invoke-LeaseBackend -Backend $Backend -Operation 'ArmExpiry' -Argument $armRequest
    $expiry = Invoke-LeaseBackend -Backend $Backend -Operation 'GetExpiry' -Argument $armRequest
  } catch {
    $record.cleanupStatus = 'EXPIRY_ARM_FAILED'
    Write-LeaseRecord -Path $StatePath -Record $record
    throw
  }
  if ($null -eq $armResult -or -not [bool]$armResult.armed -or $null -eq $expiry -or [string]$expiry.taskName -ne $taskName -or [string]$expiry.leaseId -ne $leaseGuid -or -not [bool]$expiry.enabled -or -not [bool]$expiry.actionVerified) {
    $record.cleanupStatus = 'EXPIRY_ARM_FAILED'
    Write-LeaseRecord -Path $StatePath -Record $record
    throw 'Independent expiry could not be proven armed for this exact lease; capture launch refused.'
  }
  $record.expiryArmed = $true
  $record.cleanupStatus = 'PREPARED'
  try {
    [void](Invoke-LeaseBackend -Backend $Backend -Operation 'StartSession' -Argument $record)
    $check = Invoke-LeaseBackend -Backend $Backend -Operation 'GetSession' -Argument $sessionName
    if ($null -eq $check -or [string]$check.sessionName -ne $sessionName -or [string]$check.leaseId -ne $leaseGuid -or -not [bool]$check.ownershipVerified -or [string]$check.state -ne 'RUNNING') {
      throw 'Native session launch did not produce a verifiable exact owned RUNNING session.'
    }
    $expiryAfterStart = Invoke-LeaseBackend -Backend $Backend -Operation 'GetExpiry' -Argument $armRequest
    if ($null -eq $expiryAfterStart -or -not [bool]$expiryAfterStart.enabled -or -not [bool]$expiryAfterStart.actionVerified) {
      throw 'Independent expiry was not still verified after native collector launch.'
    }
    $record.cleanupStatus = 'RUNNING'
    Write-LeaseRecord -Path $StatePath -Record $record
    return $record
  } catch {
      $record.cleanupStatus = 'START_FAILED_CLEANUP_REQUIRED'
      Write-LeaseRecord -Path $StatePath -Record $record
      throw
  }
  } finally { $leaseLock.Dispose() }
}

function Stop-CaretakerLease {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)]$Backend,
    [Parameter(Mandatory = $true)][string]$LeaseId,
    [ValidateRange(1,3)][int]$VerificationAttempts = 3
  )
  Assert-LeaseBackend -Backend $Backend
  $leaseLock = Open-LeaseStateLock -StatePath $StatePath
  try {
  $record = Read-LeaseRecord -Path $StatePath
  if ($null -eq $record) { throw 'No lease record exists.' }
  if ([string]$record.leaseId -ne $LeaseId) { throw 'Lease ID does not match; no cleanup action was taken.' }
  $native = Invoke-LeaseBackend -Backend $Backend -Operation 'GetSession' -Argument ([string]$record.nativeSessionId)
  if ([string]$record.cleanupStatus -eq 'STOPPED' -and $native -and [string]$native.state -eq 'NOT_FOUND') {
    $completedTaskRequest = [pscustomobject]@{ taskName = [string]$record.expiryTaskName; leaseId = [string]$record.leaseId; expiresAtUtc = [string]$record.expiresAtUtc; statePath = [System.IO.Path]::GetFullPath($StatePath); scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath) }
    $completedTask = Invoke-LeaseBackend -Backend $Backend -Operation 'GetExpiry' -Argument $completedTaskRequest
    if ($completedTask -and [string]$completedTask.taskName -eq [string]$record.expiryTaskName -and -not [bool]$completedTask.exists) { return [pscustomobject]@{ state = 'STOPPED'; detail = 'Lease cleanup was already verified.'; lease = $record } }
  }
  if ($null -eq $native -or [string]$native.sessionName -ne [string]$record.nativeSessionId -or [string]$native.leaseId -ne [string]$record.leaseId -or -not [bool]$native.ownershipVerified) {
    $record.cleanupStatus = 'STOP_FAILED'
    Write-LeaseRecord -Path $StatePath -Record $record
    return [pscustomobject]@{ state = 'STOP_FAILED'; detail = 'Native session identity/ownership could not be proven; no stop command was issued.'; lease = $record }
  }
  $verified = $false
  $lastStopError = $null
  for ($attempt = 1; $attempt -le $VerificationAttempts; $attempt++) {
    if ([string]$native.state -ne 'NOT_FOUND') {
      try { [void](Invoke-LeaseBackend -Backend $Backend -Operation 'StopSession' -Argument $record) } catch { $lastStopError = $_.Exception.Message }
    }
    $after = Invoke-LeaseBackend -Backend $Backend -Operation 'GetSession' -Argument ([string]$record.nativeSessionId)
    if ($null -ne $after -and [string]$after.sessionName -eq [string]$record.nativeSessionId -and [string]$after.leaseId -eq [string]$record.leaseId -and [bool]$after.ownershipVerified -and [string]$after.state -eq 'NOT_FOUND') { $verified = $true; break }
    if ($null -eq $after -or [string]$after.sessionName -ne [string]$record.nativeSessionId -or [string]$after.leaseId -ne [string]$record.leaseId -or -not [bool]$after.ownershipVerified) { break }
    $native = $after
  }
  if (-not $verified) {
    $record.cleanupStatus = 'STOP_FAILED'
    Write-LeaseRecord -Path $StatePath -Record $record
    $detail = "Exact owned session remained active or unverifiable after $VerificationAttempts bounded checks."
    if ($lastStopError) { $detail += " Last stop error: $lastStopError" }
    return [pscustomobject]@{ state = 'STOP_FAILED'; detail = $detail; lease = $record }
  }
  $expiryRequest = [pscustomobject]@{ taskName = [string]$record.expiryTaskName; leaseId = [string]$record.leaseId; expiresAtUtc = [string]$record.expiresAtUtc; statePath = [System.IO.Path]::GetFullPath($StatePath); scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath) }
  $expiry = Invoke-LeaseBackend -Backend $Backend -Operation 'GetExpiry' -Argument $expiryRequest
  if ($null -ne $expiry -and [string]$expiry.taskName -eq [string]$record.expiryTaskName -and -not [bool]$expiry.exists) {
    $record.expiryArmed = $false
    $record.cleanupStatus = 'STOPPED_EXPIRY_MISSING'
    Write-LeaseRecord -Path $StatePath -Record $record
    return [pscustomobject]@{ state = 'STOPPED_EXPIRY_MISSING'; detail = 'Exact native collector is stopped; its expiry task was already absent.'; lease = $record }
  }
  if ($null -eq $expiry -or [string]$expiry.taskName -ne [string]$record.expiryTaskName -or [string]$expiry.leaseId -ne [string]$record.leaseId -or -not [bool]$expiry.actionVerified) {
    $record.cleanupStatus = 'STOPPED_EXPIRY_UNKNOWN'
    Write-LeaseRecord -Path $StatePath -Record $record
    return [pscustomobject]@{ state = 'STOPPED_EXPIRY_UNKNOWN'; detail = 'Native capture is verified stopped; expiry task identity could not be proven for exact removal.'; lease = $record }
  }
  try { [void](Invoke-LeaseBackend -Backend $Backend -Operation 'RemoveExpiry' -Argument $record) }
  catch {
    $record.cleanupStatus = 'STOPPED_EXPIRY_REMOVE_FAILED'
    Write-LeaseRecord -Path $StatePath -Record $record
    return [pscustomobject]@{ state = 'STOPPED_EXPIRY_REMOVE_FAILED'; detail = "Native capture is stopped but exact expiry task removal failed: $($_.Exception.Message)"; lease = $record }
  }
  $expiryAfter = Invoke-LeaseBackend -Backend $Backend -Operation 'GetExpiry' -Argument $expiryRequest
  if ($null -eq $expiryAfter -or [string]$expiryAfter.taskName -ne [string]$record.expiryTaskName -or [bool]$expiryAfter.exists) {
    $record.cleanupStatus = 'STOPPED_EXPIRY_REMOVE_FAILED'
    Write-LeaseRecord -Path $StatePath -Record $record
    return [pscustomobject]@{ state = 'STOPPED_EXPIRY_REMOVE_FAILED'; detail = 'Capture is verified stopped but its exact expiry task remains.'; lease = $record }
  }
  $record.cleanupStatus = 'STOPPED'
  Write-LeaseRecord -Path $StatePath -Record $record
  return [pscustomobject]@{ state = 'STOPPED'; detail = 'Exact native session is stopped and exact expiry task removal is verified.'; lease = $record }
  } finally { $leaseLock.Dispose() }
}

function Invoke-CaretakerLeaseExpiry {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][string]$StatePath, [Parameter(Mandatory = $true)]$Backend, [Parameter(Mandatory = $true)][string]$LeaseId)
  return Stop-CaretakerLease -StatePath $StatePath -Backend $Backend -LeaseId $LeaseId -VerificationAttempts 3
}

function Add-LeaseCommandLog {
  param([string]$Label, [string]$Command, [string]$Reason, [string]$Output)
  if ($Label -eq 'lease evidence budget preflight') { return }
  if ($Label -eq 'lease status invocation' -and $Output -notmatch '^ERROR:') { return }
  if ($Label -in @('lease task query', 'lease owner identity') -and $Output -match '^(state=|pid=|files=)') { return }
  $projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
  $logPath = Join-Path $projectRoot 'diag_log.txt'
  $stamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'
  if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -ge 1048576) {
    Move-Item -LiteralPath $logPath -Destination ($logPath + '.1') -Force
  }
  $detail = 'completed'
  if ($Label -in @('lease task query', 'lease owner identity')) { $detail = 'query failed' }
  elseif ($Label -eq 'lease expiry arm' -and $Output -ne 'Task registration returned successfully.') { $detail = 'arm failed' }
  elseif ($Label -eq 'lease expiry removal' -and $Output -ne 'Task unregistration returned successfully.') { $detail = 'removal failed' }
  elseif ($Output -match '^ERROR:') { $detail = 'failed' }
  elseif ($Output -match 'exitCode=([0-9]+)') { $detail = 'exitCode=' + $matches[1] }
  elseif ($Output -match '^\s*\{') {
    try {
      $result = $Output | ConvertFrom-Json -ErrorAction Stop
      if ($result.state) { $detail = 'state=' + [string]$result.state }
    } catch { $detail = 'completed; result unreadable' }
  }
  [System.IO.File]::AppendAllText($logPath, "`r`n[$stamp] $Label; outcome=$detail`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-LeaseLogman {
  param([string[]]$Arguments, [string]$Reason, [switch]$AllowFailure)
  $exe = Join-Path $env:SystemRoot 'System32\logman.exe'
  $rendered = '"' + $exe + '" ' + (($Arguments | ForEach-Object { if ([string]$_ -match '\s') { '"' + ([string]$_).Replace('"','\"') + '"' } else { [string]$_ } }) -join ' ')
  $output = @(& $exe @Arguments 2>&1)
  $exitCode = $LASTEXITCODE
  Add-LeaseCommandLog -Label 'lease logman' -Command $rendered -Reason $Reason -Output (($output | Out-String).TrimEnd() + "`r`nexitCode=$exitCode")
  if ($exitCode -ne 0 -and -not $AllowFailure) { throw "logman failed (exit $exitCode): $($output -join ' ')" }
  return [pscustomobject]@{ exitCode = $exitCode; text = ($output -join "`n") }
}

function Get-LeaseExpiryActionText {
  param($Request)
  $scriptPath = [System.IO.Path]::GetFullPath([string]$Request.scriptPath)
  $statePath = [System.IO.Path]::GetFullPath([string]$Request.statePath)
  return ('-NoProfile -File "{0}" -Action expiry -StatePath "{1}" -LeaseId {2}' -f $scriptPath, $statePath, [string]$Request.leaseId)
}

function New-NativeLeaseBackend {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)]$Manifest, [Parameter(Mandatory = $true)][string]$StatePath, [Parameter(Mandatory = $true)][string]$ScriptPath)
  $projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
  $canonicalStatePath = [System.IO.Path]::GetFullPath($StatePath)
  $canonicalScriptPath = [System.IO.Path]::GetFullPath($ScriptPath)
  $expiryTaskName = [string]$Manifest.leasePolicy.expiryTaskName
  if ([string]::IsNullOrWhiteSpace($expiryTaskName)) { $expiryTaskName = '' }
  $getExpiry = {
    param($Request)
    $expectedAction = Get-LeaseExpiryActionText $Request
    try {
      $task = Get-ScheduledTask -TaskName ([string]$Request.taskName) -ErrorAction Stop
      $actions = @($task.Actions)
      if ($actions.Count -ne 1) { return [pscustomobject]@{ exists = $true; taskName = [string]$Request.taskName; leaseId = [string]$Request.leaseId; enabled = $false; actionVerified = $false } }
      $execute = [System.IO.Path]::GetFullPath([string]$actions[0].Execute)
      $expectedExe = [System.IO.Path]::GetFullPath((Join-Path $PSHOME 'powershell.exe'))
      $triggers = @($task.Triggers)
      $exactTrigger = $false
      if ($triggers.Count -eq 1 -and $triggers[0].Enabled -and [string]::IsNullOrEmpty([string]$triggers[0].Repetition.Interval)) {
        try {
          $actualStart = [DateTime]::Parse([string]$triggers[0].StartBoundary).ToUniversalTime()
          $expectedStart = [DateTime]::Parse([string]$Request.expiresAtUtc).ToUniversalTime()
          $exactTrigger = [Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -le 2
        } catch { $exactTrigger = $false }
      }
      $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
      $principalVerified = ([string]$task.Principal.UserId -ieq $currentUser) -and ([string]$task.Principal.LogonType -eq 'S4U') -and ([string]$task.Principal.RunLevel -eq 'Limited')
      $exactAction = ([string]$execute -ieq [string]$expectedExe) -and ([string]$actions[0].Arguments -ceq $expectedAction) -and $exactTrigger -and $principalVerified
      $enabled = [bool]$task.Settings.Enabled
      Add-LeaseCommandLog -Label 'lease task query' -Command "Get-ScheduledTask -TaskName $($Request.taskName)" -Reason 'Verify the exact one-shot expiry task action and limited principal before relying on it.' -Output ("state=$($task.State); enabled=$enabled; actionVerified=$exactAction")
      return [pscustomobject]@{ exists = $true; taskName = [string]$Request.taskName; leaseId = [string]$Request.leaseId; enabled = $enabled; actionVerified = $exactAction }
    } catch {
      Add-LeaseCommandLog -Label 'lease task query' -Command "Get-ScheduledTask -TaskName $($Request.taskName)" -Reason 'Check for the exact lease expiry task.' -Output $_.Exception.Message
      if ($_.Exception.Message -like '*No MSFT_ScheduledTask objects found*' -or $_.Exception.Message -like '*does not exist*') {
        return [pscustomobject]@{ exists = $false; taskName = [string]$Request.taskName; leaseId = [string]$Request.leaseId; enabled = $false; actionVerified = $false }
      }
      return [pscustomobject]@{ exists = $true; taskName = [string]$Request.taskName; leaseId = [string]$Request.leaseId; enabled = $false; actionVerified = $false }
    }
  }.GetNewClosure()
  $backend = @{}
  $backend.GetOwnerProcess = {
    param([int]$ProcessId)
    try {
      $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
      if ($null -eq $process) { return $null }
      $createdAt = Convert-LeaseCreationTimeToUtc -Value $process.CreationDate
      $created = $createdAt.ToString('o')
      $detail = "pid=$ProcessId; processIdentityRead=true"
      Add-LeaseCommandLog -Label 'lease owner identity' -Command "Get-CimInstance Win32_Process -Filter ProcessId = $ProcessId" -Reason 'Bind the lease owner to a PID, creation time, executable path, and parent PID.' -Output $detail
      return [pscustomobject]@{ pid = $ProcessId; creationTimeUtc = $created; executablePath = [string]$process.ExecutablePath; parentPid = [int]$process.ParentProcessId }
    } catch { Add-LeaseCommandLog -Label 'lease owner identity' -Command "Get-CimInstance Win32_Process -Filter ProcessId = $ProcessId" -Reason 'Read exact owner process identity.' -Output $_.Exception.Message; return $null }
  }.GetNewClosure()
  $backend.GetExpiry = $getExpiry
  $backend.ArmExpiry = {
    param($Request)
    $before = & $getExpiry $Request
    if ($before.exists) { throw "Expiry task name already exists: $($Request.taskName)" }
    $execute = Join-Path $PSHOME 'powershell.exe'
    $action = New-ScheduledTaskAction -Execute $execute -Argument (Get-LeaseExpiryActionText $Request)
    $at = [DateTime]::Parse([string]$Request.expiresAtUtc).ToLocalTime()
    $trigger = New-ScheduledTaskTrigger -Once -At $at
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -StartWhenAvailable
    try {
      Register-ScheduledTask -TaskName ([string]$Request.taskName) -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description ("Goliath Caretaker lease expiry {0}" -f $Request.leaseId) -ErrorAction Stop | Out-Null
      Add-LeaseCommandLog -Label 'lease expiry arm' -Command "Register-ScheduledTask -TaskName $($Request.taskName) -Action <exact lease.ps1 expiry action> -Trigger <one-shot $($Request.expiresAtUtc)> -Principal <current user S4U, limited>" -Reason 'Arm independent cleanup before starting the native collector.' -Output 'Task registration returned successfully.'
      return [pscustomobject]@{ armed = $true }
    } catch {
      Add-LeaseCommandLog -Label 'lease expiry arm' -Command "Register-ScheduledTask -TaskName $($Request.taskName) -Action <exact lease.ps1 expiry action>" -Reason 'Arm independent cleanup before capture launch.' -Output $_.Exception.Message
      throw
    }
  }.GetNewClosure()
  $backend.GetSession = {
    param([string]$SessionName)
    $result = Invoke-LeaseLogman -Arguments @('query', $SessionName) -Reason 'Check the exact unique caretaker collector name.' -AllowFailure
    if ($result.exitCode -ne 0) {
      if ($result.text -match '(?i)not found|does not exist|cannot find') {
        $record = Read-LeaseRecord -Path $canonicalStatePath
        if ($null -ne $record -and [string]$record.nativeSessionId -eq $SessionName) {
          return [pscustomobject]@{ sessionName = $SessionName; state = 'NOT_FOUND'; leaseId = [string]$record.leaseId; ownershipVerified = $true }
        }
        return [pscustomobject]@{ sessionName = $SessionName; state = 'NOT_FOUND'; leaseId = $null; ownershipVerified = $false }
      }
      return [pscustomobject]@{ sessionName = $SessionName; state = 'UNKNOWN'; leaseId = $null; ownershipVerified = $false }
    }
    $state = if ($result.text -match '(?im)^\s*Status\s*:\s*Running\s*$') { 'RUNNING' } elseif ($result.text -match '(?im)^\s*Status\s*:\s*Stopped\s*$') { 'STOPPED' } else { 'UNKNOWN' }
    $record = Read-LeaseRecord -Path $canonicalStatePath
    if ($null -eq $record -or [string]$record.nativeSessionId -ne $SessionName) { return [pscustomobject]@{ sessionName = $SessionName; state = 'UNKNOWN'; leaseId = $null; ownershipVerified = $false } }
    $outputMatches = $result.text.IndexOf([string]$record.outputPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
    $owned = $outputMatches -and [string]$record.nativeSessionId -eq $SessionName
    return [pscustomobject]@{ sessionName = $SessionName; state = $state; leaseId = [string]$record.leaseId; ownershipVerified = $owned }
  }.GetNewClosure()
  $backend.StartSession = {
    param($Record)
    if ([string]$Record.target -ne 'system-performance') { throw 'Native logman backend supports target=system-performance only.' }
    if ([string]$Record.expiryTaskName -ne $expiryTaskName) { throw 'Lease expiry task differs from the canonical manifest identity.' }
    $paths = @($Manifest.deployment.perfmon.counterPaths | ForEach-Object { [string]$_ })
    if ($paths.Count -eq 0) { throw 'Manifest has no approved PerfMon counter paths.' }
    $maxMiB = [int][Math]::Floor([long]$Record.outputLimitBytes / 1048576)
    if ($maxMiB -lt 1) { throw 'Native circular logman output requires an output limit of at least 1 MiB.' }
    $sampleSeconds = [int]$Manifest.deployment.perfmon.sampleIntervalSeconds
    $interval = [TimeSpan]::FromSeconds($sampleSeconds).ToString('hh\:mm\:ss')
    $arguments = @('create','counter',[string]$Record.nativeSessionId,'-o',[string]$Record.outputPath,'-f','bincirc','-max',[string]$maxMiB,'-si',$interval,'-c') + $paths
    [void](Invoke-LeaseLogman -Arguments $arguments -Reason 'Create only the unique caretaker circular counter collector with manifest counters and an output cap.')
    [void](Invoke-LeaseLogman -Arguments @('start',[string]$Record.nativeSessionId) -Reason 'Start the exact collector after the expiry task is verified enabled.')
  }.GetNewClosure()
  $backend.StopSession = {
    param($Record)
    if ([string]$Record.nativeBackend -ne 'logman' -or [string]$Record.nativeSessionId -notmatch '^GoliathCaretaker-Lease-[0-9a-f]{32}$') { throw 'Refusing a non-caretaker or non-unique logman session name.' }
    $current = & $backend.GetSession ([string]$Record.nativeSessionId)
    if (-not [bool]$current.ownershipVerified -or [string]$current.leaseId -ne [string]$Record.leaseId) { throw 'Exact native session ownership could not be proven; logman stop refused.' }
    if ([string]$current.state -eq 'RUNNING') { [void](Invoke-LeaseLogman -Arguments @('stop',[string]$Record.nativeSessionId) -Reason 'Stop the exact verified caretaker collector.') }
    $after = Invoke-LeaseLogman -Arguments @('query',[string]$Record.nativeSessionId) -Reason 'Verify the exact collector stopped before deleting its definition.' -AllowFailure
    if ($after.exitCode -ne 0 -or $after.text -notmatch '(?im)^\s*Status\s*:\s*Stopped\s*$') { throw 'Exact collector did not report Stopped; collector definition was preserved.' }
    [void](Invoke-LeaseLogman -Arguments @('delete',[string]$Record.nativeSessionId) -Reason 'Delete only the exact stopped caretaker collector definition.')
  }.GetNewClosure()
  $backend.RemoveExpiry = {
    param($Record)
    $request = [pscustomobject]@{ taskName = [string]$Record.expiryTaskName; leaseId = [string]$Record.leaseId; expiresAtUtc = [string]$Record.expiresAtUtc; statePath = $canonicalStatePath; scriptPath = $canonicalScriptPath }
    $task = & $getExpiry $request
    if (-not [bool]$task.exists -or -not [bool]$task.actionVerified) { throw 'Exact expiry task action could not be proven; task removal refused.' }
    try {
      Unregister-ScheduledTask -TaskName ([string]$Record.expiryTaskName) -Confirm:$false -ErrorAction Stop
      Add-LeaseCommandLog -Label 'lease expiry removal' -Command "Unregister-ScheduledTask -TaskName $($Record.expiryTaskName) -Confirm:`$false" -Reason 'Remove the exact expiry task only after native collector stop verification.' -Output 'Task unregistration returned successfully.'
    } catch {
      Add-LeaseCommandLog -Label 'lease expiry removal' -Command "Unregister-ScheduledTask -TaskName $($Record.expiryTaskName) -Confirm:`$false" -Reason 'Remove the exact expiry task only after native collector stop verification.' -Output $_.Exception.Message
      throw
    }
  }.GetNewClosure()
  return $backend
}

$wasDotSourced = $MyInvocation.InvocationName -eq '.'
if (-not $wasDotSourced) {
  $configPath = Join-Path $PSScriptRoot '..\config\caretaker.json'
  $defaultEvidenceRoot = Join-Path $PSScriptRoot '..\evidence'
  if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = Join-Path $defaultEvidenceRoot 'active-lease.json' }
  $result = $null
  $failure = $null
  try {
    $manifest = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($Action -eq 'Status' -and -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
      $result = [pscustomobject]@{ state = 'NONE'; lease = $null; detail = 'No active lease record exists.' }
    } else {
      $backend = New-NativeLeaseBackend -Manifest $manifest -StatePath $StatePath -ScriptPath $PSCommandPath
      switch ($Action) {
        'Status' { $result = Get-CaretakerLeaseStatus -StatePath $StatePath -Backend $backend }
        'Start' {
          if ([string]::IsNullOrWhiteSpace($Owner)) { $Owner = [string]$env:USERNAME }
          if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $defaultEvidenceRoot ('lease-' + [Guid]::NewGuid().ToString('N') + '.blg') }
          $result = Start-CaretakerLease -Manifest $manifest -Backend $backend -StatePath $StatePath -EvidenceRoot $defaultEvidenceRoot -Owner $Owner -Purpose $Purpose -Target $Target -OutputPath $OutputPath -OutputLimitBytes $OutputLimitBytes -DurationSeconds $DurationSeconds -OwnerProcessId $OwnerProcessId
        }
        'Stop' { if ([string]::IsNullOrWhiteSpace($LeaseId)) { throw 'Stop requires -LeaseId.' }; $result = Stop-CaretakerLease -StatePath $StatePath -Backend $backend -LeaseId $LeaseId }
        'Expiry' { if ([string]::IsNullOrWhiteSpace($LeaseId)) { throw 'Expiry requires -LeaseId.' }; $result = Invoke-CaretakerLeaseExpiry -StatePath $StatePath -Backend $backend -LeaseId $LeaseId }
      }
    }
  } catch {
    $failure = $_.Exception.Message
  }
  $rendered = if ($result) { ConvertTo-Json -InputObject $result -Depth 20 } else { "ERROR: $failure" }
  Add-LeaseCommandLog -Label "lease $($Action.ToLowerInvariant()) invocation" -Command ("powershell.exe -NoProfile -File `"{0}`" -Action {1} -StatePath `"{2}`" -LeaseId {3}" -f $PSCommandPath, $Action, $StatePath, $LeaseId) -Reason 'Run the requested local caretaker lease action and retain its result.' -Output $rendered
  if ($failure) { Write-Error $failure; exit 1 }
  $rendered
}
