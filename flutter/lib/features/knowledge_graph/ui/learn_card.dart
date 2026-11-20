import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/widgets/pulse_placeholder.dart';
import '../models.dart';
import 'learn_check_bits.dart';
import 'learn_pack_chrome.dart';
import 'turnable_y_axis_card.dart';

class LearnDeckEntry {
  const LearnDeckEntry({required this.pack, required this.checkKind});

  final TopicPack pack;
  final String checkKind;

  int get packIndex => pack.packIndex;
}

class LearnFlipCard extends StatefulWidget {
  const LearnFlipCard({
    super.key,
    required this.entry,
    required this.imageUrl,
    required this.loadImageBytes,
    required this.onShown,
    required this.onCheckAnswer,
    this.cachedBytes,
    this.imageLoading = false,
    this.completed = false,
  });

  final LearnDeckEntry entry;
  final String? imageUrl;
  final Uint8List? cachedBytes;
  final bool imageLoading;
  final bool completed;
  final Future<List<int>?> Function(String imageUrl) loadImageBytes;
  final VoidCallback onShown;
  final void Function({
    required bool correct,
    int? choiceIndex,
    bool? answerBool,
    String? answerText,
  }) onCheckAnswer;

  @override
  State<LearnFlipCard> createState() => _LearnFlipCardState();
}

class _LearnFlipCardState extends State<LearnFlipCard> {
  var _selectedChoice = -1;
  var _revealed = false;
  var _trackedLearn = false;
  final _clozeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _trackedLearn) return;
      _trackedLearn = true;
      widget.onShown();
    });
  }

  @override
  void dispose() {
    _clozeController.dispose();
    super.dispose();
  }

  void _onSelectMc(int choiceIndex) {
    if (_revealed) return;
    final bit = widget.entry.pack.bit(widget.entry.checkKind);
    final answerIndex = (bit?.body['answer_index'] as num?)?.toInt() ?? 0;
    setState(() {
      _selectedChoice = choiceIndex;
      _revealed = true;
    });
    widget.onCheckAnswer(
      correct: choiceIndex == answerIndex,
      choiceIndex: choiceIndex,
    );
  }

  void _onSelectBool(bool value) {
    if (_revealed) return;
    final bit = widget.entry.pack.bit(widget.entry.checkKind);
    final answer = bit?.body['answer'] == true;
    setState(() {
      _selectedChoice = value ? 1 : 0;
      _revealed = true;
    });
    widget.onCheckAnswer(
      correct: value == answer,
      answerBool: value,
    );
  }

  void _onSubmitCloze() {
    if (_revealed) return;
    final bit = widget.entry.pack.bit(widget.entry.checkKind);
    if (bit == null) return;
    final text = _clozeController.text;
    final correct = gradeCloze(bit, text);
    setState(() => _revealed = true);
    widget.onCheckAnswer(correct: correct, answerText: text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final pack = widget.entry.pack;
    final checkKind = widget.entry.checkKind;
    final scheme = Theme.of(context).colorScheme;

    return TurnableYAxisCard(
      resetIdentity: '${pack.packIndex}-$checkKind',
      dismissKeyboardOnInteraction: true,
      // Only the visible face stays in the tree so quiz taps hit the back.
      prelayoutFacesForHeight: false,
      front: _LearnCardFace(
        imageUrl: widget.imageUrl,
        cachedBytes: widget.cachedBytes,
        imageLoading: widget.imageLoading,
        loadImageBytes: widget.loadImageBytes,
        completed: widget.completed,
        child: LearnMarkdownBit(bit: pack.bit('learn')),
      ),
      back: _LearnCardFace(
        imageUrl: widget.imageUrl,
        cachedBytes: widget.cachedBytes,
        imageLoading: widget.imageLoading,
        loadImageBytes: widget.loadImageBytes,
        completed: widget.completed,
        child: GestureDetector(
          // Absorb card-level flip taps over interactive quiz controls.
          onTap: () {},
          behavior: HitTestBehavior.deferToChild,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Check',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurface.withValues(alpha: 0.55),
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 8),
              LearnCheckBit(
                bit: pack.bit(checkKind),
                selected: _selectedChoice,
                revealed: _revealed,
                clozeController: _clozeController,
                onSelectChoice: _onSelectMc,
                onSelectBool: _onSelectBool,
                onSubmitCloze: _onSubmitCloze,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LearnCardFace extends StatelessWidget {
  const _LearnCardFace({
    required this.child,
    required this.loadImageBytes,
    this.imageUrl,
    this.cachedBytes,
    this.imageLoading = false,
    this.completed = false,
  });

  final Widget child;
  final String? imageUrl;
  final Uint8List? cachedBytes;
  final bool imageLoading;
  final bool completed;
  final Future<List<int>?> Function(String imageUrl) loadImageBytes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              _LearnCardImage(
                imageUrl: imageUrl,
                cachedBytes: cachedBytes,
                loading: imageLoading,
                loadImageBytes: loadImageBytes,
              ),
              if (completed)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Icon(
                    Icons.check_circle,
                    color: learnOkColor(scheme.brightness),
                    size: 28,
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _LearnCardImage extends StatefulWidget {
  const _LearnCardImage({
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
  State<_LearnCardImage> createState() => _LearnCardImageState();
}

class _LearnCardImageState extends State<_LearnCardImage> {
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
  void didUpdateWidget(covariant _LearnCardImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _hydrateFromCache();
      unawaited(_load());
      return;
    }
    if (_bytes == null &&
        widget.cachedBytes != null &&
        widget.cachedBytes!.isNotEmpty) {
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
    setState(() {
      _bytes = next;
      _loadedUrl = url;
      _loadingBytes = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.vertical(top: Radius.circular(16));
    final bytes = _bytes;
    final showPlaceholder = bytes == null && (widget.loading || _loadingBytes);
    return AspectRatio(
      aspectRatio: 16 / 10,
      child: ClipRRect(
        borderRadius: radius,
        child: showPlaceholder
            ? const PulsePlaceholder.image(borderRadius: radius)
            : bytes == null
                ? ColoredBox(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.06),
                  )
                : Image.memory(
                    bytes,
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
