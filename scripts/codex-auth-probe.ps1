[CmdletBinding()]
param([string]$CodexPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-CodexPath([string]$RequestedPath) {
  if ($RequestedPath) {
    $candidate = [System.IO.Path]::GetFullPath($RequestedPath)
    if ([System.IO.Path]::GetExtension($candidate) -ine '.exe' -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      throw 'CodexPath must identify an existing native codex.exe.'
    }
    return $candidate
  }

  # Prefer the npm PATH `codex` shim's vendor binary (same file the wrapper runs).
  if ($env:APPDATA) {
    $pkgJson = Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\package.json'
    if (Test-Path -LiteralPath $pkgJson -PathType Leaf) {
      $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
      $platformPkg = if ($arch -eq 'arm64') { '@openai/codex-win32-arm64' } else { '@openai/codex-win32-x64' }
      $triple = if ($arch -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
      $resolved = & node -e "const {createRequire}=require('module'); const path=require('path'); const fs=require('fs'); const req=createRequire(process.argv[1]); const pj=req.resolve(process.argv[2]+'/package.json'); const exe=path.join(path.dirname(pj),'vendor',process.argv[3],'bin','codex.exe'); if(!fs.existsSync(exe)) process.exit(2); process.stdout.write(path.resolve(exe));" $pkgJson $platformPkg $triple 2>$null
      if ($LASTEXITCODE -eq 0 -and $resolved -and (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        return [System.IO.Path]::GetFullPath($resolved)
      }
    }
  }

  $command = Get-Command codex.exe -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $command -or -not (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
    throw 'No Codex CLI found. Install the npm `@openai/codex` CLI (PATH `codex`) or put codex.exe on PATH; pass -CodexPath to override.'
  }
  return [System.IO.Path]::GetFullPath($command.Source)
}

function Get-ChildIdentity([System.Diagnostics.Process]$Child) {
  try {
    $Child.Refresh()
    if ($Child.HasExited) { return $null }
    $imagePath = [System.IO.Path]::GetFullPath($Child.MainModule.FileName)
    return [pscustomobject]@{
      Id = $Child.Id
      StartUtcTicks = $Child.StartTime.ToUniversalTime().Ticks
      ImagePath = $imagePath
    }
  } catch {
    return $null
  }
}

function Test-SameChild([System.Diagnostics.Process]$Child, [object]$Identity) {
  if (-not $Identity) { return $false }
  $current = Get-ChildIdentity $Child
  if (-not $current) { return $false }
  return ($current.Id -eq $Identity.Id -and
    $current.StartUtcTicks -eq $Identity.StartUtcTicks -and
    [string]::Equals($current.ImagePath, $Identity.ImagePath, [System.StringComparison]::OrdinalIgnoreCase))
}

function Read-Response([System.Diagnostics.Process]$Child, [int]$RequestId, [System.Diagnostics.Stopwatch]$Timer) {
  while ($true) {
    $remaining = 10000 - [int]$Timer.ElapsedMilliseconds
    if ($remaining -le 0) { throw 'timeout' }
    $lineTask = $Child.StandardOutput.ReadLineAsync()
    if (-not $lineTask.Wait($remaining)) { throw 'timeout' }
    $line = $lineTask.Result
    if ($null -eq $line) { throw 'closed' }
    $message = ConvertFrom-Json -InputObject $line
    $idProperty = $message.PSObject.Properties['id']
    if ($idProperty -and $null -ne $idProperty.Value -and [string]$idProperty.Value -eq [string]$RequestId) {
      return $message
    }
  }
}

$process = $null
$processIdentity = $null
$stdinClosed = $false
$authType = $null
$requiresOpenaiAuth = $null
$probeFailed = $false
$cleanupFailed = $false

try {
  $resolvedCodexPath = Resolve-CodexPath $CodexPath
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $resolvedCodexPath
  $startInfo.Arguments = 'app-server'
  $startInfo.WorkingDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  if (-not $process.Start()) { throw 'start' }
  $processIdentity = Get-ChildIdentity $process
  if (-not $processIdentity) { throw 'identity' }
  $stderrTask = $process.StandardError.ReadToEndAsync()

  $initialize = [ordered]@{
    method = 'initialize'
    id = 0
    params = [ordered]@{
      clientInfo = [ordered]@{
        name = 'goliath-caretaker-auth-probe'
        title = 'Goliath Caretaker auth probe'
        version = '0.1.0'
      }
    }
  }
  $initialized = [ordered]@{ method = 'initialized'; params = [ordered]@{} }
  $process.StandardInput.WriteLine((ConvertTo-Json -InputObject $initialize -Depth 8 -Compress))
  $process.StandardInput.WriteLine((ConvertTo-Json -InputObject $initialized -Depth 8 -Compress))
  $initializeResponse = Read-Response $process 0 $stopwatch
  if ($initializeResponse.PSObject.Properties['error']) { throw 'initialize' }

  $accountRead = [ordered]@{
    method = 'account/read'
    id = 1
    params = [ordered]@{ refreshToken = $false }
  }
  $process.StandardInput.WriteLine((ConvertTo-Json -InputObject $accountRead -Depth 8 -Compress))
  $accountResponse = Read-Response $process 1 $stopwatch
  if ($accountResponse.PSObject.Properties['error']) { throw 'account' }

  $resultProperty = $accountResponse.PSObject.Properties['result']
  if (-not $resultProperty -or -not $resultProperty.Value) { throw 'result' }
  $accountResult = $resultProperty.Value
  $authProperty = $accountResult.PSObject.Properties['account']
  $authType = 'none'
  if ($authProperty -and $authProperty.Value) {
    $typeProperty = $authProperty.Value.PSObject.Properties['type']
    if (-not $typeProperty -or $typeProperty.Value -isnot [string]) { throw 'auth-type' }
    $authType = [string]$typeProperty.Value
  }
  $requiresProperty = $accountResult.PSObject.Properties['requiresOpenaiAuth']
  if (-not $requiresProperty -or $requiresProperty.Value -isnot [bool]) { throw 'auth-state' }
  $requiresOpenaiAuth = [bool]$requiresProperty.Value
} catch {
  $probeFailed = $true
} finally {
  if ($process) {
    try {
      if (-not $stdinClosed) {
        $process.StandardInput.Close()
        $stdinClosed = $true
      }
    } catch { }

    try {
      if (-not $process.HasExited) {
        $exited = $process.WaitForExit(500)
        if (-not $exited) {
          if (Test-SameChild $process $processIdentity) {
            $process.Kill()
            $exited = $process.WaitForExit(1500)
            if (-not $exited) { $cleanupFailed = $true }
          } else {
            $cleanupFailed = $true
          }
        }
      }
    } catch {
      $cleanupFailed = $true
    }

    if (-not $process.HasExited) { $cleanupFailed = $true }
    $process.Dispose()
  }
}

if ($cleanupFailed) { throw 'Codex auth probe could not verify cleanup of its child process.' }
if ($probeFailed) { throw 'Codex auth probe failed (startup, timeout, or protocol error).' }

[pscustomobject]@{
  authType = $authType
  requiresOpenaiAuth = $requiresOpenaiAuth
} | ConvertTo-Json -Compress
