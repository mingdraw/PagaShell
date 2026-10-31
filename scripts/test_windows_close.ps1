param(
  [Parameter(Mandatory = $true)][string]$Executable,
  [string]$OutputPath = 'build/windows-close-results.json',
  [ValidateRange(1, 10)][int]$Iterations = 3,
  [int]$MaxVisibleMilliseconds = 0,
  [int]$MaxExitMilliseconds = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class PagaShellCloseSmoke {
  private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr parameter);
  [DllImport("user32.dll")]
  private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
  [DllImport("user32.dll")]
  private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr hwnd);
  [DllImport("user32.dll")]
  public static extern bool IsWindow(IntPtr hwnd);
  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);

  public static IntPtr FindVisibleWindow(uint processId) {
    IntPtr result = IntPtr.Zero;
    EnumWindows((hwnd, parameter) => {
      uint owner;
      GetWindowThreadProcessId(hwnd, out owner);
      if (owner == processId && IsWindowVisible(hwnd)) {
        result = hwnd;
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return result;
  }
}
'@

$executablePath = (Resolve-Path $Executable).Path
$outputFile = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path $outputFile
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$measurements = @()
$failures = @()
$originalAppData = $env:APPDATA
$originalLocalAppData = $env:LOCALAPPDATA

try {
  for ($iteration = 1; $iteration -le $Iterations; $iteration++) {
    # A fresh profile keeps the smoke test independent of real credentials,
    # saved proxies and previous runs on a developer machine.
    $profileDirectory = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
    $env:APPDATA = Join-Path $profileDirectory 'Roaming'
    $env:LOCALAPPDATA = Join-Path $profileDirectory 'Local'
    New-Item -ItemType Directory -Path $env:APPDATA, $env:LOCALAPPDATA -Force | Out-Null
    $process = $null
    try {
      $process = Start-Process -FilePath $executablePath -WorkingDirectory (Split-Path $executablePath) `
        -RedirectStandardOutput (Join-Path $outputDirectory "close-$iteration.stdout.log") `
        -RedirectStandardError (Join-Path $outputDirectory "close-$iteration.stderr.log") -PassThru
      $startup = [Diagnostics.Stopwatch]::StartNew()
      $window = [IntPtr]::Zero
      while ($window -eq [IntPtr]::Zero -and $startup.ElapsedMilliseconds -lt 30000) {
        if ($process.HasExited) { throw "Application exited before showing a window ($($process.ExitCode))" }
        $window = [PagaShellCloseSmoke]::FindVisibleWindow($process.Id)
        Start-Sleep -Milliseconds 50
      }
      if ($window -eq [IntPtr]::Zero) { throw 'Application did not show a window within 30 seconds' }
      # The native window is shown before runApp; allow the ShellPage close
      # listener and initial local settings loads to finish mounting.
      Start-Sleep -Seconds 5
      $elapsed = [Diagnostics.Stopwatch]::StartNew()
      # SC_CLOSE matches the native caption close button/window_manager.close.
      if (-not [PagaShellCloseSmoke]::PostMessage($window, 0x0112, [IntPtr]0xF060, [IntPtr]::Zero)) {
        throw 'Cannot send SC_CLOSE to the application window'
      }
      $visibleMilliseconds = $null
      while (-not $process.HasExited -and $elapsed.ElapsedMilliseconds -lt 30000) {
        if ($null -eq $visibleMilliseconds -and
          (-not [PagaShellCloseSmoke]::IsWindow($window) -or
           -not [PagaShellCloseSmoke]::IsWindowVisible($window))) {
          $visibleMilliseconds = $elapsed.ElapsedMilliseconds
        }
        Start-Sleep -Milliseconds 20
      }
      $exitMilliseconds = $elapsed.ElapsedMilliseconds
      $exited = $process.HasExited
      if ($null -eq $visibleMilliseconds -and $exited) { $visibleMilliseconds = $exitMilliseconds }
      $exitCode = if ($exited) { $process.ExitCode } else { $null }
      $measurement = [ordered]@{
        iteration = $iteration
        windowHiddenMs = $visibleMilliseconds
        processExitMs = $exitMilliseconds
        exited = $exited
        exitCode = $exitCode
      }
      $measurements += $measurement
      $measurement | ConvertTo-Json -Compress | Write-Output
      if (-not $exited) { $failures += "Run ${iteration}: process did not exit within 30 seconds" }
      if ($exited -and $exitCode -ne 0) { $failures += "Run ${iteration}: exit code $exitCode" }
      if ($MaxVisibleMilliseconds -gt 0 -and
        ($null -eq $visibleMilliseconds -or $visibleMilliseconds -gt $MaxVisibleMilliseconds)) {
        $failures += "Run ${iteration}: window stayed visible for $visibleMilliseconds ms"
      }
      if ($MaxExitMilliseconds -gt 0 -and $exitMilliseconds -gt $MaxExitMilliseconds) {
        $failures += "Run ${iteration}: process exit took $exitMilliseconds ms"
      }
    } finally {
      if ($null -ne $process) {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
        $process.Dispose()
      }
      Remove-Item -LiteralPath $profileDirectory -Recurse -Force
    }
  }
} finally {
  $env:APPDATA = $originalAppData
  $env:LOCALAPPDATA = $originalLocalAppData
  ConvertTo-Json -InputObject @($measurements) -Depth 4 | Set-Content $outputFile -Encoding utf8
}

if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
