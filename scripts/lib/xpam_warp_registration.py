"""Temporary panel egress for WARP registration; no import-time side effects."""

from contextlib import closing, contextmanager
import json
import os
from pathlib import Path
import re
import signal
import socket
import sqlite3
import subprocess
import sys
import time
import uuid

from xpam_xray_compat import core_binary, validated_warp_registration

DATABASE = Path('/etc/x-ui/x-ui.db')
GENERATED = Path('/usr/local/x-ui/bin/config.json')
JOURNAL = Path('/var/lib/xpam-script/warp-registration-egress.json')
RUNTIME = Path('/run/xpam-warp-registration')


def parse_vless(link):
    from urllib.parse import parse_qs, unquote, urlsplit
    if not isinstance(link, str) or len(link) > 16384 or any(c.isspace() for c in link):
        raise ValueError('invalid VLESS link')
    u = urlsplit(link)
    if u.scheme != 'vless' or not u.username or u.password or not u.hostname or not u.port:
        raise ValueError('invalid VLESS address')
    uid = str(uuid.UUID(unquote(u.username)))
    q = parse_qs(u.query)
    def value(name, default=''):
        values = q.get(name, [default])
        if len(values) != 1:
            raise ValueError('ambiguous VLESS parameter')
        return values[0]
    network = value('type', value('network', 'tcp'))
    if network == 'raw':
        network = 'tcp'
    security = value('security', 'tls')
    if network not in ('tcp', 'ws', 'grpc', 'xhttp') or security not in ('none', 'tls', 'reality'):
        raise ValueError('unsupported VLESS transport')
    if value('encryption', 'none') != 'none' or value('allowInsecure', '0').lower() not in ('0', 'false'):
        raise ValueError('unsupported VLESS encryption or TLS verification')
    settings = {'address': u.hostname, 'port': u.port, 'id': uid,
                'encryption': 'none', 'flow': value('flow')}
    stream = {'network': network, 'security': security}
    if security == 'tls':
        tls = {'serverName': value('sni', u.hostname)}
        if value('alpn'):
            tls['alpn'] = value('alpn').split(',')
        if value('fp'):
            tls['fingerprint'] = value('fp')
        stream['tlsSettings'] = tls
    elif security == 'reality':
        if not value('pbk'):
            raise ValueError('REALITY public key missing')
        stream['realitySettings'] = {'serverName': value('sni', u.hostname),
            'fingerprint': value('fp', 'chrome'), 'publicKey': value('pbk'),
            'shortId': value('sid'), 'spiderX': value('spx')}
    if network == 'tcp':
        if value('headerType', 'none') != 'none':
            raise ValueError('unsupported TCP header')
        stream['tcpSettings'] = {'header': {'type': 'none'}}
    elif network == 'ws':
        stream['wsSettings'] = {'path': value('path', '/')}
        if value('host'):
            stream['wsSettings']['headers'] = {'Host': value('host')}
    elif network == 'grpc':
        stream['grpcSettings'] = {'serviceName': value('serviceName')}
        if value('authority'):
            stream['grpcSettings']['authority'] = value('authority')
    else:
        stream['xhttpSettings'] = {'path': value('path', '/'), 'mode': value('mode', 'auto')}
        if value('host'):
            stream['xhttpSettings']['host'] = value('host')
        if value('extra'):
            extra = json.loads(value('extra'))
            if not isinstance(extra, dict):
                raise ValueError('invalid XHTTP extra')
            stream['xhttpSettings']['extra'] = extra
    return {'protocol': 'vless', 'tag': 'registration-vless', 'settings': settings,
            'streamSettings': stream}


def registration_network_failure(text):
    text = text.lower()
    network = ('timeout', 'deadline exceeded', 'no such host', 'network is unreachable',
               'connection reset', 'connection refused', 'dial tcp', 'unexpected eof')
    return (('api.cloudflareclient.com' in text and any(x in text for x in network))
            or bool(re.search(r'warp api .*returned status (403|429|5\d\d)', text)))


def cache_registration(database, envelope):
    """Keep interface data so setup need not contact the blocked API again."""
    account, settings = validated_warp_registration(envelope)
    peer = settings['peers'][0]
    cached = {'device_id': account['device_id'], 'client_id': account['client_id'],
        'config': {'client_id': account['client_id'],
            'interface': {'addresses': {'v4': settings['address'][0].split('/')[0]}},
            'peers': [{'public_key': peer['publicKey'], 'endpoint': {'host': peer['endpoint']}}]}}
    with closing(sqlite3.connect(database, timeout=10)) as connection:
        connection.execute('BEGIN IMMEDIATE')
        row = connection.execute("SELECT value FROM settings WHERE key='warp'").fetchone()
        current = json.loads(row[0]) if row and row[0] else {}
        if any(current.get(key) != account[key] for key in ('device_id', 'private_key')) or (current.get('client_id') and current['client_id'] != account['client_id']):
            raise ValueError('WARP account changed concurrently')
        connection.execute("DELETE FROM settings WHERE key='xpamWarpRegistrationConfig'")
        connection.execute("INSERT INTO settings(key,value) VALUES('xpamWarpRegistrationConfig',?)", (json.dumps(cached),))
        connection.commit()


def cached_registration(database):
    with closing(sqlite3.connect(Path(database).resolve().as_uri() + '?mode=ro', uri=True)) as connection:
        row = connection.execute("SELECT value FROM settings WHERE key='warp'").fetchone()
        saved = connection.execute("SELECT value FROM settings WHERE key='xpamWarpRegistrationConfig'").fetchone()
        template = connection.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
        if not row or not saved:
            return None
        if template and any(o.get('tag') == 'warp' for o in json.loads(template[0]).get('outbounds', [])):
            return None
        account, cached = json.loads(row[0]), json.loads(saved[0])
        if account.get('device_id') != cached.get('device_id') or (account.get('client_id') and account['client_id'] != cached.get('client_id')):
            return None
        envelope = {'data': account, 'config': {'config': cached['config']}}
        validated_warp_registration(envelope)
        return envelope


def write_private(path, value):
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w') as target:
            json.dump(value, target)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def begin_egress(database, journal, port, owner=None, folder=None):
    """The persistent temporary outbound contains loopback data, never VLESS credentials."""
    tag = 'xpam-warp-reg-' + uuid.uuid4().hex
    with closing(sqlite3.connect(database, timeout=10)) as connection:
        connection.execute('BEGIN IMMEDIATE')
        rows = connection.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchall()
        if len(rows) != 1:
            raise ValueError('Xray template missing')
        row = rows[0]
        config = json.loads(row[0])
        if (config.get('routing') or {}).get('script'):
            raise ValueError('custom routing script is configured')
        previous = connection.execute("SELECT value FROM settings WHERE key='panelOutbound'").fetchall()
        if len(previous) > 1:
            raise ValueError('ambiguous panel outbound setting')
        old = previous[0] if previous else None
        record = {'tag': tag, 'previous': old[0] if old else None,
                  'previous_present': old is not None, 'owner': owner}
        if folder:
            record['folder'] = str(folder)
        write_private(journal, record)  # Durable recovery metadata precedes any database write.
        config.setdefault('outbounds', []).append({'tag': tag, 'protocol': 'socks',
            'settings': {'address': '127.0.0.1', 'port': int(port)}})
        connection.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(config),))
        if old:
            connection.execute("UPDATE settings SET value=? WHERE key='panelOutbound'", (tag,))
        else:
            connection.execute("INSERT INTO settings(key,value) VALUES('panelOutbound',?)", (tag,))
        connection.commit()
    return record


def restore_egress(database, record):
    """Remove only our temporary outbound; preserve concurrent operator edits."""
    with closing(sqlite3.connect(database, timeout=10)) as connection:
        connection.execute('BEGIN IMMEDIATE')
        row = connection.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
        if row:
            config = json.loads(row[0])
            config['outbounds'] = [o for o in config.get('outbounds', []) if o.get('tag') != record['tag']]
            connection.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(config),))
        current = connection.execute("SELECT value FROM settings WHERE key='panelOutbound'").fetchone()
        if current and current[0] == record['tag']:
            if not record.get('previous_present', record['previous'] is not None):
                connection.execute("DELETE FROM settings WHERE key='panelOutbound'")
            else:
                connection.execute("UPDATE settings SET value=? WHERE key='panelOutbound'", (record['previous'],))
        connection.commit()


def owner_identity():
    return {'pid': os.getpid(), 'boot': Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
            'start': Path('/proc/self/stat').read_text().rsplit(')', 1)[1].split()[19]}


def owner_alive(owner):
    try:
        return (owner['boot'] == Path('/proc/sys/kernel/random/boot_id').read_text().strip()
                and owner['start'] == Path('/proc', str(owner['pid']), 'stat').read_text().rsplit(')', 1)[1].split()[19])
    except (KeyError, OSError, TypeError):
        return False


def restart_panel():
    subprocess.run(['systemctl', 'restart', 'x-ui'], check=True, timeout=45,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def wait_egress_removed(tag):
    deadline = time.monotonic() + 30
    while True:
        try:
            config = json.loads(GENERATED.read_text())
            outbounds = config.get('outbounds', [])
            rules = (config.get('routing') or {}).get('rules', [])
            if not any(o.get('tag') == tag for o in outbounds) and not any(r.get('outboundTag') == tag for r in rules):
                return
        except (OSError, ValueError):
            pass
        if time.monotonic() > deadline:
            raise TimeoutError('panel has not removed temporary egress')
        time.sleep(.2)


def cleanup_runtime(folder):
    import shutil
    folder = Path(folder)
    if folder.parent.resolve() != RUNTIME.resolve() or folder.is_symlink():
        raise ValueError('unexpected registration runtime path')
    shutil.rmtree(folder, ignore_errors=True)


@contextmanager
def operation_lock():
    import fcntl
    RUNTIME.mkdir(mode=0o700, parents=True, exist_ok=True)
    with open(RUNTIME / 'operation.lock', 'a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def recover(restart=True, locked=False):
    if not locked:
        with operation_lock():
            return recover(restart, locked=True)
    if not JOURNAL.exists():
        return
    record = json.loads(JOURNAL.read_text())
    if owner_alive(record.get('owner')):
        return
    restore_egress(DATABASE, record)
    if restart:
        restart_panel()
        wait_egress_removed(record['tag'])
    if record.get('folder'):
        cleanup_runtime(record['folder'])
    JOURNAL.unlink(missing_ok=True)


def verify_bridge(generated, tag, port):
    config = json.loads(Path(generated).read_text())
    outbound = next(o for o in config.get('outbounds', []) if o.get('tag') == tag)
    settings = outbound.get('settings', {})
    if outbound.get('protocol') != 'socks' or settings.get('address') != '127.0.0.1' or settings.get('port') != port:
        raise ValueError('temporary panel egress does not match')
    routing = config.get('routing') or {}
    if routing.get('script'):
        raise ValueError('custom routing script')
    rule = next(r for r in routing.get('rules', []) if 'panel-egress' in r.get('inboundTag', []))
    if rule.get('outboundTag') != tag:
        raise ValueError('panel egress rule missing')
    inbound = next(i for i in config.get('inbounds', []) if i.get('tag') == 'panel-egress')
    if inbound.get('listen') != '127.0.0.1' or inbound.get('protocol') != 'socks':
        raise ValueError('panel egress listener mismatch')
    with socket.create_connection(('127.0.0.1', inbound['port']), timeout=.5):
        pass


def register_via_vless(link, output):
    import ctypes
    import tempfile
    import urllib.parse
    import urllib.request
    import ssl

    outbound = parse_vless(link)
    del link
    with operation_lock():
        recover(locked=True)
        if JOURNAL.exists():
            raise ValueError('another registration owns the panel egress')
        with tempfile.TemporaryDirectory(prefix='operation-', dir=RUNTIME) as folder:
            folder = Path(folder)
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            config = {'log': {'logLevel': 'error'}, 'inbounds': [
                {'listen': '127.0.0.1', 'port': port, 'protocol': 'socks',
                 'settings': {'auth': 'noauth', 'udp': False}}], 'outbounds': [outbound]}
            path = folder / 'client.json'
            write_private(path, config)
            parent = os.getpid()
            def child_setup():
                if ctypes.CDLL(None).prctl(1, signal.SIGTERM, 0, 0, 0) != 0 or os.getppid() != parent:
                    os._exit(1)
            process = None
            record = None
            try:
                with open(folder / 'core.log', 'wb') as log:
                    environment = {k: v for k, v in os.environ.items() if not k.startswith('XPAM_')}
                    environment['XRAY_LOCATION_ASSET'] = str(core_binary().parent)
                    process = subprocess.Popen([str(core_binary()), 'run', '-config', str(path)],
                        stdout=log, stderr=log, start_new_session=True, preexec_fn=child_setup,
                        env=environment)
                deadline = time.monotonic() + 5
                while True:
                    if process.poll() is not None:
                        raise ValueError('VLESS client failed to start')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.2):
                            break
                    except OSError:
                        if time.monotonic() > deadline:
                            raise TimeoutError('VLESS client startup')
                        time.sleep(.1)
                # This request has exactly one VLESS outbound; there is no direct fallback.
                test = subprocess.run(['curl', '-sS', '--noproxy', '', '--socks5-hostname',
                    '127.0.0.1:' + str(port), '--connect-timeout', '8', '--max-time', '20',
                    '-o', os.devnull, '-w', '%{http_code}', 'https://api.cloudflareclient.com/v0a4005/reg'],
                    capture_output=True, text=True, timeout=23)
                if test.returncode or not re.fullmatch(r'[234]\d\d', test.stdout):
                    raise ValueError('Cloudflare API unavailable through VLESS')
                record = begin_egress(DATABASE, JOURNAL, port, owner_identity(), folder)
                # The watcher carries no link or API credentials in its environment.
                subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'watch'],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    start_new_session=True, env={'PATH': os.environ.get('PATH', '')})
                restart_panel()
                deadline = time.monotonic() + 30
                while True:
                    try:
                        verify_bridge(GENERATED, record['tag'], port)
                        break
                    except (OSError, ValueError, StopIteration):
                        if time.monotonic() > deadline:
                            raise TimeoutError('panel egress did not become ready')
                        time.sleep(.2)
                url = os.environ['XPAM_REG_PANEL_URL'] + '/panel/api/xray/warp/reg'
                parsed = urllib.parse.urlsplit(url)
                if parsed.hostname != '127.0.0.1' or parsed.scheme != 'https':
                    raise ValueError('registration API must be local HTTPS')
                data = urllib.parse.urlencode({'privateKey': os.environ['XPAM_WARP_PRIVATE_KEY'],
                    'publicKey': os.environ['XPAM_WARP_PUBLIC_KEY']}).encode()
                request = urllib.request.Request(url, data=data, headers={
                    'Authorization': 'Bearer ' + os.environ['XPAM_REG_API_TOKEN'],
                    'Content-Type': 'application/x-www-form-urlencoded'})
                class NoRedirect(urllib.request.HTTPRedirectHandler):
                    def redirect_request(self, *args, **kwargs):
                        return None
                opener = urllib.request.build_opener(NoRedirect(), urllib.request.ProxyHandler({}),
                    urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
                with opener.open(request, timeout=30) as response:
                    result = json.loads(response.read(1024 * 1024))
                if result.get('success') is not True:
                    raise ValueError('panel registration through VLESS failed')
                envelope = result['obj']
                if isinstance(envelope, str):
                    envelope = json.loads(envelope)
                account, _ = validated_warp_registration(envelope)
                if account['private_key'] != os.environ['XPAM_WARP_PRIVATE_KEY']:
                    raise ValueError('registration key mismatch')
                write_private(output, envelope)
            finally:
                # Keep the VLESS client alive until the panel's original route is restored.
                try:
                    if record is None and JOURNAL.exists():
                        candidate = json.loads(JOURNAL.read_text())
                        if candidate.get('owner') == owner_identity():
                            record = candidate
                    if record:
                        restore_egress(DATABASE, record)
                        restart_panel()
                        wait_egress_removed(record['tag'])
                        JOURNAL.unlink(missing_ok=True)
                finally:
                    if process and process.poll() is None:
                        os.killpg(process.pid, signal.SIGTERM)
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait(timeout=5)


def main():
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda signum, frame: sys.exit(128 + signum))
    if sys.argv[1] == 'recover':
        recover(restart=False)  # Boot unit runs before x-ui.
    elif sys.argv[1] == 'watch':
        deadline = time.monotonic() + 240
        while JOURNAL.exists():
            try:
                record = json.loads(JOURNAL.read_text())
            except FileNotFoundError:
                break
            if not owner_alive(record.get('owner')):
                recover()
                break
            if time.monotonic() > deadline:
                try:
                    os.kill(record['owner']['pid'], signal.SIGTERM)
                except ProcessLookupError:
                    continue
            time.sleep(.5)
    elif sys.argv[1] == 'register':
        register_via_vless(sys.stdin.read(16385).strip(), Path(sys.argv[2]))
    else:
        raise ValueError('unknown registration operation')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Exceptions from URL parsers, the core and HTTP can contain credentials.
        print('ERROR: временная регистрация WARP не завершилась (' + type(error).__name__ + ')', file=sys.stderr)
        sys.exit(1)
