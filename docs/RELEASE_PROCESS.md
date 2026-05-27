# Release process

This document describes the recommended release packaging process.

---

## 1. Source audit

Before release, verify that the tree does not contain:

```text
real domains
real IP addresses
passwords
tokens
VLESS links
MTProto links
private keys
/root/secure-notes
/etc/xpam-script/config.env
logs
backup archives
test traces
```

---

## 2. Syntax checks

Run:

```bash
bash -n install.sh
bash -n scripts/xpam-core.sh
for f in templates/*.sh.tpl; do bash -n "$f"; done
```

---

## 3. Package

Recommended release asset name:

```text
xpam-script-v1.0.10-ubuntu24-debian12.tar.gz
```

Build:

```bash
tar -czf xpam-script-v1.0.10-ubuntu24-debian12.tar.gz xpam-script-v1.0.10
sha256sum xpam-script-v1.0.10-ubuntu24-debian12.tar.gz > xpam-script-v1.0.10-ubuntu24-debian12.tar.gz.sha256
```

---

## 4. Publish

Create a GitHub Release with:

```text
tag: v1.0.10
asset: xpam-script-v1.0.10-ubuntu24-debian12.tar.gz
asset: xpam-script-v1.0.10-ubuntu24-debian12.tar.gz.sha256
```

---

## 5. Bootstrap test

On a clean VPS:

```bash
curl -fsSL -o xpam-bootstrap.sh https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

Then run a full install and health validation.
