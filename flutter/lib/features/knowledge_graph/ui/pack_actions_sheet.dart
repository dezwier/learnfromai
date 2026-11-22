import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/media/image_pick.dart';
import '../../auth/auth_controller.dart';
import '../graph_controller.dart';
import 'admin_content_delete.dart';

/// Outcome of the pack long-press drawer.
class PackActionResult {
  const PackActionResult({
    this.deleted = false,
    this.imageUrl,
    this.imageThumbUrl,
    this.hasPackImage,
  });

  final bool deleted;
  final String? imageUrl;
  final String? imageThumbUrl;
  /// Set after upload (or when generate returns existing); null when only queued.
  final bool? hasPackImage;
}

/// Long-press drawer: pack image upload/generate (+ admin delete when applicable).
Future<PackActionResult?> showPackActionsSheet(
  BuildContext context, {
  required String nodeId,
  required String title,
  required TopicPack pack,
  required String checkKind,
  bool hasPackImage = false,
}) async {
  final graph = context.read<GraphController>();
  await graph.syncNodeJobs(nodeId, title: title);
  if (!context.mounted) return null;

  final isAdmin = context.read<AuthController>().user?.isAdmin == true;
  final imageBusy = graph.isPackImageJobActive(nodeId, pack.packIndex);
  final ownImage = hasPackImage || pack.hasPackImage;

  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.auto_awesome_outlined),
                title: Text(
                  imageBusy
                      ? 'Pack image generating…'
                      : (ownImage ? 'Regenerate pack image' : 'Generate pack image'),
                ),
                subtitle: const Text('Illustrates this learning bit'),
                enabled: !imageBusy,
                onTap: imageBusy ? null : () => Navigator.pop(context, 'generate'),
              ),
              ListTile(
                leading: const Icon(Icons.upload_outlined),
                title: Text(ownImage ? 'Replace pack image' : 'Upload pack image'),
                onTap: () => Navigator.pop(context, 'upload'),
              ),
              if (isAdmin) ...[
                const Divider(height: 16),
                ListTile(
                  leading: Icon(Icons.quiz_outlined, color: scheme.onSurface),
                  title: const Text('Delete this quiz'),
                  subtitle: const Text('Removes only this question from the pack'),
                  onTap: () => Navigator.pop(context, 'quiz'),
                ),
                ListTile(
                  leading: Icon(Icons.delete_outline_rounded, color: scheme.error),
                  title: Text('Delete pack', style: TextStyle(color: scheme.error)),
                  subtitle: const Text('Pack, quizzes, image, and related progress'),
                  onTap: () => Navigator.pop(context, 'pack'),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
  if (choice == null || !context.mounted) return null;

  if (choice == 'generate') {
    if (graph.isPackImageJobActive(nodeId, pack.packIndex)) {
      return const PackActionResult();
    }
    final ready = await graph.enqueuePackImage(
      nodeId,
      packIndex: pack.packIndex,
      title: title,
      regenerate: ownImage,
    );
    if (!context.mounted) return null;
    if (ready != null) {
      return PackActionResult(
        imageUrl: ready['image_url'],
        imageThumbUrl: ready['image_thumb_url'],
        hasPackImage: true,
      );
    }
    if (graph.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(graph.error!)));
    }
    return const PackActionResult();
  }

  if (choice == 'upload') {
    final picked = await pickImageBytes();
    if (picked == null || !context.mounted) return null;
    final ready = await graph.uploadPackImage(
      nodeId,
      packIndex: pack.packIndex,
      bytes: picked.bytes,
      filename: picked.filename,
      contentType: picked.mimeType,
    );
    if (!context.mounted) return null;
    if (ready == null) {
      final message = graph.error ?? 'Image upload failed';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      return null;
    }
    return PackActionResult(
      imageUrl: ready['image_url'],
      imageThumbUrl: ready['image_thumb_url'],
      hasPackImage: true,
    );
  }

  if (choice == 'quiz' || choice == 'pack') {
    final deleted = await executeAdminContentDelete(
      context,
      nodeId: nodeId,
      pack: pack,
      checkKind: checkKind,
      choice: choice,
    );
    if (deleted) return const PackActionResult(deleted: true);
    return null;
  }

  return null;
}
