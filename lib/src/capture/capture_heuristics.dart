/// On-device, opacity-safe document capture heuristics used only to drive the
/// auto-capture UX — never to judge the image (the server does that). Computed
/// from the camera frame's luma (Y) plane; nothing here encodes a verification
/// threshold, model, or weight from the server.
///
///  • document presence — a card shows up as a band of strong edges filling the
///    guide plus a contrast step between the card interior and the darker border
///    ring. This mirrors the Web SDK's edge-density test.
///  • quality gates — glare (near-saturated interior pixels), exposure (interior
///    too dark or blown out) and a coarse blur/focus proxy, mirroring the
///    glare/blur/exposure gates the Web SDK's capture quality checks run. These fold into `present` so
///    hands-free capture waits for an acceptable frame; the manual shutter is
///    never gated. Thresholds are lenient framing aids and need on-device tuning.
///
/// The real face detector lives in `face_detector.dart` (ML Kit); this file no
/// longer proxies faces from luma.
library;

import 'dart:math' as math;

import 'package:camera/camera.dart';

/// Outcome of the document-presence + quality heuristics for one frame.
class DocSignal {
  const DocSignal({
    required this.present,
    required this.tooFar,
    this.glare = false,
    this.dark = false,
    this.blurry = false,
  });

  /// A card fills the guide, at acceptable quality, well enough to auto-capture.
  final bool present;

  /// A card is visible but too small — nudge the user closer.
  final bool tooFar;

  /// Heavy glare/reflection on the card interior (advisory + soft gate).
  final bool glare;

  /// Interior too dark or blown out (advisory + soft gate).
  final bool dark;

  /// Low interior gradient energy suggests an out-of-focus/blurred card
  /// (advisory only; not gated on its own to avoid stalling on plain cards).
  final bool blurry;

  static const DocSignal none = DocSignal(present: false, tooFar: false);
}

// Document tuning — deliberately lenient: this only decides *when to offer* the
// shutter; the server still judges the captured image.
const int _edgeStep = 18; // luma delta between samples that counts as an edge
const double _edgeDensityFloor = 0.012;
const double _contrastStepFloor = 10;
const double _farDensity = 0.006;

// Quality gates (lenient; tune on real devices).
const double _glareFloor = 0.12; // fraction of near-saturated interior samples
const int _brightLevel = 245; // luma counted as "near saturated"
const double _darkMean = 30; // interior mean below → underexposed
const double _brightMean = 235; // interior mean above → overexposed
const double _blurGradFloor = 6.0; // mean |gradient| below → likely soft/blurred

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
  if (w < 16 || h < 16) return DocSignal.none;

  final roiW = (w * 0.84).round();
  final roiH = math.min((roiW / 1.586).round(), (h * 0.84).round());
  final left = (w - roiW) ~/ 2;
  final top = (h - roiH) ~/ 2;

  const cols = 24;
  const rows = 16;
  var interiorSum = 0;
  var interiorN = 0;
  var edgePx = 0;
  var brightN = 0;
  var gradSum = 0; // Σ|Δluma| between adjacent samples → focus/blur proxy
  for (var r = 0; r < rows; r++) {
    final py = top + roiH * r ~/ (rows - 1);
    var prev = -1;
    for (var c = 0; c <= cols; c++) {
      final px = left + roiW * c ~/ cols;
      final v = _luma(image, px, py);
      interiorSum += v;
      interiorN++;
      if (v >= _brightLevel) brightN++;
      if (prev >= 0) {
        final d = (v - prev).abs();
        gradSum += d;
        if (d >= _edgeStep) edgePx++;
      }
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
  final glareFrac = interiorN > 0 ? brightN / interiorN : 0.0;
  final gradMean = interiorN > 1 ? gradSum / (interiorN - rows) : 0.0;

  final hasCard = edgeDensity > _edgeDensityFloor && contrast > _contrastStepFloor;
  final glare = glareFrac > _glareFloor;
  final dark = interiorMean < _darkMean || interiorMean > _brightMean;
  final blurry = hasCard && gradMean < _blurGradFloor;

  // Soft-gate hands-free capture on glare/exposure so the auto-fire waits for an
  // acceptable frame; blur stays advisory to avoid stalling on plain-face cards.
  final present = hasCard && !glare && !dark;
  final tooFar = !hasCard && edgeDensity >= _farDensity && edgeDensity <= _edgeDensityFloor;
  return DocSignal(
    present: present,
    tooFar: tooFar,
    glare: glare,
    dark: dark,
    blurry: blurry,
  );
}
