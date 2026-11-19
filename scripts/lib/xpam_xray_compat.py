"""XPAM-owned outbound policy; importing this module never changes a server."""

import re
import subprocess
import platform
from pathlib import Path


def core_binary():
    machine = platform.machine().lower()
    arch = {'x86_64': 'amd64', 'amd64': 'amd64', 'aarch64': 'arm64',
            'arm64': 'arm64', 'armv7l': 'arm32', 'armv6l': 'arm32',
            'i386': '386', 'i686': '386'}.get(machine, machine)
    binary = Path('/usr/local/x-ui/bin') / ('xray-linux-' + arch)
    if not binary.is_file():
        raise ValueError('installed Xray binary is missing')
    return binary


def core_version():
    result = subprocess.run([str(core_binary()), 'version'], capture_output=True,
                            text=True, timeout=5, check=True)
    match = re.search(r'\bXray\s+(\d+\.\d+\.\d+)\b', result.stdout)
    if match:
        return tuple(map(int, match[1].split('.')))
    raise ValueError('cannot identify installed Xray binary version')


def warp_policy(outbound, version):
    """Normalize address-family policy without replacing secrets or unknown keys."""
    settings = outbound.setdefault('settings', {})
    if version >= (26, 9, 30):
        settings.pop('domainStrategy', None)
        outbound['targetStrategy'] = 'ForceIPv4'
        stream = outbound.setdefault('streamSettings', {})
        stream.setdefault('sockopt', {})['domainStrategy'] = 'ForceIPv4'
    else:
        settings['domainStrategy'] = 'ForceIPv4'
        # New-style keys also describe user choices on newer cores. Do not erase
        # them during a downgrade; the older WireGuard handler uses settings.
    if not isinstance(settings.get('noKernelTun'), bool):
        settings['noKernelTun'] = False
    for key in ('workers', 'num_workers', 'NumWorkers'):
        settings.pop(key, None)


def warp_policy_matches(outbound, version):
    settings = outbound.get('settings') or {}
    if version >= (26, 9, 30):
        return (
            outbound.get('targetStrategy') == 'ForceIPv4'
            and ((outbound.get('streamSettings') or {}).get('sockopt') or {}).get('domainStrategy') == 'ForceIPv4'
            and 'domainStrategy' not in settings
        )
    return settings.get('domainStrategy') == 'ForceIPv4'


def client_is_unshared(database, email, excluding=0):
    """Only an existing client with no other inbound may be removed globally."""
    import sqlite3
    from contextlib import closing
    with closing(sqlite3.connect(Path(database).resolve().as_uri() + '?mode=ro', uri=True)) as connection:
        row = connection.execute('SELECT id FROM clients WHERE email=?', (email,)).fetchone()
        if row is None:
            return False
        return connection.execute(
            'SELECT count(*) FROM client_inbounds WHERE client_id=? AND inbound_id<>?',
            (row[0], int(excluding)),
        ).fetchone()[0] == 0


def validated_warp_registration(envelope):
    """Accept a full 3x-ui registration response, never an executable config file."""
    import base64
    import ipaddress
    from urllib.parse import urlsplit

    def key(value):
        if not isinstance(value, str) or len(base64.b64decode(value, validate=True)) != 32:
            raise ValueError('invalid WireGuard key')
        return value

    if not isinstance(envelope, dict):
        raise ValueError('registration must be an object')
    data, response = envelope.get('data'), envelope.get('config')
    if not isinstance(data, dict) or not isinstance(response, dict):
        raise ValueError('full account and registration response are required')
    account = {}
    for name in ('access_token', 'device_id', 'private_key'):
        value = data.get(name)
        if not isinstance(value, str) or not value or len(value) > 4096 or any(ord(c) < 32 for c in value):
            raise ValueError('missing or invalid account field')
        account[name] = value
    key(account['private_key'])
    license_key = data.get('license_key', '')
    if not isinstance(license_key, str) or len(license_key) > 4096:
        raise ValueError('invalid license field')
    account['license_key'] = license_key
    config = response.get('config')
    if not isinstance(config, dict):
        raise ValueError('Cloudflare interface configuration is required')
    client_id = config.get('client_id') or data.get('client_id')
    if not isinstance(client_id, str):
        raise ValueError('client_id is required')
    reserved = list(base64.b64decode(client_id, validate=True))
    if len(reserved) != 3 or (data.get('client_id') and data['client_id'] != client_id):
        raise ValueError('invalid or inconsistent client_id')
    account['client_id'] = client_id
    address = ipaddress.ip_address(config['interface']['addresses']['v4'])
    if address.version != 4:
        raise ValueError('IPv4 WARP interface is required')
    peer = config['peers'][0]
    public_key = key(peer['public_key'])
    endpoint = peer['endpoint'].get('host') or peer['endpoint'].get('v4')
    if not isinstance(endpoint, str) or not endpoint or any(c.isspace() for c in endpoint):
        raise ValueError('invalid WARP endpoint')
    parsed = urlsplit('//' + endpoint)
    host = parsed.hostname
    port = parsed.port if parsed.port is not None else 2408
    if not host or parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment or not 1 <= port <= 65535:
        raise ValueError('invalid WARP endpoint')
    try:
        remote = ipaddress.ip_address(host)
    except ValueError:
        if not re.fullmatch(r'[A-Za-z0-9.-]+', host) or not host.lower().endswith('.cloudflareclient.com'):
            raise ValueError('unexpected WARP endpoint hostname')
    else:
        if remote.version != 4 or not remote.is_global:
            raise ValueError('a public IPv4 WARP endpoint is required')
    settings = {'secretKey': account['private_key'], 'address': [str(address) + '/32'],
                'peers': [{'publicKey': public_key, 'endpoint': host + ':' + str(port),
                           'allowedIPs': ['0.0.0.0/0'], 'keepAlive': 25}],
                'reserved': reserved, 'mtu': 1420, 'noKernelTun': False}
    return account, settings


def restore_warp_state(snapshot, database):
    """Restore WARP state without rolling back other clients or traffic counters."""
    import json
    import sqlite3
    from contextlib import closing
    with closing(sqlite3.connect(Path(snapshot).resolve().as_uri() + '?mode=ro', uri=True)) as saved:
        old_account = saved.execute("SELECT value FROM settings WHERE key='warp'").fetchone()
        old_registration = saved.execute("SELECT value FROM settings WHERE key='xpamWarpRegistrationConfig'").fetchone()
        old_template = saved.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
        old_config = json.loads(old_template[0]) if old_template and old_template[0] else {}
        old_sniffing = saved.execute("SELECT id,settings,sniffing FROM inbounds WHERE protocol='vless'").fetchall()
    with closing(sqlite3.connect(database, timeout=10)) as live:
        live.execute('BEGIN IMMEDIATE')
        try:
            row = live.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
            if row and row[0]:
                config = json.loads(row[0])
                for field in ('outbounds',):
                    current = config.get(field) or []
                    previous = old_config.get(field) or []
                    remaining = [ob for ob in current if ob.get('tag') != 'warp']
                    for position, old in enumerate(previous):
                        if old.get('tag') == 'warp':
                            remaining.insert(min(position, len(remaining)), old)
                    config[field] = remaining
                routing = config.setdefault('routing', {})
                rules = routing.get('rules') or []
                previous = (old_config.get('routing') or {}).get('rules') or []
                remaining = [rule for rule in rules if rule.get('outboundTag') != 'warp']
                for position, old in enumerate(previous):
                    if old.get('outboundTag') == 'warp':
                        remaining.insert(min(position, len(remaining)), old)
                routing['rules'] = remaining
                live.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(config),))
            for key, previous in (('warp', old_account), ('xpamWarpRegistrationConfig', old_registration)):
                live.execute('DELETE FROM settings WHERE key=?', (key,))
                if previous:
                    live.execute('INSERT INTO settings(key,value) VALUES(?,?)', (key, previous[0]))
            for ident, settings, sniffing in old_sniffing:
                # A replaced inbound is not the one whose sniffing we changed.
                live.execute('UPDATE inbounds SET sniffing=? WHERE id=? AND settings=?', (sniffing, ident, settings))
            live.commit()
        except Exception:
            live.rollback()
            raise


def probe_warp(outbound):
    """Test an isolated userspace outbound before assigning client routes to it."""
    import copy
    import json
    import os
    import signal
    import socket
    import tempfile
    import time

    outbound = copy.deepcopy(outbound)
    outbound['settings']['noKernelTun'] = True
    with tempfile.TemporaryDirectory(prefix='xpam-warp-probe-') as folder:
        folder = Path(folder)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        config = {'log': {'logLevel': 'error'}, 'inbounds': [
            {'listen': '127.0.0.1', 'port': port, 'protocol': 'socks',
             'settings': {'auth': 'noauth', 'udp': False}}], 'outbounds': [outbound]}
        path = folder / 'config.json'
        path.write_text(json.dumps(config))
        path.chmod(0o600)
        env = os.environ.copy()
        env['XRAY_LOCATION_ASSET'] = str(core_binary().parent)
        parent = os.getpid()
        def child_setup():
            # Stop the probe if SSH/Python dies, even though it has its own
            # process group so normal cleanup can terminate its descendants.
            import ctypes
            if ctypes.CDLL(None).prctl(1, signal.SIGTERM, 0, 0, 0) != 0:
                os._exit(1)
            if os.getppid() != parent:
                os._exit(1)
        with open(folder / 'xray.log', 'wb') as log:
            process = subprocess.Popen([str(core_binary()), 'run', '-config', str(path)],
                                       stdout=log, stderr=log, env=env, start_new_session=True,
                                       preexec_fn=child_setup)
            try:
                for attempt in range(30):
                    if process.poll() is not None:
                        raise ValueError('isolated WARP core did not start')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1):
                            break
                    except OSError:
                        time.sleep(.1)
                else:
                    raise TimeoutError('isolated WARP listener did not start')
                result = subprocess.run([
                    'curl', '--silent', '--show-error', '--fail', '--noproxy', '',
                    '--socks5-hostname', '127.0.0.1:' + str(port),
                    '--connect-timeout', '8', '--max-time', '25',
                    'https://www.cloudflare.com/cdn-cgi/trace',
                ], capture_output=True, text=True, timeout=28)
                if result.returncode or not any(line in ('warp=on', 'warp=plus') for line in result.stdout.splitlines()):
                    raise ValueError('WARP tunnel or egress check failed')
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=5)


def reconcile_ocsp(database, port, backups, probe=None):
    """Remove stapling only from the managed loopback VLESS cert with no OCSP URL."""
    import json
    import os
    import sqlite3
    import time
    from contextlib import closing

    def certificate_has_ocsp(path):
        result = subprocess.run(['openssl', 'x509', '-in', path, '-noout', '-ocsp_uri'],
                                capture_output=True, text=True, timeout=5)
        return bool(result.stdout.strip()) if result.returncode == 0 else None

    probe = probe or certificate_has_ocsp
    with closing(sqlite3.connect(database, timeout=10)) as source:
        changes = []
        for ident, raw in source.execute(
            "SELECT id,stream_settings FROM inbounds WHERE protocol='vless' AND listen='127.0.0.1' AND port=?",
            (int(port),),
        ):
            stream = json.loads(raw)
            touched = False
            for cert in (stream.get('tlsSettings') or {}).get('certificates', []):
                if cert.get('ocspStapling') and cert.get('certificateFile'):
                    if probe(cert['certificateFile']) is False:
                        cert.pop('ocspStapling', None)
                        touched = True
            if touched:
                changes.append((json.dumps(stream, separators=(',', ':')), ident, raw))
        if not changes:
            return False
        directory = Path(backups)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        import tempfile
        fd, snapshot = tempfile.mkstemp(prefix='x-ui.db.', dir=str(directory))
        os.close(fd)
        deadline = time.monotonic() + 30
        def progress(status, remaining, total):
            if time.monotonic() > deadline:
                raise TimeoutError('OCSP backup timed out')
        try:
            with closing(sqlite3.connect(snapshot)) as target:
                source.backup(target, pages=256, progress=progress, sleep=0.1)
                if target.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
                    raise ValueError('OCSP backup integrity check failed')
            source.execute('BEGIN IMMEDIATE')
            for change in changes:
                if source.execute('UPDATE inbounds SET stream_settings=? WHERE id=? AND stream_settings=?', change).rowcount != 1:
                    raise ValueError('inbound changed concurrently; OCSP migration cancelled')
            source.commit()
        except Exception:
            source.rollback()
            raise
        return True
