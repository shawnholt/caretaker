param(
  [datetime]$StartLocal,
  [datetime]$EndLocal,
  [switch]$NoAdmin
)

$Project = (Get-Location).Path
$Diag = Join-Path $Project "diag_log.txt"
$Summary = Join-Path $Project "freeze_summary.txt"

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

function Get-OneLine {
  param(
    [string]$Text,
    [int]$MaxLen = 200
  )
  if ([string]::IsNullOrWhiteSpace($Text)) {
    return ""
  }
  $line = ($Text -split "`r?`n")[0]
  $line = ($line -replace "\s+", " ").Trim()
  $line = $line.Replace("|", "/")
  if ($line.Length -gt $MaxLen) {
    $line = $line.Substring(0, $MaxLen)
  }
  return $line
}

function Get-FreezeReason {
  param(
    [string]$Provider,
    [int]$Id
  )
  switch -Regex ($Provider) {
    "^Display$" { if ($Id -eq 4101) { return "Display driver reset (TDR)" } }
    "^WHEA-Logger$" { return "Hardware error report" }
    "^Disk$" { return "Disk I/O error" }
    "^storahci$" { return "Storage controller timeout/reset" }
    "^stornvme$" { return "Storage controller timeout/reset" }
    "^iaStorA$" { return "Storage controller timeout/reset" }
    "^Ntfs$" { return "File system error" }
    "^volsnap$" { return "Volume shadow copy I/O error" }
    "^Kernel-Power$" { if ($Id -eq 41) { return "Unexpected power loss" } }
    "^Application Hang$" { if ($Id -eq 1002) { return "Application hang" } }
    "^Windows Error Reporting$" { if ($Id -eq 1001) { return "App hang/crash report" } }
  }
  return $null
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

$startEasternDisplay = $null
$endEasternDisplay = $null
if ($easternTz) {
  $startEasternDisplay = [TimeZoneInfo]::ConvertTime($StartLocal, $localTz, $easternTz)
  $endEasternDisplay = [TimeZoneInfo]::ConvertTime($EndLocal, $localTz, $easternTz)
}

Write-DiagBlock -Label "Analysis context" -CommandText "Analyze repeating issues in System/Application logs" -Body {
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
    "Target window eastern: $(Format-Stamp -Time $startEasternDisplay -Zone $easternTz) to $(Format-Stamp -Time $endEasternDisplay -Zone $easternTz)"
  }
  "Target window local: $(Format-Stamp -Time $StartLocal -Zone $localTz) to $(Format-Stamp -Time $EndLocal -Zone $localTz)"
}

$events = @()

foreach ($logName in @("System", "Application")) {
  $filter = @{
    LogName   = $logName
    StartTime = $StartLocal
    EndTime   = $EndLocal
    Level     = 1, 2, 3
  }

  $logEvents = @(Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue)

  Write-DiagBlock -Label "$logName events (Critical/Error/Warning)" -CommandText "Get-WinEvent -FilterHashtable @{LogName='$logName'; StartTime='$StartLocal'; EndTime='$EndLocal'; Level=1,2,3}" -Body {
    $sorted = $logEvents | Sort-Object TimeCreated
    "Count: $($sorted.Count)"
    $sorted | Select-Object @{
      Name = "TimeCreatedLocal"
      Expression = { Format-LocalStamp -Time $_.TimeCreated }
    }, Id, LevelDisplayName, ProviderName, Message | Format-List
  }
  foreach ($ev in $logEvents) {
    $events += [pscustomobject]@{
      LogName         = $logName
      TimeCreated     = $ev.TimeCreated
      ProviderName    = $ev.ProviderName
      Id              = $ev.Id
      LevelDisplayName = $ev.LevelDisplayName
      Message         = $ev.Message
    }
  }
}

if ($events.Count -eq 0) {
  Write-DiagBlock -Label "Repeating issues summary" -CommandText "No events found" -Body {
    "No Critical/Error/Warning events found in the window."
  }
  $header = @(
    "Freeze analysis summary",
    "Target window local: $(Format-Stamp -Time $StartLocal -Zone $localTz) to $(Format-Stamp -Time $EndLocal -Zone $localTz)"
  )
  if ($easternTz) {
    $header += "Target window eastern: $(Format-Stamp -Time $startEasternDisplay -Zone $easternTz) to $(Format-Stamp -Time $endEasternDisplay -Zone $easternTz)"
  }
  $header += ""
  $header += "No Critical/Error/Warning events found in the window."
  $header | Set-Content $Summary -Encoding ASCII
  exit 0
}

$groups = $events | Group-Object LogName, ProviderName, Id, LevelDisplayName
$repeating = $groups | Where-Object { $_.Count -ge 2 } | Sort-Object @{Expression = "Count"; Descending = $true}, Name

$summaryRows = @()
foreach ($group in $repeating) {
  $items = $group.Group | Sort-Object TimeCreated
  $first = $items[0].TimeCreated
  $last = $items[-1].TimeCreated
  $provider = $items[0].ProviderName
  $id = $items[0].Id
  $reason = Get-FreezeReason -Provider $provider -Id $id
  $sample = Get-OneLine -Text $items[0].Message
  $summaryRows += [pscustomobject]@{
    Count       = $group.Count
    LogName     = $items[0].LogName
    Provider    = $provider
    Id          = $id
    Level       = $items[0].LevelDisplayName
    FirstSeen   = (Format-LocalStamp -Time $first)
    LastSeen    = (Format-LocalStamp -Time $last)
    Reason      = $reason
    Sample      = $sample
  }
}

Write-DiagBlock -Label "Repeating issues summary (count >= 2)" -CommandText "Group by LogName/Provider/Id/Level" -Body {
  if ($summaryRows.Count -eq 0) {
    "No repeating issues found (count >= 2)."
  } else {
    $summaryRows | Sort-Object Count -Descending | Format-List
  }
}

$header = @(
  "Freeze analysis summary",
  "Target window local: $(Format-Stamp -Time $StartLocal -Zone $localTz) to $(Format-Stamp -Time $EndLocal -Zone $localTz)"
)
if ($easternTz) {
  $header += "Target window eastern: $(Format-Stamp -Time $startEasternDisplay -Zone $easternTz) to $(Format-Stamp -Time $endEasternDisplay -Zone $easternTz)"
}
if ($summaryRows.Count -eq 0) {
  $header += "No repeating issues found (count >= 2)."
  $header | Set-Content $Summary -Encoding ASCII
} else {
  $header += ""
  $header += "Count|LogName|Provider|Id|Level|FirstSeen|LastSeen|Reason|Sample"
  $lines = $summaryRows | Sort-Object Count -Descending | ForEach-Object {
    "{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}" -f `
      $_.Count, $_.LogName, $_.Provider, $_.Id, $_.Level, $_.FirstSeen, $_.LastSeen, $_.Reason, $_.Sample
  }
  $header + $lines | Set-Content $Summary -Encoding ASCII
}
