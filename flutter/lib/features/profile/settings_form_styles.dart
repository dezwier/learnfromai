import 'package:flutter/material.dart';

/// Shared form styling for settings drawer tabs (Talivo / Archipelago layout).
class SettingsFormStyles {
  SettingsFormStyles._();

  static InputDecoration fieldDecoration(
    BuildContext context, {
    required String labelText,
    Widget? suffixIcon,
    String? errorText,
    String? counterText,
  }) {
    final outlineColor = Theme.of(context).brightness == Brightness.light
        ? Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)
        : Theme.of(context).colorScheme.outline.withValues(alpha: 0.5);

    return InputDecoration(
      labelText: labelText,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      suffixIcon: suffixIcon,
      errorText: errorText,
      counterText: counterText,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: outlineColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: outlineColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(
          color: Theme.of(context).colorScheme.primary,
          width: 2,
        ),
      ),
    );
  }

  static OutlineInputBorder outlineBorder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isLight = Theme.of(context).brightness == Brightness.light;
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(
        color: scheme.outline.withValues(alpha: isLight ? 0.3 : 0.5),
      ),
    );
  }

  static TextStyle? finePrintStyle(BuildContext context) {
    return Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
        );
  }

  static Widget settingsRow({
    required BuildContext context,
    required String label,
    required String description,
    required Widget control,
    double controlWidth = 160,
  }) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(description, style: finePrintStyle(context)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(width: controlWidth, child: control),
      ],
    );
  }

  static Widget densePopupField<T>({
    required BuildContext context,
    required InputBorder outlineBorder,
    required Widget selectedChild,
    required List<DensePopupEntry<T>> entries,
    required ValueChanged<T?> onSelected,
    bool enabled = true,
  }) {
    return DecoratedBox(
      decoration: ShapeDecoration(shape: outlineBorder),
      child: SizedBox(
        height: 48,
        child: PopupMenuButton<T?>(
          enabled: enabled,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 220),
          offset: const Offset(0, 40),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          onSelected: onSelected,
          itemBuilder: (context) => [
            for (final entry in entries)
              PopupMenuItem<T?>(
                value: entry.value,
                enabled: entry.enabled,
                height: entry.height,
                child: entry.child,
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Expanded(child: selectedChild),
                Icon(
                  Icons.arrow_drop_down,
                  color: enabled ? IconTheme.of(context).color : Theme.of(context).disabledColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Widget stepperControl({
    required int value,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: value > min ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove),
        ),
        SizedBox(width: 28, child: Text('$value', textAlign: TextAlign.center)),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: value < max ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}

class DensePopupEntry<T> {
  const DensePopupEntry({
    required this.value,
    required this.child,
    this.enabled = true,
    this.height = 48,
  });

  final T value;
  final Widget child;
  final bool enabled;
  final double height;
}
