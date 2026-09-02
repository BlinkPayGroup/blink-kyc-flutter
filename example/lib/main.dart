// Minimal example of the Blink KYC Flutter SDK.
//
// In a real app the `sessionToken` comes from YOUR backend
// (POST /api/blink/session/create) — never hard-code a client secret in the app.
// After the flow resolves, confirm the verdict from your backend via
// GET /api/blink/session/{id}/result before trusting it.

import 'package:blink_kyc/blink_kyc.dart';
import 'package:flutter/material.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Blink KYC example',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF22C55E)),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Replace with your API base URL and a token minted by your backend.
  static const String _baseUrl = 'https://kyc-api.blink-pay.net';
  static const String _sessionToken = 'PASTE_A_SESSION_TOKEN';

  String _status = 'Idle';

  Future<void> _verify() async {
    setState(() => _status = 'Running…');
    try {
      final verdict = await BlinkKyc(_baseUrl, _sessionToken)
          .document(type: DocumentType.passport)
          .face()
          .onProgress((p) => debugPrint('progress: $p'))
          .present(context)
          .run();
      setState(() => _status = 'Verdict: ${verdict.result.name} — '
          '${verdict.detail}');
    } on BlinkStepError catch (e) {
      setState(() => _status = 'Step failed (${e.step.name}): ${e.code}');
    } on BlinkError catch (e) {
      setState(() => _status = 'Error: ${e.code}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Blink KYC example')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_status),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _verify,
              child: const Text('Start verification'),
            ),
          ],
        ),
      ),
    );
  }
}
