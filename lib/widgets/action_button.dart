import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';

class ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? color;
  final Color? textColor;
  final String? tooltip;

  const ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
    this.textColor,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    // final theme = Theme.of(context); // Unused
    final iconColor = color ?? Colors.white70;
    final txtColor = textColor ?? Colors.white70;

    switch (settings.actionButtonStyle) {
      case ActionButtonStyle.iconOnly:
        return IconButton(
          icon: Icon(icon, color: iconColor),
          tooltip: tooltip ?? label,
          onPressed: onPressed,
        );

      case ActionButtonStyle.textOnly:
        return TextButton(
          onPressed: onPressed,
          child: Text(
             label,
             style: TextStyle(color: txtColor, fontWeight: FontWeight.w600),
          ),
        );

      case ActionButtonStyle.textAndIcon:
        return InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
                width: 64,
                child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                                Icon(icon, color: iconColor, size: 22),
                                const SizedBox(height: 1),
                                Text(
                                  label,
                                  style: TextStyle(color: txtColor.withOpacity(0.6), fontSize: 10),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                        ),
                    ),
                ),
            ),
        );
    }
  }
}
