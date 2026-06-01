# Release process

This document describes the high-level release packaging workflow for XPAM Script.

## Source of truth

- Runtime changes must be compared against the previous final release archive before packaging.
- Release archives are distributed through GitHub Releases.
- Detailed per-release notes belong in GitHub Releases.
- Accumulated changes belong in `CHANGELOG.md`.
- Current test matrix belongs in `TESTING.md`.
- User guide lives in `docs/USER_GUIDE_RU.docx` and `docs/USER_GUIDE_RU.pdf`.

## Archive naming

Release assets use this naming pattern:

```text
xpam-script-vX.Y.Z-ubuntu24-debian12.tar.gz
xpam-script-vX.Y.Z-ubuntu24-debian12.tar.gz.sha256
```

Candidate archives may include an additional candidate marker and short SHA fragment during testing, but final release archives must not.

## Pre-release checklist

Before publishing a release:

1. run shell syntax checks on installer/runtime/templates;
2. compare runtime changes against the previous final release archive;
3. remove candidate archives, temporary patches and release-specific draft files;
4. verify documentation contains no private domains, IP addresses, tokens or server prefixes;
5. regenerate DOCX/PDF user guide and visually verify the rendered pages;
6. run the documented test matrix;
7. build the final tarball;
8. generate SHA256;
9. verify the archive extracts into one clean top-level directory;
10. verify bootstrap URL/version references target the published release tag.

## Final archive build example

```bash
tar -czf xpam-script-vX.Y.Z-ubuntu24-debian12.tar.gz xpam-script-vX.Y.Z-ubuntu24-debian12
sha256sum xpam-script-vX.Y.Z-ubuntu24-debian12.tar.gz > xpam-script-vX.Y.Z-ubuntu24-debian12.tar.gz.sha256
```
