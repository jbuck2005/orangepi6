# Power-cycles aiPi through a local smart plug, by hand or automatically when the firmware fails
# NIC link training ("Root Port 2/3: Link Up Fail" on the debug UART, logged by bench/serial-log.ps1).
#
# Plug: any plug with a local HTTP API and no cloud account, e.g. a Shelly Gen2+/Gen3 plug (cloud can be
# switched off in its web UI) or a plug running Tasmota. The off/on sequence runs ON THE PLUG
# (Shelly toggle_after / Tasmota Backlog Delay), so power comes back even if this PC goes away mid-cycle.
#
# Home Assistant: any plug HA can switch (e.g. an Emporia plug). This script calls HA's REST API for
# switch.turn_off, waits, then switch.turn_on, retrying turn_on until HA confirms the switch is on.
#
# Config (kept outside the repo, so no LAN addresses, tokens or passwords get committed): a JSON file,
# default aipi-plug.json next to serial.log:
#   { "type": "homeassistant", "url": "http://<ha address>:8123", "token": "<long-lived token>",
#     "entity": "switch.<plug>", "offSeconds": 30 }
#   { "type": "shelly", "host": "<plug address>", "user": "", "password": "", "offSeconds": 30 }
#   "type": "tasmota" works like shelly.
#
#   pwsh -File plug-watch.ps1 -Once                 # one power cycle now
#   pwsh -File plug-watch.ps1 [-Log <serial.log>]   # watch the serial log and cycle on link-training failure
param(
  [string]$Log    = (Join-Path $PSScriptRoot 'serial.log'),
  [string]$Config = (Join-Path (Split-Path $Log) 'aipi-plug.json'),
  [switch]$Once,
  [int]$MinGapSeconds = 180,   # never cycle more often than this
  [int]$MaxPerHour = 3         # then stop and leave it to a human
)
$ErrorActionPreference = 'Stop'
$cfg = Get-Content $Config -Raw | ConvertFrom-Json
$off = if ($cfg.offSeconds) { [int]$cfg.offSeconds } else { 30 }

function Invoke-PowerCycle {
  switch ($cfg.type) {
    'shelly' {
      $uri = "http://$($cfg.host)/rpc/Switch.Set?id=0&on=false&toggle_after=$off"
      $p = @{ Uri = $uri; TimeoutSec = 10 }
      if ($cfg.user) { $p.Credential = New-Object PSCredential($cfg.user, (ConvertTo-SecureString $cfg.password -AsPlainText -Force)) }
      Invoke-RestMethod @p | Out-Null
    }
    'tasmota' {
      $cmd = [uri]::EscapeDataString("Backlog Power Off; Delay $($off * 10); Power On")
      $auth = if ($cfg.user) { "&user=$([uri]::EscapeDataString($cfg.user))&password=$([uri]::EscapeDataString($cfg.password))" } else { '' }
      Invoke-RestMethod -Uri "http://$($cfg.host)/cm?cmnd=$cmd$auth" -TimeoutSec 10 | Out-Null
    }
    'homeassistant' {
      $base = $cfg.url.TrimEnd('/'); $h = @{ Authorization = "Bearer $($cfg.token)" }
      $body = @{ entity_id = $cfg.entity } | ConvertTo-Json
      function Ha($svc) { Invoke-RestMethod -Method Post -Uri "$base/api/services/switch/$svc" -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 15 | Out-Null }
      function HaState { (Invoke-RestMethod -Uri "$base/api/states/$($cfg.entity)" -Headers $h -TimeoutSec 15).state }
      Ha 'turn_off'
      Start-Sleep -Seconds $off
      # Power must come back: retry turn_on for up to 10 minutes until HA reports the switch on.
      $deadline = (Get-Date).AddMinutes(10); $ok = $false
      while (-not $ok -and (Get-Date) -lt $deadline) {
        try { Ha 'turn_on'; Start-Sleep -Seconds 3; $ok = (HaState) -eq 'on' } catch { Write-Warning "turn_on failed: $($_.Exception.Message)" }
        if (-not $ok) { Start-Sleep -Seconds 10 }
      }
      if (-not $ok) {
        $msg = "=== $(Get-Date -Format s) plug-watch: *** FAILED TO TURN aiPi BACK ON via $($cfg.entity); it is probably still OFF ***"
        $msg | Add-Content -Path $Log -Encoding utf8; Write-Host $msg -ForegroundColor Red
        try { [console]::beep(880, 1500) } catch {}
        throw 'power not restored'
      }
    }
    default { throw "unknown plug type '$($cfg.type)'" }
  }
  "=== $(Get-Date -Format s) plug-watch: power-cycled aiPi ($off s off, $($cfg.type))" | Add-Content -Path $Log -Encoding utf8
}

if ($Once) { Invoke-PowerCycle; return }

$history = New-Object System.Collections.Generic.List[datetime]
Write-Host "Watching $Log for NIC link-training failures (Ctrl+C to stop)"
Get-Content -Path $Log -Wait -Tail 0 | ForEach-Object {
  if ($_ -match 'Root Port [23]: Link Up Fail') {
    $now = Get-Date
    $history.RemoveAll({ param($t) $t -lt $now.AddHours(-1) }) | Out-Null
    if ($history.Count -and ($now - $history[-1]).TotalSeconds -lt $MinGapSeconds) { return }
    if ($history.Count -ge $MaxPerHour) {
      "=== $(Get-Date -Format s) plug-watch: $MaxPerHour cycles in the last hour, not cycling again" | Add-Content -Path $Log -Encoding utf8
      return
    }
    $history.Add($now)
    Start-Sleep -Seconds 2   # let the firmware finish printing
    try { Invoke-PowerCycle } catch { Write-Warning "power cycle failed: $($_.Exception.Message)" }
  }
}
