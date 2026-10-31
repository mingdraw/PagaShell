param(
  [ValidateSet('Watch', 'Apply', 'Rollback', 'Extract')][string]$Mode = 'Watch',
  [Parameter(Mandatory = $true)][string]$ConfigPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$target = $config.target
$source = $config.source
$work = $config.work
$backup = "$target.pagashell-backup"
$marker = "$backup.marker"
$incoming = "$target.pagashell-new-$(Split-Path $work -Leaf)"
$lock = "$target.pagashell-update-lock"
$powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

if ($Mode -eq 'Extract') {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($config.archive)
  try {
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName.Replace('\', '/')
      if (-not $name.StartsWith("$($config.prefix)/", [StringComparison]::Ordinal) -or
          $name.Split('/') -contains '..' -or $name.Contains(':')) {
        throw 'Unexpected archive path'
      }
    }
  } finally { $zip.Dispose() }
  Expand-Archive -LiteralPath $config.archive -DestinationPath $config.stage
  return
}

if ($Mode -ne 'Watch') {
  New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
  $moved = $false
  try {
    if ($Mode -eq 'Rollback') {
      if (-not (Test-Path -LiteralPath $marker)) { throw 'Missing backup marker' }
      Move-Item -LiteralPath $target -Destination $incoming
      Move-Item -LiteralPath $backup -Destination $target
      Remove-Item -LiteralPath $marker
      return
    }
    if (Test-Path -LiteralPath $backup) {
      if (-not (Test-Path -LiteralPath $marker)) { throw 'Unmanaged backup exists' }
      Remove-Item -LiteralPath $backup -Recurse -Force
    }
    Copy-Item -LiteralPath $source -Destination $incoming -Recurse -Force
    # Create the recovery marker before moving the working installation.
    New-Item -ItemType File -Path $marker -Force | Out-Null
    Move-Item -LiteralPath $target -Destination $backup
    $moved = $true
    Move-Item -LiteralPath $incoming -Destination $target
    $moved = $false
  } catch {
    if ($moved -and -not (Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $backup)) {
      Move-Item -LiteralPath $backup -Destination $target
      Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
    }
    throw
  } finally {
    if (Test-Path -LiteralPath $incoming) { Remove-Item -LiteralPath $incoming -Recurse -Force }
    Remove-Item -LiteralPath $lock -Force
  }
  return
}

function Invoke-Transaction([string]$Action) {
  if ($config.requiresAdmin) {
    $command = "& '" + $PSCommandPath.Replace("'", "''") + "' -Mode $Action -ConfigPath '" + $ConfigPath.Replace("'", "''") + "'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $child = Start-Process -FilePath $powershell -Verb RunAs -Wait -PassThru -ArgumentList @(
      '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
    )
    if ($child.ExitCode -ne 0) { throw 'Elevated installation failed' }
  } else {
    & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -Mode $Action -ConfigPath $ConfigPath
    if ($LASTEXITCODE -ne 0) { throw 'Installation failed' }
  }
}

New-Item -ItemType File -Path (Join-Path $work 'ready') -Force | Out-Null
while (-not (Test-Path -LiteralPath (Join-Path $work 'commit'))) {
  if (Test-Path -LiteralPath (Join-Path $work 'cancel')) { return }
  if ($null -eq (Get-Process -Id $config.parentPid -ErrorAction SilentlyContinue)) { return }
  Start-Sleep -Milliseconds 100
}
$timer = [Diagnostics.Stopwatch]::StartNew()
while ($null -ne (Get-Process -Id $config.parentPid -ErrorAction SilentlyContinue)) {
  if (Test-Path -LiteralPath (Join-Path $work 'cancel')) { return }
  if ($timer.Elapsed.TotalSeconds -gt 120) {
    'exit-timeout' | Set-Content -LiteralPath (Join-Path $work 'error')
    throw 'Exit timeout'
  }
  Start-Sleep -Milliseconds 100
}
if (Test-Path -LiteralPath (Join-Path $work 'cancel')) { return }
try {
  Invoke-Transaction 'Apply'
} catch {
  'install-failed' | Set-Content -LiteralPath (Join-Path $work 'error')
  Start-Process -FilePath (Join-Path $target 'pagashell.exe') -WorkingDirectory $target
  throw
}
try {
  # This watcher is not elevated; the restarted application keeps the user's identity.
  Start-Process -FilePath (Join-Path $target 'pagashell.exe') -WorkingDirectory $target
} catch {
  'launch-failed' | Set-Content -LiteralPath (Join-Path $work 'error')
  Invoke-Transaction 'Rollback'
  Start-Process -FilePath (Join-Path $target 'pagashell.exe') -WorkingDirectory $target
  throw
}
New-Item -ItemType File -Path (Join-Path $work 'complete') -Force | Out-Null
Remove-Item -LiteralPath $config.stage -Recurse -Force
Remove-Item -LiteralPath $config.archive -Force
