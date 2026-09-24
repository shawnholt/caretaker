[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
  [ValidateSet('Plan', 'Install', 'Pause', 'Uninstall', 'Rebind')]
  [string]$Action = 'Plan'
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $PSScriptRoot
$script:ConfigPath = Join-Path $script:Root 'config\caretaker.json'
$script:LogPath = Join-Path $script:Root 'diag_log.txt'
$script:ChangePath = Join-Path $script:Root 'change_log.txt'
$script:EvidencePath = Join-Path $script:Root 'evidence'
$script:ReceiptPath = Join-Path $script:EvidencePath 'setup-owner.json'
$script:Manifest = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
$script:TaskName = [string]$script:Manifest.deployment.taskName
$script:CheckerPath = Join-Path $script:Root 'scripts\caretaker.ps1'
$script:TaskDescription = 'GoliathCaretaker task-only R1 periodic tick; identity from config/caretaker.json.'
$script:WindowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:ActionCmdlet = $PSCmdlet

function Write-RunLog {
  param([string]$Label, [string]$Command, [string]$Reason, [string]$Output)
  if ($Label -in @('Task Scheduler query', 'Setup plan', 'Setup invocation')) { return }
  if ($Label -eq 'Lease cleanup command' -and $Output -match '^ExitCode=0') { return }
  $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
  if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -ge 1048576) {
    Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.1') -Force
  }
  $detail = if ($Output.Length -gt 500) { $Output.Substring(0, 500) + ' [truncated]' } else { $Output }
  Add-Content -LiteralPath $script:LogPath -Value "`r`n[$time] $Label; command=$Command; outcome=$detail"
}

function Write-ChangeLog {
  param([string]$Command, [string]$Outcome, [string]$Rollback)
  $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
  if ((Test-Path -LiteralPath $script:ChangePath) -and (Get-Item -LiteralPath $script:ChangePath).Length -ge 1048576) {
    Move-Item -LiteralPath $script:ChangePath -Destination ($script:ChangePath + '.1') -Force
  }
  Add-Content -LiteralPath $script:ChangePath -Value "`r`n[$time] Caretaker task setup`r`nFILES/COMMANDS: scripts/setup.ps1; $Command`r`nOUTCOME: $Outcome`r`nROLLBACK: $Rollback"
}

function Update-ManifestState {
  param([bool]$Installed, [bool]$TaskEnabled, [string]$Reason)
  $config = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
  $config.deployment.installed = $Installed
  $config.deployment.taskEnabled = $TaskEnabled
  $config.deployment.collectorEnabled = $false
  $config.deployment.perfmon.enabled = $false
  $tempPath = $script:ConfigPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
  try {
    [System.IO.File]::WriteAllText($tempPath, (ConvertTo-Json -InputObject $config -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tempPath -Destination $script:ConfigPath -Force
    $script:Manifest = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ([bool]$script:Manifest.deployment.installed -ne $Installed -or [bool]$script:Manifest.deployment.taskEnabled -ne $TaskEnabled -or [bool]$script:Manifest.deployment.collectorEnabled -or [bool]$script:Manifest.deployment.perfmon.enabled) { throw 'Canonical task-only manifest state verification failed.' }
    Write-RunLog -Label 'Canonical manifest state' -Command 'Write config/caretaker.json deployment.installed/taskEnabled; keep collectorEnabled/perfmon.enabled false' -Reason $Reason -Output ("installed={0}; taskEnabled={1}; collectorEnabled=false; perfmon.enabled=false" -f $Installed,$TaskEnabled)
    Write-ChangeLog -Command 'Update config/caretaker.json deployment state' -Outcome $Reason -Rollback 'Restore the previous canonical manifest from version control or a separately preserved copy; no collector state is managed by setup.'
  } finally { if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force } }
}

function Invoke-LoggedCmdlet {
  param([string]$Command, [string]$Reason, [scriptblock]$ScriptBlock)
  try {
    $output = & $ScriptBlock 2>&1 | Out-String
    Write-RunLog -Label 'PowerShell system command' -Command $Command -Reason $Reason -Output 'Completed.'
    return $output
  } catch {
    Write-RunLog -Label 'PowerShell system command failed' -Command $Command -Reason $Reason -Output $_.ToString()
    throw
  }
}

function Get-ExpectedAction {
  $argsText = '-NoProfile -NonInteractive -File "' + $script:CheckerPath + '" tick'
  return @{ Execute = $script:WindowsPowerShell; Arguments = $argsText; WorkingDirectory = $script:Root }
}

function Get-Task {
  try {
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
    Write-RunLog -Label 'Task Scheduler query' -Command "Get-ScheduledTask -TaskName $script:TaskName" -Reason 'Check only the exact manifest-named checker task.' -Output 'Task present.'
    return $task
  } catch {
    $errorText = $_.ToString()
    if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) { return $null }
    Write-RunLog -Label 'Task Scheduler query failed' -Command "Get-ScheduledTask -TaskName $script:TaskName" -Reason 'Check only the exact manifest-named checker task.' -Output $errorText
    throw
  }
}

function Get-Receipt {
  if (-not (Test-Path -LiteralPath $script:ReceiptPath -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $script:ReceiptPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Setup receipt is unreadable. Stop for review.' }
}

function Get-ExpectedReceipt {
  $want = Get-ExpectedAction
  return [pscustomobject]@{
    schemaVersion = 1
    taskName = $script:TaskName
    taskDescription = $script:TaskDescription
    execute = $want.Execute
    arguments = $want.Arguments
    workingDirectory = $want.WorkingDirectory
  }
}

function Test-ReceiptIdentity($Receipt) {
  if (-not $Receipt) { return $false }
  $want = Get-ExpectedReceipt
  return ([int]$Receipt.schemaVersion -eq 1 -and [string]$Receipt.taskName -eq $want.taskName -and [string]$Receipt.taskDescription -eq $want.taskDescription -and [string]$Receipt.execute -eq $want.execute -and [string]$Receipt.arguments -eq $want.arguments -and [string]$Receipt.workingDirectory -eq $want.workingDirectory)
}

function Test-OwnedTask($Task) {
  $receipt = Get-Receipt
  if (-not (Test-ReceiptIdentity $receipt) -or -not $Task -or $Task.Description -ne $script:TaskDescription -or $Task.Actions.Count -ne 1) { return $false }
  $want = Get-ExpectedAction
  $action = $Task.Actions[0]
  return ([string]$action.Execute -eq $want.Execute -and [string]$action.Arguments -eq $want.Arguments -and [string]$action.WorkingDirectory -eq $want.WorkingDirectory)
}

function Get-RebindAssessment($Task, $Receipt, [string[]]$Blockers) {
  $reasons = [System.Collections.Generic.List[string]]::new()
  $eligible = $false
  if ($Task -and (Test-OwnedTask $Task)) {
    return [pscustomobject]@{ eligible = $false; state = 'NOT_NEEDED'; receiptMatchesNativeTask = $true; oldCheckerTargetAbsent = $false; oldWorkingDirectoryAbsent = $false; currentCheckoutMismatch = $false; reasons = @() }
  }
  $oldChecker = $null
  $receiptMatchesNativeTask = $false
  $oldCheckerTargetAbsent = $false
  $oldWorkingDirectoryAbsent = $false
  $currentCheckoutMismatch = $false
  if (-not $Task) { $reasons.Add('TASK_ABSENT') }
  if (-not $Receipt) { $reasons.Add('RECEIPT_ABSENT') }
  if ($Task -and $Receipt) {
    $wantExe = (Get-ExpectedAction).Execute
    $action = if ($Task.Actions.Count -eq 1) { $Task.Actions[0] } else { $null }
    $nativeReceiptMatch = $action -and
      [int]$Receipt.schemaVersion -eq 1 -and
      [string]$Receipt.taskName -eq $script:TaskName -and
      [string]$Receipt.taskDescription -ceq [string]$Task.Description -and
      [string]$Receipt.execute -ieq [string]$action.Execute -and
      [string]$Receipt.arguments -ceq [string]$action.Arguments -and
      [string]$Receipt.workingDirectory -ieq [string]$action.WorkingDirectory
    $receiptMatchesNativeTask = [bool]$nativeReceiptMatch
    if (-not $nativeReceiptMatch) { $reasons.Add('RECEIPT_TASK_MISMATCH') }
    if ([string]$Task.TaskName -ne $script:TaskName) { $reasons.Add('TASK_NAME_MISMATCH') }
    if ([string]$Task.Description -cne $script:TaskDescription -or $Task.Actions.Count -ne 1) { $reasons.Add('TASK_IDENTITY_MISMATCH') }
    if (-not $action -or [string]$action.Execute -ine $wantExe) { $reasons.Add('EXECUTABLE_MISMATCH') }
    if ($action) {
      $pattern = '^\-NoProfile \-NonInteractive \-File "([^"]+)" tick$'
      $parsed = [regex]::Match([string]$action.Arguments, $pattern)
      if (-not $parsed.Success) {
        $reasons.Add('ACTION_SHAPE_MISMATCH')
      } else {
        try {
          $oldChecker = [System.IO.Path]::GetFullPath($parsed.Groups[1].Value)
          $oldRoot = [System.IO.Path]::GetFullPath([string]$action.WorkingDirectory)
          $expectedOldChecker = [System.IO.Path]::GetFullPath((Join-Path $oldRoot 'scripts\caretaker.ps1'))
          if (-not [string]::Equals($oldChecker, $expectedOldChecker, [System.StringComparison]::OrdinalIgnoreCase)) { $reasons.Add('ACTION_PATH_RELATION_MISMATCH') }
          $oldCheckerTargetAbsent = -not (Test-Path -LiteralPath $oldChecker)
          $oldWorkingDirectoryAbsent = -not (Test-Path -LiteralPath $oldRoot -PathType Container)
          $currentCheckoutMismatch = -not [string]::Equals($oldChecker, [System.IO.Path]::GetFullPath($script:CheckerPath), [System.StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals($oldRoot, [System.IO.Path]::GetFullPath($script:Root), [System.StringComparison]::OrdinalIgnoreCase)
          if (-not $oldCheckerTargetAbsent) { $reasons.Add('OLD_CHECKER_STILL_EXISTS') }
          if (-not $oldWorkingDirectoryAbsent) { $reasons.Add('OLD_WORKING_DIRECTORY_STILL_EXISTS') }
        } catch { $reasons.Add('ACTION_PATH_INVALID') }
      }
    }
  }
  if (-not (Test-Path -LiteralPath $script:CheckerPath -PathType Leaf)) { $reasons.Add('CURRENT_CHECKER_MISSING') }
  if ($Blockers.Count -gt 0) { $reasons.Add('CURRENT_READINESS_BLOCKED') }
  $candidateReasons = @($reasons | Where-Object { $_ -notin @('CURRENT_READINESS_BLOCKED') })
  if ($candidateReasons.Count -eq 0 -and $Blockers.Count -eq 0) { $eligible = $true }
  $state = if ($eligible) { 'ELIGIBLE' } elseif ($reasons.Count -eq 0) { 'NOT_NEEDED' } else { 'BLOCKED' }
  return [pscustomobject]@{ eligible = $eligible; state = $state; receiptMatchesNativeTask = $receiptMatchesNativeTask; oldCheckerTargetAbsent = $oldCheckerTargetAbsent; oldWorkingDirectoryAbsent = $oldWorkingDirectoryAbsent; currentCheckoutMismatch = $currentCheckoutMismatch; reasons = @($reasons) }
}

function Get-Blockers {
  $items = [System.Collections.Generic.List[string]]::new()
  $checkerText = Get-Content -LiteralPath $script:CheckerPath -Raw
  if ($checkerText -notmatch "'tick'\s*\{" -and $checkerText -notmatch 'Invoke-Tick') { $items.Add('Checker has no tick action that reconciles overdue lease expiry before snapshot work.') }
  if (-not (Test-Path -LiteralPath (Join-Path $script:Root 'scripts\retention.ps1') -PathType Leaf)) { $items.Add('Routine retention Plan/Apply is unavailable.') }
  if ([int]$script:Manifest.deployment.retentionRunIntervalHours -ne 24) { $items.Add('Routine retention cadence is not set to once daily.') }
  if ([bool]$script:Manifest.deployment.perfmon.enabled -or [bool]$script:Manifest.deployment.collectorEnabled) { $items.Add('Continuous PerfMon must remain disabled for task-only R1 setup.') }
  $pilot = $script:Manifest.deployment.pilotProfile
  if ($pilot.status -ne 'PILOT' -or $script:Manifest.deployment.runtimeAcceptance -notlike 'TASK_ONLY PILOT*' -or [double]$pilot.snapshotWallSeconds -le 0 -or [double]$pilot.snapshotProcessCpuSeconds -le 0 -or [int]$pilot.logicalProcessors -le 0) { $items.Add('A short snapshot pilot profile is missing or invalid.') }
  return @($items)
}

function Show-Plan {
  $task = Get-Task
  $receipt = Get-Receipt
  [string[]]$blockers = @(Get-Blockers)
  $taskState = if (-not $task) { 'ABSENT' } elseif (Test-OwnedTask $task) { [string]$task.State } else { 'COLLISION_OR_CHANGED' }
  $rebindAssessment = Get-RebindAssessment -Task $task -Receipt $receipt -Blockers $blockers
  if ($receipt -and -not (Test-ReceiptIdentity $receipt)) { $blockers += 'A setup receipt exists but does not match the exact task-only identity.' }
  if ($task -and -not (Test-OwnedTask $task)) { $blockers += 'The manifest-named task exists without an exact matching setup receipt/action.' }
  $perfmon = $script:Manifest.deployment.perfmon
  $result = [pscustomobject]@{
    action = 'Plan'; projectRoot = $script:Root; checkerTask = $script:TaskName; checkerState = $taskState
    checkMinutes = $script:Manifest.deployment.checkIntervalMinutes; checkerAction = 'tick'
    runtimeAcceptance = [string]$script:Manifest.deployment.runtimeAcceptance; pilotProfile = $script:Manifest.deployment.pilotProfile
    perfmonState = 'OFF_BY_DEFAULT_NOT_MANAGED'; collectorEnabled = [bool]$script:Manifest.deployment.collectorEnabled
    configuredCollectorName = [string]$perfmon.collectorName; configuredOutput = (Join-Path $script:EvidencePath 'perfmon\caretaker.blg')
    sampleSeconds = $perfmon.sampleIntervalSeconds; maximumMiB = $perfmon.circularMaxMiB; counterResolution = $perfmon.counterResolution
    taskEnabled = [bool]$script:Manifest.deployment.taskEnabled; leaseLaunchEnabled = [bool]$script:Manifest.leasePolicy.captureLaunchEnabled
    rebind = $rebindAssessment
    receiptPresent = [bool]$receipt; installState = if ($blockers.Count -eq 0) { 'PILOT_READY_FOR_REVIEW' } else { 'BLOCKED' }
    blockers = $blockers; systemChanges = 'None; Plan is read-only. Existing collectors are not queried or managed.'
  }
  $json = $result | ConvertTo-Json -Depth 5
  Write-RunLog -Label 'Setup plan' -Command 'powershell -NoProfile -File .\scripts\setup.ps1 -Action Plan' -Reason 'Read-only task identity and task-only readiness check.' -Output $json
  Write-Output $json
}

function New-TaskDefinition {
  $want = Get-ExpectedAction
  $action = New-ScheduledTaskAction -Execute $want.Execute -Argument $want.Arguments -WorkingDirectory $want.WorkingDirectory
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes ([int]$script:Manifest.deployment.checkIntervalMinutes)) -RepetitionDuration (New-TimeSpan -Days 3650)
  $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -StartWhenAvailable
  return New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $script:TaskDescription
}

function Write-Receipt {
  New-Item -ItemType Directory -Path $script:EvidencePath -Force | Out-Null
  Get-ExpectedReceipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:ReceiptPath -Encoding UTF8
}

function Write-ReceiptAtomic {
  New-Item -ItemType Directory -Path $script:EvidencePath -Force | Out-Null
  $tempPath = $script:ReceiptPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
  try {
    [System.IO.File]::WriteAllText($tempPath, (Get-ExpectedReceipt | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    if ([System.IO.File]::Exists($script:ReceiptPath)) {
      $backupPath = $script:ReceiptPath + '.' + [Guid]::NewGuid().ToString('N') + '.bak'
      try { [System.IO.File]::Replace($tempPath, $script:ReceiptPath, $backupPath) }
      finally { if ([System.IO.File]::Exists($backupPath)) { [System.IO.File]::Delete($backupPath) } }
    }
    else { [System.IO.File]::Move($tempPath, $script:ReceiptPath) }
  } finally { if ([System.IO.File]::Exists($tempPath)) { [System.IO.File]::Delete($tempPath) } }
}

function Assert-NoRunningLease {
  $statePath = Join-Path $script:EvidencePath 'active-lease.json'
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return }
  $status = Invoke-LeaseAction -LeaseAction Status
  if ($status.state -eq 'NONE' -or ([string]$status.state -match '^STOPPED(?:_|$)' -and [string]$status.lease.cleanupStatus -match '^STOPPED(?:_|$)')) { return }
  throw "Lease state is $($status.state); Rebind requires no running or unknown lease. No task changes made."
}

function Rebind-OwnedTask {
  $blockers = @(Get-Blockers)
  if ($blockers.Count) { throw ('Rebind blocked by current readiness gates: ' + ($blockers -join ' ')) }
  $task = Get-Task
  $receipt = Get-Receipt
  $assessment = Get-RebindAssessment -Task $task -Receipt $receipt -Blockers @()
  if (-not $assessment.eligible) { throw ('Rebind refused: ' + (@($assessment.reasons) -join ', ')) }
  Assert-NoRunningLease
  $task = Get-Task
  $receipt = Get-Receipt
  $assessment = Get-RebindAssessment -Task $task -Receipt $receipt -Blockers @()
  if (-not $assessment.eligible) { throw ('Rebind refused after fresh identity check: ' + (@($assessment.reasons) -join ', ')) }
  if ([string]$task.State -eq 'Running') { throw 'The caretaker task is currently running; Rebind refused without changes.' }
  if (-not $script:ActionCmdlet.ShouldProcess($script:TaskName, 'Rebind the exact receipt-matched caretaker task to the current checkout')) { return }

  $oldReceiptText = Get-Content -LiteralPath $script:ReceiptPath -Raw
  $oldReceipt = $oldReceiptText | ConvertFrom-Json -ErrorAction Stop
  $oldAction = $task.Actions[0]
  $want = Get-ExpectedAction
  New-Item -ItemType Directory -Path $script:EvidencePath -Force | Out-Null
  $rollbackPath = Join-Path $script:EvidencePath ('setup-rebind-rollback-' + [Guid]::NewGuid().ToString('N') + '.json')
  $rollbackRecord = [pscustomobject]@{
    schemaVersion = 1; taskName = $script:TaskName; taskDescription = [string]$task.Description
    priorAction = [pscustomobject]@{ execute = [string]$oldAction.Execute; arguments = [string]$oldAction.Arguments; workingDirectory = [string]$oldAction.WorkingDirectory }
    priorReceipt = $oldReceipt; enabled = [bool]$task.Settings.Enabled
    triggerCount = $task.Triggers.Count; recordedAtUtc = [DateTime]::UtcNow.ToString('o')
  }
  [System.IO.File]::WriteAllText($rollbackPath, ($rollbackRecord | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
  Write-ChangeLog -Command "Set-ScheduledTask action for $script:TaskName" -Outcome ('Rebind requested for the exact receipt-matched caretaker task; prior action and receipt preserved in evidence rollback record ' + (Split-Path -Leaf $rollbackPath) + '.') -Rollback ('Restore the prior task action and receipt from ' + (Split-Path -Leaf $rollbackPath) + '; verify native task and receipt before resuming operation.')
  try {
    Invoke-LoggedCmdlet -Command "Set-ScheduledTask -TaskName $script:TaskName -Action <current caretaker action>" -Reason 'Rebind only the exact receipt-matched caretaker task to the current checkout.' -ScriptBlock {
      $newAction = New-ScheduledTaskAction -Execute $want.Execute -Argument $want.Arguments -WorkingDirectory $want.WorkingDirectory
      Set-ScheduledTask -TaskName $script:TaskName -Action $newAction -ErrorAction Stop | Out-Null
    } | Out-Null
    $afterAction = Get-Task
    if (-not $afterAction -or $afterAction.Description -cne $script:TaskDescription -or $afterAction.Actions.Count -ne 1 -or
        [string]$afterAction.Actions[0].Execute -ine $want.Execute -or [string]$afterAction.Actions[0].Arguments -cne $want.Arguments -or
        [string]$afterAction.Actions[0].WorkingDirectory -ine $want.WorkingDirectory -or
        [bool]$afterAction.Settings.Enabled -ne [bool]$task.Settings.Enabled -or $afterAction.Triggers.Count -ne $task.Triggers.Count) {
      throw 'Native task post-rebind verification failed.'
    }
    Write-ReceiptAtomic
    $verified = Get-Task
    if (-not (Test-OwnedTask $verified)) { throw 'Receipt/task post-rebind verification failed.' }
    Write-ChangeLog -Command "Verify rebound caretaker task $script:TaskName" -Outcome 'Verified current task action and refreshed receipt; enabled state and trigger were preserved.' -Rollback 'Restore prior task action and receipt from the preceding rollback record.'
    Write-Output 'Exact caretaker task rebound to the current checkout and verified; enabled state and trigger were preserved.'
  } catch {
    $rebindError = $_.Exception.Message
    $rollbackOk = $false
    try {
      $currentTask = Get-Task
      if (-not $currentTask -or $currentTask.Description -cne $script:TaskDescription -or $currentTask.Actions.Count -ne 1 -or
          [string]$currentTask.Actions[0].Execute -ine $want.Execute -or [string]$currentTask.Actions[0].Arguments -cne $want.Arguments -or
          [string]$currentTask.Actions[0].WorkingDirectory -ine $want.WorkingDirectory) {
        throw 'Task no longer has the exact new action; rollback will not overwrite concurrent changes.'
      }
      $currentReceipt = Get-Receipt
      $currentReceiptIsOld = [string]$currentReceipt.taskName -ceq [string]$oldReceipt.taskName -and [string]$currentReceipt.taskDescription -ceq [string]$oldReceipt.taskDescription -and [string]$currentReceipt.execute -ieq [string]$oldReceipt.execute -and [string]$currentReceipt.arguments -ceq [string]$oldReceipt.arguments -and [string]$currentReceipt.workingDirectory -ieq [string]$oldReceipt.workingDirectory
      if (-not (Test-ReceiptIdentity $currentReceipt) -and -not $currentReceiptIsOld) { throw 'Receipt no longer matches old or new expected identity; rollback will not overwrite concurrent changes.' }
      $restoreAction = New-ScheduledTaskAction -Execute ([string]$oldAction.Execute) -Argument ([string]$oldAction.Arguments) -WorkingDirectory ([string]$oldAction.WorkingDirectory)
      Set-ScheduledTask -TaskName $script:TaskName -Action $restoreAction -ErrorAction Stop | Out-Null
      if (-not $currentReceiptIsOld) { [System.IO.File]::WriteAllText($script:ReceiptPath, $oldReceiptText, (New-Object System.Text.UTF8Encoding($false))) }
      $restored = Get-Task
      $restoredReceipt = Get-Receipt
      $rollbackOk = [string]$restored.Actions[0].Execute -ieq [string]$oldAction.Execute -and [string]$restored.Actions[0].Arguments -ceq [string]$oldAction.Arguments -and [string]$restored.Actions[0].WorkingDirectory -ieq [string]$oldAction.WorkingDirectory -and [bool]$restored.Settings.Enabled -eq [bool]$rollbackRecord.enabled -and $restored.Triggers.Count -eq [int]$rollbackRecord.triggerCount -and [string]$restoredReceipt.taskName -ceq [string]$oldReceipt.taskName -and [string]$restoredReceipt.taskDescription -ceq [string]$oldReceipt.taskDescription -and [string]$restoredReceipt.execute -ieq [string]$oldReceipt.execute -and [string]$restoredReceipt.arguments -ceq [string]$oldReceipt.arguments -and [string]$restoredReceipt.workingDirectory -ieq [string]$oldReceipt.workingDirectory
    } catch { $rollbackOk = $false }
    if (-not $rollbackOk) { throw "Rebind failed and rollback could not be verified. Preserve state and inspect the exact task and receipt. Original error: $rebindError" }
    throw "Rebind failed; prior task action and receipt rollback were verified. Original error: $rebindError"
  }
}

function Install-OwnedTask {
  $blockers = Get-Blockers
  if ($blockers.Count) { throw ('Install blocked: ' + ($blockers -join ' ')) }
  $task = Get-Task
  $receipt = Get-Receipt
  if ($task -and (-not (Test-ReceiptIdentity $receipt) -or -not (Test-OwnedTask $task))) { throw 'Task name exists with an unrecognized definition or receipt. No changes made.' }
  if (-not $task -and $receipt -and -not (Test-ReceiptIdentity $receipt)) { throw 'A non-matching setup receipt exists. Preserve and review it; no changes made.' }
  if (-not $script:ActionCmdlet.ShouldProcess($script:TaskName, 'Create/enable the exact task-only periodic checker')) { return }

  $madeReceipt = $false
  $madeTask = $false
  $enabledByUs = $false
  $manifestUpdateAttempted = $false
  $priorInstalled = [bool]$script:Manifest.deployment.installed
  $priorTaskEnabled = [bool]$script:Manifest.deployment.taskEnabled
  try {
    if (-not $receipt) { Write-Receipt; $madeReceipt = $true }
    if (-not $task) {
      Invoke-LoggedCmdlet -Command "Register-ScheduledTask -TaskName $script:TaskName" -Reason 'Register only the exact manifest-owned periodic tick task.' -ScriptBlock { Register-ScheduledTask -TaskName $script:TaskName -InputObject (New-TaskDefinition) -ErrorAction Stop | Out-Null } | Out-Null
      $madeTask = $true
    } elseif (-not $task.Settings.Enabled) {
      Invoke-LoggedCmdlet -Command "Enable-ScheduledTask -TaskName $script:TaskName" -Reason 'Enable only the exact receipt-matched caretaker task.' -ScriptBlock { Enable-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop | Out-Null } | Out-Null
      $enabledByUs = $true
    }
    $verified = Get-Task
    if (-not (Test-OwnedTask $verified) -or -not $verified.Settings.Enabled) { throw 'Post-install verification did not confirm the exact enabled checker task.' }
    $manifestUpdateAttempted = $true
    Update-ManifestState -Installed $true -TaskEnabled $true -Reason 'Created and verified exact task-only periodic checker; PerfMon remains disabled.'
    Write-ChangeLog -Command "Register-ScheduledTask $script:TaskName" -Outcome 'Created and verified exact task-only checker; no collector was created or started.' -Rollback "Run setup.ps1 -Action Pause or Uninstall after exact receipt/action verification; preserve all evidence and collectors."
    Write-Output 'Exact owned periodic task is installed; continuous PerfMon remains disabled.'
  } catch {
    $installError = $_.Exception.Message
    if ($madeTask) {
      try { Invoke-LoggedCmdlet -Command "Unregister-ScheduledTask -TaskName $script:TaskName" -Reason 'Rollback the task created by this failed Install invocation.' -ScriptBlock { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop | Out-Null } | Out-Null } catch {}
    } elseif ($enabledByUs) {
      try { Invoke-LoggedCmdlet -Command "Disable-ScheduledTask -TaskName $script:TaskName" -Reason 'Restore the original disabled state after this failed Install invocation.' -ScriptBlock { Disable-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop | Out-Null } | Out-Null } catch {}
    }
    $rollbackVerified = $false
    try {
      $after = Get-Task
      $rollbackVerified = if ($madeTask) { -not $after } elseif ($enabledByUs) { ($after -and -not $after.Settings.Enabled -and (Test-OwnedTask $after)) } else { $true }
    } catch {}
    if ($rollbackVerified) {
      if ($madeReceipt -and (Test-Path -LiteralPath $script:ReceiptPath -PathType Leaf)) { Remove-Item -LiteralPath $script:ReceiptPath -Force -ErrorAction SilentlyContinue }
      if ($manifestUpdateAttempted) {
        try { Update-ManifestState -Installed $priorInstalled -TaskEnabled $priorTaskEnabled -Reason 'Restored canonical task-only deployment flags after verified failed-install rollback.' } catch {}
      }
      throw $installError
    }
    throw "Install failed and task rollback could not be verified; receipt was preserved. Original error: $installError"
  }
}

function Invoke-LeaseAction {
  param([ValidateSet('Status','Stop')][string]$LeaseAction, [string]$LeaseId)
  $leaseScript = Join-Path $script:Root 'scripts\lease.ps1'
  $statePath = Join-Path $script:EvidencePath 'active-lease.json'
  $args = @('-NoProfile','-NonInteractive','-File',$leaseScript,'-Action',$LeaseAction,'-StatePath',$statePath)
  if ($LeaseId) { $args += @('-LeaseId',$LeaseId) }
  $command = 'powershell.exe ' + ($args -join ' ')
  $output = & $script:WindowsPowerShell @args 2>&1 | Out-String
  $code = $LASTEXITCODE
  Write-RunLog -Label 'Lease cleanup command' -Command $command -Reason 'Query or stop only the recorded caretaker-owned diagnostic lease before pausing/removing its checker.' -Output "ExitCode=$code"
  if ($code -ne 0) { throw "Lease CLI $LeaseAction failed; checker task left unchanged. See diag_log.txt." }
  try { return $output | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Lease CLI returned invalid JSON; checker task left unchanged.' }
}

function Confirm-LeaseQuiescent {
  function Test-VerifiedStopped($Result) {
    return ([string]$Result.state -match '^STOPPED(?:_|$)' -and [string]$Result.lease.cleanupStatus -match '^STOPPED(?:_|$)')
  }
  $statePath = Join-Path $script:EvidencePath 'active-lease.json'
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return }
  $status = Invoke-LeaseAction -LeaseAction Status
  if ($status.state -eq 'NONE' -or (Test-VerifiedStopped $status)) { return }
  if ($status.state -ne 'RUNNING' -or [string]$status.lease.leaseId -notmatch '^[0-9a-fA-F-]{36}$') { throw "Lease state is $($status.state), not verified quiescent. No task changes made." }
  $stopped = Invoke-LeaseAction -LeaseAction Stop -LeaseId ([string]$status.lease.leaseId)
  if (-not (Test-VerifiedStopped $stopped)) { throw "Owned lease cleanup result is $($stopped.state); no task changes made." }
}

function Assert-ExactTaskOwnership {
  $receipt = Get-Receipt
  if (-not (Test-ReceiptIdentity $receipt)) { throw 'Matching task setup receipt is missing or invalid; no change made.' }
  $task = Get-Task
  if ($task -and -not (Test-OwnedTask $task)) { throw 'Exact task ownership check failed; no change made.' }
  return $task
}

function Pause-OwnedTask {
  $task = Assert-ExactTaskOwnership
  if (-not $script:ActionCmdlet.ShouldProcess($script:TaskName, 'Disable only the exact owned periodic checker task')) { return }
  Confirm-LeaseQuiescent
  if ($task -and $task.Settings.Enabled) { Invoke-LoggedCmdlet -Command "Disable-ScheduledTask -TaskName $script:TaskName" -Reason 'Disable only the exact receipt-matched checker task.' -ScriptBlock { Disable-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop | Out-Null } | Out-Null }
  $after = Get-Task
  if ($after -and $after.Settings.Enabled) { throw 'Pause verification failed; inspect task state.' }
  Update-ManifestState -Installed ([bool]$after) -TaskEnabled $false -Reason 'Verified exact caretaker task disabled; collectors were not queried or changed.'
  Write-ChangeLog -Command "Disable-ScheduledTask $script:TaskName" -Outcome 'Verified exact owned checker disabled; no collector action taken.' -Rollback "Re-enable only $script:TaskName after exact receipt/action verification."
}

function Uninstall-OwnedTask {
  $task = Assert-ExactTaskOwnership
  if (-not $script:ActionCmdlet.ShouldProcess($script:TaskName, 'Remove only the exact owned checker task; preserve evidence and collectors')) { return }
  Confirm-LeaseQuiescent
  if ($task) {
    if ($task.Settings.Enabled) { Invoke-LoggedCmdlet -Command "Disable-ScheduledTask -TaskName $script:TaskName" -Reason 'Disable only the exact receipt-matched checker before removal.' -ScriptBlock { Disable-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop | Out-Null } | Out-Null }
    Invoke-LoggedCmdlet -Command "Unregister-ScheduledTask -TaskName $script:TaskName" -Reason 'Remove only the exact receipt-matched caretaker task.' -ScriptBlock { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop | Out-Null } | Out-Null
  }
  if (Get-Task) { throw 'Uninstall verification failed; the checker task remains.' }
  Remove-Item -LiteralPath $script:ReceiptPath -Force
  Update-ManifestState -Installed $false -TaskEnabled $false -Reason 'Verified exact caretaker checker task removed; collectors and evidence preserved.'
  Write-ChangeLog -Command "Unregister-ScheduledTask $script:TaskName" -Outcome 'Removed verified owned checker task; preserved evidence and all PerfMon collectors.' -Rollback 'Reinstall only after reviewing the manifest and confirming the exact task name is unused; no collector action is included.'
}

if ($MyInvocation.InvocationName -ne '.') {
  $invocation = 'powershell -NoProfile -File .\scripts\setup.ps1 -Action ' + $Action
  Write-RunLog -Label 'Setup invocation' -Command $invocation -Reason "Requested setup action: $Action" -Output 'Started.'
  try {
    switch ($Action) {
      'Plan' { Show-Plan }
      'Install' { Install-OwnedTask }
      'Pause' { Pause-OwnedTask }
      'Uninstall' { Uninstall-OwnedTask }
      'Rebind' { Rebind-OwnedTask }
    }
  } catch {
    Write-RunLog -Label 'Setup action failed' -Command $invocation -Reason "Requested setup action: $Action" -Output $_.ToString()
    throw
  }
}
