<!--
SPDX-FileCopyrightText: 2026 Gianluca Boiano
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Security Policy

OpenCIE is a volunteer-maintained, non-commercial open-source project. Reports are handled on a best-effort basis by a single maintainer.

## Supported versions

Only the [latest release](https://github.com/M0Rf30/opencie/releases/latest) receives security fixes. Please reproduce the problem on the latest release before reporting.

## Reporting a vulnerability

Please **do not** open a public issue, pull request or discussion for a suspected vulnerability.

Use GitHub private vulnerability reporting instead:

1. Go to the [Security tab](https://github.com/M0Rf30/opencie/security) of this repository.
2. Choose **Report a vulnerability** (or open [a new private advisory](https://github.com/M0Rf30/opencie/security/advisories/new) directly).

Helpful details:

- The affected version, platform (Linux/Windows/macOS/Android, Flatpak or not) and, if relevant, the version of the native library `libopencie-pkcs11`.
- A clear description of the issue and its impact.
- Steps to reproduce, or a proof of concept. Use synthetic data only: never attach real PINs, PUKs, CANs, card data, certificates or personal documents.
- Any suggested fix or mitigation.

## What to expect

- Acknowledgement within **7 days**.
- A follow-up with an assessment and, for valid reports, a fix and release plan. There is no fixed fix timeline: this is a volunteer project and fixes are made on a best-effort basis.
- Coordinated disclosure: please give me a reasonable time to ship a fix before publishing details. Fixed issues are published as a GitHub security advisory, with credit if you want it.

## Scope

In scope:

- PIN and CAN handling: entry, storage, memory handling, logging, throttling, app lock.
- Signature creation and verification (PAdES, CAdES, XAdES), timestamps and long-term validation data.
- The native library integration (`dart:ffi` boundary to [libopencie-pkcs11](https://github.com/M0Rf30/opencie-pkcs11)). Issues in the library itself should be reported in that repository.
- The phone-as-reader handoff (pairing, encryption, message handling).
- The update channel and release artifacts: update checks, release assets, build provenance.

Out of scope:

- Vulnerabilities in third-party dependencies with no demonstrable impact on OpenCIE (report them upstream).
- Attacks that require a rooted/jailbroken device, malware already running with the user's privileges, or physical possession of an unlocked device.
- Flaws in the CIE card itself or in the Italian eID infrastructure.
- Denial of service through unrealistic inputs, and issues in unsupported or old versions.

## Verifying releases

Each release ships a CycloneDX software bill of materials (`opencie-<tag>.cdx.json`), and every release asset has a signed [GitHub artifact attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds) (SLSA build provenance). To check a download:

```bash
gh attestation verify opencie-<tag>-linux-x86_64.tar.gz --repo M0Rf30/opencie
```
