# 生成 Android 发版签名（一次性），并可选把四个 GitHub Secrets 写好。
#
#   pwsh -File app/tools/android-signing.ps1                 # 只生成 keystore + key.properties
#   pwsh -File app/tools/android-signing.ps1 -SetSecrets      # 顺手写 GitHub Secrets（需要 gh 已登录）
#
# 它产生两个**永不进库**的文件（`.gitignore` 已挡）：
#   app/android/app/release.jks        密钥本体（丢了就再也无法给已装用户升级）
#   app/android/key.properties         本机构建用的口令与别名（CI 上由 Secrets 现场生成）
#
# 为什么不用 `-storepass` 直接写命令行：那会出现在进程列表里。这里用 keytool 的
# `-storepass:env` 走环境变量，跑完立刻清掉；口令只在这一次进程里存在。

[CmdletBinding()]
param(
  [string]$Alias = 'dsh-mobile',
  [string]$Dname = 'CN=dsh-mobile, OU=release, O=Imzl-zl, C=CN',
  [int]$ValidityDays = 36500,
  [switch]$SetSecrets,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$androidDir = Join-Path $repoRoot 'app\android'
$keystore = Join-Path $androidDir 'app\release.jks'
$properties = Join-Path $androidDir 'key.properties'
$secretsRepo = 'Imzl-zl/deepseek-harness-mobile'

if (-not (Get-Command keytool -ErrorAction SilentlyContinue)) {
  throw '找不到 keytool：装一个 JDK（17 即可）并把它加进 PATH'
}
if ((Test-Path $keystore) -and -not $Force) {
  throw "已经有 $keystore。真要重新生成就加 -Force（注意：换了密钥，老用户就装不上更新了）"
}

function Read-Password([string]$prompt) {
  $secure = Read-Host -AsSecureString $prompt
  return [System.Net.NetworkCredential]::new('', $secure).Password
}

$storePass = Read-Password 'keystore 密码（至少 6 位，记牢并备份）'
if ($storePass.Length -lt 6) { throw 'keystore 密码至少 6 位' }
$keyPass = Read-Password 'key 密码（直接回车 = 与 keystore 相同）'
if ([string]::IsNullOrEmpty($keyPass)) { $keyPass = $storePass }

$env:DSH_KS_PASS = $storePass
$env:DSH_KEY_PASS = $keyPass
try {
  Write-Host "生成 $keystore ..."
  & keytool -genkeypair -v -keystore $keystore -alias $Alias `
    -keyalg RSA -keysize 4096 -validity $ValidityDays -dname $Dname `
    -storepass:env DSH_KS_PASS -keypass:env DSH_KEY_PASS
  if ($LASTEXITCODE -ne 0) { throw "keytool 失败（exit $LASTEXITCODE）" }

  # 本机构建用：Flutter 的 gradle 读 android/key.properties（storeFile 相对 app 模块）。
  $lines = @(
    "storePassword=$storePass"
    "keyPassword=$keyPass"
    "keyAlias=$Alias"
    'storeFile=release.jks'
  )
  Set-Content -Path $properties -Value ($lines -join [Environment]::NewLine) -Encoding utf8
  Write-Host "已写 $properties"

  Write-Host ''
  & keytool -list -v -keystore $keystore -storepass:env DSH_KS_PASS | Select-String -Pattern 'Alias name|Valid from|Signature algorithm|Subject:' | ForEach-Object { $_.Line.Trim() }

  if ($SetSecrets) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw '找不到 gh（GitHub CLI）：先装好并 gh auth login' }
    Write-Host ''
    Write-Host "写入 $secretsRepo 的四个 Secrets ..."
    # 走标准输入（gh 不指定 --body 时读 stdin）：值不进命令行、不进 shell 历史。
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($keystore))
    $b64 | gh secret set ANDROID_KEYSTORE_BASE64 --repo $secretsRepo
    $storePass | gh secret set ANDROID_STORE_PASSWORD --repo $secretsRepo
    $keyPass | gh secret set ANDROID_KEY_PASSWORD --repo $secretsRepo
    $Alias | gh secret set ANDROID_KEY_ALIAS --repo $secretsRepo
    Write-Host '四个 Secrets 已写入（值没有打印、也没有进 shell 历史）'
  }
} finally {
  Remove-Item Env:\DSH_KS_PASS -ErrorAction SilentlyContinue
  Remove-Item Env:\DSH_KEY_PASS -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '完成。两件事必须做：'
Write-Host '  1. 把 release.jks 与两个密码备份到密码管理器 / 离线介质 —— 丢了就永远无法给已装用户升级。'
Write-Host '  2. 别提交 release.jks / key.properties（.gitignore 已挡，提交前 git status 看一眼）。'
Write-Host '之后打标签即出正式签名包：git tag v0.1.1 && git push origin v0.1.1'
