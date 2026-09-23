$ErrorActionPreference = 'Stop'
$retentionScript = Join-Path $PSScriptRoot '..\scripts\retention.ps1'
$fixturesBase = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures')) + [System.IO.Path]::DirectorySeparatorChar
$fixtureRoot = [System.IO.Path]::GetFullPath((Join-Path $fixturesBase ('retention-smoke-' + [Guid]::NewGuid().ToString('N'))))
if (-not $fixtureRoot.StartsWith($fixturesBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture path escaped tests/fixtures.' }
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
  Write-Output "PASS: $Message"
}

try {
  $old = [DateTime]::UtcNow.AddDays(-45).ToString('o')
  $fresh = [DateTime]::UtcNow.ToString('o')
  $changesPath = Join-Path $fixtureRoot 'changes.jsonl'
  $outboxPath = Join-Path $fixtureRoot 'outbox.jsonl'
  $alertPath = Join-Path $fixtureRoot 'alert-state.json'
  $snapshotPath = Join-Path $fixtureRoot 'snapshot.json'
  $attemptPath = Join-Path $fixtureRoot 'last-attempt.json'
  $leasePath = Join-Path $fixtureRoot 'active-lease.json'

  $changeRows = @(
    (ConvertTo-Json -InputObject ([pscustomobject]@{ atUtc=$old; module='tasks'; change='removed'; key='old-task' }) -Compress),
    (ConvertTo-Json -InputObject ([pscustomobject]@{ atUtc=$fresh; module='tasks'; change='added'; key='new-task' }) -Compress),
    '{malformed but protected}'
  )
  Set-Content -LiteralPath $changesPath -Value $changeRows -Encoding UTF8
  $outboxRows = @(
    (ConvertTo-Json -InputObject ([pscustomobject]@{ event='open'; atUtc=$old; alert=[pscustomobject]@{ id='protected-alert'; severity='review' } }) -Compress),
    (ConvertTo-Json -InputObject ([pscustomobject]@{ event='resolved'; atUtc=$old; alertId='old-resolved' }) -Compress)
  )
  Set-Content -LiteralPath $outboxPath -Value $outboxRows -Encoding UTF8
  Set-Content -LiteralPath $alertPath -Value (ConvertTo-Json -Compress ([pscustomobject]@{ active=@([pscustomobject]@{ id='protected-alert' }) })) -Encoding UTF8
  Set-Content -LiteralPath $snapshotPath -Value ('{"fixture":"snapshot","padding":"' + ('a' * 1100000) + '"}') -Encoding UTF8
  Set-Content -LiteralPath $attemptPath -Value '{"fixture":"attempt"}' -Encoding UTF8
  Set-Content -LiteralPath $leasePath -Value '{"fixture":"lease"}' -Encoding UTF8
  $legacyPath = Join-Path (Join-Path $fixtureRoot 'legacy') 'protected.txt'
  New-Item -ItemType Directory -Path (Split-Path -Parent $legacyPath) -Force | Out-Null
  Set-Content -LiteralPath $legacyPath -Value 'must remain byte-for-byte untouched'
  $outboxBefore = Get-Content -LiteralPath $outboxPath -Raw
  $alertBefore = Get-Content -LiteralPath $alertPath -Raw
  $snapshotBefore = Get-Content -LiteralPath $snapshotPath -Raw
  $attemptBefore = Get-Content -LiteralPath $attemptPath -Raw
  $leaseBefore = Get-Content -LiteralPath $leasePath -Raw
  $legacyBefore = Get-Content -LiteralPath $legacyPath -Raw

  $plan = & $retentionScript -Action Plan -EvidenceRoot $fixtureRoot -FixtureMode | ConvertFrom-Json
  Assert-True ($plan.action -eq 'Plan' -and $plan.changeRowsEligible -eq 1) 'Plan identifies only the expired valid change row without applying it'
  Assert-True ((Get-Content -LiteralPath $changesPath).Count -eq 3) 'Plan leaves the journal unchanged'

  $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $priorErrorPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $applyOutput = & $powershell -NoProfile -File $retentionScript -Action Apply -EvidenceRoot $fixtureRoot -FixtureMode -FixtureBudgetMiB 1 2>&1 | Out-String
  $applyExitCode = $LASTEXITCODE
  $ErrorActionPreference = $priorErrorPreference
  if ($applyExitCode -ne 2) { throw "Fixture Apply failed with exit ${applyExitCode}: $applyOutput" }
  $applied = $applyOutput | ConvertFrom-Json
  $remaining = @(Get-Content -LiteralPath $changesPath)
  Assert-True ($applyExitCode -eq 2 -and $applied.changeRowsRemoved -eq 1 -and $applied.state -eq 'OVER_BUDGET' -and -not $applied.allowHeavyCollection) 'Apply trims the expired row and returns exit 2 plus an over-budget heavy-collection gate'
  Assert-True (@($remaining | Where-Object { $_ -eq '{malformed but protected}' }).Count -eq 1) 'Malformed journal data is preserved'
  Assert-True ((Get-Content -LiteralPath $outboxPath -Raw) -ceq $outboxBefore) 'Open and resolved outbox history is preserved in full'
  Assert-True ((Get-Content -LiteralPath $alertPath -Raw) -ceq $alertBefore -and (Get-Content -LiteralPath $snapshotPath -Raw) -ceq $snapshotBefore -and (Get-Content -LiteralPath $attemptPath -Raw) -ceq $attemptBefore -and (Get-Content -LiteralPath $leasePath -Raw) -ceq $leaseBefore) 'Current alert, snapshot, attempt, and lease state are preserved'
  Assert-True ((Get-Content -LiteralPath $legacyPath -Raw) -ceq $legacyBefore) 'Legacy evidence is outside retention scope'
  Assert-True ($null -ne $applied.lastAppliedUtc -and $null -ne $applied.nextDueUtc) 'Apply exposes a machine-readable last-run and next-due marker'
  $marker = Get-Content -LiteralPath (Join-Path $fixtureRoot 'retention-state.json') -Raw | ConvertFrom-Json
  Assert-True ($marker.lastAppliedUtc -eq $applied.lastAppliedUtc -and $marker.nextDueUtc -eq $applied.nextDueUtc) 'Canonical retention-state.json marker matches the Apply summary'
  Write-Output 'Retention fixture smoke checks passed.'
} finally {
  if (Test-Path -LiteralPath $fixtureRoot -PathType Container) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
