# PowerShell Diagnostic Script
#
# This script requires administrative privileges to run.
# All output and errors will be logged to diag_log.txt

# Start Logging
Start-Transcript -Path diag_log.txt -Append

Write-Host "Starting System Diagnostics..."
Write-Host "Start Time: $(Get-Date)"
Write-Host ""

# --- Event Viewer ---
Write-Host "--- Querying Event Viewer for Critical Errors (Last 48 Hours) ---"
$startTime = (Get-Date).AddHours(-48)

# System Log
Write-Host "Querying System Log..."
Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=$startTime} -ErrorAction SilentlyContinue | Format-List | Out-File -Append -FilePath diag_log.txt

# Application Log
Write-Host "Querying Application Log..."
Get-WinEvent -FilterHashtable @{LogName='Application'; Level=1,2; StartTime=$startTime} -ErrorAction SilentlyContinue | Format-List | Out-File -Append -FilePath diag_log.txt

Write-Host "Event Viewer query complete."
Write-Host ""

# --- System File Checker ---
Write-Host "--- Running System File Checker (sfc /scannow) ---"
sfc /scannow
Write-Host "System File Checker complete."
Write-Host ""

