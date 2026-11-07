import 'package:flutter/material.dart';

const studyPagePadding = EdgeInsets.fromLTRB(20, 20, 20, 28);

class StudyCard extends StatelessWidget {
  const StudyCard({
    super.key,
    required this.title,
    this.eyebrow,
    this.subtitle,
    this.tint = const Color(0xFF1F4B6E),
    this.footer,
    this.onTap,
    this.dense = false,
  });

  final String title;
  final String? eyebrow;
  final String? subtitle;
  final Color tint;
  final Widget? footer;
  final VoidCallback? onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final card = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: Color.alphaBlend(tint.withValues(alpha: 0.16), Theme.of(context).colorScheme.surface),
        border: Border.all(color: tint.withValues(alpha: 0.18)),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 18, offset: Offset(0, 8))],
      ),
      padding: EdgeInsets.fromLTRB(18, dense ? 14 : 18, 18, dense ? 14 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (eyebrow != null) ...[
            Text(eyebrow!, style: TextStyle(color: tint, fontWeight: FontWeight.w700, letterSpacing: 0.4, fontSize: 12)),
            const SizedBox(height: 6),
          ],
          Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(color: ink, fontWeight: FontWeight.w700, height: 1.15)),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(subtitle!, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: ink.withValues(alpha: 0.78), height: 1.35)),
          ],
          if (footer != null) ...[const SizedBox(height: 14), footer!],
        ],
      ),
    );
    if (onTap == null) return card;
    return Material(color: Colors.transparent, child: InkWell(borderRadius: BorderRadius.circular(24), onTap: onTap, child: card));
  }
}
