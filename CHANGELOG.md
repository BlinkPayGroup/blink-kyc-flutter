# Changelog

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
