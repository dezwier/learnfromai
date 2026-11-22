import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../core/audio/quiz_feedback_sounds.dart';
import '../../../core/widgets/pulse_placeholder.dart';
import '../models.dart';
import 'learn_check_bits.dart';
import 'learn_pack_chrome.dart';
import 'quiz_feedback_badge.dart';
import 'turnable_y_axis_card.dart';

class LearnDeckEntry {
  const LearnDeckEntry({required this.pack, required this.checkKind});

  final TopicPack pack;
  final String checkKind;

  int get packIndex => pack.packIndex;
}

/// Max image aspect (width / height) — never taller than square.
const _imageAspect = 1.0;
/// Front scrolls only after the image has shrunk to this fraction of width.
const _minImageWidthFraction = 0.25;
const _bodyPadding = EdgeInsets.fromLTRB(16, 14, 16, 16);
/// Until the first measure lands, keep the card tall enough to avoid overflow.
const _provisionalFrontBodyH = 110.0;
const _provisionalBackBodyH = 200.0;
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
    this.startOnCheck = false,
  });

  final LearnDeckEntry entry;
  final String? imageUrl;
  final Uint8List? cachedBytes;
  final bool imageLoading;
  final bool completed;

  /// Testing track: open on the quiz face; flip to learn only after answering.
  final bool startOnCheck;
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
  bool? _answerCorrect;
  var _trackedLearn = false;
  double _frontBodyH = 0;
  double _backBodyH = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _trackedLearn) return;
      _trackedLearn = true;
      widget.onShown();
    });
  }

  void _markRevealed() {
    setState(() => _revealed = true);
  }

  void _reveal({required bool correct}) {
    _answerCorrect = correct;
    _markRevealed();
    unawaited(QuizFeedbackSounds.play(correct: correct));
  }

  void _onSelectMc(int choiceIndex) {
    if (_revealed) return;
    final bit = widget.entry.pack.bit(widget.entry.checkKind);
    final answerIndex = (bit?.body['answer_index'] as num?)?.toInt() ?? 0;
    final correct = choiceIndex == answerIndex;
    _selectedChoice = choiceIndex;
    _reveal(correct: correct);
    widget.onCheckAnswer(correct: correct, choiceIndex: choiceIndex);
  }

  void _onSelectBool(bool value) {
    if (_revealed) return;
    final bit = widget.entry.pack.bit(widget.entry.checkKind);
    final answer = bit?.body['answer'] == true;
    final correct = value == answer;
    _selectedChoice = value ? 1 : 0;
    _reveal(correct: correct);
    widget.onCheckAnswer(correct: correct, answerBool: value);
  }

  void _onFrontBodySize(Size size) {
    if (!mounted) return;
    if ((size.height - _frontBodyH).abs() < 0.5) return;
    setState(() => _frontBodyH = size.height);
  }

  void _onBackBodySize(Size size) {
    if (!mounted) return;
    if ((size.height - _backBodyH).abs() < 0.5) return;
    setState(() => _backBodyH = size.height);
  }

  Widget _frontBody() => LearnMarkdownBit(bit: widget.entry.pack.bit('learn'));

  Widget _backBody({bool interactive = true}) {
    return GestureDetector(
      onTap: interactive ? () {} : null,
      behavior: HitTestBehavior.deferToChild,
      child: LearnCheckBit(
        bit: widget.entry.pack.bit(widget.entry.checkKind),
        selected: _selectedChoice,
        revealed: _revealed,
        onSelectChoice: interactive ? _onSelectMc : (_) {},
        onSelectBool: interactive ? _onSelectBool : (_) {},
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pack = widget.entry.pack;
    final checkKind = widget.entry.checkKind;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final maxH = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : double.infinity;
        final squareImageH = width > 0 ? width / _imageAspect : 100.0;
        final minImageH =
            width > 0 ? width * _minImageWidthFraction : squareImageH * _minImageWidthFraction;
        final frontBodyH =
            _frontBodyH > 0 ? _frontBodyH : _provisionalFrontBodyH;
        final backBodyH = _backBodyH > 0 ? _backBodyH : _provisionalBackBodyH;
        // Natural size: square image + body on each face (shared height = max).
        // Cap to the slot; only then shrink images / scroll — don't stretch taller
        // than content just to reach the Next button.
        final preferred = [
          squareImageH + frontBodyH,
          squareImageH + backBodyH,
        ].reduce((a, b) => a > b ? a : b);
        final rawH = maxH.isFinite ? math.min(preferred, maxH) : preferred;
        final cardH = rawH.isFinite ? math.max(0.0, rawH) : preferred;
        if (cardH <= 0) {
          return const SizedBox.shrink();
        }

        // 1) Keep image as large as possible (≤ square) so body fits without scroll.
        // 2) Only at min image (¼ width) allow the body to scroll.
        (double, bool) imageAndScroll(double bodyH) {
          final room = cardH - bodyH;
          if (room >= squareImageH) {
            return (squareImageH, false);
          }
          if (room >= minImageH) {
            return (math.max(0.0, room), false);
          }
          return (math.max(0.0, math.min(minImageH, cardH)), true);
        }

        final frontLayout = imageAndScroll(frontBodyH);
        final backLayout = imageAndScroll(backBodyH);
        final frontImageH = frontLayout.$1;
        final frontScroll = frontLayout.$2;
        final backImageH = backLayout.$1;
        final backScroll = backLayout.$2;

        // Offstage measures body heights without painting (OverflowBox was
        // painting a second quiz/explanation over the visible card).
        // Always pin to the slot floor so the card rides the keyboard inset
        // continuously — flipping top↔bottom on open/close caused a jump.
        return Align(
          alignment: Alignment.bottomCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Offstage(
                offstage: true,
                child: ExcludeFocus(
                  child: SizedBox(
                    width: width,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MeasureSize(
                          onChange: _onFrontBodySize,
                          child: Padding(
                            padding: _bodyPadding,
                            child: _frontBody(),
                          ),
                        ),
                        _MeasureSize(
                          onChange: _onBackBodySize,
                          child: Padding(
                            padding: _bodyPadding,
                            child: _backBody(interactive: false),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: width.isFinite ? width : null,
                height: cardH,
                child: TurnableYAxisCard(
                  // Parent owns height — avoid outer padding eating face space.
                  outerPadding: EdgeInsets.zero,
                  resetIdentity: '${pack.packIndex}-$checkKind',
                  dismissKeyboardOnInteraction: true,
                  prelayoutFacesForHeight: false,
                  fixedFaceHeight: cardH,
                  initialBackFaceVisible: widget.startOnCheck,
                  interactionEnabled: !widget.startOnCheck || _revealed,
                  front: _LearnCardFace(
                    imageUrl: widget.imageUrl,
                    cachedBytes: widget.cachedBytes,
                    imageLoading: widget.imageLoading,
                    loadImageBytes: widget.loadImageBytes,
                    completed: widget.completed,
                    imageHeight: frontImageH,
                    scrollBody: frontScroll,
                    child: _frontBody(),
                  ),
                  back: _LearnCardFace(
                    imageUrl: widget.imageUrl,
                    cachedBytes: widget.cachedBytes,
                    imageLoading: widget.imageLoading,
                    loadImageBytes: widget.loadImageBytes,
                    completed: widget.completed,
                    imageHeight: backImageH,
                    scrollBody: backScroll,
                    feedback: (_revealed && _answerCorrect != null)
                        ? QuizFeedbackBadge.fromBit(
                            bit: pack.bit(checkKind),
                            correct: _answerCorrect!,
                          )
                        : null,
                    child: _backBody(),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LearnCardFace extends StatelessWidget {
  const _LearnCardFace({
    required this.child,
    required this.loadImageBytes,
    required this.imageHeight,
    required this.scrollBody,
    this.imageUrl,
    this.cachedBytes,
    this.imageLoading = false,
    this.completed = false,
    this.feedback,
  });

  final Widget child;
  final String? imageUrl;
  final Uint8List? cachedBytes;
  final bool imageLoading;
  final bool completed;
  final double imageHeight;
  final bool scrollBody;
  final Widget? feedback;
  final Future<List<int>?> Function(String imageUrl) loadImageBytes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = Padding(
      padding: _bodyPadding,
      child: child,
    );
    return ColoredBox(
      color: scheme.surfaceContainerHigh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                child: _LearnCardImage(
                  imageUrl: imageUrl,
                  cachedBytes: cachedBytes,
                  loading: imageLoading,
                  height: imageHeight,
                  loadImageBytes: loadImageBytes,
                ),
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
              if (feedback != null)
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 10,
                  child: feedback!,
                ),
            ],
          ),
          if (scrollBody)
            Expanded(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: body,
              ),
            )
          else
            // No Spacer — Column already fills the tight face height.
            body,
        ],
      ),
    );
  }
}

class _LearnCardImage extends StatefulWidget {
  const _LearnCardImage({
    required this.loadImageBytes,
    required this.height,
    this.imageUrl,
    this.cachedBytes,
    this.loading = false,
  });

  final String? imageUrl;
  final Uint8List? cachedBytes;
  final bool loading;
  final double height;
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
      unawaited(_load(force: true));
      return;
    }
    // Pack regenerate keeps the same URL — reload when the job finishes or
    // when GraphController hands us freshly cached bytes.
    if (oldWidget.loading && !widget.loading) {
      unawaited(_load(force: true));
      return;
    }
    final cached = widget.cachedBytes;
    if (cached != null &&
        cached.isNotEmpty &&
        !identical(cached, oldWidget.cachedBytes) &&
        !identical(cached, _bytes)) {
      setState(() {
        _bytes = cached;
        _loadedUrl = (widget.imageUrl ?? '').trim();
        _loadingBytes = false;
      });
      return;
    }
    if (_bytes == null && cached != null && cached.isNotEmpty) {
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

  Future<void> _load({bool force = false}) async {
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
    if (!force && url == _loadedUrl && _bytes != null) return;
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
    final showProgressOnImage = widget.loading && bytes != null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      height: widget.height,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (showPlaceholder)
              const PulsePlaceholder.image(borderRadius: radius)
            else if (bytes == null)
              ColoredBox(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.06),
              )
            else
              Image.memory(
                bytes,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
              ),
            if (showProgressOnImage)
              const ColoredBox(
                color: Color(0x4D000000),
                child: Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Reports child layout size after each layout pass.
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({
    required this.onChange,
    required Widget child,
  }) : super(child: child);

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderMeasureSize(onChange);
  }

  @override
  void updateRenderObject(BuildContext context, _RenderMeasureSize renderObject) {
    renderObject.onChange = onChange;
  }
}

class _RenderMeasureSize extends RenderProxyBox {
  _RenderMeasureSize(this.onChange);

  ValueChanged<Size> onChange;
  Size? _oldSize;

  @override
  void performLayout() {
    super.performLayout();
    final next = child?.size ?? Size.zero;
    if (_oldSize == next) return;
    _oldSize = next;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(next));
  }
}
