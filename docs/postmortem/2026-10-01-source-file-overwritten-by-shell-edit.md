# 事故:用 shell 字符串手术改源码,把文件写成空的

日期:2026-10-01
影响:无(未提交,`git checkout --` 恢复后重做)
性质:工具使用事故,**同类第二次**

## 发生了什么

改 `connector/src/transport/codec.ts`(把重复的帧类型清单收敛成别名)时,用 PowerShell 做替换:

```powershell
$t=Get-Content $p -Raw
$t=$t.Replace自然是; Set-Content $p $t -NoNewline
```

替换表达式(当时想写的是一个长字符串替换)语法就不成立 → `$t` **从未被赋值**;
`Set-Content $p $null` 于是把 6858 字节的源文件写成 **0 字节**。
`git status` 里它仍显示为 ` M`(已修改),不细看不会发现内容已经没了。

## 为什么没造成损失

- 改动还没提交,`git checkout -- src/transport/codec.ts` 一条命令恢复;
- 同批的其它改动都在别的文件里,没有被牵连;
- 恢复后立刻跑 `tsc --noEmit` 与 `pnpm test`,确认回到 178 项全绿再继续。

## 第一次是什么

更早的一次:错误的 PowerShell 变更命令造出一个**空的新文件** `connector/src/protocol/connection.ts`,
并且被 `git add -A` 顺手提交了(同样是字符串手术的产物;见当时的 `git rm --cached` + `--amend` 处置)。

## 结论(已沉淀成规则)

1. **改源码只用编辑工具**(本仓库的 `edit` / `write`),不用 shell 的字符串替换。
   shell 适合跑命令与验证,不适合改代码:它出错时是**静默**的,而编辑工具会报「没找到」。
2. **提交前必须看 `git status` 的完整清单**,特别是有没有**意外的文件**(空的、消失的、没见过的新文件)——
   两次事故都能被这一步拦住,因为两次的产物在状态列表里都长得不像"正常改动"。
3. 写完立刻跑一次最窄的检查(`tsc --noEmit` 或对应测试文件),别等全部改完再跑:
   一旦文件被写坏,越早发现越省事。
