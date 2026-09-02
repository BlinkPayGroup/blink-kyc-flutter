/// The drop-in capture experience. The SDK owns the camera UI: a document
/// framing/capture screen, then a liveness challenge screen. It renders a
/// self-contained flow and drives the protocol underneath. Nothing here reveals
/// how verification works.
library;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../blink_kyc.dart';
import '../protocol.dart';
import '../theme.dart';
import 'document_capture_screen.dart';
import 'flow_controller.dart';
import 'liveness_capture_screen.dart';

/// A full capture flow you can present as a route or embed in your own tree.
///
/// Usually you reach this via [BlinkKyc.present], but you can host it directly
/// when you want to place the capture UI in your own navigation:
///
/// ```dart
/// BlinkKycFlow(
///   baseUrl: baseUrl,
///   sessionToken: sessionToken,
///   documentType: DocumentType.passport,
///   onComplete: (verdict) => Navigator.pop(context, verdict),
///   onError: (error, _) => Navigator.pop(context),
/// )
/// ```
class BlinkKycFlow extends StatefulWidget {
  const BlinkKycFlow({
    super.key,
    this.protocol,
    this.baseUrl,
    this.sessionToken,
    this.timeoutMs,
    this.httpClient,
    this.document = true,
    this.face = true,
    this.documentType,
    this.side,
    this.theme = const BlinkTheme(),
    this.strings = const BlinkStrings(),
    required this.onComplete,
    this.onError,
    this.onProgress,
  }) : assert(
          protocol != null || (baseUrl != null && sessionToken != null),
          'Provide either a BlinkProtocol or both baseUrl and sessionToken',
        );

  /// A protocol client to use. When omitted, one is built from [baseUrl] and
  /// [sessionToken] and closed when the flow is disposed. A supplied client is
  /// never closed by the flow.
  final BlinkProtocol? protocol;

  /// Base URL of the Blink API. Required when [protocol] is not given.
  final String? baseUrl;

  /// The short-lived session token. Required when [protocol] is not given.
  final String? sessionToken;

  /// Per-request timeout in milliseconds.
  final int? timeoutMs;

  /// Optional HTTP client (used only when [protocol] is not given).
  final http.Client? httpClient;

  /// Run the document step.
  final bool document;

  /// Run the liveness step.
  final bool face;

  /// The document type to declare on submit.
  final DocumentType? documentType;

  /// The document side to declare on submit.
  final DocumentSide? side;

  /// Colours for the UI.
  final BlinkTheme theme;

  /// Copy for the UI.
  final BlinkStrings strings;

  /// Called with the verdict when the flow completes.
  final void Function(Verdict verdict) onComplete;

  /// Called on failure ([BlinkStepError], [BlinkError], or an unexpected error).
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// Called on each step transition.
  final void Function(BlinkProgress progress)? onProgress;

  @override
  State<BlinkKycFlow> createState() => _BlinkKycFlowState();
}

class _BlinkKycFlowState extends State<BlinkKycFlow> {
  late final BlinkProtocol _protocol;
  late final BlinkFlowController _controller;
  late final bool _ownsProtocol;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _ownsProtocol = widget.protocol == null;
    _protocol = widget.protocol ??
        BlinkProtocol(
          baseUrl: widget.baseUrl!,
          sessionToken: widget.sessionToken!,
          timeoutMs: widget.timeoutMs,
          httpClient: widget.httpClient,
        );
    _controller =
        BlinkFlowController(theme: widget.theme, strings: widget.strings);
    _start();
  }

  Future<void> _start() async {
    List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } catch (error, stackTrace) {
      _fail(
        const BlinkError(BlinkErrorCode.cameraUnavailable,
            'No camera is available on this device', 0),
        stackTrace,
      );
      return;
    }
    if (cameras.isEmpty) {
      _fail(
        const BlinkError(BlinkErrorCode.cameraUnavailable,
            'No camera is available on this device', 0),
        StackTrace.current,
      );
      return;
    }
    if (!mounted) return;
    _cameras = cameras;

    try {
      final verdict = await runBlinkFlow(
        proto: _protocol,
        capture: _controller,
        document: widget.document,
        face: widget.face,
        documentType: widget.documentType,
        side: widget.side,
        onProgress: _onProgress,
      );
      _controller.markDone();
      _complete(verdict);
    } catch (error, stackTrace) {
      _controller.markFailed(error);
      _fail(error, stackTrace);
    }
  }

  List<CameraDescription> _cameras = const [];

  void _onProgress(BlinkProgress progress) {
    widget.onProgress?.call(progress);
    switch (progress.step) {
      case 'document:challenge':
      case 'liveness:challenge':
      case 'finalize':
        _controller.setBusy();
      case 'done':
        _controller.markDone();
    }
  }

  void _complete(Verdict verdict) {
    if (_finished) return;
    _finished = true;
    widget.onComplete(verdict);
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (_finished) return;
    _finished = true;
    widget.onError?.call(error, stackTrace);
  }

  @override
  void dispose() {
    _controller.dispose();
    if (_ownsProtocol) _protocol.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return Scaffold(
      backgroundColor: theme.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListenableBuilder(
              listenable: _controller,
              builder: (context, _) => _stageView(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stageView() {
    switch (_controller.stage) {
      case BlinkStage.document:
        return DocumentCaptureScreen(
          key: const ValueKey('blink-document'),
          controller: _controller,
          cameras: _cameras,
          theme: widget.theme,
          strings: widget.strings,
        );
      case BlinkStage.liveness:
        return LivenessCaptureScreen(
          key: const ValueKey('blink-liveness'),
          controller: _controller,
          cameras: _cameras,
          theme: widget.theme,
          strings: widget.strings,
        );
      case BlinkStage.preparing:
      case BlinkStage.submitting:
        return _Busy(theme: widget.theme, label: widget.strings.working);
      case BlinkStage.done:
        return _Done(theme: widget.theme, label: widget.strings.doneLabel);
      case BlinkStage.failed:
        return _Failed(
          theme: widget.theme,
          message: _messageFor(_controller.error),
        );
    }
  }

  String _messageFor(Object? error) {
    if (error is BlinkStepError) return error.message;
    if (error is BlinkError) return error.message;
    return 'Something went wrong.';
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.theme, required this.label});

  final BlinkTheme theme;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 34,
          height: 34,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            valueColor: AlwaysStoppedAnimation<Color>(theme.accent),
          ),
        ),
        const SizedBox(height: 16),
        Text(label, style: TextStyle(color: theme.text.withOpacity(0.8))),
      ],
    );
  }
}

class _Done extends StatelessWidget {
  const _Done({required this.theme, required this.label});

  final BlinkTheme theme;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.check_circle, color: theme.accent, size: 48),
        const SizedBox(height: 12),
        Text(label, style: TextStyle(color: theme.text)),
      ],
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.theme, required this.message});

  final BlinkTheme theme;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFFCA5A5), size: 44),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.text),
          ),
        ],
      ),
    );
  }
}
