[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('status', 'doctor', 'snapshot', 'tick', 'busy', 'explain', 'events', 'review')]
  [string]$Action = 'status',
  [Parameter(Position = 1)]
  [ValidateSet('list', 'show', 'set', 'snooze', 'clear')]
  [string]$ReviewAction = 'list',
  [ValidateRange(1, 3)]
  [int]$SampleSeconds = 1,
  [ValidateRange(1, 10)]
  [int]$Top = 5,
  [ValidatePattern('^[A-Za-z0-9_. -]{1,80}$')]
  [string]$ProcessName = '',
  [ValidateRange(1, 2147483647)]
  [int]$ProcessId,
  [ValidateRange(1, 30)]
  [int]$WindowDays = 7,
  [ValidateRange(1, 1000)]
  [int]$MaxEventsPerLog = 1000,
  [ValidatePattern('^[A-Za-z0-9_.:|\[\]\- ]{1,200}$')]
  [string]$AlertId = '',
  [ValidateSet('wanted', 'optional', 'temporary', 'review', 'unknown')]
  [string]$Class = '',
  [ValidateLength(0, 200)]
  [string]$Purpose = '',
  [ValidateLength(0, 120)]
  [string]$Project = '',
  [ValidateLength(0, 400)]
  [string]$Note = '',
  [ValidateRange(1, 90)]
  [int]$Days = 7,
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
  if (-not ($config.PSObject.Properties.Name -contains 'decisions') -or $null -eq $config.decisions) {
    $config | Add-Member -NotePropertyName decisions -NotePropertyValue ([pscustomobject]@{ items = @() }) -Force
  } elseif (-not ($config.decisions.PSObject.Properties.Name -contains 'items') -or $null -eq $config.decisions.items) {
    $config.decisions | Add-Member -NotePropertyName items -NotePropertyValue @() -Force
  }
  return $config
}

function Get-DecisionItems {
  param($Config)
  if ($null -eq $Config -or $null -eq $Config.decisions) { return @() }
  return @($Config.decisions.items)
}

function Find-Decision {
  param($Config, [Parameter(Mandatory = $true)][string]$AlertId)
  foreach ($item in @(Get-DecisionItems -Config $Config)) {
    if ([string]$item.alertId -eq $AlertId) { return $item }
  }
  return $null
}

function Test-AlertSnoozed {
  param($Config, [Parameter(Mandatory = $true)][string]$AlertId, [DateTime]$NowUtc = [DateTime]::UtcNow)
  $item = Find-Decision -Config $Config -AlertId $AlertId
  if ($null -eq $item) { return $false }
  $until = [string]$item.snoozeUntilUtc
  if ([string]::IsNullOrWhiteSpace($until)) { return $false }
  $deadline = [DateTime]::MinValue
  if (-not [DateTime]::TryParse($until, [ref]$deadline)) { return $false }
  return ($deadline.ToUniversalTime() -gt $NowUtc.ToUniversalTime())
}

function Save-ConfigDecisions {
  param(
    [Parameter(Mandatory = $true)]$Config,
    [AllowEmptyCollection()]
    [Parameter(Mandatory = $true)][object[]]$Items
  )
  $next = [pscustomobject]@{
    schemaVersion = $Config.schemaVersion
    product = $Config.product
    deployment = $Config.deployment
    notifications = $Config.notifications
    leasePolicy = $Config.leasePolicy
    desired = $Config.desired
    decisions = [pscustomobject]@{ items = @($Items) }
  }
  Write-AtomicJson -Path $script:ConfigPath -Value $next
}

function Get-SnapshotDesired {
  # Personal decisions stay in the manifest only; evidence snapshots omit them.
  param([Parameter(Mandatory = $true)]$Config)
  return [pscustomobject]@{
    schemaVersion = $Config.schemaVersion
    product = $Config.product
    deployment = $Config.deployment
    notifications = $Config.notifications
    leasePolicy = $Config.leasePolicy
    desired = $Config.desired
  }
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
  # Routine reads are intentionally quiet. Keep only a short safe summary when
  # an internal read indicates uncertainty or failure; never persist command
  # text, raw output, process arguments, or exception details.
  if ($Output -notmatch '(?i)\b(ERROR|FAILED|WARN|UNKNOWN|BLOCKED|OVER_BUDGET)\b|exitCode=[1-9][0-9]*') { return }
  Add-CaretakerLogEntry -Label $Label -Outcome 'review required'
}

function Add-CaretakerLogEntry {
  param([Parameter(Mandatory = $true)][string]$Label, [Parameter(Mandatory = $true)][string]$Outcome)
  $logPath = Join-Path $script:ProjectRoot 'diag_log.txt'
  $backupPath = $logPath + '.1'
  $maxBytes = 65536
  $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')] $Label - $Outcome`r`n"
  $encoding = New-Object System.Text.UTF8Encoding($false)
  if (Test-Path -LiteralPath $logPath -PathType Leaf) {
    try {
      if ((Get-Item -LiteralPath $logPath).Length + $encoding.GetByteCount($entry) -gt $maxBytes) {
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) { Remove-Item -LiteralPath $backupPath -Force }
        Move-Item -LiteralPath $logPath -Destination $backupPath
      }
    } catch { return }
  }
  try { [System.IO.File]::AppendAllText($logPath, $entry, $encoding) } catch { }
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

function Get-AncestrySummary {
  param([object[]]$Processes, $Target, [int]$MaximumAncestors = 8)
  if ($null -eq $Target -or -not $Target.creationTimeUtc -or [string]::IsNullOrWhiteSpace([string]$Target.executablePath)) {
    return [pscustomobject]@{ state = 'UNKNOWN'; text = 'identity incomplete'; chain = @(); reason = 'Process creation time or executable path is unavailable.' }
  }
  $index = Get-ProcessIndex -Processes $Processes
  $chain = New-Object System.Collections.Generic.List[string]
  $child = $Target
  $complete = $false
  $reason = 'Ancestry depth cap reached.'
  for ($i = 0; $i -lt $MaximumAncestors; $i++) {
    $parentPid = 0
    if ($null -eq $child.parentPid -or -not [int]::TryParse([string]$child.parentPid, [ref]$parentPid)) { $reason = 'Parent PID is unavailable.'; break }
    if ($parentPid -eq 0) { $complete = $true; $reason = $null; break }
    $parent = $index[[string]$parentPid]
    if ($null -eq $parent -or -not $parent.creationTimeUtc -or [string]::IsNullOrWhiteSpace([string]$parent.executablePath)) { $reason = 'Parent process identity or path is unavailable in this sample.'; break }
    $expectedParentTime = [string](Get-OptionalProperty $child 'parentCreationTimeUtc')
    if ([string]::IsNullOrWhiteSpace($expectedParentTime) -or $expectedParentTime -ne [string]$parent.creationTimeUtc) { $reason = 'Parent creation time does not verify the observed ancestry link.'; break }
    $chain.Add(('{0} (pid {1}, {2})' -f $parent.name, $parent.pid, $parent.executablePath))
    $child = $parent
  }
  $state = if ($complete) { 'KNOWN' } else { 'UNKNOWN' }
  $text = if ($chain.Count -gt 0) { $chain -join ' <- ' } else { if ($complete) { 'system root' } else { 'parent chain incomplete' } }
  return [pscustomobject]@{ state = $state; text = $text; chain = @($chain.ToArray()); reason = $reason }
}

function Get-OnDemandProcessSample {
  $raw = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
  $complete = $raw.Count -le 2000
  $items = foreach ($p in @($raw | Select-Object -First 2000)) {
    $userTicks = $null; $kernelTicks = $null; $cpuTicks = $null
    try {
      $userTicks = [int64]$p.UserModeTime
      $kernelTicks = [int64]$p.KernelModeTime
      $cpuTicks = $userTicks + $kernelTicks
    } catch { }
    [pscustomobject]@{
      pid = [int]$p.ProcessId
      creationTimeUtc = Convert-CreationTime $p.CreationDate
      name = [string]$p.Name
      executablePath = [string]$p.ExecutablePath
      parentPid = if ($null -eq $p.ParentProcessId) { $null } else { [int]$p.ParentProcessId }
      workingSetBytes = if ($null -eq $p.WorkingSetSize) { $null } else { [int64]$p.WorkingSetSize }
      cpuTicks100ns = $cpuTicks
    }
  }
  $processes = @(Add-ParentCreationTimes -Processes @($items))
  return [pscustomobject]@{ processes = $processes; complete = $complete }
}

function Get-ProcessIdentityKey {
  param($Process)
  if ($null -eq $Process -or -not $Process.creationTimeUtc -or [string]::IsNullOrWhiteSpace([string]$Process.executablePath) -or $null -eq $Process.parentPid) { return $null }
  return ('{0}|{1}|{2}|{3}' -f $Process.pid, $Process.creationTimeUtc, ([string]$Process.executablePath).ToLowerInvariant(), $Process.parentPid)
}

function Get-BusyRows {
  param([object[]]$Before, [object[]]$After, [double]$ElapsedSeconds, [int]$Limit, [string]$FilterName = '')
  $beforeIndex = Get-ProcessIndex -Processes $Before
  $rows = New-Object System.Collections.Generic.List[object]
  $named = New-Object System.Collections.Generic.List[object]
  $unknownIdentity = 0
  $unknownAncestry = 0
  foreach ($process in $After) {
    $prior = $beforeIndex[[string]$process.pid]
    $priorKey = Get-ProcessIdentityKey $prior
    $currentKey = Get-ProcessIdentityKey $process
    if ($null -eq $prior) { continue }
    if ($null -eq $priorKey -or $null -eq $currentKey -or $priorKey -ne $currentKey -or $null -eq $process.cpuTicks100ns -or $null -eq $prior.cpuTicks100ns) { $unknownIdentity++; continue }
    $ancestry = Get-AncestrySummary -Processes $After -Target $process
    if ($ancestry.state -ne 'KNOWN') { $unknownAncestry++ }
    $delta = [int64]$process.cpuTicks100ns - [int64]$prior.cpuTicks100ns
    if ($delta -lt 0) { $unknownIdentity++; continue }
    $percent = [Math]::Round(($delta / ($ElapsedSeconds * 10000000.0)) * 100.0, 1)
    $row = [pscustomobject]@{
      pid = $process.pid; creationTimeUtc = $process.creationTimeUtc; name = $process.name
      executablePath = $process.executablePath; parentPid = $process.parentPid
      attributionState = $ancestry.state; ancestry = $ancestry.text
      cpuPercentOneCore = $percent
      workingSetBytes = if ($process.PSObject.Properties.Name -contains 'workingSetBytes' -and $null -ne $process.workingSetBytes) { [int64]$process.workingSetBytes } else { $null }
    }
    if ($delta -gt 0) { $rows.Add($row) }
    if ($FilterName -and $process.name.IndexOf($FilterName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $named.Add($row) }
  }
  return [pscustomobject]@{ rows = @($rows | Sort-Object cpuPercentOneCore -Descending | Select-Object -First $Limit); named = @($named | Sort-Object workingSetBytes -Descending | Select-Object -First 10); unknownIdentityCount = $unknownIdentity; unknownAncestryCount = $unknownAncestry }
}

function Get-BusyMemorySummary {
  param([object[]]$Processes, [int]$Limit)
  $memoryState = 'UNKNOWN'; $memoryReason = 'Native operating system memory counters unavailable.'
  $totalBytes = $null; $freeBytes = $null; $usedPercent = $null
  try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1
    $totalKb = [int64]$os.TotalVisibleMemorySize
    $freeKb = [int64]$os.FreePhysicalMemory
    if ($totalKb -le 0 -or $freeKb -lt 0 -or $freeKb -gt $totalKb) { throw 'invalid counters' }
    $totalBytes = [int64]($totalKb * 1024)
    $freeBytes = [int64]($freeKb * 1024)
    $usedPercent = [Math]::Round((($totalKb - $freeKb) / [double]$totalKb) * 100.0, 1)
    $memoryState = 'OK'; $memoryReason = $null
  } catch { }
  $consumers = @($Processes | Where-Object {
    $null -ne (Get-ProcessIdentityKey $_) -and $null -ne $_.workingSetBytes
  } | Sort-Object { [int64]$_.workingSetBytes } -Descending | Select-Object -First $Limit | ForEach-Object {
    $ancestry = Get-AncestrySummary -Processes $Processes -Target $_
    [pscustomobject]@{
      pid = $_.pid; creationTimeUtc = $_.creationTimeUtc; parentPid = $_.parentPid
      name = $_.name; executablePath = $_.executablePath; workingSetBytes = [int64]$_.workingSetBytes
      attributionState = $ancestry.state; ancestry = $ancestry.text
    }
  })
  $consumerState = if ($consumers.Count -gt 0) { 'OK' } else { 'UNKNOWN' }
  return [pscustomobject]@{
    state = if ($memoryState -eq 'OK' -and $consumerState -eq 'OK') { 'OK' } else { 'UNKNOWN' }
    coverage = [pscustomobject]@{ counters = $memoryState; topConsumers = $consumerState }
    reason = $memoryReason; totalBytes = $totalBytes; freeBytes = $freeBytes; usedPercent = $usedPercent
    topConsumers = $consumers
  }
}

function Invoke-Busy {
  $capturedAt = Get-UtcStamp
  try {
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $before = Get-OnDemandProcessSample
    Start-Sleep -Seconds $SampleSeconds
    $after = Get-OnDemandProcessSample
    $clock.Stop()
  } catch {
    return [pscustomobject]@{ schemaVersion = 1; action = 'busy'; capturedAtUtc = $capturedAt; state = 'UNKNOWN'; coverage = [pscustomobject]@{ processes = 'UNKNOWN' }; reason = 'Process CPU counters could not be sampled.'; sampleSeconds = $SampleSeconds; processes = @() }
  }
  if (-not $before.complete -or -not $after.complete) {
    return [pscustomobject]@{ schemaVersion = 1; action = 'busy'; capturedAtUtc = $capturedAt; state = 'UNKNOWN'; coverage = [pscustomobject]@{ processes = 'DEGRADED' }; reason = 'Process inventory exceeded the 2000 item cap.'; sampleSeconds = $SampleSeconds; processes = @() }
  }
  $systemCpu = [pscustomobject]@{ state = 'UNKNOWN'; percent = $null; capturedAtUtc = (Get-UtcStamp); source = 'Win32_PerfFormattedData_PerfOS_Processor(_Total)' }
  try {
    $counter = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $counter -or $null -eq $counter.PercentProcessorTime) { throw 'Aggregate CPU counter unavailable.' }
    $cpuValue = [double]$counter.PercentProcessorTime
    if ($cpuValue -lt 0 -or $cpuValue -gt 100) { throw 'Invalid aggregate CPU counter.' }
    $systemCpu = [pscustomobject]@{ state = 'OK'; percent = [Math]::Round($cpuValue, 1); capturedAtUtc = (Get-UtcStamp); source = 'Win32_PerfFormattedData_PerfOS_Processor(_Total)' }
  } catch { }
  $elapsed = [Math]::Max(0.001, $clock.Elapsed.TotalSeconds)
  $busy = Get-BusyRows -Before $before.processes -After $after.processes -ElapsedSeconds $elapsed -Limit $Top -FilterName $ProcessName
  $memory = Get-BusyMemorySummary -Processes $after.processes -Limit $Top
  if ($busy.rows.Count -eq 0) {
    return [pscustomobject]@{ schemaVersion = 1; action = 'busy'; capturedAtUtc = $capturedAt; state = 'UNKNOWN'; coverage = [pscustomobject]@{ cpu = 'UNKNOWN'; aggregateCpu = $systemCpu.state; processIdentity = if ($busy.unknownIdentityCount -gt 0) { 'DEGRADED' } else { 'UNKNOWN' }; ancestry = 'UNKNOWN'; memoryCounters = $memory.coverage.counters; topMemoryConsumers = $memory.coverage.topConsumers }; reason = 'No processes had stable PID, creation time, path identity across the sample.'; sampleSeconds = $elapsed; systemCpu = $systemCpu; memory = $memory; requestedProcessName = $ProcessName; namedProcesses = @($busy.named); incompleteIdentityCount = $busy.unknownIdentityCount; incompleteAncestryCount = $busy.unknownAncestryCount; processes = @() }
  }
  $cpuCoverage = 'OK'
  $identityCoverage = if ($busy.unknownIdentityCount -gt 0) { 'DEGRADED' } else { 'OK' }
  $ancestryCoverage = if ($busy.unknownAncestryCount -gt 0 -or @($memory.topConsumers | Where-Object attributionState -ne 'KNOWN').Count -gt 0) { 'UNKNOWN' } else { 'OK' }
  $state = if ($identityCoverage -ne 'OK' -or $ancestryCoverage -ne 'OK' -or $memory.state -ne 'OK') { 'DEGRADED' } else { 'OK' }
  return [pscustomobject]@{
    schemaVersion = 1; action = 'busy'; capturedAtUtc = $capturedAt; state = $state
    coverage = [pscustomobject]@{ cpu = $cpuCoverage; aggregateCpu = $systemCpu.state; processIdentity = $identityCoverage; ancestry = $ancestryCoverage; memoryCounters = $memory.coverage.counters; topMemoryConsumers = $memory.coverage.topConsumers }
    sample = [pscustomobject]@{ requestedSeconds = $SampleSeconds; elapsedSeconds = [Math]::Round($elapsed, 2); cpuUnit = 'percent of one logical CPU' }
    systemCpu = $systemCpu; memory = $memory; requestedProcessName = $ProcessName; namedProcesses = @($busy.named); incompleteIdentityCount = $busy.unknownIdentityCount; incompleteAncestryCount = $busy.unknownAncestryCount; processCount = $busy.rows.Count; processes = @($busy.rows)
  }
}

function Invoke-Explain {
  $capturedAt = Get-UtcStamp
  if ($ProcessId -le 0) { return [pscustomobject]@{ schemaVersion = 1; action = 'explain'; capturedAtUtc = $capturedAt; state = 'UNKNOWN'; processId = $ProcessId; coverage = [pscustomobject]@{ process = 'UNKNOWN'; ancestry = 'UNKNOWN'; tcpEndpoints = 'UNKNOWN'; udpEndpoints = 'UNKNOWN' }; reason = 'Supply -ProcessId with a positive PID.' } }
  try {
    $first = Get-OnDemandProcessSample
    if (-not $first.complete) { return [pscustomobject]@{ schemaVersion = 1; action = 'explain'; capturedAtUtc = $capturedAt; state = 'UNKNOWN'; processId = $ProcessId; coverage = [pscustomobject]@{ process = 'DEGRADED'; ancestry = 'UNKNOWN'; tcpEndpoints = 'UNKNOWN'; udpEndpoints = 'UNKNOWN' }; reason = 'Process inventory exceeded the 2000 item cap.' } }
    $index = Get-ProcessIndex -Processes $first.processes
    $target = $index[[string]$ProcessId]
    if ($null -eq $target) { return [pscustomobject]@{ schemaVersion = 1; action = 'explain'; capturedAtUtc = $capturedAt; state = 'UNKNOWN'; processId = $ProcessId; coverage = [pscustomobject]@{ process = 'UNKNOWN'; ancestry = 'UNKNOWN'; tcpEndpoints = 'UNKNOWN'; udpEndpoints = 'UNKNOWN' }; reason = 'PID was not present in the process inventory.' } }
    $tcpState = 'UNKNOWN'; $tcpReason = 'Native TCP owner query unavailable.'; $tcp = @()
    try {
      if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) { throw 'unavailable' }
      $tcp = @(Get-NetTCPConnection -OwningProcess $ProcessId -ErrorAction Stop | Select-Object -First 20)
      $tcpState = 'OK'
      $tcpReason = $null
    } catch {
      $tcp = @()
      if ($_.FullyQualifiedErrorId -like 'CmdletizationQuery_NotFound_OwningProcess,*') { $tcpState = 'OK'; $tcpReason = $null }
    }
    $udpState = 'UNKNOWN'; $udpReason = 'Native UDP owner query unavailable.'; $udp = @()
    try {
      if (-not (Get-Command Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) { throw 'unavailable' }
      $udp = @(Get-NetUDPEndpoint -OwningProcess $ProcessId -ErrorAction Stop | Select-Object -First 20)
      $udpState = 'OK'
      $udpReason = $null
    } catch {
      $udp = @()
      if ($_.FullyQualifiedErrorId -like 'CmdletizationQuery_NotFound_OwningProcess,*') { $udpState = 'OK'; $udpReason = $null }
    }
    if ($tcp.Count -ge 20) { $tcpState = 'DEGRADED'; $tcpReason = 'Endpoint cap reached; results may be partial.' }
    if ($udp.Count -ge 20) { $udpState = 'DEGRADED'; $udpReason = 'Endpoint cap reached; results may be partial.' }
    $last = Get-OnDemandProcessSample
    if (-not $last.complete) { return [pscustomobject]@{ schemaVersion = 1; action = 'explain'; capturedAtUtc = $capturedAt; state = 'UNKNOWN'; processId = $ProcessId; coverage = [pscustomobject]@{ process = 'DEGRADED'; ancestry = 'UNKNOWN'; tcpEndpoints = 'UNKNOWN'; udpEndpoints = 'UNKNOWN' }; reason = 'Final process inventory exceeded the 2000 item cap.' } }
    $lastIndex = Get-ProcessIndex -Processes $last.processes
    $verified = $lastIndex[[string]$ProcessId]
    $targetKey = Get-ProcessIdentityKey $target
    $verifiedKey = Get-ProcessIdentityKey $verified
    if ($null -eq $targetKey -or $null -eq $verifiedKey -or $targetKey -ne $verifiedKey) {
      return [pscustomobject]@{ schemaVersion = 1; action = 'explain'; capturedAtUtc = $capturedAt; state = 'UNKNOWN'; processId = $ProcessId; coverage = [pscustomobject]@{ process = 'UNKNOWN'; ancestry = 'UNKNOWN'; tcpEndpoints = 'UNKNOWN'; udpEndpoints = 'UNKNOWN' }; reason = 'Process identity changed or lacks creation time, path, or parent PID during the explanation.' }
    }
    $ancestry = Get-AncestrySummary -Processes $last.processes -Target $verified
    $result = if ($ancestry.state -eq 'KNOWN' -and $tcpState -eq 'OK' -and $udpState -eq 'OK') { 'OK' } else { 'UNKNOWN' }
    $tcpItems = @($tcp | ForEach-Object { [pscustomobject]@{ state = [string]$_.State; localAddress = [string]$_.LocalAddress; localPort = [int]$_.LocalPort; remoteAddress = [string]$_.RemoteAddress; remotePort = [int]$_.RemotePort } })
    $udpItems = @($udp | ForEach-Object { [pscustomobject]@{ localAddress = [string]$_.LocalAddress; localPort = [int]$_.LocalPort } })
    return [pscustomobject]@{
      schemaVersion = 1; action = 'explain'; capturedAtUtc = $capturedAt; state = $result; processId = $ProcessId
      reason = 'Live state only; this does not establish approval or workload ownership.'
      coverage = [pscustomobject]@{ process = 'OK'; ancestry = $ancestry.state; tcpEndpoints = $tcpState; udpEndpoints = $udpState }
      process = [pscustomobject]@{ pid = $verified.pid; creationTimeUtc = $verified.creationTimeUtc; parentPid = $verified.parentPid; name = $verified.name; executablePath = $verified.executablePath; workingSetBytes = $verified.workingSetBytes }
      ancestry = [pscustomobject]@{ state = $ancestry.state; chain = $ancestry.text; reason = $ancestry.reason }
      endpoints = [pscustomobject]@{ tcp = [pscustomobject]@{ state = $tcpState; reason = $tcpReason; count = $tcpItems.Count; limit = 20; items = $tcpItems }; udp = [pscustomobject]@{ state = $udpState; reason = $udpReason; count = $udpItems.Count; limit = 20; items = $udpItems } }
    }
  } catch {
    return [pscustomobject]@{ schemaVersion = 1; action = 'explain'; capturedAtUtc = $capturedAt; state = 'UNKNOWN'; processId = $ProcessId; coverage = [pscustomobject]@{ process = 'UNKNOWN'; ancestry = 'UNKNOWN'; tcpEndpoints = 'UNKNOWN'; udpEndpoints = 'UNKNOWN' }; reason = 'One or more process or endpoint queries were unavailable.' }
  }
}

function Invoke-Events {
  $eventScript = Join-Path $PSScriptRoot 'event-health.ps1'
  if (-not (Test-Path -LiteralPath $eventScript -PathType Leaf)) {
    return [pscustomobject]@{ schemaVersion = 1; action = 'events'; capturedAtUtc = (Get-UtcStamp); state = 'UNKNOWN'; coverage = [pscustomobject]@{ System = 'UNKNOWN'; Application = 'UNKNOWN' }; reason = 'Event health script is missing.' }
  }
  $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  try {
    $raw = @(& $exe -NoProfile -NonInteractive -File $eventScript -WindowDays $WindowDays -MaxEventsPerLog $MaxEventsPerLog 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'event query failed' }
    $result = ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop
    $result | Add-Member -NotePropertyName action -NotePropertyValue 'events' -Force
    $coverageStates = @($result.coverage.PSObject.Properties | ForEach-Object { [string]$_.Value.status })
    $overall = if ($coverageStates -contains 'UNKNOWN') { 'UNKNOWN' } elseif ($coverageStates -contains 'DEGRADED') { 'DEGRADED' } else { 'OK' }
    $result | Add-Member -NotePropertyName state -NotePropertyValue $overall -Force
    return $result
  } catch {
    return [pscustomobject]@{ schemaVersion = 1; action = 'events'; capturedAtUtc = (Get-UtcStamp); state = 'UNKNOWN'; coverage = [pscustomobject]@{ System = 'UNKNOWN'; Application = 'UNKNOWN' }; reason = 'Event health query or JSON output was unavailable.' }
  }
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
  $previousCoverage = $null
  $alertState = Read-JsonFile -Path $script:AlertStatePath
  if ($alertState -and $alertState.active) { foreach ($entry in @($alertState.active)) { $activeAlertIds[[string]$entry.id] = $true } }
  if ($PreviousSnapshot) {
    $prevTcpOk = $false
    $prevUdpOk = $false
    if ($PreviousSnapshot.PSObject.Properties.Name -contains 'coverage') { $previousCoverage = $PreviousSnapshot.coverage }
    if ($previousCoverage) {
      if ($previousCoverage.tcpListeners) { $prevTcpOk = ($previousCoverage.tcpListeners.status -eq 'OK') }
      if ($previousCoverage.udpEndpoints) { $prevUdpOk = ($previousCoverage.udpEndpoints.status -eq 'OK') }
    }
    foreach ($listener in @($PreviousSnapshot.observed.tcpListeners)) {
      if ($prevTcpOk) { $previousListeners[(Get-ListenerKey $listener)] = $true }
    }
    foreach ($listener in @($PreviousSnapshot.observed.udpEndpoints)) {
      if ($prevUdpOk) { $previousListeners[(Get-ListenerKey $listener)] = $true }
    }
  }
  foreach ($listener in @($Inventory.items.tcpListeners) + @($Inventory.items.udpEndpoints)) {
    $moduleName = if ($listener.protocol -eq 'TCP') { 'tcpListeners' } else { 'udpEndpoints' }
    $prevModuleOk = $false
    if ($PreviousSnapshot -and $previousCoverage -and $previousCoverage.$moduleName) {
      $prevModuleOk = ($previousCoverage.$moduleName.status -eq 'OK')
    }
    if ($Inventory.coverage.$moduleName.status -eq 'OK' -and $listener.protocol -eq 'TCP' -and -not (Test-ListenerApproved -Listener $listener -Desired $Desired)) {
      $key = Get-ListenerKey $listener
      $id = 'unreviewed-listener:' + $key
      # Without a complete prior baseline nothing is "new", but still-present open alerts must stay open.
      $isNewObservation = $prevModuleOk -and -not $previousListeners.ContainsKey($key)
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
  param([hashtable]$Candidates, $Coverage, $Config)
  $old = Read-JsonFile -Path $script:AlertStatePath
  $previous = @{}
  if ($old -and $old.active) { foreach ($entry in @($old.active)) { $previous[[string]$entry.id] = $entry } }
  $now = Get-UtcStamp
  $nowUtc = [DateTime]::UtcNow
  $next = @()
  foreach ($id in @($Candidates.Keys | Sort-Object)) {
    $candidate = $Candidates[$id]
    if ($previous.ContainsKey($id)) {
      $prior = $previous[$id]
      $next += [pscustomobject]@{ id = $id; rule = $candidate.rule; severity = $candidate.severity; subject = $candidate.subject; firstSeenUtc = $prior.firstSeenUtc; lastSeenUtc = $now; seenCount = [int]$prior.seenCount + 1 }
    } else {
      $record = [pscustomobject]@{ id = $id; rule = $candidate.rule; severity = $candidate.severity; subject = $candidate.subject; firstSeenUtc = $now; lastSeenUtc = $now; seenCount = 1 }
      $next += $record
      # Snooze keeps Needs-attention/active state; it only suppresses outbox re-nag.
      if (-not (Test-AlertSnoozed -Config $Config -AlertId $id -NowUtc $nowUtc)) {
        Add-JsonLine -Path $script:OutboxPath -Value ([pscustomobject]@{ event = 'open'; atUtc = $now; alert = $record })
      }
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
    $rawAge = ([DateTime]::UtcNow - $observedAt).TotalMinutes
    if ($rawAge -lt -5) { return [pscustomobject]@{ state = 'UNKNOWN'; ageMinutes = $null; detail = 'Snapshot time is in the future.' } }
    $age = [Math]::Max(0, [Math]::Round($rawAge, 1))
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
    desired = (Get-SnapshotDesired -Config $config)
    observed = $inventory.items
    coverage = $inventory.coverage
  }
  Update-AlertOutbox -Candidates $candidates -Coverage $inventory.coverage -Config $config
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

function Invoke-WithEvidenceLock {
  param([Parameter(Mandatory = $true)][scriptblock]$Body)
  # An OS file lock (released on process exit) serializes the scheduled tick and chat-triggered snapshots.
  if (-not (Test-Path -LiteralPath $script:EvidencePath -PathType Container)) { New-Item -ItemType Directory -Path $script:EvidencePath -Force | Out-Null }
  $lockPath = Join-Path $script:EvidencePath 'snapshot.lock'
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  $lock = $null
  while ($null -eq $lock) {
    try { $lock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [System.IO.IOException] {
      if ([DateTime]::UtcNow -ge $deadline) { throw 'Another Caretaker snapshot is still running; this attempt was skipped.' }
      Start-Sleep -Milliseconds 500
    }
  }
  try { & $Body } finally { $lock.Dispose() }
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

function Invoke-Review {
  $config = Get-Config
  $nowUtc = [DateTime]::UtcNow
  switch ($ReviewAction) {
    'list' {
      $alertState = $null
      try { $alertState = Read-JsonFile -Path $script:AlertStatePath } catch { $alertState = $null }
      $active = if ($alertState -and $alertState.active) { @($alertState.active) } else { @() }
      $decisions = @(Get-DecisionItems -Config $config)
      Write-Output 'Goliath Caretaker review'
      Write-Output ("Active alerts (Needs attention): {0}" -f $active.Count)
      Write-Output 'Snooze suppresses re-nag only; open alerts stay visible.'
      foreach ($alert in ($active | Sort-Object { [string]$_.id })) {
        $id = [string]$alert.id
        $decision = Find-Decision -Config $config -AlertId $id
        $class = if ($decision -and $decision.class) { [string]$decision.class } else { 'none' }
        $snoozed = Test-AlertSnoozed -Config $config -AlertId $id -NowUtc $nowUtc
        $until = if ($decision -and $decision.snoozeUntilUtc) { [string]$decision.snoozeUntilUtc } else { '' }
        $snoozeLabel = if ($snoozed) { "snoozed until $until" } elseif ($until) { "snooze expired ($until)" } else { 'not snoozed' }
        Write-Output ("- {0} | {1} | class={2}; {3}" -f $id, [string]$alert.subject, $class, $snoozeLabel)
      }
      $orphan = @($decisions | Where-Object {
        $id = [string]$_.alertId
        -not ($active | Where-Object { [string]$_.id -eq $id })
      })
      if ($orphan.Count -gt 0) {
        Write-Output ("Personal decisions without a current open alert: {0}" -f $orphan.Count)
        foreach ($item in ($orphan | Sort-Object { [string]$_.alertId })) {
          Write-Output ("- {0} | class={1}; reviewed={2}" -f [string]$item.alertId, [string]$item.class, [string]$item.reviewedAtUtc)
        }
      }
    }
    'show' {
      if ([string]::IsNullOrWhiteSpace($AlertId)) { throw 'review show requires -AlertId.' }
      $decision = Find-Decision -Config $config -AlertId $AlertId
      $alertState = $null
      try { $alertState = Read-JsonFile -Path $script:AlertStatePath } catch { $alertState = $null }
      $active = $null
      if ($alertState -and $alertState.active) { $active = @($alertState.active | Where-Object { [string]$_.id -eq $AlertId } | Select-Object -First 1) }
      Write-Output ("alertId: {0}" -f $AlertId)
      Write-Output ("openAlert: {0}" -f $(if ($active) { 'yes' } else { 'no' }))
      if ($active) { Write-Output ("subject: {0}" -f [string]$active.subject) }
      if ($null -eq $decision) {
        Write-Output 'decision: none'
      } else {
        Write-Output ("class: {0}" -f [string]$decision.class)
        Write-Output ("purpose: {0}" -f [string]$decision.purpose)
        Write-Output ("project: {0}" -f [string]$decision.project)
        Write-Output ("note: {0}" -f [string]$decision.note)
        Write-Output ("reviewedAtUtc: {0}" -f [string]$decision.reviewedAtUtc)
        Write-Output ("snoozeUntilUtc: {0}" -f $(if ($decision.snoozeUntilUtc) { [string]$decision.snoozeUntilUtc } else { '' }))
        Write-Output ("snoozedNow: {0}" -f (Test-AlertSnoozed -Config $config -AlertId $AlertId -NowUtc $nowUtc))
      }
    }
    'set' {
      if ([string]::IsNullOrWhiteSpace($AlertId)) { throw 'review set requires -AlertId.' }
      if ([string]::IsNullOrWhiteSpace($Class)) { throw 'review set requires -Class wanted|optional|temporary|review|unknown.' }
      $items = @(Get-DecisionItems -Config $config)
      $existing = $null
      $nextItems = @()
      foreach ($item in $items) {
        if ([string]$item.alertId -eq $AlertId) { $existing = $item } else { $nextItems += $item }
      }
      $record = [pscustomobject]@{
        alertId = $AlertId
        class = $Class
        purpose = $(if (-not [string]::IsNullOrWhiteSpace($Purpose)) { $Purpose } elseif ($existing) { [string]$existing.purpose } else { '' })
        project = $(if (-not [string]::IsNullOrWhiteSpace($Project)) { $Project } elseif ($existing) { [string]$existing.project } else { '' })
        note = $(if (-not [string]::IsNullOrWhiteSpace($Note)) { $Note } elseif ($existing) { [string]$existing.note } else { '' })
        reviewedAtUtc = Get-UtcStamp
        snoozeUntilUtc = if ($existing -and $existing.snoozeUntilUtc) { [string]$existing.snoozeUntilUtc } else { $null }
      }
      $nextItems += $record
      Save-ConfigDecisions -Config $config -Items $nextItems
      Add-CaretakerLogEntry -Label 'caretaker-review-set' -Outcome ("recorded class=$Class for $AlertId")
      Write-Output ("Recorded personal decision for {0}: class={1}" -f $AlertId, $Class)
      Write-Output 'Decision written only to config/caretaker.json; evidence/alert state was not changed.'
    }
    'snooze' {
      if ([string]::IsNullOrWhiteSpace($AlertId)) { throw 'review snooze requires -AlertId.' }
      $until = $nowUtc.AddDays($Days).ToString('o')
      $items = @(Get-DecisionItems -Config $config)
      $existing = $null
      $nextItems = @()
      foreach ($item in $items) {
        if ([string]$item.alertId -eq $AlertId) { $existing = $item } else { $nextItems += $item }
      }
      $record = [pscustomobject]@{
        alertId = $AlertId
        class = if ($existing -and $existing.class) { [string]$existing.class } else { 'review' }
        purpose = if ($existing) { [string]$existing.purpose } else { '' }
        project = if ($existing) { [string]$existing.project } else { '' }
        note = if ($existing) { [string]$existing.note } else { '' }
        reviewedAtUtc = if ($existing -and $existing.reviewedAtUtc) { [string]$existing.reviewedAtUtc } else { Get-UtcStamp }
        snoozeUntilUtc = $until
      }
      $nextItems += $record
      Save-ConfigDecisions -Config $config -Items $nextItems
      Add-CaretakerLogEntry -Label 'caretaker-review-snooze' -Outcome ("snoozed $AlertId until $until")
      Write-Output ("Snoozed re-nag for {0} until {1}" -f $AlertId, $until)
      Write-Output 'Needs attention / open alerts stay visible; only outbox re-nag is suppressed while snoozed.'
    }
    'clear' {
      if ([string]::IsNullOrWhiteSpace($AlertId)) { throw 'review clear requires -AlertId.' }
      $items = @(Get-DecisionItems -Config $config)
      $kept = @($items | Where-Object { [string]$_.alertId -ne $AlertId })
      if ($kept.Count -eq $items.Count) { throw "No personal decision found for alertId $AlertId." }
      Save-ConfigDecisions -Config $config -Items $kept
      Add-CaretakerLogEntry -Label 'caretaker-review-clear' -Outcome ("cleared decision for $AlertId")
      Write-Output ("Cleared personal decision for {0}" -f $AlertId)
      Write-Output 'Open alerts and Needs attention are unchanged.'
    }
  }
}

if (-not $LibraryOnly) {
  $exitCode = 0
  try {
    $captured = @(& {
      if ($Action -notin @('busy','explain','events')) { Write-Output ("Caretaker command: {0}" -f $Action) }
      switch ($Action) {
        'status' { Invoke-Status }
        'doctor' { Invoke-Doctor }
        'snapshot' { Invoke-WithEvidenceLock { Invoke-Snapshot } }
        'tick' { Invoke-WithEvidenceLock { Invoke-Tick } }
        'busy' { Invoke-Busy }
        'explain' { Invoke-Explain }
        'events' { Invoke-Events }
        'review' { Invoke-Review }
      }
    } *>&1)
  } catch {
    $exitCode = 1
    if ($Action -in @('busy','explain','events')) {
      $captured = @([pscustomobject]@{ schemaVersion = 1; action = $Action; capturedAtUtc = (Get-UtcStamp); state = 'UNKNOWN'; reason = 'Caretaker action failed unexpectedly.' })
    } else {
      $captured = @($_)
    }
  }
  if ($Action -in @('busy','explain','events')) {
    $jsonValue = if ($captured.Count -eq 1) { $captured[0] } else { $captured }
    $rendered = ConvertTo-Json -InputObject $jsonValue -Depth 20 -Compress
  }
  else { $rendered = ($captured | Out-String) }
  Write-Output $rendered
  if ($exitCode -ne 0) {
    Add-CaretakerLogEntry -Label "caretaker-$Action" -Outcome 'failed'
  } elseif ($Action -eq 'snapshot') {
    Add-CaretakerLogEntry -Label 'caretaker-snapshot' -Outcome 'completed'
  } elseif ($rendered -match '(?i)\b(ERROR|FAILED|WARN|UNKNOWN|DEGRADED|BLOCKED|OVER_BUDGET|NOT READY)\b') {
    Add-CaretakerLogEntry -Label "caretaker-$Action" -Outcome 'review required'
  }
  if ($exitCode -ne 0) { exit $exitCode }
}
