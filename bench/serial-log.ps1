# Logs the board's debug UART (UART2, 115200 8N1) from a USB-TTL adapter to a file.
# Each line gets a local timestamp. Reconnects if the adapter is unplugged. The log is only ever appended to.
# While the bench loggers run (bench/benchlog.sh), the board prints a "bench-t:" temperature line every minute, so
# silence means the board or the adapter is down: after -StaleMinutes without a line the log gets a
# "=== NO SERIAL DATA" marker (once, until data comes back), so a capture always shows when it went quiet.
#   pwsh -File serial-log.ps1 [-Port COM<n>] [-Log <path>] [-StaleMinutes 3]
param(
  [string]$Port = 'COM10',
  [string]$Log  = (Join-Path $PSScriptRoot 'serial.log'),
  [int]$StaleMinutes = 3
)
$ErrorActionPreference = 'Stop'
"=== logger start $(Get-Date -Format s) port=$Port" | Add-Content -Path $Log -Encoding utf8
$partial = ''
$lastData = Get-Date; $staleMarked = $false
while ($true) {
  try {
    $p = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 'One'
    $p.Handshake = 'None'; $p.ReadTimeout = 1000; $p.Encoding = [System.Text.Encoding]::Latin1
    $p.Open()
    while ($p.IsOpen) {
      $chunk = $p.ReadExisting()
      if ($chunk) {
        $text = $partial + ($chunk -replace "`r", '')
        $lines = $text -split "`n"
        $partial = $lines[-1]
        if ($lines.Count -gt 1) {
          if ($staleMarked) { "=== $(Get-Date -Format s) serial data again" | Add-Content -Path $Log -Encoding utf8; $staleMarked = $false }
          $lastData = Get-Date
          $ts = Get-Date -Format 'HH:mm:ss.fff'
          $lines[0..($lines.Count - 2)] | ForEach-Object { "$ts $_" } | Add-Content -Path $Log -Encoding utf8
        }
      } else {
        if (-not $staleMarked -and $StaleMinutes -gt 0 -and ((Get-Date) - $lastData).TotalMinutes -ge $StaleMinutes) {
          "=== $(Get-Date -Format s) NO SERIAL DATA for $StaleMinutes min (board down, hung or adapter lost)" | Add-Content -Path $Log -Encoding utf8
          $staleMarked = $true
        }
        Start-Sleep -Milliseconds 100
      }
    }
  } catch {
    "=== $(Get-Date -Format s) port error: $($_.Exception.Message); retrying in 5 s" | Add-Content -Path $Log -Encoding utf8
    try { if ($p) { $p.Close() } } catch {}
    Start-Sleep -Seconds 5
  }
}
