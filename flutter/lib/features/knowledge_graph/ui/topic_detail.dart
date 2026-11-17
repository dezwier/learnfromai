import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/widgets/pulse_placeholder.dart';
import '../../../core/widgets/study_card.dart';
import '../../profile/overlay_panel_chrome.dart';
import '../layout/graph_layout.dart';

/// Fullscreen topic overlay — same chrome pattern as [ProfileScreen].
class TopicDetailScreen extends StatelessWidget {
  const TopicDetailScreen({
    required this.node,
    required this.canViewInGraph,
    required this.canRequestNeighbors,
    required this.showRelations,
    required this.onClose,
    required this.onRequestNeighbors,
    required this.onViewInGraph,
    required this.onLearn,
    required this.onImageAction,
    required this.onEdit,
    required this.onDelete,
    required this.onOpenRelated,
    required this.loadImageBytes,
    required this.cachedImageBytes,
    this.layout,
    this.focusId,
    this.busy = false,
    this.progressMessage,
    this.imageGenerating = false,
    this.canEditImage = true,
    this.relationsPending = false,
  });

  final PlacedNode node;
  final GraphLayout? layout;
  final String? focusId;
  final bool busy;
  final String? progressMessage;
  final bool imageGenerating;
  final bool relationsPending;
  final bool showRelations;
  final bool canRequestNeighbors;
  final bool canViewInGraph;
  final bool canEditImage;
  final VoidCallback onClose;
  final VoidCallback onRequestNeighbors;
  final VoidCallback onViewInGraph;
  final VoidCallback onLearn;
  final VoidCallback onImageAction;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<PlacedNode> onOpenRelated;
  final Future<List<int>?> Function(String imageUrl) loadImageBytes;
  final Uint8List? Function(String? imageUrl) cachedImageBytes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final desc = (node.description ?? '').trim();
    final imageUrl = (node.imageUrl ?? '').trim();
    final hasImage = imageUrl.isNotEmpty;
    final bottomClearance = OverlayPanel.bottomClearance(context, hasBottom: false);

    return OverlayPanel(
      onDismiss: onClose,
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: studyPagePadding.copyWith(bottom: bottomClearance),
          children: [
            if (hasImage || imageGenerating) ...[
              _TopicHeroImage(
                key: ValueKey(node.id),
                imageUrl: hasImage ? imageUrl : null,
                cachedBytes: hasImage ? cachedImageBytes(imageUrl) : null,
                loading: imageGenerating,
                loadImageBytes: loadImageBytes,
              ),
              const SizedBox(height: 16),
            ],
            Text(
              node.title,
              style: TextStyle(
                fontFamily: 'tt_ramilas',
                fontWeight: FontWeight.w700,
                fontSize: 28,
                height: 1.15,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 12),
            if (desc.isNotEmpty)
              Text(
                desc,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.78),
                      height: 1.4,
                    ),
              )
            else
              Text(
                'No description yet.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.45),
                      fontStyle: FontStyle.italic,
                    ),
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                if (canRequestNeighbors) ...[
                  _TopicIconButton(
                    tooltip: 'Request neighbors',
                    icon: Icons.auto_awesome,
                    filled: true,
                    onPressed: onRequestNeighbors,
                  ),
                  const SizedBox(width: 8),
                ] else if (canViewInGraph) ...[
                  _TopicIconButton(
                    tooltip: 'View in graph',
                    icon: Icons.arrow_forward,
                    filled: true,
                    onPressed: onViewInGraph,
                  ),
                  const SizedBox(width: 8),
                ],
                _TopicIconButton(
                  tooltip: 'Learn',
                  icon: Icons.menu_book_outlined,
                  filled: !canRequestNeighbors && !canViewInGraph,
                  onPressed: onLearn,
                ),
                const SizedBox(width: 8),
                _TopicIconButton(
                  tooltip: hasImage ? 'Change image' : 'Add image',
                  icon: Icons.image_outlined,
                  onPressed: canEditImage ? onImageAction : null,
                ),
                const SizedBox(width: 8),
                _TopicIconButton(
                  tooltip: 'Edit',
                  icon: Icons.edit_outlined,
                  onPressed: onEdit,
                ),
                const SizedBox(width: 8),
                _TopicIconButton(
                  tooltip: 'Delete',
                  icon: Icons.delete_outline,
                  foreground: scheme.error,
                  onPressed: onDelete,
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (busy) ...[
              _TopicProgressCard(
                title: imageGenerating ? 'Updating image' : 'Building neighborhood',
                message: progressMessage ??
                    (imageGenerating ? 'Working on topic image…' : 'Loading related topics…'),
              ),
              if (showRelations || relationsPending) const SizedBox(height: 12),
            ],
            if (relationsPending)
              const SizedBox(
                height: 168,
                child: PulsePlaceholder(
                  borderRadius: BorderRadius.all(Radius.circular(16)),
                ),
              )
            else if (showRelations && layout != null)
              _RelationsCard(
                node: node,
                layout: layout!,
                focusId: focusId,
                onOpen: onOpenRelated,
              ),
          ],
        ),
      ),
    );
  }
}

class _TopicHeroImage extends StatefulWidget {
  const _TopicHeroImage({
    super.key,
    required this.loadImageBytes,
    this.imageUrl,
    this.cachedBytes,
    this.loading = false,
  });

  final String? imageUrl;
  final Uint8List? cachedBytes;
  final bool loading;
  final Future<List<int>?> Function(String imageUrl) loadImageBytes;

  @override
  State<_TopicHeroImage> createState() => _TopicHeroImageState();
}

class _TopicHeroImageState extends State<_TopicHeroImage> {
  Uint8List? _bytes;
  var _loadingBytes = false;
  String? _loadedUrl;
  var _loadGen = 0;

  @override
  void initState() {
    super.initState();
    _hydrateFromCache();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _TopicHeroImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _hydrateFromCache();
      unawaited(_load());
      return;
    }
    if (_bytes == null && widget.cachedBytes != null && widget.cachedBytes!.isNotEmpty) {
      setState(_hydrateFromCache);
    }
  }

  void _hydrateFromCache() {
    final url = (widget.imageUrl ?? '').trim();
    final cached = widget.cachedBytes;
    if (url.isEmpty || cached == null || cached.isEmpty) return;
    _bytes = cached;
    _loadedUrl = url;
    _loadingBytes = false;
  }

  Future<void> _load() async {
    final url = (widget.imageUrl ?? '').trim();
    final gen = ++_loadGen;
    if (url.isEmpty) {
      if (mounted) {
        setState(() {
          _bytes = null;
          _loadedUrl = null;
          _loadingBytes = false;
        });
      }
      return;
    }
    if (url == _loadedUrl && _bytes != null) return;
    if (_bytes == null) {
      setState(() => _loadingBytes = true);
    }
    final bytes = await widget.loadImageBytes(url);
    if (!mounted || gen != _loadGen) return;
    if ((widget.imageUrl ?? '').trim() != url) return;
    if (bytes == null || bytes.isEmpty) {
      setState(() => _loadingBytes = false);
      return;
    }
    final next = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (url == _loadedUrl && _bytes != null && identical(_bytes, next)) {
      if (_loadingBytes) setState(() => _loadingBytes = false);
      return;
    }
    setState(() {
      _bytes = next;
      _loadedUrl = url;
      _loadingBytes = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(16));
    final bytes = _bytes;
    final showPlaceholder = bytes == null && (widget.loading || _loadingBytes);
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: radius,
        child: showPlaceholder
            ? const PulsePlaceholder.image(borderRadius: radius)
            : Image.memory(
                bytes!,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
              ),
      ),
    );
  }
}

class _TopicProgressCard extends StatelessWidget {
  const _TopicProgressCard({
    required this.message,
    this.title = 'Building neighborhood',
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.onSurface.withValues(
        alpha: scheme.brightness == Brightness.dark ? 0.10 : 0.045,
      ),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: scheme.primary.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.72),
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.78),
                          height: 1.35,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RelationsCard extends StatelessWidget {
  const _RelationsCard({
    required this.node,
    required this.layout,
    required this.onOpen,
    this.focusId,
  });

  final PlacedNode node;
  final GraphLayout layout;
  final String? focusId;
  final ValueChanged<PlacedNode> onOpen;

  static const _order = [
    NodeRole.parent,
    NodeRole.sibling,
    NodeRole.child,
    NodeRole.related,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = relationsFor(node, layout, focusId: focusId);
    final sections = [
      for (final role in _order)
        if ((groups[role] ?? const []).isNotEmpty) (role, groups[role]!),
    ];
    if (sections.isEmpty) {
      return Material(
        color: scheme.onSurface.withValues(
          alpha: scheme.brightness == Brightness.dark ? 0.08 : 0.04,
        ),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Text(
            'No linked topics in this view.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface.withValues(alpha: 0.45),
                  fontStyle: FontStyle.italic,
                ),
          ),
        ),
      );
    }

    return Material(
      color: scheme.onSurface.withValues(
        alpha: scheme.brightness == Brightness.dark ? 0.10 : 0.045,
      ),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < sections.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                color: scheme.onSurface.withValues(alpha: 0.06),
              ),
            _RelationSection(
              role: sections[i].$1,
              nodes: sections[i].$2,
              onOpen: onOpen,
            ),
          ],
        ],
      ),
    );
  }
}

class _RelationSection extends StatelessWidget {
  const _RelationSection({
    required this.role,
    required this.nodes,
    required this.onOpen,
  });

  final NodeRole role;
  final List<PlacedNode> nodes;
  final ValueChanged<PlacedNode> onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = roleFill(role, scheme);
    final onAccent = scheme.brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.92)
        : const Color(0xFF1A1C1E).withValues(alpha: 0.88);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                relationSectionLabel(role),
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
              ),
            ],
          ),
        ),
        for (final item in nodes)
          InkWell(
            onTap: () => onOpen(item),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: item.role == NodeRole.focus
                          ? accent
                          : nodeFill(item, scheme),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _topicInitial(item.title),
                      style: TextStyle(
                        color: onAccent,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: scheme.onSurface.withValues(alpha: 0.9),
                            height: 1.25,
                            fontWeight: FontWeight.w500,
                          ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: scheme.onSurface.withValues(alpha: 0.28),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 4),
      ],
    );
  }
}

String _topicInitial(String title) {
  final trimmed = title.trim();
  if (trimmed.isEmpty) return '?';
  return String.fromCharCode(trimmed.runes.first).toUpperCase();
}

class _TopicIconButton extends StatelessWidget {
  const _TopicIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.filled = false,
    this.foreground,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool filled;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final fg = (foreground ?? (filled ? scheme.onPrimary : scheme.onSurfaceVariant))
        .withValues(alpha: enabled ? 1 : 0.38);
    final bg = filled
        ? scheme.primary.withValues(alpha: enabled ? 1 : 0.38)
        : scheme.onSurface.withValues(alpha: scheme.brightness == Brightness.dark ? 0.10 : 0.06);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 20, color: fg),
          ),
        ),
      ),
    );
  }
}

