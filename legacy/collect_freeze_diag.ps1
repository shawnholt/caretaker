param(
  [datetime]$StartLocal,
  [datetime]$EndLocal,
  [switch]$NoAdmin
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
$easternTz = $null
try {
  $easternTz = [TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time")
} catch {
  $easternTz = $null
}

$nowLocal = Get-Date
$nowEastern = if ($easternTz) { [TimeZoneInfo]::ConvertTime($nowLocal, $localTz, $easternTz) } else { $null }

if (-not $StartLocal -or -not $EndLocal) {
  if ($easternTz) {
    $dateEastern = $nowEastern.Date
    $startEastern = $dateEastern.AddHours(9)
    $endEastern = $dateEastern.AddHours(9.5)
    $StartLocal = [TimeZoneInfo]::ConvertTime($startEastern, $easternTz, $localTz)
    $EndLocal = [TimeZoneInfo]::ConvertTime($endEastern, $easternTz, $localTz)
  } else {
    $StartLocal = Get-Date -Hour 9 -Minute 0 -Second 0
    $EndLocal = Get-Date -Hour 9 -Minute 30 -Second 0
  }
}

Write-DiagBlock -Label "Context" -CommandText "Context and time window" -Body {
  "Invocation: $($MyInvocation.Line)"
  "NoAdmin switch: $NoAdmin"
  "Local timezone: $($localTz.Id) / $($localTz.DisplayName)"
  if ($easternTz) {
    "Eastern timezone: $($easternTz.Id) / $($easternTz.DisplayName)"
  } else {
    "Eastern timezone: not available on this system"
  }
  "Now local: $(Format-Stamp -Time $nowLocal -Zone $localTz)"
  if ($easternTz) {
    "Now eastern: $(Format-Stamp -Time $nowEastern -Zone $easternTz)"
    "Target window eastern: $(Format-Stamp -Time $startEastern -Zone $easternTz) to $(Format-Stamp -Time $endEastern -Zone $easternTz)"
  }
  "Target window local: $(Format-Stamp -Time $StartLocal -Zone $localTz) to $(Format-Stamp -Time $EndLocal -Zone $localTz)"
}

$sysFilter = @{
  LogName  = "System"
  StartTime = $StartLocal
  EndTime   = $EndLocal
  Level     = 1, 2, 3
}

Write-DiagBlock -Label "System events (Critical/Error/Warning)" -CommandText "Get-WinEvent -FilterHashtable @{LogName='System'; StartTime='$StartLocal'; EndTime='$EndLocal'; Level=1,2,3}" -Body {
  $events = Get-WinEvent -FilterHashtable $sysFilter | Sort-Object TimeCreated
  "Count: $($events.Count)"
  $events | Select-Object @{
    Name = "TimeCreatedLocal"
    Expression = { Format-LocalStamp -Time $_.TimeCreated }
  }, Id, LevelDisplayName, ProviderName, Message | Format-List
}

$appFilter = @{
  LogName  = "Application"
  StartTime = $StartLocal
  EndTime   = $EndLocal
  Level     = 1, 2, 3
}

Write-DiagBlock -Label "Application events (Critical/Error/Warning)" -CommandText "Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime='$StartLocal'; EndTime='$EndLocal'; Level=1,2,3}" -Body {
  $events = Get-WinEvent -FilterHashtable $appFilter | Sort-Object TimeCreated
  "Count: $($events.Count)"
  $events | Select-Object @{
    Name = "TimeCreatedLocal"
    Expression = { Format-LocalStamp -Time $_.TimeCreated }
  }, Id, LevelDisplayName, ProviderName, Message | Format-List
}
