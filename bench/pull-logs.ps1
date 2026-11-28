# Copies the board's bench logs to this PC every minute while tests run (bench/TEST-PROCESS.md), so a crash, a hang
# or a lost disk write on the board cannot lose them. Nothing on the PC is ever deleted or shortened: a file is only
# replaced by a board copy that is at least as long, so the PC keeps the longer copy when the board lost the tail of
# a file in a crash. Needs the Windows OpenSSH client (ssh) and tar (both ship with Windows 10/11) and key login.
#   powershell -File pull-logs.ps1 -Board <ssh host> [-Dest <folder>] [-IntervalSeconds 60] [-Once]
# Default board folders: /var/log/opi6-bench (boot loggers), ~/crash-repro and ~/stability-logs (test sets).
param(
  [Parameter(Mandatory = $true)][string]$Board,
  [string]$Dest = (Join-Path $PSScriptRoot 'bench-logs'),
  [string[]]$Paths = @('/var/log/opi6-bench', '~/crash-repro', '~/stability-logs'),
  [int]$IntervalSeconds = 60,
  [switch]$Once
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$Dest = (Resolve-Path $Dest).Path
$plog = Join-Path $Dest 'pull.log'
function Note($m) { "$(Get-Date -Format s) $m" | Add-Content -Path $plog -Encoding utf8; Write-Host $m }
$down = $false
Note "pull start board=$Board every ${IntervalSeconds}s"
while ($true) {
  $failed = $false
  foreach ($p in $Paths) {
    $name = ($p -replace '^~/', '' -replace '^/', '' -replace '/', '_')
    $stage = Join-Path $Dest ".staging\$name"; $target = Join-Path $Dest $name
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    New-Item -ItemType Directory -Force -Path $stage, $target | Out-Null
    # cmd /c keeps the tar stream binary (Windows PowerShell pipes between programs as text).
    cmd /c "ssh -o BatchMode=yes -o ConnectTimeout=10 $Board ""if [ -d $p ]; then tar -C $p --exclude=./current -cf - .; else tar -cf - -T /dev/null; fi"" 2>nul | tar -C ""$stage"" -xf - 2>nul"
    if ($LASTEXITCODE -ne 0) { $failed = $true }
    Get-ChildItem -Path $stage -Recurse -File | ForEach-Object {
      $rel = $_.FullName.Substring($stage.Length).TrimStart('\')
      $dst = Join-Path $target $rel
      if (Test-Path $dst) {
        $old = (Get-Item $dst).Length
        if ($_.Length -lt $old) { Note "kept the longer PC copy of $name\$rel (board $($_.Length) bytes, PC $old)"; return }
        if ($_.Length -eq $old) { return }
      }
      New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
      Copy-Item -Force $_.FullName $dst
    }
  }
  if ($failed -and -not $down) { Note "BOARD UNREACHABLE or pull failed"; $down = $true }
  elseif (-not $failed -and $down) { Note "board reachable again"; $down = $false }
  if ($Once) { break }
  Start-Sleep -Seconds $IntervalSeconds
}
