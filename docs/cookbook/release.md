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

### 生成一次（在你自己的机器上）

```bash
keytool -genkeypair -v -keystore dsh-mobile.jks -alias dsh-mobile \
  -keyalg RSA -keysize 4096 -validity 10000
```

口令自己定。**这个文件丢了，就再也无法覆盖升级**（用户只能卸载重装）。备份两处。

### 放进 GitHub Secrets（三个 + 一个 base64）

把 `.jks` 转成 base64 再上传（仓库 Settings → Secrets and variables → Actions）：

```powershell
# Windows / PowerShell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("dsh-mobile.jks")) | Set-Clipboard
```

| Secret | 内容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | 上面那段 base64 |
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

`connector/package.json` 已去掉 `private`，`publishConfig.access = public`，`prepack` 会先构建。

1. 改 `connector/package.json` 的 `version`（如 `0.2.0`）
2. 打标签：`git tag connector-v0.2.0 && git push origin connector-v0.2.0`
3. `.github/workflows/publish-connector.yml` 校验 `标签 == version` 后 `npm publish`

**前置**：仓库 Secrets 里的 `NPM_TOKEN`（npm 的 Automation token），且你的 npm 账号拥有
`@dsh-mobile` 这个 scope（没有就先在 npm 建 org，否则发布会 403）。没有 token 时那一步
会明确失败，不会静默跳过。

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
