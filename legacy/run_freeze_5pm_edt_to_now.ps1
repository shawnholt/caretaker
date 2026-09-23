param(
  [switch]$NoAdmin,
  [switch]$IncludeInfo
)

$Project = (Get-Location).Path
$Diag = Join-Path $Project "diag_log.txt"

function Get-OffsetText {
  param([TimeSpan]$Offset)
  $totalMinutes = [int][Math]::Round($Offset.TotalMinutes)
  $sign = if ($totalMinutes -ge 0) { "+" } else { "-" }
  $absMinutes = [Math]::Abs($totalMinutes)
  $hours = [Math]::Floor($absMinutes / 60)
  $minutes = $absMinutes % 60
  return ("{0}{1:00}:{2:00}" -f $sign, $hours, $minutes)
}

function Format-Stamp {
  param([datetime]$Time, [TimeZoneInfo]$Zone)
  $zoneName = if ($Zone.IsDaylightSavingTime($Time)) { $Zone.DaylightName } else { $Zone.StandardName }
  $offsetText = Get-OffsetText -Offset ($Zone.GetUtcOffset($Time))
  return ("{0:yyyy-MM-dd HH:mm:ss} {1} (UTC{2})" -f $Time, $zoneName, $offsetText)
}

function Format-LocalStamp {
  param([datetime]$Time)
  return (Format-Stamp -Time $Time -Zone ([TimeZoneInfo]::Local))
}

function Write-DiagBlock {
  param(
    [string]$Label,
    [string]$CommandText,
    [scriptblock]$Body
  )
  $stamp = Format-LocalStamp -Time (Get-Date)
  "=== [$stamp] $Label ===" | Out-File $Diag -Append
  if ($CommandText) {
    $CommandText | Out-File $Diag -Append
  }
  try {
    & $Body 2>&1 | Out-File $Diag -Append
  } catch {
    $_ | Out-File $Diag -Append
  }
  "" | Out-File $Diag -Append
}

$localTz = [TimeZoneInfo]::Local
$nowLocal = Get-Date

$startLocal = $nowLocal.Date.AddHours(17)
$endLocal = $nowLocal

Write-DiagBlock -Label "Run window (5pm local to present)" -CommandText "Compute time window from 5pm local time today to now" -Body {
  "Invocation: $($MyInvocation.Line)"
  "NoAdmin switch: $NoAdmin"
  "IncludeInfo switch: $IncludeInfo"
  "Local timezone: $($localTz.Id) / $($localTz.DisplayName)"
  "Now local: $(Format-Stamp -Time $nowLocal -Zone $localTz)"
  "Start local: $(Format-Stamp -Time $startLocal -Zone $localTz)"
  "End local: $(Format-Stamp -Time $endLocal -Zone $localTz)"
}

$stampAnalyze = Format-LocalStamp -Time (Get-Date)
"=== [$stampAnalyze] Analyze freeze indicators ===" | Out-File $Diag -Append
"analyze_freeze_indicators.ps1 -StartLocal '$startLocal' -EndLocal '$endLocal' -NoAdmin -IncludeInfo:$IncludeInfo" | Out-File $Diag -Append
"" | Out-File $Diag -Append
& .\analyze_freeze_indicators.ps1 -StartLocal $startLocal -EndLocal $endLocal -NoAdmin -IncludeInfo:$IncludeInfo

Write-DiagBlock -Label "Read freeze_indicators.txt" -CommandText "Get-Content .\\freeze_indicators.txt" -Body {
  Get-Content .\freeze_indicators.txt
}
