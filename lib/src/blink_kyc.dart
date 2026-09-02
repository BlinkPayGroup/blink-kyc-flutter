/// Blink KYC — Flutter SDK.
///
/// Drop-in identity verification. Your backend mints a session; the SDK runs the
/// capture (document + liveness) and returns a verdict. A black box: you get
/// VERIFIED / REJECTED / REVIEW and a neutral reason, never a score or any detail
/// of how it was reached.
///
/// ```dart
/// final verdict = await BlinkKyc(baseUrl, sessionToken)
///     .document(type: DocumentType.passport)
///     .face()
///     .onProgress((p) => debugPrint(p.step))
///     .present(context) // the SDK renders its camera UI
///     .run();
/// // Confirm verdict.result from YOUR backend before trusting it.
/// ```
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'capture/blink_kyc_flow.dart';
import 'protocol.dart';
import 'theme.dart';

/// The stage the SDK is at, delivered to [BlinkKyc.onProgress].
class BlinkProgress {
  const BlinkProgress(this.step, [this.detail]);

  /// A coarse step identifier, e.g. `document:capture`, `liveness:submit`,
  /// `finalize`, `done`.
  final String step;

  /// Optional extra context (e.g. the comma-joined liveness actions).
  final String? detail;

  @override
  String toString() => detail == null ? step : '$step ($detail)';
}

/// The media source a flow captures from. Implemented by the built-in UI
/// controller and by [CaptureHooks] for headless mode.
abstract interface class BlinkCapture {
  /// Produce a single document image.
  Future<Uint8List> captureDocument(DocumentType? type, DocumentSide? side);

  /// Perform [actions] and produce the recorded liveness frames.
  Future<List<Uint8List>> captureLiveness(List<String> actions);
}

/// Headless capture: supply the media yourself instead of using the built-in UI.
class CaptureHooks implements BlinkCapture {
  const CaptureHooks({required this.document, required this.liveness});

  /// Return one document image.
  final Future<Uint8List> Function() document;

  /// Perform the requested actions and return the recorded frames.
  final Future<List<Uint8List>> Function(List<String> actions) liveness;

  @override
  Future<Uint8List> captureDocument(DocumentType? type, DocumentSide? side) =>
      document();

  @override
  Future<List<Uint8List>> captureLiveness(List<String> actions) =>
      liveness(actions);
}

/// Run the configured flow against [proto], sourcing media from [capture], and
/// resolve with the verdict.
///
/// If neither step is requested, both run (the default full capture). Throws
/// [BlinkStepError] on a business failure and [BlinkError] on transport.
///
/// Shared by [BlinkKyc.run] (headless) and [BlinkKycFlow] (drop-in UI).
Future<Verdict> runBlinkFlow({
  required BlinkProtocol proto,
  required BlinkCapture capture,
  bool document = false,
  bool face = false,
  DocumentType? documentType,
  DocumentSide? side,
  void Function(BlinkProgress progress)? onProgress,
}) async {
  final runDocument = document || (!document && !face);
  final runFace = face || (!document && !face);

  void emit(String step, [String? detail]) =>
      onProgress?.call(BlinkProgress(step, detail));

  void check(StepOutcome outcome) {
    if (!outcome.ok) throw BlinkStepError(outcome);
  }

  if (runDocument) {
    emit('document:challenge');
    final ch = await proto.documentChallenge();
    emit('document:capture');
    final image = await capture.captureDocument(documentType, side);
    emit('document:submit');
    check(await proto.submitDocument(
      image,
      nonce: ch.nonce,
      documentType: documentType,
      side: side,
    ));
  }

  if (runFace) {
    emit('liveness:challenge');
    final ch = await proto.livenessChallenge();
    emit('liveness:capture', ch.actions.join(','));
    final frames = await capture.captureLiveness(ch.actions);
    emit('liveness:submit');
    check(await proto.submitLiveness(frames, ch.nonce));
  }

  emit('finalize');
  final result = await proto.finalize();
  emit('done', result.result.wireValue);
  return result;
}

/// Fluent entry point. Configure the steps, choose a presentation mode
/// ([present] for the drop-in UI or [capture] for headless), then [run].
class BlinkKyc {
  /// Create a builder for a session your backend already minted.
  ///
  /// [sessionToken] is the short-lived token from
  /// `POST /api/blink/session/create` — never the client secret.
  BlinkKyc(
    this.baseUrl,
    this.sessionToken, {
    this.timeoutMs,
    BlinkTheme? theme,
    BlinkStrings? strings,
    http.Client? httpClient,
  })  : theme = theme ?? const BlinkTheme(),
        strings = strings ?? const BlinkStrings(),
        _httpClient = httpClient {
    _proto = BlinkProtocol(
      baseUrl: baseUrl,
      sessionToken: sessionToken,
      timeoutMs: timeoutMs,
      httpClient: httpClient,
    );
  }

  /// Base URL of the Blink API, e.g. `https://kyc-api.blink-pay.net`.
  final String baseUrl;

  /// The session token your backend obtained and handed to the app.
  final String sessionToken;

  /// Per-request timeout in milliseconds (default 30000).
  final int? timeoutMs;

  /// Colours for the drop-in UI.
  final BlinkTheme theme;

  /// Copy for the drop-in UI.
  final BlinkStrings strings;

  final http.Client? _httpClient;
  late final BlinkProtocol _proto;

  bool _wantDocument = false;
  DocumentType? _documentType;
  DocumentSide? _documentSide;
  bool _wantFace = false;
  BuildContext? _context;
  CaptureHooks? _hooks;
  final List<void Function(BlinkProgress progress)> _listeners = [];

  /// Enable the document step (default type `NATIONAL_ID` server-side).
  BlinkKyc document({DocumentType? type, DocumentSide? side}) {
    _wantDocument = true;
    _documentType = type;
    _documentSide = side;
    return this;
  }

  /// Enable the liveness + face step.
  BlinkKyc face() {
    _wantFace = true;
    return this;
  }

  /// Present the built-in capture UI, pushing it as a full-screen route on the
  /// navigator that owns [context] (drop-in mode).
  BlinkKyc present(BuildContext context) {
    _context = context;
    return this;
  }

  /// Alias for [present], mirroring the web SDK's `mount`.
  BlinkKyc mount(BuildContext context) => present(context);

  /// Supply your own capture media instead of the built-in UI (headless mode).
  BlinkKyc capture(CaptureHooks hooks) {
    _hooks = hooks;
    return this;
  }

  /// Subscribe to progress events.
  BlinkKyc onProgress(void Function(BlinkProgress progress) callback) {
    _listeners.add(callback);
    return this;
  }

  /// The low-level protocol client, if you want to drive steps yourself.
  BlinkProtocol get session => _proto;

  /// Read-only session progress from the server.
  Future<StatusView> status() => _proto.status();

  /// Run the configured flow and resolve with the verdict.
  ///
  /// Throws [BlinkStepError] on a business failure, [BlinkError] on transport,
  /// and [BlinkError] with code `BLINK_CANCELLED` if the user dismisses the
  /// built-in UI before it finishes.
  Future<Verdict> run() {
    void emit(BlinkProgress progress) {
      for (final listener in _listeners) {
        try {
          listener(progress);
        } catch (_) {
          // A listener must not break the flow.
        }
      }
    }

    final hooks = _hooks;
    if (hooks != null) {
      return runBlinkFlow(
        proto: _proto,
        capture: hooks,
        document: _wantDocument,
        face: _wantFace,
        documentType: _documentType,
        side: _documentSide,
        onProgress: emit,
      );
    }

    final context = _context;
    if (context == null) {
      return Future<Verdict>.error(const BlinkError(
        BlinkErrorCode.config,
        'Call present(context) for the built-in UI, or capture(hooks) to '
            'supply media yourself',
        0,
      ));
    }

    final completer = Completer<Verdict>();
    final navigator = Navigator.of(context, rootNavigator: true);
    late final MaterialPageRoute<void> route;

    void closeRoute() {
      if (route.isActive) navigator.removeRoute(route);
    }

    route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => BlinkKycFlow(
        baseUrl: baseUrl,
        sessionToken: sessionToken,
        timeoutMs: timeoutMs,
        httpClient: _httpClient,
        document: _wantDocument,
        face: _wantFace,
        documentType: _documentType,
        side: _documentSide,
        theme: theme,
        strings: strings,
        onProgress: emit,
        onComplete: (verdict) {
          if (!completer.isCompleted) completer.complete(verdict);
          closeRoute();
        },
        onError: (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
          closeRoute();
        },
      ),
    );

    unawaited(navigator.push(route).then((_) {
      if (!completer.isCompleted) {
        completer.completeError(const BlinkError(
          BlinkErrorCode.cancelled,
          'The verification was cancelled',
          0,
        ));
      }
    }));

    return completer.future;
  }

  /// The HTTP client this builder was given, if any (kept for symmetry with
  /// [BlinkProtocol] ownership — the builder never closes a client it did not
  /// create).
  http.Client? get httpClient => _httpClient;
}
