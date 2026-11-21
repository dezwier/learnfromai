import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/widgets/pulse_placeholder.dart';
import '../auth/auth_controller.dart';
import 'settings_cron_queue_table.dart';
import 'settings_form_styles.dart';

/// Admin preview of which neighbor / pack jobs the ranking cron would enqueue next.
class SettingsCronOverview extends StatefulWidget {
  const SettingsCronOverview({super.key});

  @override
  State<SettingsCronOverview> createState() => _SettingsCronOverviewState();
}

class _SettingsCronOverviewState extends State<SettingsCronOverview> {
  static const _placeholderHeight = 160.0;

  var _loading = true;
  var _running = false;
  String? _error;
  _CronPreview? _preview;

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
      final raw = Map<String, dynamic>.from(
        await api.get('/admin/cron-runs/preview') as Map,
      );
      if (!mounted) return;
      setState(() {
        _preview = _CronPreview.fromJson(raw);
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

  Future<void> _runNow() async {
    if (_running) return;
    final api = context.read<AuthController>().api;
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final raw = Map<String, dynamic>.from(
        await api.post('/admin/cron-runs/run', body: {}) as Map,
      );
      final previewRaw = raw['preview'];
      final preview = previewRaw is Map
          ? _CronPreview.fromJson(Map<String, dynamic>.from(previewRaw))
          : null;
      if (!mounted) return;
      if (preview != null) {
        setState(() {
          _preview = preview;
          _running = false;
        });
      } else {
        setState(() => _running = false);
        await _load();
      }
      if (!mounted) return;
      final n = preview?.neighborJobs.length ?? 0;
      final p = preview?.learnJobs.length ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Enqueued $n neighbor · $p pack jobs.')),
      );
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        _error = exc.toString();
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Ranking queue',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: (_loading || _running) ? null : _load,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
            const SizedBox(width: 4),
            FilledButton.tonal(
              onPressed: (_loading || _running) ? null : _runNow,
              child: _running
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Run now'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Next neighbor expands and learn packs, ranked a priori.',
          style: SettingsFormStyles.finePrintStyle(context),
        ),
        if (_preview?.latestRunLabel != null) ...[
          const SizedBox(height: 6),
          Text(
            _preview!.latestRunLabel!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.45),
              letterSpacing: 0.2,
            ),
          ),
        ],
        const SizedBox(height: 14),
        if (_loading)
          const SizedBox(
            height: _placeholderHeight,
            width: double.infinity,
            child: PulsePlaceholder(borderRadius: BorderRadius.all(Radius.circular(12))),
          )
        else if (_error != null)
          Text(
            _error!,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          )
        else if (_preview == null || _preview!.isEmpty)
          Text('Nothing ranked yet.', style: theme.textTheme.bodyMedium)
        else ...[
          CronQueueTable(
            title: 'Neighbors',
            subtitle:
                'Top ${_preview!.limits.neighborJobsPerDay} · target ${_preview!.limits.desiredNeighbors}',
            columns: const ['Topic', 'Aff', 'N', 'Fill', 'Score', 'Result'],
            flex: const [3, 1, 1, 1, 1, 2],
            rows: [
              for (final job in _preview!.neighborJobs)
                [
                  job.name,
                  cronFmtScore(job.affinity),
                  '${job.neighborCount}',
                  cronFmtScore(job.fillTerm),
                  cronFmtScore(job.score),
                  job.neighborResultLabel,
                ],
            ],
          ),
          const SizedBox(height: 18),
          CronQueueTable(
            title: 'Packs',
            subtitle:
                'Top ${_preview!.limits.learnJobsPerDay} · target ${_preview!.limits.desiredPacks}',
            columns: const ['Topic', 'Aff', 'Pk', 'Fill', 'Score', 'Result'],
            flex: const [3, 1, 1, 1, 1, 2],
            rows: [
              for (final job in _preview!.learnJobs)
                [
                  job.name,
                  cronFmtScore(job.affinity),
                  '${job.packCount}',
                  cronFmtScore(job.fillTerm),
                  cronFmtScore(job.score),
                  job.packResultLabel,
                ],
            ],
          ),
        ],
      ],
    );
  }
}

class _CronPreview {
  const _CronPreview({
    required this.neighborJobs,
    required this.learnJobs,
    required this.limits,
    this.latestRunLabel,
  });

  final List<_CronQueueRow> neighborJobs;
  final List<_CronQueueRow> learnJobs;
  final _CronLimits limits;
  final String? latestRunLabel;

  bool get isEmpty => neighborJobs.isEmpty && learnJobs.isEmpty;

  factory _CronPreview.fromJson(Map<String, dynamic> raw) {
    final limitsRaw = raw['limits'];
    final latest = raw['latest_run'];
    String? latestLabel;
    if (latest is Map) {
      final status = latest['status']?.toString() ?? '';
      final started = DateTime.tryParse(latest['started_at']?.toString() ?? '')?.toLocal();
      if (started != null) {
        latestLabel =
            'Last run ${_two(started.month)}/${_two(started.day)} '
            '${_two(started.hour)}:${_two(started.minute)} · $status';
      }
    }
    return _CronPreview(
      neighborJobs: _rows(raw['neighbor_jobs']),
      learnJobs: _rows(raw['learn_jobs'], pack: true),
      limits: _CronLimits.fromJson(
        limitsRaw is Map ? Map<String, dynamic>.from(limitsRaw) : null,
      ),
      latestRunLabel: latestLabel,
    );
  }

  static List<_CronQueueRow> _rows(Object? raw, {bool pack = false}) {
    if (raw is! List) return const [];
    return [
      for (final row in raw)
        if (row is Map)
          _CronQueueRow.fromJson(Map<String, dynamic>.from(row), pack: pack),
    ];
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

class _CronLimits {
  const _CronLimits({
    required this.neighborJobsPerDay,
    required this.learnJobsPerDay,
    required this.desiredNeighbors,
    required this.desiredPacks,
  });

  final int neighborJobsPerDay;
  final int learnJobsPerDay;
  final int desiredNeighbors;
  final int desiredPacks;

  factory _CronLimits.fromJson(Map<String, dynamic>? raw) {
    return _CronLimits(
      neighborJobsPerDay: (raw?['neighbor_jobs_per_day'] as num?)?.toInt() ?? 5,
      learnJobsPerDay: (raw?['learn_jobs_per_day'] as num?)?.toInt() ?? 10,
      desiredNeighbors: (raw?['desired_neighbors'] as num?)?.toInt() ?? 16,
      desiredPacks: (raw?['desired_packs'] as num?)?.toInt() ?? 20,
    );
  }
}

class _CronQueueRow {
  const _CronQueueRow({
    required this.name,
    required this.affinity,
    required this.score,
    required this.fillTerm,
    required this.neighborCount,
    required this.packCount,
    required this.packIndex,
    required this.jobState,
    required this.neighborsAdded,
  });

  final String name;
  final double affinity;
  final double score;
  final double fillTerm;
  final int neighborCount;
  final int packCount;
  final int? packIndex;
  final String? jobState;
  final int? neighborsAdded;

  factory _CronQueueRow.fromJson(Map<String, dynamic> raw, {bool pack = false}) {
    return _CronQueueRow(
      name: raw['name']?.toString() ?? 'Topic',
      affinity: (raw['tile_affinity'] as num?)?.toDouble() ?? 0,
      score: (raw['score'] as num?)?.toDouble() ?? 0,
      fillTerm: (raw['fill_term'] as num?)?.toDouble() ?? 0,
      neighborCount: (raw['neighbor_count'] as num?)?.toInt() ?? 0,
      packCount: (raw['pack_count'] as num?)?.toInt() ?? 0,
      packIndex: pack ? (raw['pack_index'] as num?)?.toInt() : null,
      jobState: raw['job_state']?.toString(),
      neighborsAdded: (raw['neighbors_added'] as num?)?.toInt(),
    );
  }

  String get neighborResultLabel {
    if (neighborsAdded != null) {
      final n = neighborsAdded!;
      return n == 1 ? 'wrote 1' : 'wrote $n';
    }
    return _stateLabel(jobState);
  }

  String get packResultLabel {
    final state = jobState;
    if (state == 'succeeded' && packIndex != null) return 'pack $packIndex';
    if (state == 'queued' || state == 'running') {
      return packIndex != null ? 'pack $packIndex…' : _stateLabel(state);
    }
    if (state == 'failed') return 'failed';
    return '—';
  }

  static String _stateLabel(String? state) {
    switch (state) {
      case 'queued':
        return 'queued';
      case 'running':
        return 'running';
      case 'succeeded':
        return 'done';
      case 'failed':
        return 'failed';
      default:
        return '—';
    }
  }
}
