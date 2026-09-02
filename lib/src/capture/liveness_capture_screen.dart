/// The liveness challenge screen: a front-camera preview inside a circular guide
/// that shows each requested action in turn and records the frames a live
/// capture must supply. The first frame is a settled, front-facing still (grabbed
/// before any gesture prompt) so the verifier has a clean frontal face; the rest
/// are a short burst per requested action, which supplies the movement a live
/// capture shows. Nothing here reveals how verification works.
library;

import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../protocol.dart';
import '../theme.dart';
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
  String? _prompt;

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
      imageFormatGroup: ImageFormatGroup.jpeg,
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
  }

  Future<void> _run() async {
    final camera = _camera;
    if (camera == null || _running) return;
    setState(() => _running = true);

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
    _camera?.dispose();
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
            strings.livenessHint,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.text.withOpacity(0.75)),
          ),
          const SizedBox(height: 16),
          AspectRatio(
            aspectRatio: 1,
            child: ClipOval(
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
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: theme.accent, width: 3),
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
          ),
          const SizedBox(height: 16),
          if (!_running)
            SizedBox(
              height: 50,
              width: double.infinity,
              child: FilledButton(
                onPressed: _initialised ? _run : null,
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
