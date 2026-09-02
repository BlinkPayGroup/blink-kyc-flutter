/// On-device, opacity-safe capture heuristics used only to drive the auto-capture
/// UX — never to judge the image (the server does that). Both signals are computed
/// from the camera frame's luma (Y) plane; nothing here encodes a verification
/// threshold, model, or weight from the server.
///
///  • document presence — a card shows up as a band of strong edges filling the
///    guide plus a contrast step between the card interior and the darker border
///    ring. This mirrors the Web SDK's edge-density test.
///  • face fit — a centred subject with facial detail fills the oval: the centre
///    region carries far more edge energy than the corners (which see the plain
///    background). A lightweight luma heuristic, no face model shipped.
library;

import 'dart:math' as math;

import 'package:camera/camera.dart';

/// Outcome of the document-presence heuristic for one frame.
class DocSignal {
  const DocSignal({required this.present, required this.tooFar});

  /// A card fills the guide well enough to auto-capture.
  final bool present;

  /// A card is visible but too small — nudge the user closer.
  final bool tooFar;
}

/// Outcome of the face-fit heuristic for one frame.
class FaceSignal {
  const FaceSignal({required this.fit, required this.present});

  /// A centred subject fills the oval well enough to auto-start.
  final bool fit;

  /// Some centred subject is present but not yet framed.
  final bool present;
}

// Document tuning — deliberately lenient: this only decides *when to offer* the
// shutter; the server still judges the captured image.
const int _edgeStep = 18; // luma delta between samples that counts as an edge
const double _edgeDensityFloor = 0.012;
const double _contrastStepFloor = 10;
const double _farDensity = 0.006;

int _luma(CameraImage image, int x, int y) {
  final plane = image.planes[0];
  final bpp = plane.bytesPerPixel ?? 1;
  final cx = x.clamp(0, image.width - 1);
  final cy = y.clamp(0, image.height - 1);
  final idx = cy * plane.bytesPerRow + cx * bpp;
  if (idx < 0 || idx >= plane.bytes.length) return 0;
  return plane.bytes[idx];
}

/// Inspect a centred, card-shaped region of the luma plane on a coarse grid.
DocSignal analyzeDocument(CameraImage image) {
  final w = image.width;
  final h = image.height;
  if (w < 16 || h < 16) return const DocSignal(present: false, tooFar: false);

  final roiW = (w * 0.84).round();
  final roiH = math.min((roiW / 1.586).round(), (h * 0.84).round());
  final left = (w - roiW) ~/ 2;
  final top = (h - roiH) ~/ 2;

  const cols = 24;
  const rows = 16;
  var interiorSum = 0;
  var interiorN = 0;
  var edgePx = 0;
  for (var r = 0; r < rows; r++) {
    final py = top + roiH * r ~/ (rows - 1);
    var prev = -1;
    for (var c = 0; c <= cols; c++) {
      final px = left + roiW * c ~/ cols;
      final v = _luma(image, px, py);
      interiorSum += v;
      interiorN++;
      if (prev >= 0 && (v - prev).abs() >= _edgeStep) edgePx++;
      prev = v;
    }
  }

  var ringSum = 0;
  var ringN = 0;
  final pad = math.max(6, roiW ~/ 40);
  for (var c = 0; c <= cols; c++) {
    final px = left + roiW * c ~/ cols;
    ringSum += _luma(image, px, top - pad);
    ringSum += _luma(image, px, top + roiH + pad);
    ringN += 2;
  }
  for (var r = 0; r < rows; r++) {
    final py = top + roiH * r ~/ (rows - 1);
    ringSum += _luma(image, left - pad, py);
    ringSum += _luma(image, left + roiW + pad, py);
    ringN += 2;
  }

  final edgeDensity = interiorN > 0 ? edgePx / interiorN : 0.0;
  final interiorMean = interiorN > 0 ? interiorSum / interiorN : 0.0;
  final ringMean = ringN > 0 ? ringSum / ringN : 0.0;
  final contrast = (interiorMean - ringMean).abs();

  final present = edgeDensity > _edgeDensityFloor && contrast > _contrastStepFloor;
  final tooFar = !present && edgeDensity >= _farDensity && edgeDensity <= _edgeDensityFloor;
  return DocSignal(present: present, tooFar: tooFar);
}

// Face tuning — the centre must carry clearly more edge energy than the corners.
const double _centreEdgeFloor = 0.03;
const double _centreToCornerRatio = 1.8;

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

/// A face fills the oval when the central region carries markedly more detail
/// than the corners (which see the plain background).
FaceSignal analyzeFace(CameraImage image) {
  final w = image.width;
  final h = image.height;
  if (w < 16 || h < 16) return const FaceSignal(fit: false, present: false);

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
