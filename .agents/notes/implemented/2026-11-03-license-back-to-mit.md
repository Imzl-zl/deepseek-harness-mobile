# 协议改回 MIT（放弃"禁止商用"）

- 日期：2026-11-03
- 触发：用户「那你全开源算了真麻烦」—— 非商用协议带来的摩擦大于收益
- 状态：implemented
- 取代：`.agents/notes/archived/2026-11-03-license-polyform-noncommercial.md`

## 背景

同一天早些时候把协议从 MIT 换成了 PolyForm Noncommercial 1.0.0（理由："不能商用、
其余自由"）。落地过程中出现三类摩擦：

1. **不是 OSI 开源**：GitHub 的协议识别、企业合规扫描、发行版打包都把它归到
   "source-available"，别人公司里用会被工具标红；
2. **换协议要动三处**：根 `LICENSE`、`connector/LICENSE`（npm 包随附的副本）、
   `package.json` 的 `license`；首次就漏了副本（0.1.17），又补发 0.1.18；
3. **商用还得单独授权**：等于给自己留了一个长期要回答的客服入口。

## 决定

**改回 MIT**（`LICENSE`、`connector/LICENSE`、`connector/package.json`、两份 README
全部回退），版本发 `0.1.19`。

## 被否掉的

- **Apache-2.0**：同样是 OSI 开源、还带专利授权，比 MIT 更"企业友好"。但本项目当前
  没有专利诉求，多出来的 NOTICE 义务对使用者是负担 —— 用户要的是"省事"，MIT 更短。
- **AGPL-3.0**（开源但传染：改了/拿去做在线服务必须开源）：最接近原来"防别人白嫖"的
  意图，但它是**最麻烦**的那一档 —— 与用户此刻的诉求（省事）正相反。
- **保持 PolyForm、只是补好副本**：用户的判断是这套限制本身不值当，不是"没配好"。

## 代价

- **0.1.17 / 0.1.18 收不回来**：那两个版本的 tarball 是在 PolyForm 状态下发的，
  拿到的人对**那两个版本**仍适用 PolyForm。README 里写了一句，避免以后被当矛盾。
- 任何人现在都可以把这份代码拿去做闭源产品并商用 —— 这是 MIT 的本意，不是疏漏。

## 落地

- `LICENSE` / `connector/LICENSE`：MIT 正文（两者逐字相同，`connector/tests/license.test.ts` 盯着）。
- `connector/package.json`：`"license": "MIT"`。
- README 徽章与 License 小节回到 MIT，并保留一句"0.1.17/0.1.18 当时是 PolyForm"。
- `connector/tests/license.test.ts` 的协议断言同步改成 MIT —— 故意保留这条硬编码：
  下次换协议必须显式改它，不会被"只改一半"蒙混过去。
