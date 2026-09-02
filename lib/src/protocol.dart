/// Low-level Blink session protocol — the exact `/api/sdk/**` surface, typed.
///
/// The client secret never reaches this layer: your backend mints a session with
/// `POST /api/blink/session/create` and hands the device only the short-lived
/// `sessionToken`. Every step fetches a fresh single-use nonce and submits echoing
/// it; a replay is refused by the server. The verdict you act on is the one your
/// backend fetches server-to-server — never trust the copy the device sees.
///
/// This is a black box by design: you get a verdict and a neutral reason, never a
/// score or method.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

/// The three — and only — outcomes a verification can resolve to.
enum VerdictResult {
  verified('VERIFIED'),
  rejected('REJECTED'),
  review('REVIEW');

  const VerdictResult(this.wireValue);

  /// The value as it appears on the wire.
  final String wireValue;

  /// Parse a wire value, or `null` if it is absent.
  static VerdictResult? maybeFromWire(String? value) {
    if (value == null) return null;
    for (final v in VerdictResult.values) {
      if (v.wireValue == value) return v;
    }
    throw BlinkError(
        BlinkErrorCode.malformedResponse, 'Unexpected verdict "$value"', 0);
  }
}

/// Neutral, region-agnostic document type. Defaults to [nationalId] server-side.
enum DocumentType {
  passport('PASSPORT'),
  nationalId('NATIONAL_ID'),
  idCard('ID_CARD'),
  drivingLicence('DRIVING_LICENCE');

  const DocumentType(this.wireValue);

  /// The value as it appears on the wire.
  final String wireValue;
}

/// Which face of the document was captured.
enum DocumentSide {
  front('FRONT'),
  back('BACK');

  const DocumentSide(this.wireValue);

  /// The value as it appears on the wire.
  final String wireValue;
}

/// The capture step a [StepOutcome] belongs to.
enum StepName {
  document('DOCUMENT'),
  liveness('LIVENESS');

  const StepName(this.wireValue);

  /// The value as it appears on the wire.
  final String wireValue;

  /// Parse a wire value, falling back to [document] for forward-compatibility.
  static StepName fromWire(String? value) {
    for (final v in StepName.values) {
      if (v.wireValue == value) return v;
    }
    return StepName.document;
  }
}

/// A single-use challenge. Echo [nonce] on the matching submit.
class Challenge {
  const Challenge({required this.nonce, required this.expiresInSeconds});

  /// Single-use nonce. Echo it on the matching submit or the server refuses it.
  final String nonce;

  /// How long the nonce stays valid.
  final int expiresInSeconds;

  factory Challenge.fromJson(Map<String, dynamic> json) => Challenge(
        nonce: (json['nonce'] as String?) ?? '',
        expiresInSeconds: (json['expiresInSeconds'] as num?)?.toInt() ?? 0,
      );
}

/// A liveness challenge — a [Challenge] plus the actions the user must perform.
class LivenessChallenge extends Challenge {
  const LivenessChallenge({
    required super.nonce,
    required super.expiresInSeconds,
    required this.actions,
  });

  /// Actions the user must perform (e.g. `BLINK`, `TURN_HEAD_LEFT`).
  final List<String> actions;

  factory LivenessChallenge.fromJson(Map<String, dynamic> json) =>
      LivenessChallenge(
        nonce: (json['nonce'] as String?) ?? '',
        expiresInSeconds: (json['expiresInSeconds'] as num?)?.toInt() ?? 0,
        actions:
            (json['actions'] as List<dynamic>?)?.cast<String>() ?? const [],
      );
}

/// The result of a capture step.
///
/// A business failure (e.g. document unreadable) arrives as [ok] `= false` with
/// HTTP 200 — inspect this flag, not the status code.
class StepOutcome {
  const StepOutcome({
    required this.ok,
    required this.step,
    required this.code,
    required this.detail,
  });

  /// Whether the step was accepted.
  final bool ok;

  /// Which step this outcome is for.
  final StepName step;

  /// A neutral outcome code (see [BlinkOutcomeCode]).
  final String code;

  /// A neutral, human-readable reason.
  final String detail;

  factory StepOutcome.fromJson(Map<String, dynamic> json) => StepOutcome(
        ok: (json['ok'] as bool?) ?? false,
        step: StepName.fromWire(json['step'] as String?),
        code: (json['code'] as String?) ?? '',
        detail: (json['detail'] as String?) ?? '',
      );
}

/// The verdict of a verification: a result plus a neutral reason.
///
/// This is the copy the device sees. Always confirm the authoritative verdict
/// from your backend before acting on it.
class Verdict {
  const Verdict({required this.result, required this.detail});

  /// One of [VerdictResult.verified], [VerdictResult.rejected],
  /// [VerdictResult.review].
  final VerdictResult result;

  /// A neutral, human-readable reason. Never a score or method.
  final String detail;

  factory Verdict.fromJson(Map<String, dynamic> json) {
    final result = VerdictResult.maybeFromWire(json['result'] as String?);
    if (result == null) {
      throw BlinkError(
          BlinkErrorCode.malformedResponse, 'Missing verdict result', 0);
    }
    return Verdict(result: result, detail: (json['detail'] as String?) ?? '');
  }

  @override
  String toString() => 'Verdict(${result.wireValue}): $detail';
}

/// Read-only session progress reported by the server.
class StatusView {
  const StatusView({
    required this.status,
    required this.currentStep,
    required this.stepsCompleted,
    required this.resultStatus,
  });

  /// Session lifecycle status.
  final String status;

  /// The step currently in progress, if any.
  final String? currentStep;

  /// Steps already completed.
  final List<String> stepsCompleted;

  /// The verdict, once the session has completed; otherwise `null`.
  final VerdictResult? resultStatus;

  factory StatusView.fromJson(Map<String, dynamic> json) => StatusView(
        status: (json['status'] as String?) ?? '',
        currentStep: json['currentStep'] as String?,
        stepsCompleted:
            (json['stepsCompleted'] as List<dynamic>?)?.cast<String>() ??
                const [],
        resultStatus:
            VerdictResult.maybeFromWire(json['resultStatus'] as String?),
      );
}

/// Stable machine codes carried by [BlinkError.code]. Switch on these, not on
/// the message. The server-issued codes mirror the client API catalog; the
/// remainder are raised on the device before a request leaves.
abstract final class BlinkErrorCode {
  // Server-issued (HTTP error bodies).
  static const String sessionInvalid = 'BLINK_SESSION_INVALID';
  static const String originNotAllowed = 'BLINK_ORIGIN_NOT_ALLOWED';
  static const String sessionExpired = 'BLINK_SESSION_EXPIRED';
  static const String sessionSpent = 'BLINK_SESSION_SPENT';
  static const String challengeInvalid = 'BLINK_CHALLENGE_INVALID';
  static const String stepOutOfSequence = 'BLINK_STEP_OUT_OF_SEQUENCE';
  static const String stepIncomplete = 'BLINK_STEP_INCOMPLETE';
  static const String unknownDocumentType = 'BLINK_UNKNOWN_DOCUMENT_TYPE';
  static const String uploadRejected = 'BLINK_UPLOAD_REJECTED';
  static const String quotaExceeded = 'BLINK_QUOTA_EXCEEDED';

  // Device-side (raised before/around the request).
  static const String config = 'BLINK_CONFIG';
  static const String timeout = 'BLINK_TIMEOUT';
  static const String network = 'BLINK_NETWORK';
  static const String cancelled = 'BLINK_CANCELLED';
  static const String cameraDenied = 'BLINK_CAMERA_DENIED';
  static const String cameraUnavailable = 'BLINK_CAMERA_UNAVAILABLE';
  static const String malformedResponse = 'BLINK_MALFORMED_RESPONSE';

  /// Fallback when the server sent no code.
  static const String unknown = 'BLINK_ERROR';
}

/// Neutral outcome codes carried by [StepOutcome.code].
abstract final class BlinkOutcomeCode {
  static const String documentAccepted = 'DOCUMENT_ACCEPTED';
  static const String documentUnreadable = 'DOCUMENT_UNREADABLE';
  static const String livenessAccepted = 'LIVENESS_ACCEPTED';
  static const String livenessFailed = 'LIVENESS_FAILED';
  static const String livenessChallengeInvalid = 'LIVENESS_CHALLENGE_INVALID';
}

/// A transport/HTTP failure carrying the stable server [code]. Switch on [code],
/// not on the message.
class BlinkError implements Exception {
  const BlinkError(this.code, this.message, [this.httpStatus = 0]);

  /// A stable machine code (see [BlinkErrorCode]).
  final String code;

  /// A human-readable message. Do not switch on this.
  final String message;

  /// The HTTP status, or `0` for device-side failures.
  final int httpStatus;

  @override
  String toString() => 'BlinkError($code'
      '${httpStatus != 0 ? ', HTTP $httpStatus' : ''}): $message';
}

/// A business failure at a capture step (e.g. document unreadable), surfaced
/// from a [StepOutcome] whose [StepOutcome.ok] is `false`.
class BlinkStepError implements Exception {
  BlinkStepError(StepOutcome outcome)
      : code = outcome.code,
        step = outcome.step,
        message = outcome.detail.isNotEmpty ? outcome.detail : outcome.code;

  /// The neutral outcome code (see [BlinkOutcomeCode]).
  final String code;

  /// Which step failed.
  final StepName step;

  /// A neutral, human-readable reason.
  final String message;

  @override
  String toString() => 'BlinkStepError(${step.wireValue}/$code): $message';
}

/// The typed `/api/sdk/**` protocol client.
///
/// Drive the steps yourself with this, or let [BlinkKyc] orchestrate them.
class BlinkProtocol {
  BlinkProtocol({
    required String baseUrl,
    required String sessionToken,
    int? timeoutMs,
    http.Client? httpClient,
  })  : _base = _requireBaseUrl(baseUrl),
        _token = _requireToken(sessionToken),
        _timeout = Duration(milliseconds: timeoutMs ?? 30000),
        _client = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  final String _base;
  final String _token;
  final Duration _timeout;
  final http.Client _client;
  final bool _ownsClient;

  static String _requireBaseUrl(String value) {
    if (value.isEmpty) {
      throw const BlinkError(BlinkErrorCode.config, 'baseUrl is required', 0);
    }
    return value.replaceAll(RegExp(r'/+$'), '');
  }

  static String _requireToken(String value) {
    if (value.isEmpty) {
      throw const BlinkError(
          BlinkErrorCode.config, 'sessionToken is required', 0);
    }
    return value;
  }

  /// Start the document step.
  Future<Challenge> documentChallenge() async =>
      Challenge.fromJson(await _postJson('/api/sdk/document/challenge'));

  /// Submit the captured document [image], echoing the challenge [nonce].
  Future<StepOutcome> submitDocument(
    Uint8List image, {
    required String nonce,
    DocumentType? documentType,
    DocumentSide? side,
  }) async {
    final req = http.MultipartRequest('POST', _uri('/api/sdk/document'));
    req.files.add(http.MultipartFile.fromBytes(
      'image',
      image,
      filename: 'document.jpg',
      contentType: MediaType('image', 'jpeg'),
    ));
    req.fields['nonce'] = nonce;
    if (documentType != null) req.fields['documentType'] = documentType.wireValue;
    if (side != null) req.fields['side'] = side.wireValue;
    return StepOutcome.fromJson(await _dispatch(req));
  }

  /// Start the liveness step.
  Future<LivenessChallenge> livenessChallenge() async =>
      LivenessChallenge.fromJson(
          await _postJson('/api/sdk/liveness/challenge'));

  /// Submit the recorded liveness [frames], echoing the challenge [nonce].
  Future<StepOutcome> submitLiveness(
      List<Uint8List> frames, String nonce) async {
    final req = http.MultipartRequest('POST', _uri('/api/sdk/liveness'));
    for (var i = 0; i < frames.length; i++) {
      req.files.add(http.MultipartFile.fromBytes(
        'frames',
        frames[i],
        filename: 'frame-$i.jpg',
        contentType: MediaType('image', 'jpeg'),
      ));
    }
    req.fields['nonce'] = nonce;
    return StepOutcome.fromJson(await _dispatch(req));
  }

  /// Finalize and return the verdict (non-authoritative copy). Always confirm
  /// the verdict from your backend via the result endpoint.
  Future<Verdict> finalize() async =>
      Verdict.fromJson(await _postJson('/api/sdk/finalize'));

  /// Read-only session progress from the server.
  Future<StatusView> status() async =>
      StatusView.fromJson(await _getJson('/api/sdk/status'));

  /// Release the underlying HTTP client, if this protocol created it.
  void close() {
    if (_ownsClient) _client.close();
  }

  // ── transport ──────────────────────────────────────────────────────────────

  Uri _uri(String path) => Uri.parse('$_base$path');

  Future<Map<String, dynamic>> _postJson(String path) =>
      _dispatch(http.Request('POST', _uri(path)));

  Future<Map<String, dynamic>> _getJson(String path) =>
      _dispatch(http.Request('GET', _uri(path)));

  Future<Map<String, dynamic>> _dispatch(http.BaseRequest request) async {
    request.headers['Authorization'] = 'Bearer $_token';
    http.Response res;
    try {
      final streamed = await _client.send(request).timeout(_timeout);
      res = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw const BlinkError(
          BlinkErrorCode.timeout, 'The request timed out', 0);
    } catch (_) {
      throw const BlinkError(
          BlinkErrorCode.network, 'Network error reaching Blink', 0);
    }

    final body = _safeJson(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final code = (body['code'] as String?) ?? BlinkErrorCode.unknown;
      final message = (body['message'] as String?) ??
          (res.reasonPhrase?.isNotEmpty == true
              ? res.reasonPhrase!
              : 'Request failed');
      throw BlinkError(code, message, res.statusCode);
    }
    return body;
  }

  static Map<String, dynamic> _safeJson(String text) {
    if (text.isEmpty) return const {};
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }
}
