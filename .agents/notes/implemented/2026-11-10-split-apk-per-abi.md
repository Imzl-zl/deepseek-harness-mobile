# Agent Note: 发版 APK 按 ABI 拆开 —— 75 MB 里有两份是白下的

Status: implemented

## Problem

`release.yml` 一直只有一句 `flutter build apk --release`，出来的是一份**通用包**。
Flutter 的默认 target platform 是 `armeabi-v7a` + `arm64-v8a` + `x86_64`，所以这一个文件里
装了三份 Flutter 引擎（每份约 10 MB）+ 三份 `libapp.so`。

实测（`memory.md` 三次发版记录）：

| 版本 | APK 大小 |
|---|---|
| v0.2.13 | 78.8 MB |
| v0.2.14 | 78.79 MB |
| v0.2.15 | 75.14 MB |

而每台手机只用其中**一份**。`app/assets` 只有 36 KB（一枚 256 宽的鲸鱼图），所以这个体积
不是资源造成的，就是三份原生代码叠出来的。

后果：每一次安装/升级都要下 75 MB；用户的流量与等待时间是三倍；GitHub Release 的资产也占
三倍。**这是本项目唯一一个用户直接可感的量化指标，而它一直没被处理** —— 三次发版都在
`memory.md` 里记下了这个数字，却没人问"为什么这么大"。

## Decision

`flutter build apk --release --split-per-abi`，出三个包：

```
dsh-mobile-<tag>-arm64-v8a.apk     ← 2017 年之后的安卓机（几乎所有人），~30 MB
dsh-mobile-<tag>-armeabi-v7a.apk   ← 32 位老机，~28 MB
dsh-mobile-<tag>-x86_64.apk        ← 模拟器，~30 MB
```

准入的机械判据：

1. `release.yml` 的收集步骤**逐个 ABI 检查文件存在**，缺一个就红并列出目录
   —— 不允许"发一个少了包的版本"。产物名是 Flutter 定的，不是我们起的；
   升级 Flutter（版本闸门锁 3.41.9）后这里红了就说明产物名变了。
2. **不保留通用包**。留下的代价是它仍会被一部分人下到，换来只是"发布页少一次选择"。
3. **不改任何 App 代码**：`platform/update_checker.dart` 只问 `releases/latest` 的 `tag_name`
   比版本，不认资产名；「下载」开的是 `releases/latest` 页面。所以拆包与更新流程**无关**。

## Alternatives considered

1. **只出 arm64 一个**（`--target-platform android-arm64`）
   - 最强的理由：发布页仍然只有一个文件，体积同样降到 ~30 MB，用户不用选。
   - 为何被否：32 位机器会拿到一个**装不上的包，而且没有任何解释**（"应用未安装"）。
     三个包各自完整、选错也能自己纠正，比"少一个文件但有人装不上"好。
2. **三个包 + 一个通用包当兜底**
   - 最强的理由：谁都不会落单。
   - 为何被否：多一次完整构建（CI 时间翻倍），而兜底那份正是要被淘汰的 75 MB；
     而且"不确定就下通用包"会让大多数人继续下 75 MB，优化就白做了。
3. **出 AAB 交给商店**
   - 最强的理由：这是官方推荐的现代分发方式，商店会做按设备下发。
   - 为何被否：本项目**没有上架任何商店**（`memory.md` 的范围决定），APK 是 GitHub Release
     直发。AAB 在这里没有消费者。

## Consequences

- 收益：下载量从 ~75 MB 降到 ~30 MB（-60%）；Release 资产总量基本不变，但每个人只取自己那份。
- 代价：发布页从 1 个 APK 变成 3 个，下载的人要看一眼 CPU 架构。已在
  `docs/cookbook/release.md` §3.5 与 `README` 的安装表里写明"该下哪个"。
- 代价：`release.yml` 的收集步骤从一行 `cp` 变成逐个检查的循环。这是刻意的：
  通用包时路径写错会得到"文件不存在"，而拆包时有三个路径可写错，**漏一个的后果是
  某个架构永远拿不到新版本**，所以宁可让 CI 红。
- 未做：**体积门禁**。不同 ABI 的差异大、且随依赖变，钉一个数字会频繁误报。
  要看趋势就本地跑 `--analyze-size`（只出报告，不改结论），写在 `release.md` §4。
- 未做：`isMinifyEnabled` / `shrinkResources`。R8 对 Flutter 包的收益主要在 dex 与资源，
  而我们的 dex 大头是 Flutter 引擎的 Java 声明 —— 先看拆完之后的数字再决定要不要动
  （拆之前量，拆之后再量，才知道下一刀值不值）。
