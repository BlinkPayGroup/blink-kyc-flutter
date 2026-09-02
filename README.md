# blink_kyc

Drop-in identity verification for Flutter. Your backend mints a session; the SDK
runs the capture (document + liveness) and returns a verdict. **A black box** —
you get `VERIFIED` / `REJECTED` / `REVIEW` and a neutral reason, never a score or
any detail of how it was reached.

Null-safe · Android + iOS · themeable drop-in camera UI · headless mode.

## Install

```yaml
# pubspec.yaml
dependencies:
  blink_kyc:
    git:
      url: https://github.com/BlinkPayGroup/blink-kyc-flutter.git
      ref: "1.0.0"
```

Then `flutter pub get`.

## The trust boundary — read this first

```
Your backend                          Device (this SDK)                  Blink
────────────                          ─────────────────                  ─────
client_id + client_secret ── POST /api/blink/session/create ──────────▶  (never sees the secret)
        │  ◀── { sessionId, sessionToken } ─────────┐
        └── hands sessionToken to the app ──────────▶ BlinkKyc(baseUrl, sessionToken).run()
Your backend ◀── GET /api/blink/session/{id}/result ── the AUTHORITATIVE verdict (never trust the app)
```

- The **client secret never reaches the device** — your backend mints the
  session server-to-server.
- Every step is **replay-resistant** (a fresh single-use nonce per step).
- **Act on the verdict your backend fetches**, not the copy the app reports.

## Quick start (drop-in UI)

The SDK owns the camera and presents its own capture screens as a full-screen
route on the navigator that owns the `context` you pass to `present`.

```dart
import 'package:blink_kyc/blink_kyc.dart';

// sessionToken came from YOUR backend (POST /api/blink/session/create).
final verdict = await BlinkKyc(baseUrl, sessionToken)
    .document(type: DocumentType.passport) // PASSPORT | NATIONAL_ID | ID_CARD | DRIVING_LICENCE
    .face()                                // liveness + face
    .onProgress((p) => debugPrint(p.step))
    .present(context)                      // the SDK renders its camera UI
    .run();

// verdict.result: VerdictResult.verified | .rejected | .review
// verdict.detail: a neutral reason.
// Confirm verdict.result from YOUR backend before trusting it.
```

`present(context)` (aliased as `mount(context)` for parity with the web SDK)
pushes the built-in flow and resolves `run()` with the verdict. If the user
dismisses the flow first, `run()` throws `BlinkError` with code
`BLINK_CANCELLED`.

You can also embed the flow yourself instead of using `present`:

```dart
BlinkKycFlow(
  baseUrl: baseUrl,
  sessionToken: sessionToken,
  documentType: DocumentType.nationalId,
  onComplete: (verdict) => Navigator.pop(context, verdict),
  onError: (error, _) => Navigator.pop(context),
)
```

## Headless mode (bring your own camera)

Supply the media yourself; the SDK owns only the protocol. No `context` needed.

```dart
await BlinkKyc(baseUrl, sessionToken)
    .document(type: DocumentType.nationalId)
    .face()
    .capture(CaptureHooks(
      document: () async => grabDocumentBytes(),          // Future<Uint8List>
      liveness: (actions) async => recordFrames(actions), // Future<List<Uint8List>>
    ))
    .run();
```

## Theming

```dart
BlinkKyc(
  baseUrl,
  sessionToken,
  theme: const BlinkTheme(accent: Color(0xFF16A34A), background: Color(0xFF0F1729)),
  strings: const BlinkStrings(documentTitle: 'Scan your ID'),
);
```

## API

| | |
|---|---|
| `BlinkKyc(baseUrl, sessionToken, {timeoutMs, theme, strings, httpClient})` | create the builder |
| `.document({type, side})` | enable the document step |
| `.face()` | enable liveness + face |
| `.present(context)` / `.mount(context)` | present the built-in capture UI |
| `.capture(hooks)` | headless: supply the media yourself |
| `.onProgress(cb)` | step progress events |
| `.run()` | `Future<Verdict>` |
| `.session` | the low-level `BlinkProtocol` if you want to drive steps yourself |
| `.status()` | read-only session progress from the server |

If neither `.document()` nor `.face()` is called, both steps run (full capture).

## Errors

- **`BlinkError`** — transport / HTTP failure. `.code` (e.g.
  `BLINK_SESSION_INVALID`, `BLINK_CHALLENGE_INVALID`), `.httpStatus`. Switch on
  `.code` (see `BlinkErrorCode`), not the message.
- **`BlinkStepError`** — a business failure at a step (e.g.
  `DOCUMENT_UNREADABLE`, `LIVENESS_FAILED`). `.code` (see `BlinkOutcomeCode`),
  `.step`.

## Platform setup

The drop-in UI uses the [`camera`](https://pub.dev/packages/camera) plugin.

**iOS** — add to `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Used to capture your document and a liveness check.</string>
```

Set the iOS deployment target to 12.0+ in `ios/Podfile`.

**Android** — set `minSdkVersion` to at least 21 in
`android/app/build.gradle`. The `camera` plugin declares the `CAMERA`
permission; on Android 6+ it is requested at runtime when the flow opens.

## Confirming the verdict (backend)

The verdict the app receives is a convenience copy. Fetch the authoritative
result server-to-server:

```
GET /api/blink/session/{sessionId}/result
X-Blink-Client-Key: <your client key>
X-Blink-Client-Secret: <your client secret>
```

Act on the top-level `result` field. See `docs/blink-client-openapi.yaml` for the
full contract and the error/outcome code catalog.

## License

Proprietary. See [LICENSE](LICENSE).
