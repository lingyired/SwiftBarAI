# Add GitHub Actions CI workflow

**Date:** 2026-06-13
**Status:** done
**Commit:** 28019a2

## Summary
- Added `.github/workflows/test.yml` that runs `xcodebuild test` on
  `menubar01.xcodeproj` for the `menubar01` scheme on every push to `main`
  and every pull request.
- Cached SwiftPM dependencies keyed on `Package.resolved` so subsequent runs
  skip the resolve step.
- Uploads the `*.xcresult` bundle as a workflow artifact on test failure.
- Documented the new CI in `README.md` (or `.github/workflows/README.md`).

## Impact
- No code or test changes.
- First CI run will be slow (~5–10 min) while it warms the SPM cache; later
  runs are typically 1–2 min.
- Code signing is disabled in CI (`CODE_SIGN_IDENTITY=""`); this matches the
  project's local-development config.
