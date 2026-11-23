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
    this.topicImageUpdated = false,
  });

  final bool deleted;
  final String? imageUrl;
  final String? imageThumbUrl;
  /// Set after pack upload (or when generate returns existing); null when only queued.
  final bool? hasPackImage;
  /// Topic image was uploaded (or already present after generate). Display still
  /// prefers atom image when [hasPackImage] is set.
  final bool topicImageUpdated;
}

/// Long-press drawer: atom + topic image upload/generate (+ admin delete).
Future<PackActionResult?> showPackActionsSheet(
  BuildContext context, {
  required String nodeId,
  required String title,
  required TopicPack pack,
  required String checkKind,
  bool hasPackImage = false,
  bool hasTopicImage = false,
}) async {
  final graph = context.read<GraphController>();
  await graph.syncNodeJobs(nodeId, title: title);
  if (!context.mounted) return null;

  final isAdmin = context.read<AuthController>().user?.isAdmin == true;
  final imageBusy = graph.isPackImageJobActive(nodeId, pack.packIndex);
  final topicBusy = graph.isJobTypeActive(nodeId, 'generate_image');
  final ownImage = hasPackImage || pack.hasPackImage;
  final topicHasImage = hasTopicImage || _topicHasImage(graph, nodeId);

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
                      ? 'Atom image generating…'
                      : (ownImage ? 'Regenerate atom image' : 'Generate atom image'),
                ),
                subtitle: const Text('Illustrates this learning bit'),
                enabled: !imageBusy,
                onTap: imageBusy ? null : () => Navigator.pop(context, 'generate'),
              ),
              ListTile(
                leading: const Icon(Icons.upload_outlined),
                title: Text(ownImage ? 'Replace atom image' : 'Upload atom image'),
                onTap: () => Navigator.pop(context, 'upload'),
              ),
              const Divider(height: 16),
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: Text(
                  topicBusy
                      ? 'Topic image generating…'
                      : (topicHasImage
                          ? 'Regenerate topic image'
                          : 'Generate topic image'),
                ),
                subtitle: const Text('Shown when this atom has no image'),
                enabled: !topicBusy,
                onTap: topicBusy ? null : () => Navigator.pop(context, 'generate_topic'),
              ),
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: Text(
                  topicHasImage ? 'Replace topic image' : 'Upload topic image',
                ),
                onTap: () => Navigator.pop(context, 'upload_topic'),
              ),
              if (isAdmin) ...[
                const Divider(height: 16),
                ListTile(
                  leading: Icon(Icons.quiz_outlined, color: scheme.onSurface),
                  title: const Text('Delete this quiz'),
                  subtitle: const Text('Removes only this question from the atom'),
                  onTap: () => Navigator.pop(context, 'quiz'),
                ),
                ListTile(
                  leading: Icon(Icons.delete_outline_rounded, color: scheme.error),
                  title: Text('Delete atom', style: TextStyle(color: scheme.error)),
                  subtitle: const Text('Atom, quizzes, image, and related progress'),
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

  if (choice == 'generate_topic') {
    if (graph.isJobTypeActive(nodeId, 'generate_image')) {
      return const PackActionResult();
    }
    final ok = await graph.enqueueImage(
      nodeId,
      title: title,
      regenerate: topicHasImage,
    );
    if (!context.mounted) return null;
    if (!ok && graph.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(graph.error!)));
    }
    // Queued or already had an image — graph patch / poller updates display.
    return const PackActionResult(topicImageUpdated: true);
  }

  if (choice == 'upload_topic') {
    final picked = await pickImageBytes();
    if (picked == null || !context.mounted) return null;
    final ok = await graph.uploadImage(
      nodeId,
      bytes: picked.bytes,
      filename: picked.filename,
      contentType: picked.mimeType,
    );
    if (!context.mounted) return null;
    if (!ok) {
      final message = graph.error ?? 'Image upload failed';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      return null;
    }
    final urls = _topicImageUrls(graph, nodeId);
    return PackActionResult(
      topicImageUpdated: true,
      imageUrl: urls.$1,
      imageThumbUrl: urls.$2,
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

bool _topicHasImage(GraphController graph, String nodeId) {
  final urls = _topicImageUrls(graph, nodeId);
  return urls.$1 != null || urls.$2 != null;
}

(String?, String?) _topicImageUrls(GraphController graph, String nodeId) {
  final nodes = graph.categoryGraph?['nodes'];
  if (nodes is! List) return (null, null);
  for (final raw in nodes) {
    if (raw is Map && raw['id']?.toString() == nodeId) {
      final url = raw['image_url']?.toString().trim();
      final thumb = raw['image_thumb_url']?.toString().trim();
      return (
        (url == null || url.isEmpty) ? null : url,
        (thumb == null || thumb.isEmpty) ? null : thumb,
      );
    }
  }
  return (null, null);
}
