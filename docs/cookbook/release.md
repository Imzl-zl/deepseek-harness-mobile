# 发版（插件 + APK）

推一个 `v*` 标签，`.github/workflows/release.yml` 出两个产物并挂到 GitHub Release：
`dsh-mobile-connector-<version>.tgz` 与 `dsh-mobile-<tag>.apk`。

## 1. 版本号在哪

- 插件：`connector/package.json` 的 `version`（打包名与它一致）。
- App：`app/pubspec.yaml` 的 `version: 1.0.0+1`。CI 用 `--build-name="${tag#v}"`
  与 `--build-number=$GITHUB_RUN_NUMBER` 覆盖，所以**发版时只认标签**。
- 标签：`v1.2.3`（不要带 `v` 以外的修饰）。

## 2. 签名（Android 必须，开源项目也一样）

Android 要求所有 APK 都带签名。"开源不签名"是误会：开源项目一般由维护者**自己**签，
把密钥放进 CI Secrets；F-Droid 则是用它自己的密钥重新构建并签名。**debug 签名的包
能装，但换机器/换 CI 就签名不一致，装不上更新**，所以只适合试用。

### 生成一次（脚本，口令不进命令行）

```powershell
pwsh -File app/tools/android-signing.ps1                 # 生成密钥 + key.properties
pwsh -File app/tools/android-signing.ps1 -SetSecrets      # 顺手写四个 GitHub Secrets
```

脚本做的事：读口令（`Read-Host -AsSecureString`，只活在这一个进程里）→ 用
`keytool -storepass:env` 生成 `app/android/app/release.jks` → 写 `app/android/key.properties`
（本机 `flutter build apk --release` 用）→ 打印证书摘要 → 可选地把四个 Secrets 写进仓库。
两个产物都在 `.gitignore` 里；提交前 `git status` 看一眼。

手动等价命令（不想跑脚本时）：

```bash
keytool -genkeypair -v -keystore app/android/app/release.jks -alias dsh-mobile \
  -keyalg RSA -keysize 4096 -validity 36500
```

**这个文件丢了，就再也无法覆盖升级**（用户只能卸载重装）。备份两处：密码管理器 + 离线。

| Secret | 内容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `release.jks` 的 base64 |
| `ANDROID_STORE_PASSWORD` | keystore 口令 |
| `ANDROID_KEY_PASSWORD` | key 口令（一般同上） |
| `ANDROID_KEY_ALIAS` | `dsh-mobile` |

### CI 怎么用

`release.yml` 的"写入签名配置"一步：有 `ANDROID_KEYSTORE_BASE64` 就把密钥解码到
`app/android/app/release.jks` 并写 `app/android/key.properties`；没有就跳过。
`app/android/app/build.gradle.kts` 里 `key.properties` 存在就用 release 签名，否则退到 debug。

本机想验证签名构建：把 `.jks` 放到 `app/android/app/`，在 `app/android/` 写
`key.properties`（`storeFile=release.jks` + 三个口令），然后 `flutter build apk --release`。
两个文件都在 `.gitignore` 里。

## 2.5 发布插件到 npm

包名 **`dsh-mobile-connector`**（不带 scope：与本仓其他插件包 `dsh-*` 一致，也不需要建 npm 组织）。
`connector/package.json` 已去掉 `private`，`publishConfig.access = public`，`prepack` 先构建。

### 首次发布：staged publish（不需要命令行 OTP）

npm 的**可信发布（OIDC）不能发一个新包的第一个版本**（[npm/cli#8544](https://github.com/npm/cli/issues/8544)）。
但 npm 现在有 **staged publish**：`npm stage publish` 不需要终端里的 6 位 OTP，
发布后**在网页上审批**（那一步用 2FA/安全密钥）即可。账号只有安全密钥（WebAuthn）时，
这是唯一顺畅的引导路径（本包 0.0.0-stage 与 0.1.0 就是这么发的）。

### 然后：配可信发布，之后 CI 全自动

https://www.npmjs.com/package/dsh-mobile-connector/access → Add Trusted Publisher：
Publisher `GitHub Actions`、organization or user `Imzl-zl`、repository
`deepseek-harness-mobile`、workflow filename `publish-connector.yml`，勾 **Allow npm publish**。
建好是 `Pending validation`，**用一次 OIDC 发布即转 `Valid`**（本仓用 0.1.1 验的）。

### 之后每次发版

改 `connector/package.json` 的 `version` → `git tag connector-vX.Y.Z` → push。
流水线校验 `标签 == version`，用 OIDC 发布并带 **provenance（SLSA v1）**，不需要任何 token。

## 3. 插件包

`connector` 是 DSH 插件（`dsh.bundle.patch` 指向 `cordis.patch.yml`），发版产物就是
`pnpm pack` 出来的 `.tgz`。发之前确认 `peerDependencies` 里的 DSH 版本与目标宿主一致
（现在是 `0.2.1-rc.3`）。

## 4. 本地先跑一遍门禁

```bash
node protocol/verify-fixtures.mjs && node protocol/verify-loopback.mjs && node protocol/verify-vectors.mjs
cd relay && pnpm typecheck && node --test
cd connector && pnpm exec tsc --noEmit && pnpm build && pnpm test
cd app && dart analyze --fatal-infos lib test integration_test && flutter test
```

CI（`.github/workflows/ci.yml`）跑的是同一组命令；标签构建前它必须绿。

## 5. 上线这一步之后

- 中转与插件是**独立升级**的：中转先升、插件后升（`?id=` 必带，旧连接器会被 403）。
- App 升级只看 `versionCode`（CI 用 run number，单调递增）。
