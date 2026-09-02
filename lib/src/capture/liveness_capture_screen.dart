/// The liveness challenge screen: a front-camera preview inside an oval guide
/// that greens when the face is centred and large enough, then starts the
/// challenge automatically — the same hands-free flow the reference bank screens
/// use (a manual Start remains for anyone who prefers it). The first frame is a
/// settled, front-facing still (grabbed before any gesture prompt) so the
/// verifier has a clean frontal face; the rest are a short burst per requested
/// action, which supplies the movement a live capture shows. Face detection is a
/// framing aid only; nothing here reveals how verification works.
library;

import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../protocol.dart';
import '../theme.dart';
import 'capture_heuristics.dart';
import 'flow_controller.dart';

/// Max frames the server accepts for one liveness submission.
const int _maxFrames = 12;

/// Minimum frames a live capture must contain.
const int _minFrames = 3;

/// Settle time before grabbing the primary frontal still, so it is not a
/// mid-motion blur.
const Duration _settleDelay = Duration(milliseconds: 900);

/// Delay before the first grab of an action, to let the user perform it.
const Duration _perActionDelay = Duration(milliseconds: 1400);

/// Gap before the second grab of an action, so the pair carries motion.
const Duration _burstGap = Duration(milliseconds: 400);

/// Gap between grabs in the fallback burst for a degenerate challenge.
const Duration _fallbackGap = Duration(milliseconds: 450);

/// Face held in the oval before the challenge auto-starts.
const int _fitDwellMs = 900;
const int _fitGraceMs = 300;
const int _analyzeIntervalMs = 140;

/// Shown while [BlinkFlowController.stage] is [BlinkStage.liveness].
class LivenessCaptureScreen extends StatefulWidget {
  const LivenessCaptureScreen({
    super.key,
    required this.controller,
    required this.cameras,
    required this.theme,
    required this.strings,
  });

  final BlinkFlowController controller;
  final List<CameraDescription> cameras;
  final BlinkTheme theme;
  final BlinkStrings strings;

  @override
  State<LivenessCaptureScreen> createState() => _LivenessCaptureScreenState();
}

class _LivenessCaptureScreenState extends State<LivenessCaptureScreen> {
  CameraController? _camera;
  bool _initialised = false;
  bool _running = false;
  bool _streaming = false;
  String? _prompt;

  bool _matched = false;
  double _progress = 0;
  int _fitSince = 0;
  int _lastAnalyzedAt = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final description = _pickCamera(widget.cameras, CameraLensDirection.front);
    final camera = CameraController(
      description,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await camera.initialize();
    } catch (error, stackTrace) {
      widget.controller.failCapture(
        BlinkError(BlinkErrorCode.cameraDenied, widget.strings.cameraDenied, 0),
        stackTrace,
      );
      return;
    }
    if (!mounted) {
      await camera.dispose();
      return;
    }
    setState(() {
      _camera = camera;
      _initialised = true;
    });
    await _startDetection();
  }

  Future<void> _startDetection() async {
    final camera = _camera;
    if (camera == null || _streaming || _running) return;
    try {
      await camera.startImageStream(_onFrame);
      _streaming = true;
    } catch (_) {
      // If streaming is unavailable, the manual Start button still works.
    }
  }

  Future<void> _stopDetection() async {
    final camera = _camera;
    if (camera == null || !_streaming) return;
    try {
      await camera.stopImageStream();
    } catch (_) {
      // ignore
    }
    _streaming = false;
  }

  void _onFrame(CameraImage image) {
    if (!mounted || _running) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastAnalyzedAt < _analyzeIntervalMs) return;
    _lastAnalyzedAt = now;

    final signal = analyzeFace(image);
    if (signal.fit) {
      if (_fitSince == 0) _fitSince = now;
      final held = now - _fitSince;
      setState(() {
        _matched = true;
        _progress = (held / _fitDwellMs).clamp(0.0, 1.0);
      });
      if (held >= _fitDwellMs) _autoStart();
    } else {
      if (_fitSince != 0 && now - _fitSince < _fitGraceMs) return;
      _fitSince = 0;
      setState(() {
        _matched = false;
        _progress = 0;
      });
    }
  }

  Future<void> _autoStart() async {
    if (_running) return;
    await _stopDetection();
    await _run();
  }

  Future<void> _manualStart() async {
    if (_running) return;
    await _stopDetection();
    await _run();
  }

  Future<void> _run() async {
    final camera = _camera;
    if (camera == null || _running) return;
    setState(() {
      _running = true;
      _matched = true;
      _progress = 0;
    });

    final frames = <Uint8List>[];
    try {
      // 1) Primary frontal frame — a settled still grabbed before any gesture
      //    prompt, so the verifier scores a sharp frontal face, never a blur.
      if (!mounted) return;
      setState(() => _prompt = 'Look straight ahead');
      await Future<void>.delayed(_settleDelay);
      if (!mounted) return;
      frames.add(await _grab(camera));

      // 2) A short two-frame burst per requested action supplies the inter-frame
      //    motion a live capture must show.
      final actions = widget.controller.actions.isNotEmpty
          ? widget.controller.actions.toList()
          : const ['MOVE_CLOSER', 'TURN_HEAD_RIGHT'];
      final perAction = ((_maxFrames - 1 - frames.length) ~/ actions.length)
          .clamp(1, 2);
      for (final action in actions) {
        if (frames.length >= _maxFrames) break;
        if (!mounted) return;
        setState(() => _prompt = _humanAction(action));
        await Future<void>.delayed(_perActionDelay);
        if (!mounted) return;
        frames.add(await _grab(camera));
        if (perAction > 1 && frames.length < _maxFrames) {
          await Future<void>.delayed(_burstGap);
          if (!mounted) return;
          frames.add(await _grab(camera));
        }
      }

      // 3) Guarantee enough frames with motion even for a degenerate challenge.
      while (frames.length < _minFrames) {
        if (!mounted) return;
        setState(() => _prompt = 'Move a little closer');
        await Future<void>.delayed(_fallbackGap);
        if (!mounted) return;
        frames.add(await _grab(camera));
      }

      if (!mounted) return;
      setState(() => _prompt = '✓');
      widget.controller.provideLiveness(frames.take(_maxFrames).toList());
    } catch (error, stackTrace) {
      widget.controller.failCapture(
        BlinkError(BlinkErrorCode.cameraDenied, widget.strings.cameraDenied, 0),
        stackTrace,
      );
    }
  }

  @override
  void dispose() {
    final camera = _camera;
    if (camera != null && _streaming) {
      camera.stopImageStream().catchError((_) {});
    }
    camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final strings = widget.strings;

    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            strings.livenessTitle,
            style: TextStyle(
              color: theme.text,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _running
                ? strings.livenessHint
                : (_matched ? strings.livenessHintFit : strings.livenessHint),
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.text.withOpacity(0.75)),
          ),
          const SizedBox(height: 16),
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipOval(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(color: Colors.black),
                      if (_initialised && _camera != null)
                        _CameraFill(controller: _camera!)
                      else
                        Center(
                          child: Text(
                            strings.granting,
                            style: TextStyle(color: theme.text),
                          ),
                        ),
                    ],
                  ),
                ),
                IgnorePointer(
                  child: CustomPaint(
                    painter: _FaceOvalPainter(
                      color: _matched ? const Color(0xFF22C55E) : theme.accent,
                      matched: _matched,
                      progress: _progress,
                    ),
                  ),
                ),
                if (_prompt != null)
                  Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: _PromptPill(text: _prompt!),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (!_running)
            SizedBox(
              height: 50,
              width: double.infinity,
              child: FilledButton(
                onPressed: _initialised ? _manualStart : null,
                style: FilledButton.styleFrom(
                  backgroundColor: theme.accent,
                  foregroundColor: const Color(0xFF08131F),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  strings.startButton,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            )
          else
            SizedBox(
              height: 50,
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    valueColor: AlwaysStoppedAnimation<Color>(theme.accent),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PromptPill extends StatelessWidget {
  const _PromptPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Draws the oval face guide plus a countdown ring during the fit dwell.
class _FaceOvalPainter extends CustomPainter {
  _FaceOvalPainter({
    required this.color,
    required this.matched,
    required this.progress,
  });

  final Color color;
  final bool matched;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = color;
    canvas.drawOval(rect, border);

    if (progress > 0) {
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF22C55E);
      final path = Path()..addOval(rect);
      for (final metric in path.computeMetrics()) {
        canvas.drawPath(
          metric.extractPath(0, metric.length * progress.clamp(0.0, 1.0)),
          ring,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_FaceOvalPainter old) =>
      old.progress != progress || old.matched != matched || old.color != color;
}

/// Fills its box with the camera preview at the camera's native aspect ratio.
class _CameraFill extends StatelessWidget {
  const _CameraFill({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: controller.value.previewSize?.height ?? 1,
        height: controller.value.previewSize?.width ?? 1,
        child: CameraPreview(controller),
      ),
    );
  }
}

CameraDescription _pickCamera(
  List<CameraDescription> cameras,
  CameraLensDirection preferred,
) {
  for (final camera in cameras) {
    if (camera.lensDirection == preferred) return camera;
  }
  return cameras.first;
}

/// Human-readable label for a liveness action.
String _humanAction(String action) {
  const map = <String, String>{
    'BLINK': 'Blink',
    'TURN_HEAD_LEFT': 'Turn your head left',
    'TURN_HEAD_RIGHT': 'Turn your head right',
    'LOOK_STRAIGHT': 'Look straight ahead',
    'SMILE': 'Smile',
    'MOVE_CLOSER': 'Move a little closer',
    'NOD': 'Nod',
  };
  return map[action] ?? action.replaceAll('_', ' ').toLowerCase();
}

/// Grab a single frame from the live preview as JPEG bytes.
Future<Uint8List> _grab(CameraController camera) async {
  final file = await camera.takePicture();
  return file.readAsBytes();
}
