import 'package:flutter/material.dart';

class GradientTopBar extends StatelessWidget implements PreferredSizeWidget {
  const GradientTopBar({super.key, required this.title, this.leading, this.actions});

  final String title;
  final Widget? leading;
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      stops: const [0.0, 0.6, 1.0],
      colors: isDark
          ? const [Color(0xFF2A2E2A), Color(0xFF757575), Color(0xFF5C5C5C)]
          : const [Color(0xFF626A62), Color(0xFF4A4A4A), Color(0xFF353535)],
    );
    return Container(
      decoration: BoxDecoration(
        gradient: gradient,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 2, offset: const Offset(0, 2))],
      ),
      child: AppBar(
        toolbarHeight: 42,
        automaticallyImplyLeading: false,
        leading: leading,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: Colors.white)),
        centerTitle: true,
        actions: actions,
        elevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
    );
  }
}
