/// Bridges the protocol loop (in [runBlinkFlow]) with the capture widgets. The
/// loop `await`s [captureDocument] / [captureLiveness]; the widgets drive the
/// camera and hand media back via [provideDocument] / [provideLiveness]. Nothing
/// here reveals how verification works.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../blink_kyc.dart' show BlinkCapture;
import '../protocol.dart';
import '../theme.dart';

/// Which screen the drop-in UI should be showing.
enum BlinkStage {
  /// A short transitional/loading state (fetching a challenge, submitting).
  preparing,

  /// The document framing/capture screen.
  document,

  /// The liveness challenge screen.
  liveness,

  /// Media handed off; waiting on the server.
  submitting,

  /// The flow finished successfully.
  done,

  /// The flow failed.
  failed,
}

/// A [ChangeNotifier] the drop-in UI listens to, and a [BlinkCapture] the
/// protocol loop pulls media from.
class BlinkFlowController extends ChangeNotifier implements BlinkCapture {
  BlinkFlowController({required this.theme, required this.strings});

  /// Colours for the UI.
  final BlinkTheme theme;

  /// Copy for the UI.
  final BlinkStrings strings;

  BlinkStage _stage = BlinkStage.preparing;
  List<String> _actions = const [];
  DocumentType? _documentType;
  DocumentSide? _documentSide;
  Object? _error;
  bool _disposed = false;

  Completer<Uint8List>? _document;
  Completer<List<Uint8List>>? _liveness;

  /// The screen currently requested.
  BlinkStage get stage => _stage;

  /// The liveness actions the user must perform (valid in [BlinkStage.liveness]).
  List<String> get actions => _actions;

  /// The requested document type, if any.
  DocumentType? get documentType => _documentType;

  /// The requested document side, if any.
  DocumentSide? get documentSide => _documentSide;

  /// The failure, when [stage] is [BlinkStage.failed].
  Object? get error => _error;

  @override
  Future<Uint8List> captureDocument(DocumentType? type, DocumentSide? side) {
    _documentType = type;
    _documentSide = side;
    final completer = _document = Completer<Uint8List>();
    _set(BlinkStage.document);
    return completer.future;
  }

  @override
  Future<List<Uint8List>> captureLiveness(List<String> actions) {
    _actions = actions.isEmpty ? const ['LOOK_STRAIGHT'] : actions;
    final completer = _liveness = Completer<List<Uint8List>>();
    _set(BlinkStage.liveness);
    return completer.future;
  }

  /// Called by the document screen once the user confirms a photo.
  void provideDocument(Uint8List image) {
    final completer = _document;
    if (completer != null && !completer.isCompleted) {
      _set(BlinkStage.submitting);
      completer.complete(image);
    }
  }

  /// Called by the liveness screen once all frames are recorded.
  void provideLiveness(List<Uint8List> frames) {
    final completer = _liveness;
    if (completer != null && !completer.isCompleted) {
      _set(BlinkStage.submitting);
      completer.complete(frames);
    }
  }

  /// Called by a screen when capture cannot proceed (e.g. camera denied).
  void failCapture(Object error, [StackTrace? stackTrace]) {
    _error = error;
    _set(BlinkStage.failed);
    final document = _document;
    final liveness = _liveness;
    if (document != null && !document.isCompleted) {
      document.completeError(error, stackTrace);
    } else if (liveness != null && !liveness.isCompleted) {
      liveness.completeError(error, stackTrace);
    }
  }

  /// Enter a transitional/loading state (fetching a challenge, submitting).
  void setBusy() => _set(BlinkStage.preparing);

  /// Enter the completed state.
  void markDone() => _set(BlinkStage.done);

  /// Record a terminal failure for display (the protocol loop reports the real
  /// error separately).
  void markFailed(Object error) {
    _error = error;
    _set(BlinkStage.failed);
  }

  void _set(BlinkStage stage) {
    _stage = stage;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
