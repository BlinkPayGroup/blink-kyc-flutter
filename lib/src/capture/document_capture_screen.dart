/// The document framing/capture screen: a live back-camera preview with a
/// framing guide that auto-detects the document on-device, holds while it
/// settles, runs a short countdown ring, and captures hands-free — the same flow
/// the reference bank screens use (auto-capture can be toggled off for a manual
/// shutter). A retake/confirm review follows. Detection here is a framing aid
/// only; nothing reveals how verification works.
library;

import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../protocol.dart';
import '../theme.dart';
import 'capture_heuristics.dart';
import 'flow_controller.dart';

/// Steady time before the shutter fires.
const int _holdMs = 1100;

/// Brief loss of detection tolerated without resetting the countdown.
const int _graceMs = 250;

/// Minimum spacing between analysed frames.
const int _analyzeIntervalMs = 110;

/// Session-scoped auto-capture preference (mirrors the Web SDK's sessionStorage
/// toggle without adding a persistence dependency).
bool _autoCaptureEnabled = true;

/// Shown while [BlinkFlowController.stage] is [BlinkStage.document].
class DocumentCaptureScreen extends StatefulWidget {
  const DocumentCaptureScreen({
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
  State<DocumentCaptureScreen> createState() => _DocumentCaptureScreenState();
}

class _DocumentCaptureScreenState extends State<DocumentCaptureScreen> {
  CameraController? _camera;
  bool _initialised = false;
  bool _capturing = false;
  bool _streaming = false;
  Uint8List? _shot;

  bool _auto = _autoCaptureEnabled;
  bool _matched = false;
  double _progress = 0;
  bool _tooFar = false;
  int _stableSince = 0;
  int _lastAnalyzedAt = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final description = _pickCamera(widget.cameras, CameraLensDirection.back);
    final camera = CameraController(
      description,
      ResolutionPreset.high,
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
    if (camera == null || _streaming || !_auto || _shot != null) return;
    try {
      await camera.startImageStream(_onFrame);
      _streaming = true;
    } catch (_) {
      // If streaming is unavailable, the manual shutter still works.
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
    if (!mounted || _capturing || _shot != null || !_auto) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastAnalyzedAt < _analyzeIntervalMs) return;
    _lastAnalyzedAt = now;

    final signal = analyzeDocument(image);
    if (signal.present) {
      if (_stableSince == 0) _stableSince = now;
      final held = now - _stableSince;
      final p = (held / _holdMs).clamp(0.0, 1.0);
      setState(() {
        _matched = true;
        _tooFar = false;
        _progress = p;
      });
      if (held >= _holdMs) _autoTrigger();
    } else {
      if (_stableSince != 0 && now - _stableSince < _graceMs && !signal.tooFar) {
        return;
      }
      _stableSince = 0;
      setState(() {
        _matched = false;
        _tooFar = signal.tooFar;
        _progress = 0;
      });
    }
  }

  Future<void> _autoTrigger() async {
    if (_capturing || _shot != null) return;
    await _capture();
  }

  Future<void> _capture() async {
    final camera = _camera;
    if (camera == null || _capturing) return;
    setState(() {
      _capturing = true;
      _progress = 0;
    });
    await _stopDetection();
    try {
      final file = await camera.takePicture();
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _shot = bytes;
        _capturing = false;
        _matched = false;
      });
    } catch (error, stackTrace) {
      widget.controller.failCapture(
        BlinkError(BlinkErrorCode.cameraDenied, widget.strings.cameraDenied, 0),
        stackTrace,
      );
    }
  }

  Future<void> _retake() async {
    setState(() {
      _shot = null;
      _stableSince = 0;
      _matched = false;
      _progress = 0;
    });
    await _startDetection();
  }

  void _use() {
    final shot = _shot;
    if (shot != null) widget.controller.provideDocument(shot);
  }

  void _toggleAuto() {
    setState(() {
      _auto = !_auto;
      _autoCaptureEnabled = _auto;
      _matched = false;
      _progress = 0;
      _stableSince = 0;
    });
    if (_auto) {
      _startDetection();
    } else {
      _stopDetection();
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

  String get _hint {
    if (!_auto) return widget.strings.documentHintManual;
    if (_matched) return widget.strings.documentHintHold;
    if (_tooFar) return widget.strings.documentHintFar;
    return widget.strings.documentHint;
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final strings = widget.strings;
    final shot = _shot;

    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            strings.documentTitle,
            style: TextStyle(
              color: theme.text,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _hint,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.text.withOpacity(0.75)),
          ),
          const SizedBox(height: 16),
          AspectRatio(
            aspectRatio: 3 / 2,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: Colors.black),
                  if (shot != null)
                    Image.memory(shot, fit: BoxFit.cover)
                  else if (_initialised && _camera != null)
                    _CameraFill(controller: _camera!),
                  if (shot == null)
                    CustomPaint(
                      painter: _DocumentGuidePainter(
                        color: _matched ? const Color(0xFF22C55E) : theme.accent,
                        matched: _matched,
                        progress: _progress,
                      ),
                    )
                  else
                    const SizedBox.shrink(),
                  if (!_initialised && shot == null)
                    Center(
                      child: Text(
                        strings.granting,
                        style: TextStyle(color: theme.text),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (shot == null)
            GestureDetector(
              onTap: _toggleAuto,
              child: Text(
                _auto ? strings.autoCaptureOn : strings.autoCaptureOff,
                style: TextStyle(
                  color: theme.text.withOpacity(0.85),
                  fontSize: 13,
                ),
              ),
            ),
          const SizedBox(height: 10),
          if (shot == null)
            _PrimaryButton(
              label: strings.captureButton,
              theme: theme,
              onPressed: _initialised && !_capturing ? _capture : null,
            )
          else
            Row(
              children: [
                Expanded(
                  child: _GhostButton(
                    label: strings.retake,
                    theme: theme,
                    onPressed: _retake,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _PrimaryButton(
                    label: strings.use,
                    theme: theme,
                    onPressed: _use,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
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

/// Draws the card framing guide plus a countdown ring around it during the
/// auto-capture hold.
class _DocumentGuidePainter extends CustomPainter {
  _DocumentGuidePainter({
    required this.color,
    required this.matched,
    required this.progress,
  });

  final Color color;
  final bool matched;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(18, 22, size.width - 18, size.height - 22);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(12));
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = matched ? 3 : 2
      ..color = color;
    canvas.drawRRect(rrect, border);

    if (progress > 0) {
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF22C55E);
      final path = Path()..addRRect(rrect);
      final metrics = path.computeMetrics().toList();
      for (final metric in metrics) {
        canvas.drawPath(
          metric.extractPath(0, metric.length * progress.clamp(0.0, 1.0)),
          ring,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DocumentGuidePainter old) =>
      old.progress != progress || old.matched != matched || old.color != color;
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.theme,
    required this.onPressed,
  });

  final String label;
  final BlinkTheme theme;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      width: double.infinity,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: theme.accent,
          foregroundColor: const Color(0xFF08131F),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.label,
    required this.theme,
    required this.onPressed,
  });

  final String label;
  final BlinkTheme theme;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.text,
          side: BorderSide(color: theme.text.withOpacity(0.2)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
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
