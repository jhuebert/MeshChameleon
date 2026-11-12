import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Small numeric edit dialog shared by the port and GPS-interval editors.
///
/// Keeps the invalid draft editable (validation is inline, never resets the
/// field), re-checks eligibility at save time, and never writes on Cancel.
/// IME submission matches the Save action.
class NumericEditDialog extends StatefulWidget {
  const NumericEditDialog({
    super.key,
    required this.title,
    required this.label,
    required this.initialValue,
    required this.min,
    required this.max,
    required this.saveLabel,
    required this.stillEligible,
    required this.ineligibleMessage,
    required this.onSave,
    required this.failureMessage,
    this.helperText,
  });

  final String title;
  final String label;
  final int initialValue;
  final int min;
  final int max;

  /// Visible button text and accessible label (for example 'Save port').
  final String saveLabel;

  /// Re-checked on save; if false, the dialog stays open and explains.
  final bool Function() stillEligible;
  final String ineligibleMessage;
  final Future<bool> Function(int value) onSave;
  final String failureMessage;
  final String? helperText;

  @override
  State<NumericEditDialog> createState() => _NumericEditDialogState();
}

class _NumericEditDialogState extends State<NumericEditDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue.toString());
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null || parsed < widget.min || parsed > widget.max) {
      setState(() => _error =
          'Enter a whole number between ${widget.min} and ${widget.max}');
      return;
    }
    if (!widget.stillEligible()) {
      setState(() => _error = widget.ineligibleMessage);
      return;
    }
    setState(() => _saving = true);
    bool saved;
    try {
      saved = await widget.onSave(parsed);
    } catch (_) {
      saved = false;
    }
    if (!mounted) return;
    if (saved && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop(parsed);
    } else if (!saved) {
      setState(() {
        _saving = false;
        _error = widget.failureMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: widget.label,
          helperText: widget.helperText,
          errorText: _error,
        ),
        onChanged: (_) => setState(() => _error = null),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(widget.saveLabel),
        ),
      ],
    );
  }
}

/// Show the dialog; returns the accepted value, or null when canceled.
Future<int?> showNumericEditDialog(
  BuildContext context, {
  required String title,
  required String label,
  required int initialValue,
  required int min,
  required int max,
  required String saveLabel,
  required bool Function() stillEligible,
  required String ineligibleMessage,
  required Future<bool> Function(int value) onSave,
  required String failureMessage,
  String? helperText,
}) =>
    showDialog<int>(
      context: context,
      builder: (_) => NumericEditDialog(
        title: title,
        label: label,
        initialValue: initialValue,
        min: min,
        max: max,
        saveLabel: saveLabel,
        stillEligible: stillEligible,
        ineligibleMessage: ineligibleMessage,
        onSave: onSave,
        failureMessage: failureMessage,
        helperText: helperText,
      ),
    );
