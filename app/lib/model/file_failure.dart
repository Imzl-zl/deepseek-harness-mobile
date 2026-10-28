/// 文件预览失败的那一句话 ——**按码换文案，不打印宿主的英文原文**。
///
/// ## 判据出处
///
/// 桌面 `ui-sidebar-documentpreview` 的 `failureLine()`
/// （`packages/client/ui-sidebar-documentpreview/src/client/failure-line.ts:24-35`）：
///
/// | 码 | 文案（zh） | 动作 |
/// |---|---|---|
/// | `workspace-file/not-found` | `找不到这个文件`（`locales.ts:27`） | 无（`emptyFailureRecourse` → `none`） |
/// | `workspace-file/too-large` | `单页内容超过 {limit} 上限，无法读取` | 建议用外部程序打开（`open`） |
/// | `workspace-file/not-text` | `该格式文件暂时无法预览` | 同上 |
/// | `workspace-file/not-regular-file` | `该路径不是普通文件，没有可显示的内容` | 无 |
/// | 其它 | `读取失败：{宿主原文}` | 重试（`retry`） |
///
/// 手机没有"用外部程序打开"这条能力（那是桌面把文件交给本机程序，`ui-open-in-app`），
/// 所以对前两类**只说不能预览**，不假装能打开。
///
/// ## 为什么放在 `model/`
///
/// 它是纯映射（码 + 原话 → 一句中文），没有 IO、不认识 `AppModel`，
/// 于是"文案只有一处"这件事可以被一条纯 Dart 用例钉住。
///
/// Note: 四个码为什么必须进封闭表、以及被否的"按英文猜码"方案，见
/// `.agents/notes/implemented/2026-10-28-file-preview-error-codes.md`。
library;

import '../core/errors.dart';

/// 文件读取失败该显示的那句话。
///
/// [code] 为 `null`（老连接器把码归成了 `internal` 之外的情况）或不在四类里时，
/// 退回宿主原话 —— 与桌面 `error.unavailable` 的 `读取失败：{message}` 同一条。
String fileFailureText(ErrorCode? code, String? message) {
  switch (code) {
    case ErrorCode.workspaceFileNotText:
      return '该格式文件暂时无法预览';
    case ErrorCode.workspaceFileTooLarge:
      // 桌面的文案里带 `{limit}`（`humanBytes(details.limit)`）；我们的异常不带
      // details，所以只说"超过上限"，不编一个具体数字。
      return '单页内容超过上限，无法读取';
    case ErrorCode.workspaceFileNotFound:
      return '找不到这个文件';
    case ErrorCode.workspaceFileNotRegularFile:
      return '该路径不是普通文件，没有可显示的内容';
    case null:
      return message ?? '读取文件失败';
    default:
      // **其它码保留宿主原话**：桌面也是 `读取失败：{message}`
      // （`error.unavailable`，`:33`）—— 我们这句前缀就是简体中文的同一句。
      return message == null || message.isEmpty ? '读取文件失败' : '读取失败：$message';
  }
}
