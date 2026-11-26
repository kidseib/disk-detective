# Code signing policy

**Status:** Draft for the SignPath Foundation application. No signed release has been published yet. The `v1.1.0` candidate is unsigned and intended for local evaluation. Its launcher uses PowerShell's `RemoteSigned` policy; if Windows marks the extracted scripts as downloaded, unblock the ZIP or use the fallback `Disk Detective.bat`. A signed release will contain signed scripts.

Free code signing provided by [SignPath.io](https://about.signpath.io/), certificate by [SignPath Foundation](https://signpath.org/).

## What will be signed

When signing is approved and configured, these files will be Authenticode-signed:

- `DiskDetectiveLauncher.exe`
- `DiskDetective.ps1`
- `DiskDetective.Core.ps1`
- `DiskDetective.Tools.ps1`
- `DiskDetective.Data.ps1`

These files will not be signed:

- `Disk Detective.bat` — the legacy fallback launcher; `.bat` files cannot be Authenticode-signed
- `HOW TO USE.txt`, `FEATURES.txt`, and `LICENSE`
- The release ZIP itself — the ZIP is not signed, but the executable and scripts inside it are

The certificate is issued to **SignPath Foundation**, so the publisher shown by Windows will be **SignPath Foundation**, not an individual.

## Team and roles

- **Committers and reviewers:** `kidseib` (sole maintainer)
- **Approvers:** `kidseib`

GitHub two-factor authentication is enabled. SignPath access will also use MFA. Changes from outside contributors are reviewed before merge.

## Build origin

Signed files will be built from this public repository by the GitHub Actions release workflow. SignPath will sign only artifacts produced by that workflow. No handwritten binaries or third-party executables will be submitted for signing.

## Privacy

Disk Detective does not transfer any information to other networked systems. It has no server, telemetry, analytics, or update check. Read the full [privacy policy](PRIVACY.md).

## Verifying a release

After a signed release is published:

1. Right-click `DiskDetectiveLauncher.exe` and choose **Properties** → **Digital Signatures**.
2. Confirm the signer is **SignPath Foundation**.
3. In PowerShell, run `Get-AuthenticodeSignature .\DiskDetectiveLauncher.exe` and confirm the status is `Valid`.
4. Compare the release ZIP's SHA-256 with the value in the release notes.

The legacy `.bat` fallback remains unsigned. Use the launcher unless you are troubleshooting a problem with it.
