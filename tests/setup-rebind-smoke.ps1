$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAIL: $Message" }
  Write-Output "PASS: $Message"
}

$sourceSetup = Join-Path $PSScriptRoot '..\scripts\setup.ps1'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('caretaker-setup-rebind-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
  $project = Join-Path $scratch 'current'
  $oldRoot = Join-Path $scratch 'removed-checkout'
  $scripts = Join-Path $project 'scripts'
  $evidence = Join-Path $project 'evidence'
  $config = Join-Path $project 'config'
  New-Item -ItemType Directory -Path $scripts,$evidence,$config -Force | Out-Null
  Copy-Item -LiteralPath $sourceSetup -Destination (Join-Path $scripts 'setup.ps1')
  Set-Content -LiteralPath (Join-Path $scripts 'caretaker.ps1') -Value "function Invoke-Tick { }"
  Set-Content -LiteralPath (Join-Path $scripts 'retention.ps1') -Value '# fixture'
  $manifest = [pscustomobject]@{
    deployment = [pscustomobject]@{
      taskName = 'GoliathCaretaker-R1'; installed = $true; taskEnabled = $true
      collectorEnabled = $false; checkIntervalMinutes = 15; retentionRunIntervalHours = 24
      perfmon = [pscustomobject]@{ enabled = $false; collectorName = 'unused'; sampleIntervalSeconds = 15; circularMaxMiB = 512; counterResolution = 'fixture' }
      pilotProfile = [pscustomobject]@{ status = 'PILOT'; snapshotWallSeconds = 1; snapshotProcessCpuSeconds = 1; logicalProcessors = 1 }
      runtimeAcceptance = 'TASK_ONLY PILOT'
    }
    leasePolicy = [pscustomobject]@{ captureLaunchEnabled = $false; expiryTaskName = $null }
  }
  $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $config 'caretaker.json')

  $script:MockTask = $null
  $script:MutateAfterSet = $false
  function Get-ScheduledTask { param([string]$TaskName, [string]$ErrorAction); if (-not $script:MockTask) { throw 'Task missing.' }; return $script:MockTask }
  function New-ScheduledTaskAction { param([string]$Execute,[string]$Argument,[string]$WorkingDirectory); return [pscustomobject]@{ Execute=$Execute; Arguments=$Argument; WorkingDirectory=$WorkingDirectory } }
  function Set-ScheduledTask { param([string]$TaskName,$Action,[string]$ErrorAction); $script:MockTask.Actions = @($Action); if ($script:MutateAfterSet) { $script:MockTask.Actions = @([pscustomobject]@{ Execute=$Action.Execute; Arguments=([string]$Action.Arguments + ' external-change'); WorkingDirectory=$Action.WorkingDirectory }); $script:MutateAfterSet = $false }; return $script:MockTask }

  $taskName = 'GoliathCaretaker-R1'
  $description = 'GoliathCaretaker task-only R1 periodic tick; identity from config/caretaker.json.'
  $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $oldArgs = '-NoProfile -NonInteractive -File "' + (Join-Path $oldRoot 'scripts\caretaker.ps1') + '" tick'
  $currentArgs = '-NoProfile -NonInteractive -File "' + (Join-Path $project 'scripts\caretaker.ps1') + '" tick'
  $receipt = [pscustomobject]@{ schemaVersion=1; taskName=$taskName; taskDescription=$description; execute=$exe; arguments=$oldArgs; workingDirectory=$oldRoot }
  $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence 'setup-owner.json')
  $script:MockTask = [pscustomobject]@{
    TaskName=$taskName; Description=$description; State='Ready'
    Actions=@([pscustomobject]@{ Execute=$exe; Arguments=$oldArgs; WorkingDirectory=$oldRoot })
    Settings=[pscustomobject]@{ Enabled=$true }; Triggers=@([pscustomobject]@{ RepetitionInterval='15m' })
  }

  . (Join-Path $scripts 'setup.ps1')
  $script:ActionCmdlet = [pscustomobject]@{}
  $script:ActionCmdlet | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target,$Action) return $true }
  $plan = Show-Plan | ConvertFrom-Json
  Assert-True ($plan.checkerState -eq 'COLLISION_OR_CHANGED' -and $plan.installState -eq 'BLOCKED') 'Plan keeps ordinary setup blocked for stale checkout identity'
  Assert-True ($plan.rebind.eligible -and $plan.rebind.state -eq 'ELIGIBLE') 'Plan identifies exact receipt/task pair with absent old checkout as eligible for explicit rebind'

  Rebind-OwnedTask | Out-Null
  $writtenReceipt = Get-Content -LiteralPath (Join-Path $evidence 'setup-owner.json') -Raw | ConvertFrom-Json
  Assert-True ([string]$script:MockTask.Actions[0].Arguments -ceq $currentArgs -and [string]$script:MockTask.Actions[0].WorkingDirectory -ieq $project) 'Rebind changes only the mock task action to the current checkout'
  Assert-True ([string]$writtenReceipt.arguments -ceq $currentArgs -and [string]$writtenReceipt.workingDirectory -ieq $project) 'Rebind refreshes receipt after task action verification'
  Assert-True ($script:MockTask.Settings.Enabled -and $script:MockTask.Triggers.Count -eq 1) 'Rebind preserves enabled state and trigger count'
  Assert-True (@(Get-ChildItem -LiteralPath $evidence -Filter 'setup-rebind-rollback-*.json').Count -eq 1) 'Rebind preserves an exact rollback record before mutation'

  # A concurrent task edit after Set must not be overwritten by rollback.
  $script:MockTask.Actions = @([pscustomobject]@{ Execute=$exe; Arguments=$oldArgs; WorkingDirectory=$oldRoot })
  $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence 'setup-owner.json')
  $script:MutateAfterSet = $true
  $raceFailed = $false
  try { Rebind-OwnedTask | Out-Null } catch { $raceFailed = $true }
  Assert-True ($raceFailed -and [string]$script:MockTask.Actions[0].Arguments -like '*external-change') 'Rollback preserves a concurrent native task edit rather than overwriting it'

  # Malformed path fields in an otherwise matching task/receipt remain a read-only blocked Plan result.
  $badPath = 'bad' + [char]0
  $badArgs = '-NoProfile -NonInteractive -File "' + $badPath + '" tick'
  $script:MockTask.Actions = @([pscustomobject]@{ Execute=$exe; Arguments=$badArgs; WorkingDirectory=$badPath })
  ([pscustomobject]@{ schemaVersion=1; taskName=$taskName; taskDescription=$description; execute=$exe; arguments=$badArgs; workingDirectory=$badPath } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $evidence 'setup-owner.json')
  $malformedPlan = Show-Plan | ConvertFrom-Json
  Assert-True ($malformedPlan.rebind.state -eq 'BLOCKED' -and $malformedPlan.rebind.reasons -contains 'ACTION_PATH_INVALID') 'Plan reports malformed stale paths as blocked without throwing'

  $script:MockTask.Actions = @([pscustomobject]@{ Execute=$exe; Arguments=$oldArgs; WorkingDirectory=$oldRoot })
  $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence 'setup-owner.json')
  Set-Content -LiteralPath (Join-Path $evidence 'active-lease.json') -Value '{}'
  function Invoke-LeaseAction { param([string]$LeaseAction,[string]$LeaseId); return [pscustomobject]@{ state='RUNNING'; lease=[pscustomobject]@{ leaseId='fixture' } } }
  $beforeLease = [string]$script:MockTask.Actions[0].Arguments
  $refusedLease = $false
  try { Rebind-OwnedTask | Out-Null } catch { $refusedLease = $true }
  Assert-True ($refusedLease -and [string]$script:MockTask.Actions[0].Arguments -ceq $beforeLease) 'Rebind refuses a running recorded lease without changing task'
  Remove-Item -LiteralPath (Join-Path $evidence 'active-lease.json') -Force

  $script:MockTask.Actions = @([pscustomobject]@{ Execute=$exe; Arguments=$oldArgs; WorkingDirectory=$oldRoot })
  $receipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence 'setup-owner.json')
  New-Item -ItemType Directory -Path (Join-Path $oldRoot 'scripts') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $oldRoot 'scripts\caretaker.ps1') -Value 'old checker fixture'
  $blockedPlan = Show-Plan | ConvertFrom-Json
  $beforeExisting = [string]$script:MockTask.Actions[0].Arguments
  $refusedExisting = $false
  try { Rebind-OwnedTask | Out-Null } catch { $refusedExisting = $true }
  Assert-True (-not $blockedPlan.rebind.eligible -and $blockedPlan.rebind.reasons -contains 'OLD_CHECKER_STILL_EXISTS' -and $refusedExisting -and [string]$script:MockTask.Actions[0].Arguments -ceq $beforeExisting) 'Rebind refuses when the old checker target still exists'
  Remove-Item -LiteralPath $oldRoot -Recurse -Force

  # Receipt mismatch must block before the mock native update is called.
  $script:MockTask.Actions = @([pscustomobject]@{ Execute=$exe; Arguments=$oldArgs + ' '; WorkingDirectory=$oldRoot })
  $writtenReceipt.arguments = $oldArgs
  $writtenReceipt | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence 'setup-owner.json')
  $before = [string]$script:MockTask.Actions[0].Arguments
  $refused = $false
  try { Rebind-OwnedTask | Out-Null } catch { $refused = $true }
  Assert-True ($refused -and [string]$script:MockTask.Actions[0].Arguments -ceq $before) 'Rebind refuses receipt/native action mismatch without changing task'
} finally {
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'Setup rebind smoke checks passed.'
