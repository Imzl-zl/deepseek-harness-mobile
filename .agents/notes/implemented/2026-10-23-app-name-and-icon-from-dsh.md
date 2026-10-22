# Agent Note: 应用名取 `DSH`，图标取 DSH 桌面端那枚鲸鱼

Status: implemented

## Problem

用户 2026-10-23：「这个软件图标换成 dsh 的图标，名字你看叫啥好啊，
要和 deepseek-harness 相关包含它但又不能很长」。

现状：安卓 `android:label="dsh_mobile"`（开发者味、带下划线）、图标是
`flutter create` 的默认 Flutter 图标（五档 PNG 都是 0.4–1.4 KB 的占位）。

## Decision

1. **名字 = `DSH`**，三处同口径：安卓 `android:label`、iOS `CFBundleDisplayName`、
   `MaterialApp.title`。理由：
   - 它是 **DeepSeek Harness** 的缩写，与仓库里既有的称呼完全一致
     （`dsh-mobile` / `DSH_HOME` / profile 名 `dsh-mobile-test`）；
   - 三个字母，启动器里不会被截断，也不占图标下方的第二行；
   - 备选「Harness」（7 字母，更像个产品名）与「DSH Mobile」（10 字母，与桌面端区分开）
     都没有采用：前者会让"这是桌面端本身"的错觉更重，后者是"缩写 + 通用词"的冗余。
2. **图标 = DSH 桌面端那枚鲸鱼**，源 `D:\sudy\github\deepseek-harness\apps\desktop\resources\icon.png`
   （1104×1104）：
   - legacy：`mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png` = 48/72/96/144/192，整枚缩放；
   - adaptive（API 26+）：`mipmap-anydpi-v26/ic_launcher.xml` +
     `mipmap-*/ic_launcher_foreground.png`（108/162/216/324/432），
     前景是**抠成透明底的鲸鱼**、居中占画布 66%（Android 的安全区），
     底色 `res/values/colors.xml` 的 `ic_launcher_background = #FFFFFF`。

## Alternatives considered

1. **名字用「DSH Mobile」**
   - 最强理由：与桌面端区分度最高，一看就知道是手机那端。
   - 为何被否：启动器里"缩写 + Mobile"是纯冗余（图标在手机上已经说明是移动端），
     而且用户要"不能很长"。与桌面端并列时靠图标区分即可。
2. **名字用「DeepSeek Harness」**
   - 最强理由：字面就是它，绝不会有歧义。
   - 为何被否：17 个字符，安卓启动器会把标签折行/省略，反而看不清。
3. **自己重画一枚图标（鲸鱼 + 手机轮廓之类）**
   - 最强理由：能表达"远程控制"这层意思。
   - 为何被否：用户明确要"dsh 的图标"；自绘还会引入"两枚品牌图"的问题 ——
     以后 DSH 换图标，手机端就跟不上了。
4. **把原图连白色圆角卡片一起塞进自适应图标的前景**
   - 最强理由：零处理，直接缩放。
   - 为何被否：自适应图标会被系统裁成圆形/方形/水滴形，白卡片会被裁掉一角；
     正确做法是"底色 + 抠出来的图形"。

## Consequences

- 收益：启动器、任务切换器、设置页的"应用信息"里都显示 `DSH` + 鲸鱼，
  与电脑端同一枚品牌图。
- 代价与注意：
  - 图标是**位图产物**，仓库里没有生成脚本（生成用的是 Python + Pillow 的一次性脚本，
    因为这两样不在本项目的工具链里）。要重做时的配方写在
    `docs/design-and-tech-plan.md` §1 与本节：
    源图 → 合成到白底（源 PNG 的透明区编码成黑色，直接 `convert("RGB")` 会得到黑边）→
    阈值 `<150` 抠出鲸鱼 → 前景按 66% 安全区居中；
  - `CFBundleName`（内部短名）仍是 `dsh_mobile`：那是构建标识，不是显示名，没动；
  - `debug` 与 `release` 共用同一套图标（没有按 buildType 分叉）。
- 判据：
  - `aapt2 dump badging` 的 `application-label:'DSH'` 与
    `application-icon-*:'res/mipmap-anydpi-v26/ic_launcher.xml'`；
  - 真机截图 `shots-2026-10-22/q1-launcher.png`（启动器里的图标与名字）。
