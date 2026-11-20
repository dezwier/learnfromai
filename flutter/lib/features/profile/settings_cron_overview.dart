import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/pulse_placeholder.dart';
import '../auth/auth_controller.dart';
import 'settings_form_styles.dart';

/// Admin-only compact summary of the last daily ranking cron run.
class SettingsCronOverview extends StatefulWidget {
  const SettingsCronOverview({super.key});

  @override
  State<SettingsCronOverview> createState() => _SettingsCronOverviewState();
}

class _SettingsCronOverviewState extends State<SettingsCronOverview> {
  static const _placeholderHeight = 120.0;

  var _loading = true;
  String? _error;
  _CronRunSummary? _run;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AuthController>().api;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = Map<String, dynamic>.from(await api.get('/admin/cron-runs/latest') as Map);
      final runRaw = raw['run'];
      final run = runRaw is Map ? _CronRunSummary.fromJson(Map<String, dynamic>.from(runRaw)) : null;
      if (!mounted) return;
      setState(() {
        _run = run;
        _loading = false;
      });
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        _error = exc.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Daily ranking cron',
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          'Last automatic neighbor expands and learn packs enqueued.',
          style: SettingsFormStyles.finePrintStyle(context),
        ),
        const SizedBox(height: 12),
        if (_loading)
          const SizedBox(
            height: _placeholderHeight,
            width: double.infinity,
            child: PulsePlaceholder(borderRadius: BorderRadius.all(Radius.circular(12))),
          )
        else if (_error != null)
          SizedBox(
            height: _placeholderHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
            ),
          )
        else if (_run == null)
          SizedBox(
            height: _placeholderHeight,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('No cron run yet.', style: theme.textTheme.bodyMedium),
            ),
          )
        else
          _CronRunBody(run: _run!),
      ],
    );
  }
}

class _CronRunSummary {
  const _CronRunSummary({
    required this.status,
    required this.startedAt,
    required this.neighborJobs,
    required this.learnJobs,
  });

  final String status;
  final DateTime? startedAt;
  final List<_CronJobLine> neighborJobs;
  final List<_CronJobLine> learnJobs;

  factory _CronRunSummary.fromJson(Map<String, dynamic> raw) {
    DateTime? started;
    final rawStarted = raw['started_at']?.toString();
    if (rawStarted != null && rawStarted.isNotEmpty) {
      started = DateTime.tryParse(rawStarted)?.toLocal();
    }
    return _CronRunSummary(
      status: raw['status']?.toString() ?? 'unknown',
      startedAt: started,
      neighborJobs: _lines(raw['neighbor_jobs']),
      learnJobs: _lines(raw['learn_jobs'], pack: true),
    );
  }

  static List<_CronJobLine> _lines(Object? raw, {bool pack = false}) {
    if (raw is! List) return const [];
    return [
      for (final row in raw)
        if (row is Map)
          _CronJobLine(
            name: row['name']?.toString() ?? 'Topic',
            packIndex: pack ? (row['pack_index'] as num?)?.toInt() : null,
          ),
    ];
  }
}

class _CronJobLine {
  const _CronJobLine({required this.name, this.packIndex});

  final String name;
  final int? packIndex;
}

class _CronRunBody extends StatelessWidget {
  const _CronRunBody({required this.run});

  final _CronRunSummary run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final when = run.startedAt == null
        ? '—'
        : '${run.startedAt!.year}-${_two(run.startedAt!.month)}-${_two(run.startedAt!.day)} '
            '${_two(run.startedAt!.hour)}:${_two(run.startedAt!.minute)}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$when · ${run.status}', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        Text('Expanded', style: theme.textTheme.labelLarge),
        if (run.neighborJobs.isEmpty)
          Text('None', style: SettingsFormStyles.finePrintStyle(context))
        else
          for (final job in run.neighborJobs.take(8))
            Text('· ${job.name}', style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        Text('Packs', style: theme.textTheme.labelLarge),
        if (run.learnJobs.isEmpty)
          Text('None', style: SettingsFormStyles.finePrintStyle(context))
        else
          for (final job in run.learnJobs.take(10))
            Text(
              '· ${job.name}${job.packIndex != null ? ' · pack ${job.packIndex}' : ''}',
              style: theme.textTheme.bodySmall,
            ),
      ],
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}
