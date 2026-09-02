/// Theming and copy for the drop-in capture UI. Nothing here reveals how
/// verification works — it only styles the camera experience.
library;

import 'package:flutter/painting.dart';

/// Colours for the drop-in capture UI. All fields have sensible defaults, so
/// override only what you need.
class BlinkTheme {
  const BlinkTheme({
    this.accent = const Color(0xFF22C55E),
    this.background = const Color(0xFF0F1729),
    this.text = const Color(0xFFF4F6FB),
  });

  /// Accent colour for controls and the framing guide.
  final Color accent;

  /// Background colour behind the camera.
  final Color background;

  /// Text colour.
  final Color text;

  BlinkTheme copyWith({Color? accent, Color? background, Color? text}) =>
      BlinkTheme(
        accent: accent ?? this.accent,
        background: background ?? this.background,
        text: text ?? this.text,
      );
}

/// User-facing copy for the drop-in capture UI. Override to localise.
class BlinkStrings {
  const BlinkStrings({
    this.documentTitle = 'Scan your document',
    this.documentHint = 'Fit the document inside the frame, then capture.',
    this.captureButton = 'Capture',
    this.retake = 'Retake',
    this.use = 'Use photo',
    this.livenessTitle = 'Liveness check',
    this.livenessHint = 'Follow the prompts. Keep your face inside the circle.',
    this.startButton = 'Start',
    this.granting = 'Requesting camera…',
    this.working = 'Working…',
    this.cameraDenied = 'Camera access is required to continue.',
    this.doneLabel = 'Done',
  });

  final String documentTitle;
  final String documentHint;
  final String captureButton;
  final String retake;
  final String use;
  final String livenessTitle;
  final String livenessHint;
  final String startButton;
  final String granting;
  final String working;
  final String cameraDenied;
  final String doneLabel;
}
