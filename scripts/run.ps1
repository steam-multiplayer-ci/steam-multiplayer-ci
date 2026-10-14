# steam-multiplayer-ci: install the Steam client, sign in a test account, run the command, collect logs, sign out.
# Inputs come from SMCI_* environment variables set by action.yml. Credentials are never printed and are removed
# from the environment before the command starts.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$out = Join-Path $env:RUNNER_TEMP ('smci-out-role-' + $env:SMCI_ROLE)
New-Item -ItemType Directory -Force -Path $out | Out-Null
$logFile = Join-Path $out 'smci.log'
function Log([string]$m) {
  $line = '[smci ' + (Get-Date).ToString('HH:mm:ss') + '] ' + $m
  Write-Host $line
  Add-Content -Path $logFile -Value $line
}
function SetOutput([string]$k, [string]$v) { Add-Content -Path $env:GITHUB_OUTPUT -Value ($k + '=' + $v) }
SetOutput 'out-dir' $out

$user = $env:SMCI_STEAM_USER
$pass = $env:SMCI_STEAM_PASS
[Environment]::SetEnvironmentVariable('SMCI_STEAM_USER', $null)
[Environment]::SetEnvironmentVariable('SMCI_STEAM_PASS', $null)
if ([string]::IsNullOrEmpty($user) -or [string]::IsNullOrEmpty($pass)) { throw 'steam-username and steam-password are required' }

$steamDir = Join-Path ${env:ProgramFiles(x86)} 'Steam'
$steamExe = Join-Path $steamDir 'steam.exe'
$cdpBase = 'http://127.0.0.1:8080'
$timing = [ordered]@{}

# ---------- CDP (the Steam client's own UI debug port, reachable only from this machine) ----------
function Invoke-Cdp([string]$wsUrl, [string]$expr, [int]$timeoutSec = 20) {
  $ws = [System.Net.WebSockets.ClientWebSocket]::new()
  $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($timeoutSec))
  try {
    $ws.ConnectAsync([Uri]$wsUrl, $cts.Token).GetAwaiter().GetResult()
    $msg = @{ id = 1; method = 'Runtime.evaluate'; params = @{ expression = $expr; awaitPromise = $true; returnByValue = $true } } | ConvertTo-Json -Depth 6 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
    $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
    $buf = New-Object byte[] 262144
    $sb = [Text.StringBuilder]::new()
    while ($true) {
      $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).GetAwaiter().GetResult()
      [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Count))
      if ($r.EndOfMessage) {
        $j = $sb.ToString() | ConvertFrom-Json
        if ($j.id -eq 1) { return $j.result.result.value }
        [void]$sb.Clear()
      }
    }
  } finally {
    try { $ws.Dispose() } catch {}
    $cts.Dispose()
  }
}
function Get-CdpTargets {
  try { return @(Invoke-RestMethod -Uri ($cdpBase + '/json') -TimeoutSec 5) } catch { return @() }
}
function Get-ActiveUser {
  try { return [int](Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam\ActiveProcess' -Name ActiveUser -ErrorAction Stop).ActiveUser } catch { return 0 }
}
function Save-Screen([string]$name) {
  try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $bmp.Save((Join-Path $out $name), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Log ('screenshot ' + $name + ' ' + $b.Width + 'x' + $b.Height)
  } catch { Log ('screenshot failed: ' + $_.Exception.Message) }
}
function Stop-Steam {
  try { if (Test-Path $steamExe) { Start-Process -FilePath $steamExe -ArgumentList '-shutdown' | Out-Null; Start-Sleep -Seconds 5 } } catch {}
  Get-Process -Name steam, steamwebhelper, steamservice -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

$exitCode = 125
try {
  # ---------- 1. install ----------
  $t = Get-Date
  if (-not (Test-Path $steamExe)) {
    $inst = Join-Path $env:RUNNER_TEMP 'SteamSetup.exe'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe' -OutFile $inst
    $sig = Get-AuthenticodeSignature -FilePath $inst
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Valve') { throw 'SteamSetup.exe is not validly signed by Valve' }
    Start-Process -FilePath $inst -ArgumentList '/S' -Wait
  }
  if (-not (Test-Path $steamExe)) { throw 'Steam did not install' }
  New-Item -ItemType File -Force -Path (Join-Path $steamDir '.cef-enable-remote-debugging') | Out-Null
  $timing['install_s'] = [int]((Get-Date) - $t).TotalSeconds
  Log ('steam installed in ' + $timing['install_s'] + ' s')

  # ---------- 2. start + sign in ----------
  $t = Get-Date
  Start-Process -FilePath $steamExe | Out-Null
  $loginWs = $null
  $deadline = (Get-Date).AddMinutes(12)
  while (-not $loginWs -and (Get-Date) -lt $deadline) {
    if ((Get-ActiveUser) -ne 0) { break }
    foreach ($tg in (Get-CdpTargets)) {
      if (-not $tg.webSocketDebuggerUrl) { continue }
      try { $has = Invoke-Cdp $tg.webSocketDebuggerUrl "!!document.querySelector('input[type=password]')" 5 } catch { $has = $false }
      if ($has -eq $true) { $loginWs = $tg.webSocketDebuggerUrl; break }
    }
    if (-not $loginWs) { Start-Sleep -Seconds 3 }
  }
  $timing['to_login_form_s'] = [int]((Get-Date) - $t).TotalSeconds
  if ($loginWs) {
    Log ('sign-in form found after ' + $timing['to_login_form_s'] + ' s')
    Save-Screen 'screen-signin.png'
    $u = ConvertTo-Json -InputObject $user -Compress
    $p = ConvertTo-Json -InputObject $pass -Compress
    $fill = @"
(() => {
  const U = $u, P = $p;
  const setv = (el, v) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };
  const pw = document.querySelector('input[type=password]');
  const name = [...document.querySelectorAll('input')].find(i => i !== pw && (i.type === 'text' || i.type === 'email'));
  if (!pw || !name) return 'no-fields';
  setv(name, U); setv(pw, P);
  const btn = document.querySelector('button[type=submit]');
  if (btn) { btn.click(); return 'submitted'; }
  return 'no-button';
})()
"@
    $res = Invoke-Cdp $loginWs $fill 15
    $fill = $null; $u = $null; $p = $null
    Log ('sign-in form: ' + $res)
  } elseif ((Get-ActiveUser) -eq 0) {
    throw 'sign-in form did not appear'
  }
  $deadline = (Get-Date).AddMinutes(4)
  while ((Get-ActiveUser) -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
  if ((Get-ActiveUser) -eq 0) {
    $why = 'unknown'
    if ($loginWs) {
      try {
        $txt = [string](Invoke-Cdp $loginWs 'document.body ? document.body.innerText : ""' 5)
        if ($txt -match '(?i)code|guard|authenticator') { $why = 'Steam asked for a verification code - turn off Steam Guard on the test account' }
        elseif ($txt -match '(?i)incorrect|check your password|not match') { $why = 'Steam rejected the account name or password' }
        elseif ($txt -match '(?i)too many') { $why = 'Steam is rate limiting sign-ins from this address' }
      } catch {}
    }
    throw ('not signed in after 4 minutes: ' + $why)
  }
  $timing['login_s'] = [int]((Get-Date) - $t).TotalSeconds
  SetOutput 'login-seconds' ([string]$timing['login_s'])
  Log ('signed in after ' + $timing['login_s'] + ' s (from starting the client)')
  $user = $null; $pass = $null

  # ---------- 3. run the command ----------
  $wd = (Resolve-Path -Path $env:SMCI_WORKDIR).Path
  $stdout = Join-Path $out 'stdout.txt'
  $stderr = Join-Path $out 'stderr.txt'
  $limitMs = [int]([double]$env:SMCI_TIMEOUT_MIN * 60000)
  Log ('run role ' + $env:SMCI_ROLE + '/' + $env:SMCI_ROLES + ' marker ' + $env:SMCI_RUN)
  $t = Get-Date
  $proc = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $env:SMCI_COMMAND) -WorkingDirectory $wd -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow -PassThru
  $null = $proc.Handle
  Start-Sleep -Seconds 8
  Save-Screen 'screen-running.png'
  if ($proc.WaitForExit([Math]::Max(1000, $limitMs - 8000))) {
    $exitCode = $proc.ExitCode
  } else {
    Log 'command timed out, stopping it'
    & taskkill.exe /PID $proc.Id /T /F | Out-Null
    $exitCode = 124
  }
  $timing['command_s'] = [int]((Get-Date) - $t).TotalSeconds
  Log ('command exit ' + $exitCode + ' after ' + $timing['command_s'] + ' s')

  # ---------- 4. collect ----------
  foreach ($pat in (($env:SMCI_LOG_PATHS -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    Get-ChildItem -Path (Join-Path $wd $pat) -File -ErrorAction SilentlyContinue | Copy-Item -Destination $out -Force
  }
} catch {
  Log ('error: ' + $_.Exception.Message)
} finally {
  # ---------- 5. sign out (revokes the remembered login) + stop Steam ----------
  try {
    if ((Get-ActiveUser) -ne 0) {
      $shared = (Get-CdpTargets) | Where-Object { $_.title -eq 'SharedJSContext' } | Select-Object -First 1
      if ($shared) {
        try { [void](Invoke-Cdp $shared.webSocketDebuggerUrl 'SteamClient.User.SignOutAndRestart(), "sent"' 5) } catch {}
        $d = (Get-Date).AddSeconds(20)
        while ((Get-ActiveUser) -ne 0 -and (Get-Date) -lt $d) { Start-Sleep -Seconds 1 }
        Log ('signed out: ' + ((Get-ActiveUser) -eq 0))
      } else { Log 'sign out skipped: client UI not reachable' }
    }
  } catch { Log ('sign out failed: ' + $_.Exception.Message) }
  Stop-Steam
  SetOutput 'exit-code' ([string]$exitCode)
  $sum = '### steam-multiplayer-ci role ' + $env:SMCI_ROLE + "`n`n| step | seconds |`n|---|---|`n"
  foreach ($k in $timing.Keys) { $sum += '| ' + $k + ' | ' + $timing[$k] + " |`n" }
  $sum += "`nexit code: " + $exitCode + "`n"
  Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $sum
}
exit $exitCode
