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
  Assert-True ($html.Contains('4 / 6') -and $html.Contains('modules collected OK')) 'coverage summary counts only modules explicitly reported OK'
  Assert-True ($html.Contains('TCP listeners') -and $html.Contains('Review')) 'listener section carries review status'
  Assert-True ($html.Contains('Needs attention') -and $html.Contains('button.help')) 'summary exposes attention count and contextual help'
  Assert-True ($html.Contains('Memory at capture (working set)')) 'resource table labels the single-point memory sample'
  Assert-True ($html.Contains('SAVED EVIDENCE') -and $html.Contains('Evidence mode')) 'page identifies its static saved-evidence scope'
  Assert-True ($html.Contains('does not certify overall machine health')) 'coverage is not presented as an overall health claim'
  Assert-True ($html.Contains('DEGRADED')) 'partial module state is displayed'
  Assert-True ($html.Contains('UNKNOWN')) 'unknown module state remains visible'
  Assert-True ($html.Contains('100.0 MiB')) 'process memory is displayed in descending order'
  Assert-True ($html.Contains('&lt;script&gt;alert(1)&lt;/script&gt;')) 'process names are HTML-escaped'
  Assert-True ($html.Contains('&lt;unsafe&amp;&gt;:4321')) 'listener endpoint values are HTML-escaped'
  Assert-True ($html.Contains('listener&lt;&amp;&gt;')) 'listener process name is HTML-escaped'
  Assert-True (-not $html.Contains('PRIVATE-COMMAND-LINE')) 'process command lines are omitted'
  Assert-True (-not $html.Contains('PRIVATE-SECOND-COMMAND')) 'non-top process command lines are omitted'
  Assert-True (-not $html.Contains('PRIVATE-LISTENER-COMMAND')) 'listener command lines are omitted'
  Assert-True ($html.Contains('does not poll Windows') -and $html.Contains('claim live status')) 'page does not claim live monitoring'
  Assert-True ($html.Contains('href="#coverage"') -and $html.Contains('href="#processes"') -and $html.Contains('href="#listeners"')) 'section navigation points to evidence panels'

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
  Assert-True ($partialHtml.Contains('0 / 6') -and $partialHtml.Contains('class="metric-value unknown"')) 'missing evidence does not inflate coverage or freshness'

  Write-Output 'Dashboard smoke checks passed.'
} finally {
  if ($fixtureRoot.StartsWith($fixturesBase + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and [System.IO.Directory]::Exists($fixtureRoot)) {
    [System.IO.Directory]::Delete($fixtureRoot, $true)
  }
}
