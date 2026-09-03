/// Real on-device face detection for the liveness fit-oval, replacing the earlier
/// centre-vs-corner luma proxy. This wraps Google ML Kit's on-device face
/// detector (`google_mlkit_face_detection`) — the same class of face-detection
/// model used on the web — and derives the framing signal (face
/// present, centred and large enough to fill the oval) plus an advisory
/// face-quality superset (too close, pose off-axis, eyes closed) that mirrors the
/// hints the web capture surfaces. It stays a framing aid: nothing here encodes
/// a verification threshold or model weight from the server, and the server still
/// judges the captured frames.
///
/// If a frame cannot be converted for the detector on this device/format, it
/// falls back to the lightweight luma proxy so auto-start still degrades
/// gracefully rather than stalling.
library;

import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Outcome of the face-fit analysis for one frame.
///
/// [fit] and [present] are the framing signals the liveness screen gates on; the
/// remaining flags are advisory quality hints (they never gate on their own).
class FaceSignal {
  const FaceSignal({
    required this.fit,
    required this.present,
    this.tooClose = false,
    this.poseOff = false,
    this.eyesClosed = false,
  });

  /// A single centred subject fills the oval well enough to auto-start.
  final bool fit;

  /// A face is visible but not yet framed.
  final bool present;

  /// The face fills too much of the frame (nudge the user back).
  final bool tooClose;

  /// Head yaw/pitch/roll is off-axis (advisory).
  final bool poseOff;

  /// One or both eyes read as closed (advisory).
  final bool eyesClosed;

  static const FaceSignal none = FaceSignal(fit: false, present: false);
}

/// ML Kit-backed face detector. Construct once per capture screen and [close] it
/// on dispose. [analyze] is safe to call from the camera image stream; it
/// self-throttles by dropping frames while a detection is already in flight.
class BlinkFaceDetector {
  BlinkFaceDetector({required this.lensDirection, required this.sensorOrientation});

  /// Which camera the frames come from (front for liveness).
  final CameraLensDirection lensDirection;

  /// The camera sensor orientation in degrees (from [CameraDescription]).
  final int sensorOrientation;

  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      // Classification gives eyes-open / smiling probabilities for the advisory
      // quality hints; landmarks + fast mode keep it cheap enough per frame.
      enableClassification: true,
      enableLandmarks: true,
      enableTracking: false,
      performanceMode: FaceDetectorMode.fast,
      minFaceSize: 0.15,
    ),
  );

  bool _busy = false;
  bool _closed = false;

  /// Analyse one camera frame. Returns [FaceSignal.none] while busy or on any
  /// conversion/detection failure the caller should ignore. When the frame cannot
  /// be handed to ML Kit (unsupported format), it falls back to the luma proxy so
  /// the fit-oval still greens.
  Future<FaceSignal> analyze(CameraImage image) async {
    if (_closed || _busy) return FaceSignal.none;
    _busy = true;
    try {
      final input = _toInputImage(image);
      if (input == null) return _lumaProxy(image);
      final faces = await _detector.processImage(input);
      if (faces.isEmpty) return FaceSignal.none;
      return _signalFor(faces, image.width, image.height);
    } catch (_) {
      return _lumaProxy(image);
    } finally {
      _busy = false;
    }
  }

  Future<void> close() async {
    _closed = true;
    await _detector.close();
  }

  FaceSignal _signalFor(List<Face> faces, int w, int h) {
    // Pick the largest face; a single centred face fills the oval.
    Face largest = faces.first;
    for (final f in faces) {
      if (f.boundingBox.height > largest.boundingBox.height) largest = f;
    }
    final box = largest.boundingBox;
    final fill = math.max(box.width / w, box.height / h);
    final cx = (box.left + box.width / 2) / w;
    final cy = (box.top + box.height / 2) / h;
    final centred = (cx - 0.5).abs() < 0.22 && (cy - 0.5).abs() < 0.24;
    final bigEnough = fill > 0.34;
    final tooClose = fill > 0.82;

    final yaw = largest.headEulerAngleY ?? 0; // left/right
    final pitch = largest.headEulerAngleX ?? 0; // up/down
    final roll = largest.headEulerAngleZ ?? 0; // tilt
    final poseOff = yaw.abs() > 18 || pitch.abs() > 18 || roll.abs() > 18;

    final left = largest.leftEyeOpenProbability;
    final right = largest.rightEyeOpenProbability;
    final eyesClosed = (left != null && left < 0.35) && (right != null && right < 0.35);

    return FaceSignal(
      fit: faces.length == 1 && centred && bigEnough && !tooClose && !poseOff,
      present: true,
      tooClose: tooClose,
      poseOff: poseOff,
      eyesClosed: eyesClosed,
    );
  }

  /// Build the ML Kit [InputImage] from a camera frame. Follows the canonical
  /// `google_ml_kit` recipe: NV21 single-plane on Android, BGRA8888 on iOS, with
  /// the rotation compensated for the sensor + lens. Returns null when the format
  /// is not one ML Kit accepts (the caller then uses the luma proxy).
  InputImage? _toInputImage(CameraImage image) {
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else {
      // Portrait-locked capture; compensate lens mirroring for the front camera.
      var compensation = 0;
      if (lensDirection == CameraLensDirection.front) {
        compensation = (sensorOrientation + 0) % 360;
      } else {
        compensation = (sensorOrientation - 0 + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(compensation);
    }
    if (rotation == null) return null;

    // `image.format.raw` is dynamic in the camera plugin (int on both platforms).
    final rawFormat = image.format.raw;
    final format =
        rawFormat is int ? InputImageFormatValue.fromRawValue(rawFormat) : null;
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }
    if (image.planes.length != 1) return null;
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  // ── Fallback luma proxy ─────────────────────────────────────────────────────
  // Retained only for frames ML Kit can't ingest: a centred subject carries more
  // edge energy in the centre than the corners (plain background). Never a model.

  static const int _edgeStep = 18;
  static const double _centreEdgeFloor = 0.03;
  static const double _centreToCornerRatio = 1.8;

  int _luma(CameraImage image, int x, int y) {
    final plane = image.planes[0];
    final bpp = plane.bytesPerPixel ?? 1;
    final cx = x.clamp(0, image.width - 1);
    final cy = y.clamp(0, image.height - 1);
    final idx = cy * plane.bytesPerRow + cx * bpp;
    if (idx < 0 || idx >= plane.bytes.length) return 0;
    return plane.bytes[idx];
  }

  double _edgeDensityIn(
    CameraImage image,
    int left,
    int top,
    int boxW,
    int boxH,
    int cols,
    int rows,
  ) {
    var edgePx = 0;
    var n = 0;
    for (var r = 0; r < rows; r++) {
      final py = top + boxH * r ~/ math.max(1, rows - 1);
      var prev = -1;
      for (var c = 0; c <= cols; c++) {
        final px = left + boxW * c ~/ cols;
        final v = _luma(image, px, py);
        if (prev >= 0 && (v - prev).abs() >= _edgeStep) edgePx++;
        n++;
        prev = v;
      }
    }
    return n > 0 ? edgePx / n : 0.0;
  }

  FaceSignal _lumaProxy(CameraImage image) {
    final w = image.width;
    final h = image.height;
    if (w < 16 || h < 16) return FaceSignal.none;

    final side = (math.min(w, h) * 0.5).round();
    final cLeft = (w - side) ~/ 2;
    final cTop = (h - side) ~/ 2;
    final centre = _edgeDensityIn(image, cLeft, cTop, side, side, 20, 20);

    final cornerBox = (math.min(w, h) * 0.18).round();
    final corners = <double>[
      _edgeDensityIn(image, 0, 0, cornerBox, cornerBox, 8, 8),
      _edgeDensityIn(image, w - cornerBox, 0, cornerBox, cornerBox, 8, 8),
      _edgeDensityIn(image, 0, h - cornerBox, cornerBox, cornerBox, 8, 8),
      _edgeDensityIn(image, w - cornerBox, h - cornerBox, cornerBox, cornerBox, 8, 8),
    ];
    final cornerAvg = corners.reduce((a, b) => a + b) / corners.length;

    final present = centre > _centreEdgeFloor * 0.6;
    final fit = centre > _centreEdgeFloor &&
        (cornerAvg <= 0.0001 || centre / cornerAvg >= _centreToCornerRatio);
    return FaceSignal(fit: fit, present: present);
  }
}
