# Changelog

## 1.3.0

- Real on-device face detection for the liveness fit-oval via ML Kit
  (`google_mlkit_face_detection`), replacing the earlier luma proxy, with a luma
  fallback for frames that cannot be converted.
- Advisory face-quality superset (centred, large enough, not too close, roughly
  frontal pose) plus document glare / exposure soft-gates and a blur advisory in
  the capture heuristics.
- Public API and the liveness frame contract are unchanged; on-device detection
  remains a framing aid only — the server still judges the captured frames.

## 1.2.0

- Capture UX parity: document alignment template with on-device auto-detection
  (edge density + contrast step), a hold + countdown ring, and hands-free
  auto-capture with a persisted toggle, plus a preview/retake step.
- Liveness step shows a fit oval that greens on a settled face and then
  auto-starts. Detection ships no server model — framing aids only.

## 1.1.0

- Liveness capture fix: a settled frontal primary frame is captured before the
  gestures, followed by a short burst per action, so the standard two-action
  challenge submits enough frames.

## 1.0.0

- Initial release.
- Typed session protocol client over the `/api/sdk/**` device endpoints
  (`documentChallenge`, `submitDocument`, `livenessChallenge`, `submitLiveness`,
  `finalize`, `status`) with single-use nonces and Bearer session-token auth.
- Typed errors: `BlinkError` (code + httpStatus) and `BlinkStepError`
  (code + step).
- `BlinkKyc` fluent builder with headless (`capture`) and drop-in
  (`present`/`mount`) modes.
- `BlinkKycFlow` drop-in capture UI (document framing/capture + liveness
  challenge screens) built on the `camera` plugin, themeable via `BlinkTheme`
  and `BlinkStrings`.
