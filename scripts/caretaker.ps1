[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('status', 'doctor', 'snapshot', 'tick')]
  [string]$Action = 'status',
  [switch]$LibraryOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:ConfigPath = Join-Path $script:ProjectRoot 'config/caretaker.json'
$script:EvidencePath = Join-Path $script:ProjectRoot 'evidence'
$script:SnapshotPath = Join-Path $script:EvidencePath 'snapshot.json'
$script:AlertStatePath = Join-Path $script:EvidencePath 'alert-state.json'
$script:OutboxPath = Join-Path $script:EvidencePath 'outbox.jsonl'
$script:ChangesPath = Join-Path $script:EvidencePath 'changes.jsonl'
$script:LastAttemptPath = Join-Path $script:EvidencePath 'last-attempt.json'
$script:LeasePath = Join-Path $script:EvidencePath 'active-lease.json'
$script:LeaseCliPath = Join-Path $PSScriptRoot 'lease.ps1'
$script:RetentionCliPath = Join-Path $PSScriptRoot 'retention.ps1'
$script:RetentionStatePath = Join-Path $script:EvidencePath 'retention-state.json'
$script:CommandLogBuffer = New-Object System.Collections.Generic.List[string]
$script:Transcribing = $false

function Get-UtcStamp {
  return [DateTime]::UtcNow.ToString('o')
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop)
}

function Write-AtomicJson {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )
  $parent = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  $tempPath = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
  try {
    $json = ConvertTo-Json -InputObject $Value -Depth 40
    [System.IO.File]::WriteAllText($tempPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
  } finally {
    if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
      Remove-Item -LiteralPath $tempPath -Force
    }
  }
}

function Add-JsonLine {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
  if (-not (Test-Path -LiteralPath $script:EvidencePath -PathType Container)) {
    New-Item -ItemType Directory -Path $script:EvidencePath -Force | Out-Null
  }
  $line = ConvertTo-Json -InputObject $Value -Depth 20 -Compress
  [System.IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Config {
  $config = Read-JsonFile -Path $script:ConfigPath
  if ($null -eq $config) { throw "Canonical manifest missing: $script:ConfigPath" }
  if ([int]$config.schemaVersion -ne 1) { throw "Unsupported manifest schemaVersion: $($config.schemaVersion)" }
  if ($null -eq $config.desired.approvedWorkloads -or $null -eq $config.desired.listeners) {
    throw 'Manifest must define desired.approvedWorkloads and desired.listeners arrays.'
  }
  return $config
}

function Get-TaskState {
  param([Parameter(Mandatory = $true)][string]$TaskName)
  if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    return [pscustomobject]@{ state = 'UNKNOWN'; detail = 'ScheduledTasks module is unavailable.' }
  }
  try {
    $tasks = @(Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop)
    Add-CaretakerCommandLog -Label 'Named caretaker task query' -Command "Get-ScheduledTask -TaskName `"$TaskName`"" -Reason 'Read only the exact task name from the canonical manifest.' -Output ("matches=$($tasks.Count)")
    if ($tasks.Count -eq 0) { return [pscustomobject]@{ state = 'NOT_INSTALLED'; detail = 'Named caretaker task was not found.' } }
    if ($tasks.Count -ne 1) { return [pscustomobject]@{ state = 'UNKNOWN'; detail = "More than one task matches the exact configured name ($($tasks.Count))." } }
    $task = $tasks[0]
    return [pscustomobject]@{
      state = if ($task.Settings.Enabled) { 'PRESENT_ENABLED' } else { 'PRESENT_DISABLED' }
      detail = 'A task with the configured caretaker name exists.'
    }
  } catch {
    Add-CaretakerCommandLog -Label 'Named caretaker task query' -Command "Get-ScheduledTask -TaskName `"$TaskName`"" -Reason 'Read only the exact task name from the canonical manifest.' -Output $_.Exception.Message
    if ($_.Exception.Message -like '*No MSFT_ScheduledTask objects found*') {
      return [pscustomobject]@{ state = 'NOT_INSTALLED'; detail = 'Named caretaker task was not found.' }
    }
    return [pscustomobject]@{ state = 'UNKNOWN'; detail = $_.Exception.Message }
  }
}

function Add-CaretakerCommandLog {
  param([string]$Label, [string]$Command, [string]$Reason, [string]$Output)
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
  $entry = "`r`n[$stamp] $Label`r`nCOMMAND: $Command`r`nREASON: $Reason`r`nOUTPUT:`r`n$Output"
  if ($script:Transcribing) { $script:CommandLogBuffer.Add($entry) }
  else { Add-Content -LiteralPath (Join-Path $script:ProjectRoot 'diag_log.txt') -Value $entry }
}

function Get-CollectorState {
  param([Parameter(Mandatory = $true)][string]$CollectorName)
  if ([string]::IsNullOrWhiteSpace($CollectorName)) { return [pscustomobject]@{ state = 'UNKNOWN'; detail = 'Manifest collector name is empty.' } }
  $exe = Join-Path $env:WINDIR 'System32\logman.exe'
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return [pscustomobject]@{ state = 'UNKNOWN'; detail = 'logman.exe is unavailable.' } }
  $command = "`"$exe`" query `"$CollectorName`""
  $output = @(& $exe query $CollectorName 2>&1)
  $exitCode = $LASTEXITCODE
  $text = $output -join "`n"
  Add-CaretakerCommandLog -Label 'Named PerfMon collector query' -Command $command -Reason 'Read only the exact collector name in the canonical manifest.' -Output ($text + "`r`nexitCode=$exitCode")
  if ($exitCode -ne 0) {
    if ($text -match '(?i)not found|does not exist|cannot find') { return [pscustomobject]@{ state = 'NOT_INSTALLED'; detail = 'The exact configured collector name was not found.' } }
    return [pscustomobject]@{ state = 'UNKNOWN'; detail = "Exact collector query failed (exit $exitCode)." }
  }
  if ($text -match '(?im)^\s*Status\s*:\s*Running\s*$') { return [pscustomobject]@{ state = 'PRESENT_RUNNING'; detail = 'The exact configured collector reports Running.' } }
  if ($text -match '(?im)^\s*Status\s*:\s*Stopped\s*$') { return [pscustomobject]@{ state = 'PRESENT_STOPPED'; detail = 'The exact configured collector reports Stopped.' } }
  return [pscustomobject]@{ state = 'UNKNOWN'; detail = 'The exact configured collector exists, but its state could not be parsed.' }
}

function Test-RetentionDue {
  param($Marker, [DateTime]$NowUtc = [DateTime]::UtcNow)
  if ($null -eq $Marker -or $null -eq $Marker.PSObject.Properties['nextDueUtc'] -or [string]::IsNullOrWhiteSpace([string]$Marker.nextDueUtc)) { return $true }
  try { return ([DateTime]::Parse([string]$Marker.nextDueUtc).ToUniversalTime() -le $NowUtc.ToUniversalTime()) }
  catch { return $false }
}

function Get-RetentionDoctorState {
  param($Retention, [bool]$Installed)
  if ($Retention.marker -eq 'UNKNOWN' -or $Retention.state -eq 'UNKNOWN') { return 'UNKNOWN' }
  if ($Retention.state -eq 'OVER_BUDGET') { return 'ERROR' }
  if ($Retention.marker -eq 'MISSING' -and -not $Installed) { return 'UNKNOWN' }
  if ($Retention.marker -in @('MISSING','OVERDUE')) { return 'WARN' }
  return 'PASS'
}

function Get-LeaseStartDoctorState {
  param([bool]$CaptureLaunchEnabled, [string]$ExpiryTaskName)
  if ($CaptureLaunchEnabled -and -not [string]::IsNullOrWhiteSpace($ExpiryTaskName)) { return 'PASS' }
  return 'INFO'
}

function Get-RetentionHealth {
  if (-not (Test-Path -LiteralPath $script:RetentionCliPath -PathType Leaf)) {
    return [pscustomobject]@{ state = 'UNKNOWN'; marker = 'UNKNOWN'; nextDueUtc = $null; totalBytes = $null; budgetBytes = $null; detail = 'Retention script is missing.' }
  }
  $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $command = "`"$exe`" -NoProfile -NonInteractive -File `"$script:RetentionCliPath`" -Action Plan"
  $output = @(& $exe -NoProfile -NonInteractive -File $script:RetentionCliPath -Action Plan 2>&1)
  $exitCode = $LASTEXITCODE
  $text = $output -join "`n"
  Add-CaretakerCommandLog -Label 'Retention plan' -Command $command -Reason 'Read retention marker health and evidence budget from the retention script Plan action.' -Output ($text + "`r`nexitCode=$exitCode")
  try { $plan = $text | ConvertFrom-Json -ErrorAction Stop }
  catch { return [pscustomobject]@{ state = 'UNKNOWN'; marker = 'UNKNOWN'; nextDueUtc = $null; totalBytes = $null; budgetBytes = $null; detail = 'Retention Plan output is unreadable.' } }
  $marker = if ($plan.retentionMarkerUnknown) { 'UNKNOWN' } elseif (-not $plan.lastAppliedUtc) { 'MISSING' } elseif (Test-RetentionDue ([pscustomobject]@{ nextDueUtc = $plan.nextDueUtc })) { 'OVERDUE' } else { 'CURRENT' }
  $state = [string]$plan.state
  if ($exitCode -notin @(0,2,3) -or $state -notin @('OK','OVER_BUDGET','UNKNOWN')) { $state = 'UNKNOWN' }
  return [pscustomobject]@{
    state = $state; marker = $marker; nextDueUtc = $plan.nextDueUtc
    totalBytes = $plan.totalBytes; budgetBytes = $plan.budgetBytes
    detail = "marker=$marker; budgetState=$state; totalBytes=$($plan.totalBytes); budgetBytes=$($plan.budgetBytes)"
  }
}

function Invoke-RetentionIfDue {
  $marker = $null
  try { $marker = Read-JsonFile -Path $script:RetentionStatePath }
  catch {
    Add-CaretakerCommandLog -Label 'Retention marker read' -Command "Read-JsonFile `"$script:RetentionStatePath`"" -Reason 'Read nextDueUtc before deciding whether retention Apply is due.' -Output $_.Exception.Message
    throw 'Retention marker is unreadable; due Apply was skipped.'
  }
  if (-not (Test-RetentionDue -Marker $marker)) {
    Write-Output ("Retention skipped; next due at {0}." -f $marker.nextDueUtc)
    return
  }
  if (-not (Test-Path -LiteralPath $script:RetentionCliPath -PathType Leaf)) { throw 'Retention script is missing; due retention was not applied.' }
  $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $command = "`"$exe`" -NoProfile -NonInteractive -File `"$script:RetentionCliPath`" -Action Apply"
  $output = @(& $exe -NoProfile -NonInteractive -File $script:RetentionCliPath -Action Apply 2>&1)
  $exitCode = $LASTEXITCODE
  $text = $output -join "`n"
  Add-CaretakerCommandLog -Label 'Due retention apply' -Command $command -Reason 'Run the self-logged Apply action only when retention-state.json nextDueUtc is missing or past.' -Output ($text + "`r`nexitCode=$exitCode")
  Write-Output $text
  if ($exitCode -ne 0) { throw "Due retention Apply failed with exit code $exitCode." }
}

function Convert-CreationTime {
  param($Value)
  if ($null -eq $Value) { return $null }
  try {
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    return ([Management.ManagementDateTimeConverter]::ToDateTime([string]$Value)).ToUniversalTime().ToString('o')
  } catch { return $null }
}

function Get-ProcessIndex {
  param([object[]]$Processes)
  $index = @{}
  foreach ($process in $Processes) { $index[[string]$process.pid] = $process }
  return ,$index
}

function Add-ParentCreationTimes {
  param([object[]]$Processes)
  $index = Get-ProcessIndex -Processes $Processes
  foreach ($process in $Processes) {
    $parentTime = $null
    $parent = $index[[string]$process.parentPid]
    if ($parent -and $process.creationTimeUtc -and $parent.creationTimeUtc) {
      try {
        $childStamp = [DateTime]::Parse([string]$process.creationTimeUtc).ToUniversalTime()
        $candidateStamp = [DateTime]::Parse([string]$parent.creationTimeUtc).ToUniversalTime()
        if ($candidateStamp -le $childStamp) { $parentTime = $parent.creationTimeUtc }
      } catch {}
    }
    $process | Add-Member -MemberType NoteProperty -Name parentCreationTimeUtc -Value $parentTime -Force
  }
  return $Processes
}

function Get-OptionalProperty {
  param($Object, [string]$Name)
  if ($null -eq $Object) { return '' }
  try { $value = $Object.$Name } catch { return '' }
  if ($null -eq $value) { return '' }
  return [string]$value
}

function Get-InventoryModule {
  param([string]$Name, [scriptblock]$Collector)
  $attempted = Get-UtcStamp
  try {
    $result = & $Collector
    $items = @($result.items)
    $complete = $true
    if ($result -and $result.PSObject.Properties.Name -contains 'complete') { $complete = [bool]$result.complete }
    return [pscustomobject]@{
      items = $items
      coverage = [pscustomobject]@{ status = if ($complete) { 'OK' } else { 'DEGRADED' }; attemptedAtUtc = $attempted; count = $items.Count; reason = if ($complete) { $null } else { 'Inventory reached the configured item cap; results are partial.' } }
    }
  } catch {
    return [pscustomobject]@{
      items = @()
      coverage = [pscustomobject]@{ status = 'UNKNOWN'; attemptedAtUtc = $attempted; count = $null; reason = $_.Exception.Message }
    }
  }
}

function Get-CurrentInventory {
  $processModule = Get-InventoryModule -Name 'processes' -Collector {
    $raw = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    $complete = $raw.Count -le 2000
    $items = foreach ($p in @($raw | Select-Object -First 2000)) {
      [pscustomobject]@{
        pid = [int]$p.ProcessId
        creationTimeUtc = Convert-CreationTime $p.CreationDate
        name = [string]$p.Name
        executablePath = [string]$p.ExecutablePath
        parentPid = if ($null -eq $p.ParentProcessId) { $null } else { [int]$p.ParentProcessId }
        workingSetBytes = if ($null -eq $p.WorkingSetSize) { $null } else { [int64]$p.WorkingSetSize }
      }
    }
    [pscustomobject]@{ items = @($items); complete = $complete }
  }
  $processes = @(Add-ParentCreationTimes -Processes @($processModule.items))
  $processModule.items = $processes
  $processIndex = Get-ProcessIndex -Processes $processes

  $tcpModule = Get-InventoryModule -Name 'tcpListeners' -Collector {
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { throw 'Get-NetTCPConnection is unavailable.' }
    $raw = @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
    $complete = $raw.Count -le 2000
    $items = foreach ($socket in @($raw | Select-Object -First 2000)) {
      $owner = $processIndex[[string]$socket.OwningProcess]
      [pscustomobject]@{
        protocol = 'TCP'; localAddress = [string]$socket.LocalAddress; localPort = [int]$socket.LocalPort
        process = if ($owner) { $owner } else { $null }
      }
    }
    [pscustomobject]@{ items = @($items); complete = $complete }
  }
  $udpModule = Get-InventoryModule -Name 'udpEndpoints' -Collector {
    if (-not (Get-Command Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) { throw 'Get-NetUDPEndpoint is unavailable.' }
    $raw = @(Get-NetUDPEndpoint -ErrorAction Stop)
    $complete = $raw.Count -le 2000
    $items = foreach ($endpoint in @($raw | Select-Object -First 2000)) {
      $owner = $processIndex[[string]$endpoint.OwningProcess]
      [pscustomobject]@{
        protocol = 'UDP'; localAddress = [string]$endpoint.LocalAddress; localPort = [int]$endpoint.LocalPort
        process = if ($owner) { $owner } else { $null }
      }
    }
    [pscustomobject]@{ items = @($items); complete = $complete }
  }
  $serviceModule = Get-InventoryModule -Name 'services' -Collector {
    $raw = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
    $complete = $raw.Count -le 2000
    $items = foreach ($service in @($raw | Select-Object -First 2000)) {
      [pscustomobject]@{ name = [string]$service.Name; displayName = [string]$service.DisplayName; state = [string]$service.State; startMode = [string]$service.StartMode }
    }
    [pscustomobject]@{ items = @($items); complete = $complete }
  }
  $taskModule = Get-InventoryModule -Name 'tasks' -Collector {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { throw 'Get-ScheduledTask is unavailable.' }
    $raw = @(Get-ScheduledTask -ErrorAction Stop)
    $complete = $raw.Count -le 2000
    $items = foreach ($task in @($raw | Select-Object -First 2000)) {
      $safeAction = @($task.Actions | ForEach-Object { '{0}|{1}|{2}' -f (Get-OptionalProperty $_ 'CimClass'), (Get-OptionalProperty $_ 'Execute'), (Get-OptionalProperty $_ 'Arguments') }) -join ';'
      $safeTrigger = @($task.Triggers | ForEach-Object { $kind = ''; try { $kind = Get-OptionalProperty $_.CimClass 'CimClassName' } catch {}; '{0}|{1}|{2}' -f $kind, (Get-OptionalProperty $_ 'StartBoundary'), (Get-OptionalProperty $_ 'Enabled') }) -join ';'
      $fingerprintInput = $safeAction + '||' + $safeTrigger
      $sha = [System.Security.Cryptography.SHA256]::Create()
      try { $fingerprint = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprintInput)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
      [pscustomobject]@{ name = [string]$task.TaskName; path = [string]$task.TaskPath; state = [string]$task.State; enabled = [bool]$task.Settings.Enabled; actionCount = @($task.Actions).Count; triggerCount = @($task.Triggers).Count; actionTriggerFingerprint = $fingerprint }
    }
    [pscustomobject]@{ items = @($items); complete = $complete }
  }
  $startupModule = Get-InventoryModule -Name 'startup' -Collector {
    $raw = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction Stop)
    $complete = $raw.Count -le 1000
    $items = foreach ($entry in @($raw | Select-Object -First 1000)) {
      $commandHash = $null
      if (-not [string]::IsNullOrWhiteSpace([string]$entry.Command)) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $commandHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$entry.Command)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
      }
      [pscustomobject]@{ name = [string]$entry.Name; location = [string]$entry.Location; user = [string]$entry.User; commandFingerprint = $commandHash }
    }
    [pscustomobject]@{ items = @($items); complete = $complete }
  }

  $modules = [ordered]@{
    processes = $processModule
    tcpListeners = $tcpModule
    udpEndpoints = $udpModule
    services = $serviceModule
    tasks = $taskModule
    startup = $startupModule
  }
  $items = [ordered]@{}
  $coverage = [ordered]@{}
  foreach ($name in $modules.Keys) { $items[$name] = @($modules[$name].items); $coverage[$name] = $modules[$name].coverage }
  return [pscustomobject]@{ items = $items; coverage = $coverage }
}

function Get-ListenerKey {
  param($Listener)
  return ('{0}|{1}|{2}' -f ([string]$Listener.protocol).ToUpperInvariant(), ([string]$Listener.localAddress).ToLowerInvariant(), [int]$Listener.localPort)
}

function Test-ListenerApproved {
  param($Listener, $Desired)
  foreach ($expected in @($Desired.listeners)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$expected.executablePath) -and $Listener.process -and
        ([string]$expected.executablePath).Equals([string]$Listener.process.executablePath, [StringComparison]::OrdinalIgnoreCase) -and
        ([string]$expected.protocol).ToUpperInvariant() -eq ([string]$Listener.protocol).ToUpperInvariant() -and
        [int]$expected.localPort -eq [int]$Listener.localPort -and
        ([string]$expected.localAddress).ToLowerInvariant() -eq ([string]$Listener.localAddress).ToLowerInvariant()) { return $true }
  }
  return $false
}

function Get-AlertCandidates {
  param($Inventory, $Desired, $PreviousSnapshot)
  $candidates = @{}
  $previousListeners = @{}
  $activeAlertIds = @{}
  $alertState = Read-JsonFile -Path $script:AlertStatePath
  if ($alertState -and $alertState.active) { foreach ($entry in @($alertState.active)) { $activeAlertIds[[string]$entry.id] = $true } }
  if ($PreviousSnapshot) {
    foreach ($listener in @($PreviousSnapshot.observed.tcpListeners) + @($PreviousSnapshot.observed.udpEndpoints)) {
      $previousListeners[(Get-ListenerKey $listener)] = $true
    }
  }
  foreach ($listener in @($Inventory.items.tcpListeners) + @($Inventory.items.udpEndpoints)) {
    $moduleName = if ($listener.protocol -eq 'TCP') { 'tcpListeners' } else { 'udpEndpoints' }
    if ($Inventory.coverage.$moduleName.status -eq 'OK' -and $PreviousSnapshot -and $listener.protocol -eq 'TCP' -and -not (Test-ListenerApproved -Listener $listener -Desired $Desired)) {
      $key = Get-ListenerKey $listener
      $id = 'unreviewed-listener:' + $key
      $isNewObservation = (-not $PreviousSnapshot) -or (-not $previousListeners.ContainsKey($key))
      if (-not $isNewObservation -and -not $activeAlertIds.ContainsKey($id)) { continue }
      $candidates[$id] = [pscustomobject]@{
        id = $id; rule = 'unreviewed-listener'; severity = 'review';
        subject = ('{0} {1}:{2}' -f $listener.protocol, $listener.localAddress, $listener.localPort)
      }
    }
  }
  foreach ($workload in @($Desired.approvedWorkloads)) {
    $type = ([string]$workload.type).ToLowerInvariant()
    if ($type -eq 'service' -and $Inventory.coverage.services.status -eq 'OK') {
      $matches = @($Inventory.items.services | Where-Object { $_.name -eq $workload.name })
      $actual = if ($matches.Count -gt 0) { $matches[0].state } else { 'MISSING' }
      if ($workload.expectedState -and $actual -ne $workload.expectedState) {
        $id = 'workload-state:service:' + [string]$workload.name
        $candidates[$id] = [pscustomobject]@{ id = $id; rule = 'workload-state'; severity = 'review'; subject = "service $($workload.name) expected $($workload.expectedState), observed $actual" }
      }
    } elseif ($type -eq 'task' -and $Inventory.coverage.tasks.status -eq 'OK') {
      $matches = @($Inventory.items.tasks | Where-Object { $_.name -eq $workload.name })
      $actual = if ($matches.Count -gt 0) { [string]$matches[0].enabled } else { 'MISSING' }
      $expected = [string]$workload.expectedEnabled
      if ($expected -and $actual -ne $expected) {
        $id = 'workload-state:task:' + [string]$workload.name
        $candidates[$id] = [pscustomobject]@{ id = $id; rule = 'workload-state'; severity = 'review'; subject = "task $($workload.name) expected enabled=$expected, observed $actual" }
      }
    }
  }
  return ,$candidates
}

function Update-AlertOutbox {
  param([hashtable]$Candidates, $Coverage)
  $old = Read-JsonFile -Path $script:AlertStatePath
  $previous = @{}
  if ($old -and $old.active) { foreach ($entry in @($old.active)) { $previous[[string]$entry.id] = $entry } }
  $now = Get-UtcStamp
  $next = @()
  foreach ($id in @($Candidates.Keys | Sort-Object)) {
    $candidate = $Candidates[$id]
    if ($previous.ContainsKey($id)) {
      $prior = $previous[$id]
      $next += [pscustomobject]@{ id = $id; rule = $candidate.rule; severity = $candidate.severity; subject = $candidate.subject; firstSeenUtc = $prior.firstSeenUtc; lastSeenUtc = $now; seenCount = [int]$prior.seenCount + 1 }
    } else {
      $record = [pscustomobject]@{ id = $id; rule = $candidate.rule; severity = $candidate.severity; subject = $candidate.subject; firstSeenUtc = $now; lastSeenUtc = $now; seenCount = 1 }
      $next += $record
      Add-JsonLine -Path $script:OutboxPath -Value ([pscustomobject]@{ event = 'open'; atUtc = $now; alert = $record })
    }
  }
  foreach ($id in @($previous.Keys)) {
    $item = $previous[$id]
    $domain = if ($item.rule -eq 'unreviewed-listener') { if ($id -like 'unreviewed-listener:TCP|*') { 'tcpListeners' } else { 'udpEndpoints' } } elseif ($item.rule -eq 'workload-state' -and $id -like 'workload-state:service:*') { 'services' } elseif ($item.rule -eq 'workload-state') { 'tasks' } else { $null }
    if ($domain -and $Coverage.$domain.status -ne 'OK') { $next += $item; continue }
    if (-not $Candidates.ContainsKey($id)) {
      Add-JsonLine -Path $script:OutboxPath -Value ([pscustomobject]@{ event = 'resolved'; atUtc = $now; alertId = $id; rule = $previous[$id].rule; subject = $previous[$id].subject })
    }
  }
  Write-AtomicJson -Path $script:AlertStatePath -Value ([pscustomobject]@{ schemaVersion = 1; updatedAtUtc = $now; active = @($next) })
}

function Get-DiffKey {
  param([string]$Module, $Item)
  switch ($Module) {
    'processes' { return ('{0}@{1}' -f $Item.pid, $Item.creationTimeUtc) }
    'tcpListeners' { return (Get-ListenerKey $Item) }
    'udpEndpoints' { return (Get-ListenerKey $Item) }
    'services' { return ([string]$Item.name).ToLowerInvariant() }
    'tasks' { return (('{0}|{1}' -f $Item.path, $Item.name).ToLowerInvariant()) }
    'startup' { return (('{0}|{1}|{2}' -f $Item.location, $Item.name, $Item.user).ToLowerInvariant()) }
  }
}

function Get-DiffSummary {
  param([string]$Module, $Item)
  switch ($Module) {
    'processes' { return [pscustomobject]@{ pid = $Item.pid; creationTimeUtc = $Item.creationTimeUtc; name = $Item.name; executablePath = $Item.executablePath; parentPid = $Item.parentPid; parentCreationTimeUtc = (Get-OptionalProperty $Item 'parentCreationTimeUtc') } }
    'tcpListeners' { return [pscustomobject]@{ protocol = 'TCP'; localAddress = $Item.localAddress; localPort = $Item.localPort; process = if ($Item.process) { [pscustomobject]@{ pid = $Item.process.pid; creationTimeUtc = $Item.process.creationTimeUtc; name = $Item.process.name; executablePath = $Item.process.executablePath; parentPid = $Item.process.parentPid } } else { $null } } }
    'udpEndpoints' { return [pscustomobject]@{ protocol = 'UDP'; localAddress = $Item.localAddress; localPort = $Item.localPort; process = if ($Item.process) { [pscustomobject]@{ pid = $Item.process.pid; creationTimeUtc = $Item.process.creationTimeUtc; name = $Item.process.name; executablePath = $Item.process.executablePath; parentPid = $Item.process.parentPid } } else { $null } } }
    'services' { return [pscustomobject]@{ name = $Item.name; state = $Item.state; startMode = $Item.startMode } }
    'tasks' { return [pscustomobject]@{ name = $Item.name; path = $Item.path; enabled = $Item.enabled; state = $Item.state; actionCount = (Get-OptionalProperty $Item 'actionCount'); triggerCount = (Get-OptionalProperty $Item 'triggerCount'); actionTriggerFingerprint = (Get-OptionalProperty $Item 'actionTriggerFingerprint') } }
    'startup' { return [pscustomobject]@{ name = $Item.name; location = $Item.location; user = $Item.user; commandFingerprint = (Get-OptionalProperty $Item 'commandFingerprint') } }
  }
}

function Add-ChangeLine {
  param([Parameter(Mandatory = $true)]$Value)
  if (-not (Test-Path -LiteralPath $script:EvidencePath -PathType Container)) { New-Item -ItemType Directory -Path $script:EvidencePath -Force | Out-Null }
  [System.IO.File]::AppendAllText($script:ChangesPath, (ConvertTo-Json -InputObject $Value -Depth 20 -Compress) + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
}

function Update-ChangeLog {
  param($PreviousSnapshot, $Snapshot)
  if ($null -eq $PreviousSnapshot) { return }
  $modules = @('processes', 'tcpListeners', 'udpEndpoints', 'services', 'tasks', 'startup')
  foreach ($module in $modules) {
    if ($Snapshot.coverage.$module.status -ne 'OK' -or $PreviousSnapshot.coverage.$module.status -ne 'OK') { continue }
    $before = @{}
    $after = @{}
    foreach ($item in @($PreviousSnapshot.observed.$module)) { $before[(Get-DiffKey $module $item)] = $item }
    foreach ($item in @($Snapshot.observed.$module)) { $after[(Get-DiffKey $module $item)] = $item }
    foreach ($key in @($after.Keys)) {
      $current = $after[$key]
      if (-not $before.ContainsKey($key)) {
        if ($module -eq 'processes') {
          $started = $null
          try { $started = [DateTime]::Parse([string]$current.creationTimeUtc).ToUniversalTime() } catch {}
          if ($null -eq $started -or ([DateTime]::UtcNow - $started).TotalMinutes -lt 10) { continue }
        }
        Add-ChangeLine ([pscustomobject]@{ atUtc = $Snapshot.capturedAtUtc; module = $module; change = 'added'; key = $key; current = (Get-DiffSummary $module $current) })
      } elseif ($module -ne 'processes') {
        $oldSummary = ConvertTo-Json -InputObject (Get-DiffSummary $module $before[$key]) -Depth 20 -Compress
        $newSummary = ConvertTo-Json -InputObject (Get-DiffSummary $module $current) -Depth 20 -Compress
        if ($oldSummary -ne $newSummary) { Add-ChangeLine ([pscustomobject]@{ atUtc = $Snapshot.capturedAtUtc; module = $module; change = 'changed'; key = $key; previous = (Get-DiffSummary $module $before[$key]); current = (Get-DiffSummary $module $current) }) }
      }
    }
    foreach ($key in @($before.Keys)) {
      if ($after.ContainsKey($key)) { continue }
      $old = $before[$key]
      if ($module -eq 'processes') {
        $started = $null
        try { $started = [DateTime]::Parse([string]$old.creationTimeUtc).ToUniversalTime() } catch {}
        if ($null -eq $started -or ([DateTime]::UtcNow - $started).TotalMinutes -lt 10) { continue }
      }
      Add-ChangeLine ([pscustomobject]@{ atUtc = $Snapshot.capturedAtUtc; module = $module; change = 'removed'; key = $key; previous = (Get-DiffSummary $module $old) })
    }
  }
}

function Get-Freshness {
  param($Snapshot, $Config)
  if ($null -eq $Snapshot) { return [pscustomobject]@{ state = 'MISSING'; ageMinutes = $null; detail = 'No snapshot has been saved.' } }
  try {
    $observedAt = [DateTime]::Parse([string]$Snapshot.capturedAtUtc).ToUniversalTime()
    $age = [Math]::Max(0, [Math]::Round(([DateTime]::UtcNow - $observedAt).TotalMinutes, 1))
    $limit = [Math]::Max(15, ([int]$Config.deployment.checkIntervalMinutes * 3))
    if ($age -le $limit) { return [pscustomobject]@{ state = 'FRESH'; ageMinutes = $age; detail = "Within $limit minute freshness window." } }
    return [pscustomobject]@{ state = 'STALE'; ageMinutes = $age; detail = "Older than $limit minute freshness window." }
  } catch { return [pscustomobject]@{ state = 'UNKNOWN'; ageMinutes = $null; detail = 'Snapshot timestamp is invalid.' } }
}

function Invoke-SnapshotCore {
  $config = Get-Config
  $previous = Read-JsonFile -Path $script:SnapshotPath
  $inventory = Get-CurrentInventory
  $candidates = Get-AlertCandidates -Inventory $inventory -Desired $config.desired -PreviousSnapshot $previous
  $snapshot = [pscustomobject]@{
    schemaVersion = 1
    capturedAtUtc = Get-UtcStamp
    machineName = $env:COMPUTERNAME
    desired = $config
    observed = $inventory.items
    coverage = $inventory.coverage
  }
  Update-AlertOutbox -Candidates $candidates -Coverage $inventory.coverage
  Update-ChangeLog -PreviousSnapshot $previous -Snapshot $snapshot
  Write-AtomicJson -Path $script:SnapshotPath -Value $snapshot
  Write-Output "Snapshot saved: $script:SnapshotPath"
  Write-Output ("Captured at UTC: {0}" -f $snapshot.capturedAtUtc)
  foreach ($name in $inventory.coverage.Keys) { Write-Output ("{0}: {1} ({2})" -f $name, $inventory.coverage[$name].status, $inventory.coverage[$name].count) }
  Write-Output ("Active local alert items: {0}" -f $candidates.Count)
}

function Invoke-Snapshot {
  $started = Get-UtcStamp
  Write-AtomicJson -Path $script:LastAttemptPath -Value ([pscustomobject]@{ schemaVersion = 1; state = 'IN_PROGRESS'; startedAtUtc = $started; completedAtUtc = $null; reason = $null })
  try {
    Invoke-SnapshotCore
    Write-AtomicJson -Path $script:LastAttemptPath -Value ([pscustomobject]@{ schemaVersion = 1; state = 'OK'; startedAtUtc = $started; completedAtUtc = (Get-UtcStamp); reason = $null })
  } catch {
    $reason = $_.Exception.Message
    try {
      Write-AtomicJson -Path $script:LastAttemptPath -Value ([pscustomobject]@{ schemaVersion = 1; state = 'ERROR'; startedAtUtc = $started; completedAtUtc = (Get-UtcStamp); reason = $reason })
    } catch { }
    Write-Error ("Snapshot failed: {0}" -f $reason)
    throw
  }
}

function Get-AttemptHealth {
  param($Attempt)
  if ($null -eq $Attempt) { return [pscustomobject]@{ state = 'UNKNOWN'; detail = 'No recorded snapshot attempt.' } }
  if ($Attempt.state -eq 'OK') { return [pscustomobject]@{ state = 'PASS'; detail = "Completed at $($Attempt.completedAtUtc)." } }
  if ($Attempt.state -eq 'ERROR') { return [pscustomobject]@{ state = 'ERROR'; detail = [string]$Attempt.reason } }
  return [pscustomobject]@{ state = 'UNKNOWN'; detail = "Latest snapshot attempt is $($Attempt.state); no successful completion is recorded." }
}

function Get-LeaseHealth {
  if (-not (Test-Path -LiteralPath $script:LeasePath -PathType Leaf)) {
    return [pscustomobject]@{ state = 'NONE'; detail = 'No owned temporary capture is recorded.'; lease = $null }
  }
  if (-not (Test-Path -LiteralPath $script:LeaseCliPath -PathType Leaf)) {
    return [pscustomobject]@{ state = 'UNKNOWN'; detail = 'Lease status script is missing.'; lease = $null }
  }
  $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $command = "`"$exe`" -NoProfile -NonInteractive -File `"$script:LeaseCliPath`" -Action Status"
  $output = @(& $exe -NoProfile -NonInteractive -File $script:LeaseCliPath -Action Status 2>&1)
  $text = $output -join "`n"
  Add-CaretakerCommandLog -Label 'Lease status' -Command $command -Reason 'Read only the recorded caretaker lease and exact native session status.' -Output ($text + "`r`nexitCode=$LASTEXITCODE")
  if ($LASTEXITCODE -ne 0) {
    return [pscustomobject]@{ state = 'UNKNOWN'; detail = $text; lease = $null }
  }
  try { return ($text | ConvertFrom-Json -ErrorAction Stop) }
  catch { return [pscustomobject]@{ state = 'UNKNOWN'; detail = 'Lease status output is unreadable.'; lease = $null } }
}

function Invoke-Status {
  try { $config = Get-Config } catch { Write-Output ("Manifest: ERROR - {0}" -f $_.Exception.Message); return }
  try { $snapshot = Read-JsonFile -Path $script:SnapshotPath } catch { Write-Output ("Snapshot: ERROR - unreadable runtime JSON: {0}" -f $_.Exception.Message); $snapshot = $null }
  try { $attempt = Read-JsonFile -Path $script:LastAttemptPath; $attemptHealth = Get-AttemptHealth $attempt } catch { $attemptHealth = [pscustomobject]@{ state = 'ERROR'; detail = "Unreadable attempt record: $($_.Exception.Message)" } }
  $freshness = Get-Freshness -Snapshot $snapshot -Config $config
  $task = Get-TaskState -TaskName ([string]$config.deployment.taskName)
  $collector = Get-CollectorState -CollectorName ([string]$config.deployment.perfmon.collectorName)
  $taskEnabledDesired = [bool]$config.deployment.taskEnabled
  $taskDesired = if (-not [bool]$config.deployment.installed) { 'NOT_INSTALLED' } elseif ($taskEnabledDesired) { 'PRESENT_ENABLED' } else { 'PRESENT_DISABLED' }
  $taskMatch = if ($task.state -eq 'UNKNOWN') { 'UNKNOWN' } elseif ($task.state -eq $taskDesired) { 'MATCH' } else { 'MISMATCH' }
  $collectorEnabledDesired = [bool]$config.deployment.collectorEnabled -or [bool]$config.deployment.perfmon.enabled
  $collectorMatch = if ($collector.state -eq 'UNKNOWN') { 'UNKNOWN' } elseif ($collectorEnabledDesired -and $collector.state -eq 'PRESENT_RUNNING') { 'MATCH' } elseif (-not $collectorEnabledDesired -and $collector.state -in @('NOT_INSTALLED','PRESENT_STOPPED')) { 'MATCH' } else { 'MISMATCH' }
  Write-Output 'Goliath Caretaker status'
  Write-Output ("Desired deployment: installed={0}; taskEnabled={1}; collectorEnabled={2}; perfmonEnabled={3}; notifications={4}" -f $config.deployment.installed, $config.deployment.taskEnabled, $config.deployment.collectorEnabled, $config.deployment.perfmon.enabled, $config.notifications.mode)
  Write-Output ("Named caretaker task {0}: observed={1}; desired={2}; {3} ({4})" -f $config.deployment.taskName, $task.state, $taskDesired, $taskMatch, $task.detail)
  Write-Output ("Named PerfMon collector {0}: observed={1}; enabledDesired={2}; {3} ({4})" -f $config.deployment.perfmon.collectorName, $collector.state, $collectorEnabledDesired, $collectorMatch, $collector.detail)
  Write-Output ("Latest snapshot: {0}{1}" -f $freshness.state, $(if ($null -ne $freshness.ageMinutes) { " ($($freshness.ageMinutes) min old)" } else { '' }))
  Write-Output ("Latest snapshot attempt: {0} - {1}" -f $attemptHealth.state, $attemptHealth.detail)
  if ($snapshot) {
    foreach ($name in $snapshot.coverage.PSObject.Properties.Name) { Write-Output ("Coverage {0}: {1}" -f $name, $snapshot.coverage.$name.status) }
  } else { Write-Output 'Coverage: UNKNOWN (no snapshot)' }
  try { $alertState = Read-JsonFile -Path $script:AlertStatePath; $alertHealth = 'readable' } catch { $alertState = $null; $alertHealth = 'ERROR (unreadable local alert state)' }
  $activeCount = if ($alertState -and $alertState.active) { @($alertState.active).Count } else { 0 }
  Write-Output ("Active local alert items: {0}; state: {1}; delivery enabled: {2}" -f $activeCount, $alertHealth, $config.notifications.deliveryEnabled)
  $leaseHealth = Get-LeaseHealth
  Write-Output ("Owned temporary capture: {0} - {1}" -f $leaseHealth.state, $leaseHealth.detail)
  $retention = Get-RetentionHealth
  Write-Output ("Retention marker: {0}; budget: {1} ({2}/{3} bytes); next due: {4}" -f $retention.marker, $retention.state, $retention.totalBytes, $retention.budgetBytes, $retention.nextDueUtc)
  if (Test-Path -LiteralPath $script:ChangesPath -PathType Leaf) {
    try {
      $lastChange = Get-Content -LiteralPath $script:ChangesPath -Tail 1 | ConvertFrom-Json -ErrorAction Stop
      Write-Output ("Local material-change journal: present; last record at {0}" -f $lastChange.atUtc)
    } catch { Write-Output 'Local material-change journal: present; latest record UNKNOWN (tail unreadable)' }
  } else { Write-Output 'Local material-change journal: not initialized' }
  Write-Output 'Only the manifest-named caretaker task and PerfMon collector were queried; unrelated collectors were not surveyed.'
}

function Invoke-Doctor {
  try { $config = Get-Config } catch {
    Write-Output 'Goliath Caretaker doctor (read-only)'
    Write-Output ("manifest: ERROR - {0}" -f $_.Exception.Message)
    Write-Output 'Result: NOT READY'
    return
  }
  $checks = @()
  $checks += [pscustomobject]@{ name = 'manifest'; state = 'PASS'; detail = 'Schema version 1 parsed; desired and deployment data are separate.' }
  $task = Get-TaskState -TaskName ([string]$config.deployment.taskName)
  $taskEnabledDesired = [bool]$config.deployment.taskEnabled
  $taskDesired = if (-not [bool]$config.deployment.installed) { 'NOT_INSTALLED' } elseif ($taskEnabledDesired) { 'PRESENT_ENABLED' } else { 'PRESENT_DISABLED' }
  $taskCheck = if ($task.state -eq 'UNKNOWN') { 'UNKNOWN' } elseif ($task.state -eq $taskDesired) { 'PASS' } else { 'ERROR' }
  $checks += [pscustomobject]@{ name = 'scheduledTask'; state = $taskCheck; detail = "name=$($config.deployment.taskName); observed=$($task.state); desired=$taskDesired; $($task.detail)" }
  $collector = Get-CollectorState -CollectorName ([string]$config.deployment.perfmon.collectorName)
  $collectorEnabledDesired = [bool]$config.deployment.collectorEnabled -or [bool]$config.deployment.perfmon.enabled
  $collectorCheck = if ($collector.state -eq 'UNKNOWN') { 'UNKNOWN' } elseif ($collectorEnabledDesired -and $collector.state -eq 'PRESENT_RUNNING') { 'PASS' } elseif (-not $collectorEnabledDesired -and $collector.state -in @('NOT_INSTALLED','PRESENT_STOPPED')) { 'PASS' } else { 'ERROR' }
  $flagsConsistent = ([bool]$config.deployment.collectorEnabled -eq [bool]$config.deployment.perfmon.enabled)
  if (-not $flagsConsistent -and $collectorCheck -eq 'PASS') { $collectorCheck = 'WARN' }
  $checks += [pscustomobject]@{ name = 'namedCollector'; state = $collectorCheck; detail = "name=$($config.deployment.perfmon.collectorName); observed=$($collector.state); collectorEnabled=$($config.deployment.collectorEnabled); perfmonEnabled=$($config.deployment.perfmon.enabled); $($collector.detail)" }
  $attemptError = $null
  try { $attempt = Read-JsonFile -Path $script:LastAttemptPath; $attemptHealth = Get-AttemptHealth $attempt } catch { $attemptError = $_.Exception.Message; $attemptHealth = [pscustomobject]@{ state = 'ERROR'; detail = "Unreadable attempt record: $attemptError" } }
  $checks += [pscustomobject]@{ name = 'lastSnapshotAttempt'; state = $attemptHealth.state; detail = $attemptHealth.detail }
  $snapshotError = $null
  try { $snapshot = Read-JsonFile -Path $script:SnapshotPath } catch { $snapshot = $null; $snapshotError = $_.Exception.Message }
  $freshness = Get-Freshness -Snapshot $snapshot -Config $config
  $freshCheck = if ($snapshotError) { 'ERROR' } elseif ($freshness.state -eq 'FRESH') { 'PASS' } else { 'UNKNOWN' }
  $freshDetail = if ($snapshotError) { "Unreadable runtime JSON: $snapshotError" } else { "$($freshness.state): $($freshness.detail)" }
  $checks += [pscustomobject]@{ name = 'snapshot'; state = $freshCheck; detail = $freshDetail }
  try {
    $alertState = Read-JsonFile -Path $script:AlertStatePath
    $checks += [pscustomobject]@{ name = 'alertState'; state = 'PASS'; detail = if ($alertState) { "Readable; active items: $(@($alertState.active).Count)." } else { 'Not initialized; no local alert state yet.' } }
  } catch {
    $checks += [pscustomobject]@{ name = 'alertState'; state = 'ERROR'; detail = "Unreadable runtime JSON: $($_.Exception.Message)" }
  }
  if ($snapshot) {
    foreach ($name in $snapshot.coverage.PSObject.Properties.Name) {
      $coverage = $snapshot.coverage.$name
      $checks += [pscustomobject]@{ name = "coverage.$name"; state = if ($coverage.status -eq 'OK') { 'PASS' } else { 'UNKNOWN' }; detail = if ($coverage.reason) { [string]$coverage.reason } else { "Observed $($coverage.count) records." } }
    }
  }
  $leaseHealth = Get-LeaseHealth
  $leaseCheck = switch ([string]$leaseHealth.state) {
    'NONE' { 'PASS' }
    'STOPPED' { 'PASS' }
    'STOPPED_EXPIRY_MISSING' { 'WARN' }
    'STOPPED_EXPIRY_UNKNOWN' { 'ERROR' }
    'STOPPED_EXPIRY_REMOVE_FAILED' { 'ERROR' }
    'RUNNING' { 'WARN' }
    'STOP_PENDING_CLEANUP' { 'WARN' }
    default { 'ERROR' }
  }
  if ($leaseHealth.state -eq 'RUNNING' -and $leaseHealth.lease -and $leaseHealth.lease.expiresAtUtc) {
    try { if ([DateTime]::Parse([string]$leaseHealth.lease.expiresAtUtc).ToUniversalTime() -le [DateTime]::UtcNow) { $leaseCheck = 'ERROR' } } catch { $leaseCheck = 'ERROR' }
  }
  $checks += [pscustomobject]@{ name = 'lease'; state = $leaseCheck; detail = "$($leaseHealth.state): $($leaseHealth.detail)" }
  $retention = Get-RetentionHealth
  $retentionCheck = Get-RetentionDoctorState -Retention $retention -Installed ([bool]$config.deployment.installed)
  $checks += [pscustomobject]@{ name = 'retention'; state = $retentionCheck; detail = "$($retention.detail); nextDueUtc=$($retention.nextDueUtc)" }
  $launchConfigured = [bool]$config.leasePolicy.captureLaunchEnabled -and -not [string]::IsNullOrWhiteSpace([string]$config.leasePolicy.expiryTaskName)
  $leaseStartState = Get-LeaseStartDoctorState -CaptureLaunchEnabled ([bool]$config.leasePolicy.captureLaunchEnabled) -ExpiryTaskName ([string]$config.leasePolicy.expiryTaskName)
  $checks += [pscustomobject]@{ name = 'leaseStart'; state = $leaseStartState; detail = if ($launchConfigured) { 'Configured for explicit bounded starts; each start still verifies its own expiry task before collection.' } else { 'OFF_BY_POLICY: capture launch is intentionally disabled; explicit enablement is required before an on-demand lease can start.' } }
  Write-Output 'Goliath Caretaker doctor (read-only)'
  foreach ($check in $checks) { Write-Output ('{0}: {1} - {2}' -f $check.name, $check.state, $check.detail) }
  $bad = @($checks | Where-Object { $_.state -eq 'ERROR' -or $_.state -eq 'WARN' -or $_.state -eq 'UNKNOWN' -or $_.state -eq 'BLOCKED' })
  Write-Output ("Result: {0}" -f $(if ($bad.Count -eq 0) { 'READY' } else { 'DEGRADED / NOT READY' }))
}

function Invoke-Tick {
  # A resumed machine may have missed a one-shot expiry. Reconcile that lease
  # before doing the slower inventory, without touching any unregistered trace.
  $expiryFailure = $null
  $lease = Read-JsonFile -Path $script:LeasePath
  $leaseCleanupStatus = if ($lease) { [string]$lease.cleanupStatus } else { '' }
  $leaseNeedsReconcile = $lease -and $leaseCleanupStatus -notin @('STOPPED','STOPPED_EXPIRY_MISSING','STOPPED_EXPIRY_UNKNOWN')
  if ($leaseNeedsReconcile) {
    $leaseId = [Guid]::Empty
    if (-not [Guid]::TryParse([string]$lease.leaseId, [ref]$leaseId)) {
      $expiryFailure = 'Recorded lease ID is invalid; no collector was touched.'
    } else {
      $deadline = [DateTime]::MinValue
      if (-not [DateTime]::TryParse([string]$lease.expiresAtUtc, [ref]$deadline)) {
        $expiryFailure = 'Recorded lease deadline is invalid; no collector was touched.'
      } elseif ($deadline.ToUniversalTime() -le [DateTime]::UtcNow) {
        if (-not (Test-Path -LiteralPath $script:LeaseCliPath -PathType Leaf)) {
          $expiryFailure = 'Lease expiry script is missing; no collector was touched.'
        } else {
          $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
          $command = "`"$exe`" -NoProfile -NonInteractive -File `"$script:LeaseCliPath`" -Action Expiry -LeaseId $($leaseId.ToString())"
          $expiryOutput = @(& $exe -NoProfile -NonInteractive -File $script:LeaseCliPath -Action Expiry -LeaseId $leaseId.ToString() 2>&1)
          $expiryExitCode = $LASTEXITCODE
          $expiryText = $expiryOutput -join "`n"
          Add-CaretakerCommandLog -Label 'Overdue lease reconciliation' -Command $command -Reason 'Reconcile only the exact recorded overdue lease before the snapshot.' -Output ($expiryText + "`r`nexitCode=$expiryExitCode")
          Write-Output $expiryText
          if ($expiryExitCode -ne 0) { $expiryFailure = "Owned lease expiry failed with exit code $expiryExitCode." }
        }
      }
    }
  }
  Invoke-Snapshot
  $retentionFailure = $null
  try { Invoke-RetentionIfDue } catch { $retentionFailure = $_.Exception.Message }
  $failures = @()
  if ($expiryFailure) { $failures += $expiryFailure }
  if ($retentionFailure) { $failures += $retentionFailure }
  if ($failures.Count -gt 0) { throw ($failures -join ' ') }
}

if (-not $LibraryOnly) {
  $commandText = "powershell -NoProfile -NonInteractive -File `"$PSCommandPath`" $Action"
  $startedAt = Get-Date -Format o
  $exitCode = 0
  try {
    $captured = @(& {
      Write-Output ("Caretaker command: {0}" -f $Action)
      switch ($Action) {
        'status' { Invoke-Status }
        'doctor' { Invoke-Doctor }
        'snapshot' { Invoke-Snapshot }
        'tick' { Invoke-Tick }
      }
    } *>&1)
  } catch {
    $exitCode = 1
    $captured = @($_)
  }
  $rendered = ($captured | Out-String)
  Write-Output $rendered
  Add-Content -LiteralPath (Join-Path $script:ProjectRoot 'diag_log.txt') -Value "`r`n[$startedAt] label=caretaker-$Action command=$commandText reason=Run the requested caretaker CLI action; stdout and stderr are captured below. exitCode=$exitCode`r`n$rendered"
  if ($exitCode -ne 0) { exit $exitCode }
}
