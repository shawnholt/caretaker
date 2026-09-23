param(
  [datetime]$StartLocal,
  [datetime]$EndLocal,
  [switch]$NoAdmin,
  [switch]$IncludeInfo
)

$Project = (Get-Location).Path
$Diag = Join-Path $Project "diag_log.txt"
$Summary = Join-Path $Project "freeze_indicators.txt"

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

function Is-FreezeIndicator {
  param(
    [string]$Provider,
    [int]$Id
  )
  $providerPatterns = @(
    "^Display$",
    "^Microsoft-Windows-Display$",
    "^Microsoft-Windows-DxgKrnl$",
    "^nvlddmkm$",
    "^amdkmdag$",
    "^amdkmdap$",
    "^WHEA-Logger$",
    "^Disk$",
    "^Ntfs$",
    "^volsnap$",
    "^storahci$",
    "^stornvme$",
    "^iaStorA$",
    "^iaStorAC$",
    "^iaStorAV$",
    "^iaStorAfs$",
    "^Kernel-Power$",
    "^Microsoft-Windows-Kernel-Power$",
    "^Microsoft-Windows-Kernel-Boot$",
    "^BugCheck$",
    "^Microsoft-Windows-WER-SystemErrorReporting$",
    "^Application Hang$",
    "^Application Error$",
    "^Windows Error Reporting$",
    "^Microsoft-Windows-Resource-Exhaustion-Detector$",
    "^EventLog$"
  )

  $idList = @(
    41,    # Kernel-Power unexpected shutdown
    1001,  # BugCheck/WER
    1002,  # Application Hang
    4101,  # Display driver reset (TDR)
    14,    # GPU driver error (e.g., nvlddmkm)
    17, 18, 19, # WHEA hardware errors
    7, 11, 51, # Disk I/O errors
    55, 57, 98, 140, # NTFS errors
    129, 153, # storage timeouts/resets
    6008, # unexpected shutdown
    2004  # resource exhaustion
  )

  if ($idList -contains $Id) {
    return $true
  }

  foreach ($pattern in $providerPatterns) {
    if ($Provider -match $pattern) {
      return $true
    }
  }

  return $false
}

$localTz = [TimeZoneInfo]::Local
$nowLocal = Get-Date

Write-DiagBlock -Label "Freeze indicator analysis context" -CommandText "Analyze System/Application logs for freeze indicators" -Body {
  "Invocation: $($MyInvocation.Line)"
  "NoAdmin switch: $NoAdmin"
  "IncludeInfo switch: $IncludeInfo"
  "Local timezone: $($localTz.Id) / $($localTz.DisplayName)"
  "Now local: $(Format-Stamp -Time $nowLocal -Zone $localTz)"
  "Target window local: $(Format-Stamp -Time $StartLocal -Zone $localTz) to $(Format-Stamp -Time $EndLocal -Zone $localTz)"
}

$indicatorEvents = @()
$levels = @(1, 2, 3)
if ($IncludeInfo) {
  $levels += 4
}
$filterCommand = "Providers or IDs commonly linked to freezes (display, WHEA, disk/storage, kernel-power, app hang, resource exhaustion); levels: $($levels -join ',')"

foreach ($logName in @("System", "Application")) {
  $filter = @{
    LogName   = $logName
    StartTime = $StartLocal
    EndTime   = $EndLocal
    Level     = $levels
  }

  $logEvents = @(Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue)
  foreach ($ev in $logEvents) {
    if (Is-FreezeIndicator -Provider $ev.ProviderName -Id $ev.Id) {
      $indicatorEvents += [pscustomobject]@{
        LogName          = $logName
        TimeCreated      = $ev.TimeCreated
        ProviderName     = $ev.ProviderName
        Id               = $ev.Id
        LevelDisplayName = $ev.LevelDisplayName
        Message          = $ev.Message
      }
    }
  }
}

Write-DiagBlock -Label "Freeze indicators (Critical/Error/Warning)" -CommandText $filterCommand -Body {
  if ($indicatorEvents.Count -eq 0) {
    "No freeze-indicator events found in the window."
  } else {
    $indicatorEvents | Sort-Object TimeCreated | Select-Object @{
      Name = "TimeCreatedLocal"
      Expression = { Format-LocalStamp -Time $_.TimeCreated }
    }, LogName, ProviderName, Id, LevelDisplayName, Message | Format-List
  }
}

$header = @(
  "Freeze indicator summary",
  "Target window local: $(Format-Stamp -Time $StartLocal -Zone $localTz) to $(Format-Stamp -Time $EndLocal -Zone $localTz)",
  "IncludeInfo: $IncludeInfo"
)

if ($indicatorEvents.Count -eq 0) {
  $header += ""
  $header += "No freeze-indicator events found in the window."
  $header | Set-Content $Summary -Encoding ASCII
  exit 0
}

$groups = $indicatorEvents | Group-Object LogName, ProviderName, Id, LevelDisplayName
$summaryRows = @()
foreach ($group in $groups) {
  $items = $group.Group | Sort-Object TimeCreated
  $summaryRows += [pscustomobject]@{
    Count     = $group.Count
    LogName   = $items[0].LogName
    Provider  = $items[0].ProviderName
    Id        = $items[0].Id
    Level     = $items[0].LevelDisplayName
    FirstSeen = (Format-LocalStamp -Time $items[0].TimeCreated)
    LastSeen  = (Format-LocalStamp -Time $items[-1].TimeCreated)
    Sample    = (Get-OneLine -Text $items[0].Message)
  }
}

$header += ""
$header += "Count|LogName|Provider|Id|Level|FirstSeen|LastSeen|Sample"
$lines = $summaryRows | Sort-Object Count -Descending | ForEach-Object {
  "{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}" -f `
    $_.Count, $_.LogName, $_.Provider, $_.Id, $_.Level, $_.FirstSeen, $_.LastSeen, $_.Sample
}

$details = @(
  "",
  "Details",
  "TimeCreatedLocal|LogName|Provider|Id|Level|Message"
)

$detailLines = $indicatorEvents | Sort-Object TimeCreated | ForEach-Object {
  "{0}|{1}|{2}|{3}|{4}|{5}" -f `
    (Format-LocalStamp -Time $_.TimeCreated), $_.LogName, $_.ProviderName, $_.Id, $_.LevelDisplayName, (Get-OneLine -Text $_.Message -MaxLen 240)
}

($header + $lines + $details + $detailLines) | Set-Content $Summary -Encoding ASCII
