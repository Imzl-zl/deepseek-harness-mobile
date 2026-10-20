# Agent Note: 图片附件这条链做真了（系统照片选择器 + 自写通道，零依赖）

Status: implemented

## Problem

两条用户反馈合起来是同一件事：

1. 2026-10-19：「比人家的上传点击弹框有拍照，图片，上传文件啥的」；
2. 2026-10-20：`＋` 的「附件」原先加一枚**假芯片**
   （`PendingAttachment('新增文件.txt')`），而 `_send()` 的 `content` 只有文本块
   —— **附件被静默丢弃**（已单独记在
   `2026-10-20-remove-fake-attachment.md`）。

拔掉假的那条之后，真的一条现在补上了。

## 调查：我之前把一个"未来目标"当成了当前约束

上一轮我判"卡在 picker 依赖"，理由是"鸿蒙 fork 可能编不过"。2026-10-20 核实：

- `app/` 下只有 `android/` / `ios/` / `windows/` —— **没有 `ohos/` 工程**
  （也没有 `oh-package.json5` / `build-profile.json5` / `hvigorfile.ts` / `*.hap`）。
- 鸿蒙是 `memory.md` 里"前置事实"记的**未来目标**（Flutter 版本上界为它留着），
  不是一个今天会被破坏的构建。

**所以引不引第三方插件，风险与我原来说的不同**：真正的风险不是"破坏鸿蒙"，
而是"把鸿蒙能不能编过交给别人的发布节奏"。既然本仓已有**自写平台通道**的先例
（`dsh/gesture-exclusion`，2026-10-16），选图也照这个模式做 —— **零 pub 依赖**，
既没有版本冲突，也不欠鸿蒙什么。

## DSH 侧的权威形状（决定了这条链怎么做）

`packages/api/session-controller/src/types.ts:90-98`：

```ts
export type PromptContentPart =
  | { readonly type: 'text'; readonly text: string }
  | { readonly type: 'image'; readonly mediaType: ImageMediaType
      readonly data: string; readonly name?: string }
  | { readonly type: 'file'; readonly receiptId: Branded<'file-upload-receipt-id'> }
```

原注释（`:86-89`）："Browser-submitted prompt content; the Host promotes image
bytes to durable references."

- **图片 = 内联 base64 直发**，**不需要先上传** → 这条链可以闭环；
- **文件 = 要 `receiptId`**，来自一次 `uploadFile` → 那是另一个方法面，
  本仓未接，**所以「上传文件」不做**（摆了就是又加一排假入口）；
- `ImageMediaType` = `'image/png' | 'image/jpeg' | 'image/webp' | 'image/gif'`
  （`attachment/src/types.ts:8`）。

## Decision

### 1. 原生侧：系统照片选择器，**不申请任何权限**

`MainActivity.kt` 新增 `dsh/photo-picker` 通道：

- **API 33+ 用 `MediaStore.ACTION_PICK_IMAGES`**（系统照片选择器，
  官方说它取代 `READ_MEDIA_IMAGES`，**不需要权限**，且只交回用户选中的那一张）；
- API 33 以下退 `ACTION_GET_CONTENT`（SAF，同样**不需要权限**）。

两条路都不申请权限 ⇒ `AndroidManifest.xml` 一行没加，也没有
`requestPermissions` —— 少一个用户会被弹窗打扰的地方。

字节**立刻读成 base64** 回给 Dart：`content://` 的读权限只在这段回调窗口内有效，
而 DSH 要的正是 base64。读字节在后台线程（几 MB 的图会卡帧）。

`FlutterActivity extends Activity`（不是 `ComponentActivity`，实测 SDK 源码
`engine/src/flutter/shell/platform/android/io/flutter/embedding/android/
FlutterActivity.java`），拿不到 `registerForActivityResult` ⇒ 用
`startActivityForResult` + `onActivityResult`，并把 `MethodChannel.Result`
存起来（它只能被调用一次）。

### 2. Dart 侧：只做"校验形状"，业务判断可测

`lib/platform/photo_picker.dart`（与 `gesture_exclusion.dart` 同一层）：

- `parsePhotoPickReply(Object?)` —— **纯函数**：`null` = 取消；
  形状不对 = 失败（**与取消分开**：混在一起会让"点了没反应"查不出来）；
  媒体类型不在四个之内 = `PhotoPickUnsupportedType`；
- `pickPhoto({invoke})` —— 通道调用，`MissingPluginException` → `unavailable`，
  `PlatformException` → `failed`（带原生原话）。

### 3. 载荷由一个纯函数决定

`dsh_composer.dart` 的 `promptContentOf({text, attachments})`：
图片在前、文本在后；**只有带图片的附件才进 content**
（`PendingAttachment.isInert` 的那些留在输入栏，不假装发出去）。

### 4. `＋` 菜单：「照片」是真入口，「上传文件」不做

图标用 `paperclip`：DSH 与我们的图标集里都**没有** image/photo/camera
那一枚（`ui-primitives/src/icons/index.tsx` 只有 folder 系列），
而图标集是机生成的、不许手写 —— 用已有的"附件"字形 + 文案说清。

### 5. 「拍照」也做了 —— 但它比相册麻烦，因为**本 App 已经声明了 CAMERA**

`AndroidManifest.xml:4` 早就为**配对页的扫一扫**声明了 `CAMERA`。
而 Android 的规矩是（`MediaStore.ACTION_IMAGE_CAPTURE` 官方文档原话）：

> If your app declares the `CAMERA` permission, then `ACTION_IMAGE_CAPTURE`
> requires that permission to be granted, otherwise a `SecurityException`
> is thrown.

所以拍照**必须先有权限**：`startCameraPick` 先 `checkSelfPermission`，
没授予就 `requestPermissions` 并挂起回包，`onRequestPermissionsResult`
里授予了才发 intent、否则回 `camera-permission` 错误（Dart 侧单独一种结果
`PhotoPickPermissionDenied` —— 它的恢复动作是"去系统设置开"，不是重试）。

`EXTRA_OUTPUT` 走 **`FileProvider`**（`cacheDir/dsh_photo/`）：
- API 24+ 给 `file://` 会抛 `FileUriExposedException`，必须 `content://`；
- 所以加了 `res/xml/dsh_file_paths.xml`（**只暴露那一个子目录**）、
  清单里一个 `<provider>`（`authorities="${applicationId}.dshfileprovider"`，
  用 `${applicationId}` 让 debug/release 不撞名）；
- 另外给了 `clipData = ClipData.newRawUri(...)` —— 有些机型只认 clipData 里的授权；
- 临时文件**读完即删**（它只是 `EXTRA_OUTPUT` 的落盘中转）。

**新增了一个 Gradle 依赖**（本仓第一个手写 Android 依赖）：
`implementation("androidx.core:core:1.13.1")` —— `FileProvider` 在它里面，
Flutter 的 embedding 不带。取 1.13.1 而不是最新：与
`flutter.compileSdkVersion`（36）兼容的常用稳定版，不追新
（追新只会让"下次构建能不能过"变成运气问题）。
**实测构建通过**（`flutter build apk --debug` 成功，装机启动无异常）。

## 自查抓到的一个真 bug：只要文字、漏了附件

2026-10-20 自查（"选了照片却不打字"会怎样）发现两处**状态判据只看文字**：

```dart
final canSend = enabled && !sending && hasDraft;   // hasDraft 只看 controller.text
if (text.isEmpty || _sending) return;              // _send() 也只看文字
```

于是**选了照片但没打字 → 发送键是灰的、点下去什么都不发生**。
而"只发一张图"是完全正常的用法（DSH 的 `content` 本来就是 part 数组，
可以没有文本 part）。

修法三条：

1. `canSend` 的判据改成 `hasText || hasImage`，而 `hasImage` 只数
   **可发送**的（`!isInert`）—— 只有名字的芯片不算草稿，
   否则点亮发送键会发出一个什么都没带的消息；
2. `_send()` 的早退同样改成 `text.isEmpty && !hasImage`；
3. `promptContentOf` **空文本不发那一段** ——
   `{type:'text', text:''}` 对电脑侧只是噪音。

判据：`composer_layout_test.dart` 新增两条（挂图不打字 → 发送键可点、
点下去真回调 / 惰性附件 → 不许点亮）；
`photo_attachment_test.dart` 新增一条（空文本 + 一张图 → content 里**没有**
text part）。**一处变异验证**：把 `canSend` 退回只看文字 → 1 条红。

## Alternatives considered（否掉的）

- **引 `image_picker` / `file_picker`**：把"鸿蒙能不能编过"交给别人的发布节奏；
  而这两个能力在 Android 侧各只有几十行。否。
- **申请 `READ_MEDIA_IMAGES` / `CAMERA` 再自己扫相册**：系统照片选择器
  已经不需要权限，申请权限只是给用户加一个弹窗。否。
- **做「上传文件」**：要 `uploadFile` 换 `receiptId`，本仓未接 ——
  摆了就是假入口。否。
- **在原生侧过滤媒体类型**：DSH 只认四个，但"哪些该拒"是业务判断，
  放 Dart 侧才可单测。否（放在 Dart）。

## Consequences

- 收益：图片附件从"假芯片静默丢弃"变成真的发得出去（内联 base64）；
  Android 侧零新增依赖、零新增权限。
- 代价：`MainActivity.kt` 从 58 行涨到约 210 行（两个通道）；
  `PendingAttachment` / `PickedImagePart` 两个新类型；
  iOS / Windows **没有实现**（通道不存在 ⇒ 点「照片」会说
  "这台设备上没有可用的相册选择器"，而不是静默无反应）。
- 测试：`photo_attachment_test.dart` 14 项 —— 解析四种结果分开、
  四个受支持类型（含大写）、形状不对报失败、byteCount 估算、
  平台没有 / 原生报错 / 成功三条通道路径、
  载荷形状（图片在前 / 无名字不带 `name` 键 / **惰性附件不进 content** / 多图顺序）。
  **一处变异验证**：把"空名字不带 `name`"改成永远带 → 1 条红。
  `flutter test 855` 全绿。
- **真机状态**：APK 构建通过（Kotlin 编过、通道注册进去）；
  但**端到端未验** —— 未配对时输入栏是置灰的（`enabled: paired && sid != null`），
  `＋` 点不开，所以"点照片 → 相册 → 芯片 → 发送"要等配对后再看。
  判据：`＋` → 照片 → 系统相册浮出 → 选一张 → 输入栏出现芯片 →
  发送后该消息气泡旁显示附件计数。
