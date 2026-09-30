# 启动一个独立的 headless Chrome 用于原型验证,不占用/不影响日常浏览器。
# 用法:
#   pwsh -File mock/proto/tools/cdp.ps1                 # 默认端口 9400
#   pwsh -File mock/proto/tools/cdp.ps1 -Port 9401
# 说明:
#   - 9222 常被日常 Chrome 占用,探测会返回 `404 page not found`,所以默认避开它。
#   - 端口号与 user-data-dir 打印在末尾,供 verify-*.mjs 的 CDP_URL 使用。
#   - 用完直接 Ctrl+C 或关闭该进程;临时 profile 在 %TEMP%\proto-cdp-* 下,可随时删。
param(
  [int]$Port = 9400,
  [switch]$KeepOpen
)

$chrome = @(
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $chrome) { Write-Error 'no chrome/edge binary found'; exit 1 }

if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) {
  Write-Error "port $Port already in use; pick another with -Port"
  exit 1
}

$ud = Join-Path $env:TEMP ('proto-cdp-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$args = @(
  '--headless=new',
  "--remote-debugging-port=$Port",
  '--remote-allow-origins=*',
  "--user-data-dir=$ud",
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-gpu',
  '--disable-extensions',
  'about:blank'
)

if ($KeepOpen) {
  Start-Process -FilePath $chrome -ArgumentList $args -WindowStyle Hidden | Out-Null
} else {
  $p = Start-Process -FilePath $chrome -ArgumentList $args -PassThru -WindowStyle Hidden
}

for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 250
  if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) { break }
}

try {
  $v = (Invoke-WebRequest -UseBasicParsing -NoProxy "http://127.0.0.1:$Port/json/version" -TimeoutSec 5).Content | ConvertFrom-Json
  Write-Host "CDP ready on port $Port ($($v.Browser))"
  Write-Host "CDP_URL=http://127.0.0.1:$Port"
  Write-Host "user-data-dir=$ud"
  Write-Host ""
  Write-Host "然后跑任一验证(示例):"
  Write-Host "  `$env:CDP_URL='http://127.0.0.1:$Port'; `$env:NO_PROXY='127.0.0.1,localhost'; node mock/proto/tools/verify-proto.mjs"
} catch {
  Write-Error "CDP did not come up on $Port : $($_.Exception.Message)"
  exit 1
}
