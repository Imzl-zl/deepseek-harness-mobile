# 协议从 MIT 换成 PolyForm Noncommercial 1.0.0

- 日期：2026-11-03
- 触发：用户要求「不能商用、其它要自由」
- 状态：**已被取代** —— 同一天改回 MIT，见 `.agents/notes/implemented/2026-11-03-license-back-to-mit.md`

## 决定

仓库根 `LICENSE`、`connector/package.json`、两份 README 全部换成
**PolyForm Noncommercial License 1.0.0**（SPDX：`PolyForm-Noncommercial-1.0.0`），
正文照 SPDX 的 `licenseText` 逐字取（不改写、不摘要）。

效果：允许个人/研究/教学/慈善与公共机构使用，允许修改与再分发（须随附协议与
`Required Notice`），**禁止任何商业用途**。

## 被否掉的

- **CC BY-NC-SA 4.0**：名气最大，但 Creative Commons 自己**不建议**用于软件 ——
  它没有专利授权条款、没有源码分发与"修改后如何标注"的软件语义，
  配套的 NC 解释也不覆盖 SaaS 这类使用。同一个"非商用"诉求，PolyForm 是专为软件写的。
- **BSL / Elastic License**：那是"若干年后转开源"的源码可得许可，仍然允许一定商业使用
  （BSL 允许非生产用途），与"不能商用"不符。
- **自己写一段「禁止商用」**：自定义协议没有 SPDX id、npm 与依赖扫描器都读不懂，
  下游合规成本高，法律措辞也容易漏（衍生作品、SaaS、内部商用都算边界）。
- **连 GitHub 仓库可见性一起收（转私有）**：用户要的是"自由但不可商用"，不是"不给看"。

## 代价

- **不是 OSI 开源许可**了：GitHub 的 license 识别、部分包管理器/发行版打包会把它归到
  "source-available"。README 里已如实写明"不可商用"，不再自称开源。
- **不追溯**：`0.1.15` 及更早版本是按 MIT 发布的，已经拿到那些副本的人对**那些副本**
  仍然适用 MIT，协议变更管不到已发出的授权。README 里写了这一句，避免误解。
- 商用要单独授权 —— 意味着以后有人来问是正常的，得准备一句回话。

## 落地

- `LICENSE`：PolyForm 正文（首行保留 `Copyright (c) 2026 Imzl-zl`）。
- `connector/package.json`：`"license": "PolyForm-Noncommercial-1.0.0"`。
- **`connector/LICENSE` 是给 npm 包的副本**（`files` 里列了它），换协议时容易漏 ——
  0.1.17 就漏了：`package.json` 已写 PolyForm，而 tarball 里的 LICENSE 正文还是 MIT，
  对外授权文本自相矛盾。现在 `connector/tests/license.test.ts` 逐字比对副本与正本，
  漂移立刻红；随后补发 0.1.18 修正。
- 版本发到 **0.1.18**：0.1.16 是 MIT 状态下发的、0.1.17 的副本没换，元数据的事后修正
  只能靠新版本。
- `README.md` / `connector/README.md`：徽章与 License 小节同步，并写明不追溯。
