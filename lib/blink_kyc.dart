/// Blink KYC — Flutter SDK.
///
/// Drop-in identity verification. Your backend mints a session; this SDK runs the
/// capture (document + liveness) and returns a verdict. A black box: you get
/// `VERIFIED` / `REJECTED` / `REVIEW` and a neutral reason, never a score or any
/// detail of how it was reached.
///
/// See the README for the trust-boundary diagram and a quick start.
library;

export 'src/blink_kyc.dart'
    show BlinkKyc, BlinkProgress, BlinkCapture, CaptureHooks, runBlinkFlow;
export 'src/capture/blink_kyc_flow.dart' show BlinkKycFlow;
export 'src/protocol.dart'
    show
        BlinkProtocol,
        BlinkError,
        BlinkErrorCode,
        BlinkStepError,
        BlinkOutcomeCode,
        Challenge,
        LivenessChallenge,
        StepOutcome,
        StepName,
        StatusView,
        Verdict,
        VerdictResult,
        DocumentType,
        DocumentSide;
export 'src/theme.dart' show BlinkTheme, BlinkStrings;
