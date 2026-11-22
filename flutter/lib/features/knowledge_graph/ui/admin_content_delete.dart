import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/networking/api_exception.dart';
import '../../auth/auth_controller.dart';
import '../graph_controller.dart';
import '../models.dart';

/// Remaining check kinds on [pack] (check1–check3).
int remainingCheckCount(TopicPack pack) {
  var n = 0;
  for (final kind in const ['check1', 'check2', 'check3']) {
    if (pack.bit(kind) != null) n += 1;
  }
  return n;
}

/// Admin long-press menu after a quiz is answered: delete quiz or whole pack.
Future<bool> showAdminContentDeleteMenu(
  BuildContext context, {
  required String nodeId,
  required TopicPack pack,
  required String checkKind,
}) async {
  final auth = context.read<AuthController>();
  if (auth.user?.isAdmin != true) return false;

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
                leading: Icon(Icons.quiz_outlined, color: scheme.onSurface),
                title: const Text('Delete this quiz'),
                subtitle: const Text('Removes only this question from the atom'),
                onTap: () => Navigator.pop(context, 'quiz'),
              ),
              ListTile(
                leading: Icon(Icons.delete_outline_rounded, color: scheme.error),
                title: Text('Delete atom', style: TextStyle(color: scheme.error)),
                subtitle: const Text('Atom, quizzes, and related progress'),
                onTap: () => Navigator.pop(context, 'pack'),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (choice == null || !context.mounted) return false;
  return executeAdminContentDelete(
    context,
    nodeId: nodeId,
    pack: pack,
    checkKind: checkKind,
    choice: choice,
  );
}

/// Run admin delete for [choice] `'quiz'` or `'pack'` (after confirmations).
Future<bool> executeAdminContentDelete(
  BuildContext context, {
  required String nodeId,
  required TopicPack pack,
  required String checkKind,
  required String choice,
}) async {
  final graph = context.read<GraphController>();
  if (choice == 'pack') {
    final ok = await _confirm(
      context,
      title: 'Delete atom?',
      body: 'This removes the atom, all quizzes, and related interactions/progress for everyone.',
      destructive: true,
    );
    if (!ok || !context.mounted) return false;
    final result = await graph.adminDeletePack(nodeId: nodeId, packIndex: pack.packIndex);
    return result != null;
  }

  // Delete quiz — last remaining check deletes the atom (with confirm).
  if (remainingCheckCount(pack) <= 1) {
    final ok = await _confirm(
      context,
      title: 'Last quiz on this atom',
      body:
          'This is the last quiz. Deleting it removes the whole atom, including related progress.',
      destructive: true,
      confirmLabel: 'Delete atom',
    );
    if (!ok || !context.mounted) return false;
    try {
      final result = await graph.adminDeleteQuiz(
        nodeId: nodeId,
        packIndex: pack.packIndex,
        checkKind: checkKind,
        confirmLastPack: true,
      );
      return result != null;
    } on ApiException catch (exc) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(exc.message)));
      }
      return false;
    }
  }

  final ok = await _confirm(
    context,
    title: 'Delete this quiz?',
    body: 'Only this question is removed. The atom and other quizzes stay.',
    destructive: true,
    confirmLabel: 'Delete quiz',
  );
  if (!ok || !context.mounted) return false;
  try {
    final result = await graph.adminDeleteQuiz(
      nodeId: nodeId,
      packIndex: pack.packIndex,
      checkKind: checkKind,
    );
    return result != null;
  } on ApiException catch (exc) {
    if (exc.code == 'CONFIRM_PACK_DELETE') {
      if (!context.mounted) return false;
      final proceed = await _confirm(
        context,
        title: 'Last quiz on this atom',
        body: exc.message,
        destructive: true,
        confirmLabel: 'Delete atom',
      );
      if (!proceed || !context.mounted) return false;
      final result = await graph.adminDeleteQuiz(
        nodeId: nodeId,
        packIndex: pack.packIndex,
        checkKind: checkKind,
        confirmLastPack: true,
      );
      return result != null;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(exc.message)));
    }
    return false;
  }
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required bool destructive,
  String confirmLabel = 'Delete',
}) async {
  final scheme = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: destructive
                ? TextButton.styleFrom(foregroundColor: scheme.error)
                : null,
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result == true;
}
