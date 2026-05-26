# Installation

XPAM Script expects a fresh Ubuntu 24.04 or Debian 12 VPS.

---

## Required preparation

Before running XPAM Script, the operator must have:

1. root access to the VPS;
2. SSH key access confirmed;
3. a domain name;
4. ability to create DNS `A` records;
5. DNS records pointing to the VPS IPv4 address.

Do not start step `0` until SSH key login works.

---

## Bootstrap installation

Download the bootstrap script first, then run it:

```bash
curl -fsSL -o xpam-bootstrap.sh https://raw.githubusercontent.com/deepru/xpam-script/main/bootstrap.sh
sudo XPAM_REPO="deepru/xpam-script" bash xpam-bootstrap.sh
```

The repository owner placeholder must be replaced before publication or provided through `XPAM_REPO`.

---

## Manual archive installation

```bash
cd /root

sha256sum -c xpam-script-v1.0.6-ubuntu24-debian12.tar.gz.sha256

rm -rf /root/xpam-install
mkdir -p /root/xpam-install

tar -xzf xpam-script-v1.0.6-ubuntu24-debian12.tar.gz -C /root/xpam-install

KIT_DIR="$(find /root/xpam-install -maxdepth 3 -type f -name install.sh -printf '%h\n' | head -n1)"
cd "$KIT_DIR"

bash ./install.sh
```

---

## Step 0

Step `0` configures SSH security and creates the command prefix.

The prefix determines the final command names:

```text
sudo <prefix>-install
sudo <prefix>-health
sudo <prefix>-links
sudo <prefix>-vless
sudo <prefix>-telega
```

After step `0`, continue through:

```bash
sudo <prefix>-install
```

---

## Step 1

Step `1` installs and configures the server. It may require a reboot. If a reboot is requested:

```bash
sudo reboot
```

After reconnecting by SSH key:

```bash
sudo <prefix>-install
```

Then choose step `1` again to continue.

---

## Post-install validation

Run:

```bash
sudo <prefix>-health
sudo <prefix>-links
```

The health check should end with:

```text
OK: <PREFIX> server looks healthy
```
