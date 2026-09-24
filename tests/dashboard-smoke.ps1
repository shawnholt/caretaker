$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAIL: $Message" }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$dashboardScript = Join-Path $projectRoot 'scripts\dashboard.ps1'
$fixturesBase = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'tests\fixtures'))
$fixtureRoot = Join-Path $fixturesBase ('caretaker-dashboard-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null

try {
  $capturedAt = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
  $snapshot = [ordered]@{
    schemaVersion = 1
    capturedAtUtc = $capturedAt
    observed = [ordered]@{
      processes = @(
        [ordered]@{ name = '<script>alert(1)</script>'; pid = 41; workingSetBytes = 104857600; commandLine = 'PRIVATE-COMMAND-LINE' },
        [ordered]@{ name = 'small-process'; pid = 42; workingSetBytes = 1048576; commandLine = 'PRIVATE-SECOND-COMMAND' }
      )
      tcpListeners = @(
        [ordered]@{ protocol = 'TCP'; localAddress = '<unsafe&>'; localPort = 4321; process = [ordered]@{ name = 'listener<&>'; pid = 41; commandLine = 'PRIVATE-LISTENER-COMMAND' } }
      )
      udpEndpoints = @([ordered]@{ protocol = 'UDP'; localAddress = '<udp&>'; localPort = 5353; process = [ordered]@{ name = '<udp-owner>'; commandLine = 'PRIVATE-UDP-COMMAND' } })
      services = @([ordered]@{ name = 'svc'; displayName = '<service>'; state = 'Running'; startMode = 'Auto' })
      tasks = @([ordered]@{ name = '<task>'; path = '\\'; state = 'Ready'; enabled = $true; actionCount = 1; triggerCount = 1 })
      startup = @([ordered]@{ name = '<startup>'; location = 'Run'; commandFingerprint = 'PRIVATE-STARTUP-COMMAND' })
    }
    coverage = [ordered]@{
      processes = [ordered]@{ status = 'OK'; count = 2 }
      tcpListeners = [ordered]@{ status = 'DEGRADED'; count = 1 }
      udpEndpoints = [ordered]@{ status = 'OK'; count = 0 }
      services = [ordered]@{ status = 'OK'; count = 0 }
      tasks = [ordered]@{ status = 'OK'; count = 0 }
      startup = [ordered]@{ status = 'UNKNOWN'; count = $null }
    }
  }
  $snapshotPath = Join-Path $fixtureRoot 'snapshot.json'
  [System.IO.File]::WriteAllText($snapshotPath, (ConvertTo-Json -InputObject $snapshot -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
  $outputPath = Join-Path $fixtureRoot 'dashboard.html'
  & $dashboardScript -EvidenceRoot $fixtureRoot -OutputPath $outputPath | Out-Null
  $html = [System.IO.File]::ReadAllText($outputPath)
  Assert-True ($html.Contains('FRESH')) 'freshness is computed from capturedAtUtc'
  Assert-True ($html.Contains('Freshness when generated')) 'static freshness label identifies when it was evaluated'
  Assert-True ($html.Contains('4 of 6') -and $html.Contains('modules collected OK')) 'coverage summary counts only modules explicitly reported OK'
  Assert-True ($html.Contains('TCP listeners') -and $html.Contains('Review')) 'listener section carries review status'
  Assert-True ($html.Contains('Needs attention') -and $html.Contains('button.help')) 'summary exposes attention count and contextual help'
  Assert-True ($html.Contains('<strong class="metric-value">UNKNOWN</strong><span class="metric-detail">Alert state unavailable.')) 'missing alert state is UNKNOWN, not zero attention items'
  Assert-True ($html.Contains('Memory at capture (working set)')) 'resource table labels the single-point memory sample'
  Assert-True ($html.Contains('SAVED EVIDENCE') -and $html.Contains('Evidence mode')) 'page identifies its static saved-evidence scope'
  Assert-True ($html.Contains('None is a health verdict')) 'coverage is not presented as an overall health claim'
  Assert-True ($html.Contains('DEGRADED')) 'partial module state is displayed'
  Assert-True ($html.Contains('UNKNOWN')) 'unknown module state remains visible'
  Assert-True ($html.Contains('100.0 MiB')) 'process memory is displayed in descending order'
  Assert-True ($html.Contains('min old; within checker window')) 'freshness shows a scannable age beside the status'
  Assert-True ($html.Contains('FRESH means the saved snapshot is no older than 45 minutes')) 'freshness help states the calculation window'
  Assert-True ([regex]::IsMatch($html, 'Captured \(local\).*?(EDT|EST)', [Text.RegularExpressions.RegexOptions]::Singleline)) 'capture time shows a local Eastern timezone abbreviation'
  Assert-True ($html.Contains('4 of 6') -and $html.Contains('does not mean a health check passed')) 'coverage explicitly describes collection, not health'
  Assert-True ($html.Contains('href="#records-udpEndpoints"') -and $html.Contains('id="records-udpEndpoints"')) 'UDP coverage links to its saved records'
  Assert-True ($html.Contains('id="records-services"') -and $html.Contains('id="records-tasks"') -and $html.Contains('id="records-startup"')) 'remaining module records have drilldown targets'
  Assert-True ($html.Contains('aria-expanded="false"') -and $html.Contains('aria-describedby=') -and $html.Contains('role="tooltip"') -and $html.Contains("button.addEventListener('click'") -and $html.Contains("button.addEventListener('focus'") -and $html.Contains("button.addEventListener('mouseenter'")) 'help controls are accessible and work by pointer, click, and keyboard'
  Assert-True ($html.Contains('Expected requires complete TCP coverage') -and $html.Contains('Needs review means complete coverage plus an open saved alert')) 'listener review rule is explicit and evidence-backed'
  Assert-True ($html.Contains('UNKNOWN (partial TCP coverage)')) 'partial listener coverage does not produce a positive review verdict'
  Assert-True ($html.Contains('&lt;udp&amp;&gt;:5353') -and $html.Contains('&lt;service&gt;') -and $html.Contains('&lt;task&gt;')) 'drilldown record values are HTML-escaped'
  Assert-True ($html.Contains('&lt;script&gt;alert(1)&lt;/script&gt;')) 'process names are HTML-escaped'
  Assert-True ($html.Contains('&lt;unsafe&amp;&gt;:4321')) 'listener endpoint values are HTML-escaped'
  Assert-True ($html.Contains('listener&lt;&amp;&gt;')) 'listener process name is HTML-escaped'
  Assert-True (-not $html.Contains('PRIVATE-COMMAND-LINE')) 'process command lines are omitted'
  Assert-True (-not $html.Contains('PRIVATE-SECOND-COMMAND')) 'non-top process command lines are omitted'
  Assert-True (-not $html.Contains('PRIVATE-LISTENER-COMMAND')) 'listener command lines are omitted'
  Assert-True (-not $html.Contains('PRIVATE-UDP-COMMAND') -and -not $html.Contains('PRIVATE-STARTUP-COMMAND')) 'drilldown omits command-line evidence'
  Assert-True ($html.Contains('does not poll Windows') -and $html.Contains('claim live status')) 'page does not claim live monitoring'
  Assert-True (-not $html.Contains([string][char]0x2014) -and -not $html.Contains([string][char]0xFFFD)) 'page avoids broken em dash and replacement characters'
  Assert-True ($html.Contains('href="#coverage"') -and $html.Contains('href="#processes"') -and $html.Contains('href="#listeners"')) 'section navigation points to evidence panels'

  $completeRoot = Join-Path $fixtureRoot 'complete-with-alert'
  [System.IO.Directory]::CreateDirectory($completeRoot) | Out-Null
  $completeOutput = Join-Path $completeRoot 'dashboard.html'
  $snapshot.coverage.tcpListeners.status = 'OK'
  $snapshot.capturedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
  [System.IO.File]::WriteAllText((Join-Path $completeRoot 'snapshot.json'), (ConvertTo-Json -InputObject $snapshot -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
  $alertState = [ordered]@{ active = @([ordered]@{ id = 'unreviewed-listener:TCP|<unsafe&>|4321' }) }
  [System.IO.File]::WriteAllText((Join-Path $completeRoot 'alert-state.json'), (ConvertTo-Json -InputObject $alertState -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
  & $dashboardScript -EvidenceRoot $completeRoot -OutputPath $completeOutput | Out-Null
  Assert-True ([System.IO.File]::ReadAllText($completeOutput).Contains('Needs review (open alert)')) 'complete coverage and saved alert are required for the review result'

  $unknownTcpRoot = Join-Path $fixtureRoot 'unknown-tcp'
  [System.IO.Directory]::CreateDirectory($unknownTcpRoot) | Out-Null
  $unknownTcpOutput = Join-Path $unknownTcpRoot 'dashboard.html'
  $snapshot.coverage.tcpListeners.status = 'UNKNOWN'
  [System.IO.File]::WriteAllText((Join-Path $unknownTcpRoot 'snapshot.json'), (ConvertTo-Json -InputObject $snapshot -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
  & $dashboardScript -EvidenceRoot $unknownTcpRoot -OutputPath $unknownTcpOutput | Out-Null
  Assert-True ([System.IO.File]::ReadAllText($unknownTcpOutput).Contains('UNKNOWN (TCP coverage unavailable)')) 'unavailable listener coverage is distinguished from partial coverage'

  $missingRoot = Join-Path $fixtureRoot 'missing'
  [System.IO.Directory]::CreateDirectory($missingRoot) | Out-Null
  $missingOutput = Join-Path $missingRoot 'dashboard.html'
  & $dashboardScript -EvidenceRoot $missingRoot -OutputPath $missingOutput | Out-Null
  $missingHtml = [System.IO.File]::ReadAllText($missingOutput)
  Assert-True ($missingHtml.Contains('Snapshot file is missing')) 'missing source creates an explicit unknown report'
  Assert-True ($missingHtml.Contains('UNKNOWN')) 'missing source does not imply healthy coverage'

  [System.IO.File]::WriteAllText((Join-Path $missingRoot 'snapshot.json'), '{}', (New-Object System.Text.UTF8Encoding($false)))
  & $dashboardScript -EvidenceRoot $missingRoot -OutputPath $missingOutput | Out-Null
  $partialHtml = [System.IO.File]::ReadAllText($missingOutput)
  Assert-True ($partialHtml.Contains('UNKNOWN</strong><span class="metric-detail">UTC evidence: UNKNOWN')) 'missing timestamp remains unknown'
  Assert-True ([regex]::Matches($partialHtml, 'class="state state-unknown"').Count -eq 6) 'missing coverage remains unknown for all modules'
  Assert-True ($partialHtml.Contains('0 of 6') -and $partialHtml.Contains('class="metric-value unknown"')) 'missing evidence does not inflate coverage or freshness'
  Assert-True ($partialHtml.Contains('id="records-services"') -and $partialHtml.Contains('UNKNOWN - no saved records are available.')) 'missing module records have a clear unavailable state'

  $futureRoot = Join-Path $fixtureRoot 'future'
  [System.IO.Directory]::CreateDirectory($futureRoot) | Out-Null
  $futureOutput = Join-Path $futureRoot 'dashboard.html'
  $snapshot.capturedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(30).ToString('o')
  [System.IO.File]::WriteAllText((Join-Path $futureRoot 'snapshot.json'), (ConvertTo-Json -InputObject $snapshot -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
  & $dashboardScript -EvidenceRoot $futureRoot -OutputPath $futureOutput | Out-Null
  Assert-True ([System.IO.File]::ReadAllText($futureOutput).Contains('Snapshot time is in the future.')) 'future snapshot time is UNKNOWN, not fresh'

  if ([TimeZoneInfo]::Local.Id -in @('Eastern Standard Time', 'America/New_York')) {
    $winterRoot = Join-Path $fixtureRoot 'winter'
    [System.IO.Directory]::CreateDirectory($winterRoot) | Out-Null
    $winterOutput = Join-Path $winterRoot 'dashboard.html'
    $snapshot.capturedAtUtc = [DateTimeOffset]::new(2026, 1, 15, 12, 0, 0, [TimeSpan]::Zero).ToString('o')
    [System.IO.File]::WriteAllText((Join-Path $winterRoot 'snapshot.json'), (ConvertTo-Json -InputObject $snapshot -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
    & $dashboardScript -EvidenceRoot $winterRoot -OutputPath $winterOutput | Out-Null
    Assert-True ([System.IO.File]::ReadAllText($winterOutput).Contains('Jan 15, 2026 7:00 AM EST')) 'winter capture time uses EST'
  }

  Write-Output 'Dashboard smoke checks passed.'
} finally {
  if ($fixtureRoot.StartsWith($fixturesBase + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and [System.IO.Directory]::Exists($fixtureRoot)) {
    [System.IO.Directory]::Delete($fixtureRoot, $true)
  }
}
