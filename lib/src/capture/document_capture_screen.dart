/// The document framing/capture screen: a live back-camera preview with a
/// framing guide, a capture control, and a retake/confirm review. Nothing here
/// reveals how verification works.
library;

import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../protocol.dart';
import '../theme.dart';
import 'flow_controller.dart';

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
  Uint8List? _shot;

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

  Future<void> _capture() async {
    final camera = _camera;
    if (camera == null || _capturing) return;
    setState(() => _capturing = true);
    try {
      final file = await camera.takePicture();
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() {
        _shot = bytes;
        _capturing = false;
      });
    } catch (error, stackTrace) {
      widget.controller.failCapture(
        BlinkError(BlinkErrorCode.cameraDenied, widget.strings.cameraDenied, 0),
        stackTrace,
      );
    }
  }

  void _retake() => setState(() => _shot = null);

  void _use() {
    final shot = _shot;
    if (shot != null) widget.controller.provideDocument(shot);
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
            strings.documentHint,
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
                    _DocumentGuide(color: theme.accent)
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
          const SizedBox(height: 16),
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

class _DocumentGuide extends StatelessWidget {
  const _DocumentGuide({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
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
