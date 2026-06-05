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

Local working archives, release candidates and final validation archives must include a short SHA256 fragment in the filename to avoid mixing artifacts. The canonical filename without a SHA fragment is used only for the public GitHub Release asset, because bootstrap expects the canonical asset name.

## Pre-release checklist

Before publishing a release:

1. run shell syntax checks on installer/runtime/templates;
2. compare runtime changes against the previous final release archive;
3. remove candidate archives, temporary patches and release-specific draft files;
4. verify documentation contains no private domains, IP addresses, tokens or server prefixes;
5. regenerate DOCX/PDF user guide and visually verify the rendered pages;
6. run the documented test matrix;
7. build the local final validation tarball with a short SHA fragment in the filename;
8. generate SHA256 and verify it;
9. verify the archive extracts into one clean top-level directory;
10. only after QA PASS, copy/rename the exact tested archive to the canonical GitHub Release asset name;
11. verify bootstrap URL/version references target the published release tag.

## Final archive build example

```bash
tar -czf xpam-script-vX.Y.Z-final-<shortsha>-ubuntu24-debian12.tar.gz xpam-script-vX.Y.Z-ubuntu24-debian12
sha256sum xpam-script-vX.Y.Z-final-<shortsha>-ubuntu24-debian12.tar.gz > xpam-script-vX.Y.Z-final-<shortsha>-ubuntu24-debian12.tar.gz.sha256

# After QA PASS, create the public GitHub Release asset name from the exact tested bytes:
cp xpam-script-vX.Y.Z-final-<shortsha>-ubuntu24-debian12.tar.gz xpam-script-vX.Y.Z-ubuntu24-debian12.tar.gz
sha256sum xpam-script-vX.Y.Z-ubuntu24-debian12.tar.gz > xpam-script-vX.Y.Z-ubuntu24-debian12.tar.gz.sha256
```
