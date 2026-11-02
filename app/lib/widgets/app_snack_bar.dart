import 'package:flutter/material.dart';

/// Show a consistent transient message.
///
/// Set [replace] to false when a caller intentionally queues a message behind
/// the current one; the default replaces the visible snackbar so rapid actions
/// do not stack stale text.
void showAppSnackBar(
  BuildContext context,
  String message, {
  SnackBarAction? action,
  bool replace = true,
}) {
  final messenger = ScaffoldMessenger.of(context);
  if (replace) messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(content: Text(message), action: action));
}
