#!/usr/bin/env bash
# XPAM payload smoke-harness (dev/CI only — NOT run at install time).
#
# Runs the three 3x-ui inbound-payload builders offline and asserts the emitted
# JSON against the field/type contract of 3x-ui's Go model.Client / model.Inbound
# (pinned tag v3.5.0). Catches the class of bug that ships silently otherwise:
#   * a client field sent with the wrong JSON type (e.g. tgId as a string) — 3.5.0
#     strict-parses clients into model.Client and rejects a type mismatch;
#   * a phantom top-level inbound key (e.g. allocate) that 3.x silently drops;
#   * the xHTTP-behind-nginx share-link contract (security=none inbound, but the
#     externalProxy entry must carry forceTls=tls + sni + fingerprint, and the
#     inbound must NOT carry a vestigial tlsSettings block).
#
# The builders are sourced from the real kit (scripts/xpam-core.sh sources every
# lib), driven with dummy-but-valid config, so this exercises the shipping code —
# not a copy. Requires python3 (present in CI and on target boxes). On a host
# without python3 it prints SKIP and exits 0 so it never blocks a dev release build.
#
# Usage:  bash tests/payload-smoke.sh
# Exit:   0 = all builders satisfied the contract (or skipped); 1 = a FAIL finding.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not found — payload smoke-harness needs python3 (CI/target boxes have it)."
  exit 0
fi

# Source the real kit. xpam-core.sh defines the builders, sets empty config
# defaults, then sources every lib module (functions only at source time); it
# does NOT run the menu (that starts from install.sh). Silence its source-time
# banner noise; a non-zero source is a genuine failure.
#
# xpam-core.sh pins PATH to a fixed system list (a hardening choice for the target
# box, where python3 lives in /usr/bin). This test may run on a dev host whose
# python3/python is elsewhere, so capture PATH first and re-append it after the
# source as a fallback. Harmless: this affects only the harness, never install.sh.
_XPAM_SMOKE_ORIG_PATH="$PATH"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/xpam-core.sh" >/dev/null 2>&1
export PATH="$PATH:$_XPAM_SMOKE_ORIG_PATH"

# Dummy-but-valid config. Values satisfy validate_port / validate_domain and the
# root_mtproto profile so uses_mtproto is true and every builder runs.
PROFILE="root_mtproto"
SERVER_PREFIX="us"
ROOT_DOMAIN="example.com"
WWW_DOMAIN="www.example.com"
PRIMARY_DOMAIN="vpn.example.com"
SYNC_DOMAIN="sync.example.com"
WEB_CERT_NAME=""
CERT_EMAIL=""
XRAY_PUBLIC_PORT="443"
XRAY_LOCAL_PORT="1443"
SITE_BACKEND_PORT="8080"
SYNC_BACKEND_PORT="8443"
MTPROTO_PORT="1450"
VLESS_ALT_TRANSPORT="xhttp"
VLESS_ALT_DOMAIN="cdn.example.com"
VLESS_ALT_PATH="/v1/streams/0123456789abcdef"
XRAY_ALT_PORT="1444"
NGINX_ALT_TLS_PORT="8443"

work="$(mktemp -d "${TMPDIR:-/tmp}/xpam-payload-smoke.XXXXXX")"
trap 'rm -rf "$work"' EXIT
vless_json="$work/vless.json"
mtg_json="$work/mtg.json"
xhttp_json="$work/xhttp.json"
grpc_json="$work/grpc.json"

echo "==> Building payloads offline (kit: $REPO_ROOT)"
xui_build_inbound_payload "$vless_json" >/dev/null
mtproto_3xui_mtg_payload "$mtg_json" "" "$MTPROTO_PORT" >/dev/null
alt_build_xhttp_payload "$xhttp_json" >/dev/null
VLESS_ALT_TRANSPORT="grpc" VLESS_ALT_PATH="v1/streams/0123456789abcdef" alt_build_grpc_payload "$grpc_json" >/dev/null

SMOKE_VLESS="$vless_json" SMOKE_MTG="$mtg_json" SMOKE_XHTTP="$xhttp_json" SMOKE_GRPC="$grpc_json" python3 - <<'PY_SMOKE_VALIDATE'
import json, os, sys

# --- 3x-ui contract, pinned to tag v3.5.0 -----------------------------------
# internal/database/model/model.go, type Client (JSON key -> type category).
CLIENT_FIELDS = {
    "id": "str", "security": "str", "password": "str", "flow": "str",
    "reverse": "obj", "auth": "str", "privateKey": "str", "publicKey": "str",
    "allowedIPs": "list", "preSharedKey": "str", "keepAlive": "int",
    "secret": "str", "adTag": "str", "email": "str", "limitIp": "int",
    "totalGB": "int", "expiryTime": "int", "enable": "bool", "tgId": "int",
    "subId": "str", "group": "str", "comment": "str", "reset": "int",
    "created_at": "int", "updated_at": "int",
}
# internal/database/model/model.go, type Inbound (json/form keys; UserId is json:"-").
INBOUND_TOP_FIELDS = {
    "id", "up", "down", "total", "remark", "subSortIndex", "enable",
    "expiryTime", "trafficReset", "lastTrafficResetTime", "clientStats",
    "listen", "port", "protocol", "settings", "streamSettings", "tag",
    "sniffing", "nodeId", "shareAddrStrategy", "shareAddr", "originNodeGuid",
    "fallbackParent",
}

fails, warns = [], []


def fail(where, msg):
    fails.append("%s: %s" % (where, msg))


def warn(where, msg):
    warns.append("%s: %s" % (where, msg))


def type_ok(value, cat):
    if cat == "str":
        return isinstance(value, str)
    if cat == "bool":
        return isinstance(value, bool)
    if cat == "int":
        return isinstance(value, int) and not isinstance(value, bool)
    if cat == "list":
        return isinstance(value, list)
    if cat == "obj":
        return isinstance(value, dict)
    return True


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def parse_embedded(where, payload, key):
    raw = payload.get(key)
    if raw is None or raw == "":
        return {}
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        try:
            return json.loads(raw)
        except Exception as exc:
            fail(where, "%s is not valid JSON: %s" % (key, exc))
            return {}
    fail(where, "%s has unexpected type %s" % (key, type(raw).__name__))
    return {}


def check_top_level(where, payload):
    for key in payload:
        if key not in INBOUND_TOP_FIELDS:
            warn(where, "unknown top-level key %r (3.x silently drops it)" % key)
    if "port" in payload and not type_ok(payload["port"], "int"):
        fail(where, "port must be a number, got %r" % (payload["port"],))
    if "enable" in payload and not type_ok(payload["enable"], "bool"):
        fail(where, "enable must be a bool, got %r" % (payload["enable"],))


def check_clients(where, settings):
    clients = settings.get("clients")
    if not isinstance(clients, list) or not clients:
        fail(where, "settings.clients missing or empty")
        return []
    for i, c in enumerate(clients):
        cw = "%s clients[%d]" % (where, i)
        if not isinstance(c, dict):
            fail(cw, "client entry is not an object")
            continue
        for key, value in c.items():
            if key not in CLIENT_FIELDS:
                warn(cw, "unknown client key %r" % key)
                continue
            if not type_ok(value, CLIENT_FIELDS[key]):
                fail(cw, "%r must be %s, got %r (%s)"
                     % (key, CLIENT_FIELDS[key], value, type(value).__name__))
    return clients


def check_vless_primary(where, payload, settings, stream):
    if stream.get("network") != "tcp":
        fail(where, "expected network=tcp, got %r" % stream.get("network"))
    if stream.get("security") != "tls":
        fail(where, "primary VLESS must be security=tls, got %r" % stream.get("security"))
    if settings.get("decryption") != "none":
        fail(where, "VLESS settings.decryption must be 'none', got %r" % settings.get("decryption"))
    ep = stream.get("externalProxy")
    if not isinstance(ep, list) or not ep:
        fail(where, "externalProxy missing (needed to advertise :443)")
    elif ep[0].get("forceTls") not in ("same", "tls", "none"):
        fail(where, "externalProxy[0].forceTls invalid: %r" % ep[0].get("forceTls"))


def check_vless_xhttp(where, payload, settings, stream):
    # xHTTP behind nginx: the inbound is plain (nginx terminates TLS), but the
    # share-link the panel/hosts generate must advertise TLS via the externalProxy
    # entry (forceTls=tls + sni + fingerprint). The inbound must NOT carry a
    # tlsSettings block: genVlessLink ignores it when stream.security != 'tls', so
    # it does nothing for the link and only risks confusing the panel/xray.
    if stream.get("network") != "xhttp":
        fail(where, "expected network=xhttp, got %r" % stream.get("network"))
    if stream.get("security") != "none":
        fail(where, "xhttp inbound must be security=none (nginx terminates TLS), got %r"
             % stream.get("security"))
    if "tlsSettings" in stream:
        fail(where, "xhttp inbound must NOT carry tlsSettings (useless for the link; drop it)")
    ep = stream.get("externalProxy")
    if not isinstance(ep, list) or not ep:
        fail(where, "externalProxy missing (needed for the security=tls share-link)")
    else:
        e0 = ep[0]
        if e0.get("forceTls") != "tls":
            fail(where, "externalProxy[0].forceTls must be 'tls', got %r" % e0.get("forceTls"))
        if not str(e0.get("sni") or "").strip():
            fail(where, "externalProxy[0].sni must be set (panel link sni comes from it)")
        if not str(e0.get("fingerprint") or "").strip():
            fail(where, "externalProxy[0].fingerprint must be set (panel link fp comes from it)")
    xh = stream.get("xhttpSettings")
    if not isinstance(xh, dict) or not xh.get("path") or not xh.get("host"):
        fail(where, "xhttpSettings must carry path + host")


def check_vless_grpc(where, payload, settings, stream):
    # gRPC behind nginx: same discipline as xhttp — plain inbound (security=none), share-link TLS via the
    # externalProxy entry, no vestigial inbound tlsSettings. grpcSettings.serviceName carries the secret.
    if stream.get("network") != "grpc":
        fail(where, "expected network=grpc, got %r" % stream.get("network"))
    if stream.get("security") != "none":
        fail(where, "grpc inbound must be security=none (nginx terminates TLS), got %r"
             % stream.get("security"))
    if "tlsSettings" in stream:
        fail(where, "grpc inbound must NOT carry tlsSettings (useless for the link; drop it)")
    ep = stream.get("externalProxy")
    if not isinstance(ep, list) or not ep:
        fail(where, "externalProxy missing (needed for the security=tls share-link)")
    else:
        e0 = ep[0]
        if e0.get("forceTls") != "tls":
            fail(where, "externalProxy[0].forceTls must be 'tls', got %r" % e0.get("forceTls"))
        if not str(e0.get("sni") or "").strip():
            fail(where, "externalProxy[0].sni must be set (panel link sni comes from it)")
        if not str(e0.get("fingerprint") or "").strip():
            fail(where, "externalProxy[0].fingerprint must be set (panel link fp comes from it)")
    gs = stream.get("grpcSettings")
    if not isinstance(gs, dict) or not str(gs.get("serviceName") or "").strip():
        fail(where, "grpcSettings must carry a non-empty serviceName")
    elif not isinstance(gs.get("multiMode"), bool):
        fail(where, "grpcSettings.multiMode must be a bool")


def check_mtproto(where, payload, settings, clients):
    if not any(str(c.get("secret") or "").strip() for c in clients):
        fail(where, "no mtproto client carries a secret")
    df = settings.get("domainFronting")
    if not isinstance(df, dict) or not df.get("ip") or not df.get("port"):
        fail(where, "domainFronting must carry ip + port")
    if payload.get("shareAddrStrategy") != "custom":
        warn(where, "shareAddrStrategy expected 'custom', got %r" % payload.get("shareAddrStrategy"))
    if not str(payload.get("shareAddr") or "").strip():
        warn(where, "shareAddr not set")


def run(where, path, kind):
    payload = load(path)
    check_top_level(where, payload)
    settings = parse_embedded(where, payload, "settings")
    stream = parse_embedded(where, payload, "streamSettings")
    clients = check_clients(where, settings)
    if kind == "vless_primary":
        check_vless_primary(where, payload, settings, stream)
    elif kind == "vless_xhttp":
        check_vless_xhttp(where, payload, settings, stream)
    elif kind == "vless_grpc":
        check_vless_grpc(where, payload, settings, stream)
    elif kind == "mtproto":
        check_mtproto(where, payload, settings, clients)


run("VLESS-primary", os.environ["SMOKE_VLESS"], "vless_primary")
run("MTProto/MTG", os.environ["SMOKE_MTG"], "mtproto")
run("VLESS-xhttp", os.environ["SMOKE_XHTTP"], "vless_xhttp")
run("VLESS-grpc", os.environ["SMOKE_GRPC"], "vless_grpc")

for w in warns:
    print("  WARN  " + w)
for f in fails:
    print("  FAIL  " + f)

if fails:
    print("\nRESULT: FAIL (%d finding(s), %d warning(s))" % (len(fails), len(warns)))
    sys.exit(1)
print("\nRESULT: PASS (%d warning(s))" % len(warns))
PY_SMOKE_VALIDATE
