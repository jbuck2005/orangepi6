# Logs the board's debug UART (UART2, 115200 8N1) from a USB-TTL adapter to a file.
# Each line gets a local timestamp. Reconnects if the adapter is unplugged.
#   pwsh -File serial-log.ps1 [-Port COM10] [-Log <path>]
param(
  [string]$Port = 'COM10',
  [string]$Log  = (Join-Path $PSScriptRoot 'serial.log')
)
$ErrorActionPreference = 'Stop'
"=== logger start $(Get-Date -Format s) port=$Port" | Add-Content -Path $Log -Encoding utf8
$partial = ''
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
          $ts = Get-Date -Format 'HH:mm:ss.fff'
          $lines[0..($lines.Count - 2)] | ForEach-Object { "$ts $_" } | Add-Content -Path $Log -Encoding utf8
        }
      } else {
        Start-Sleep -Milliseconds 100
      }
    }
  } catch {
    "=== $(Get-Date -Format s) port error: $($_.Exception.Message); retrying in 5 s" | Add-Content -Path $Log -Encoding utf8
    try { if ($p) { $p.Close() } } catch {}
    Start-Sleep -Seconds 5
  }
}
