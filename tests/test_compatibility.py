"""Regression tests use temporary fixtures, never the host's XPAM configuration."""

import copy
import base64
import json
from contextlib import closing
from contextlib import redirect_stdout
from io import StringIO
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/lib'))
from xpam_xray_compat import warp_policy, warp_policy_matches, reconcile_ocsp, client_is_unshared, validated_warp_registration, restore_warp_state


def bash_binary():
    if os.name == 'nt':
        git = shutil.which('git')
        if git:
            candidate = Path(git).parents[1] / 'bin/bash.exe'
            if candidate.exists():
                return str(candidate)
    return shutil.which('bash')


def shell_function(path, name):
    source = (ROOT / path).read_text(encoding='utf-8')
    return re.search(r'^' + name + r'\(\)\{.*?^\}', source, re.M | re.S).group()


class WarpPolicyTests(unittest.TestCase):
    def registration(self):
        return {'data': {'access_token': '<redacted>', 'device_id': '<redacted>',
                         'private_key': base64.b64encode(bytes(range(32))).decode()},
                'config': {'config': {'client_id': base64.b64encode(bytes([1,2,3])).decode(),
                                      'interface': {'addresses': {'v4': '172.16.0.2'}},
                                      'peers': [{'public_key': base64.b64encode(bytes(range(32))).decode(),
                                                 'endpoint': {'host': 'engage.cloudflareclient.com:2408'}}]}}}

    def test_complete_account_import_and_invalid_inputs(self):
        source = self.registration()
        account, settings = validated_warp_registration(source)
        self.assertEqual(account['access_token'], '<redacted>')
        self.assertEqual(settings['reserved'], [1,2,3])
        self.assertEqual(settings['address'], ['172.16.0.2/32'])
        for kind in ('missing-token', 'bad-key', 'bad-client-id', 'local-endpoint', 'wrong-host'):
            candidate = self.registration()
            if kind == 'missing-token':
                candidate['data'].pop('access_token')
            elif kind == 'bad-key':
                candidate['data']['private_key'] = '<redacted>'
            elif kind == 'bad-client-id':
                candidate['config']['config']['client_id'] = 'AA=='
            elif kind == 'local-endpoint':
                candidate['config']['config']['peers'][0]['endpoint']['host'] = '127.0.0.1:2408'
            else:
                candidate['config']['config']['peers'][0]['endpoint']['host'] = 'example.com:2408'
            with self.subTest(kind=kind), self.assertRaises((ValueError,KeyError)):
                validated_warp_registration(candidate)

    def test_old_and_new_core_policy_preserves_secrets_and_extensions(self):
        for version in [(26, 9, 9), (26, 9, 30), (26, 11, 9)]:
            with self.subTest(version=version):
                outbound = {'tag': 'warp', 'protocol': 'wireguard',
                            'settings': {'secretKey': '<redacted>', 'reserved': [1, 2, 3],
                                         'noKernelTun': True, 'workers': 2},
                            'streamSettings': {'sockopt': {'mark': 123}},
                            'extension': {'preserve': True}}
                warp_policy(outbound, version)
                self.assertTrue(warp_policy_matches(outbound, version))
                self.assertEqual(outbound['settings']['secretKey'], '<redacted>')
                self.assertEqual(outbound['settings']['reserved'], [1, 2, 3])
                self.assertTrue(outbound['settings']['noKernelTun'])
                self.assertEqual(outbound['streamSettings']['sockopt']['mark'], 123)
                self.assertTrue(outbound['extension']['preserve'])
                self.assertNotIn('workers', outbound['settings'])
                normalized = copy.deepcopy(outbound)
                warp_policy(outbound, version)
                self.assertEqual(outbound, normalized)

    def test_upgrade_and_downgrade(self):
        outbound = {'settings': {'domainStrategy': 'ForceIPv4'}}
        warp_policy(outbound, (26, 11, 9))
        self.assertNotIn('domainStrategy', outbound['settings'])
        self.assertTrue(warp_policy_matches(outbound, (26, 11, 9)))
        warp_policy(outbound, (26, 9, 9))
        self.assertTrue(warp_policy_matches(outbound, (26, 9, 9)))


class DatabaseBackupTests(unittest.TestCase):
    def test_warp_import_probes_before_writing_account_or_outbound(self):
        source=(ROOT/'scripts/xpam-core.sh').read_text(encoding='utf-8')
        code=source.split("<<'PY_XPAM_WARP_INJECT'\n",1)[1].split('\nPY_XPAM_WARP_INJECT',1)[0]
        registration=WarpPolicyTests().registration()
        for healthy in (False,True):
            with self.subTest(healthy=healthy),tempfile.TemporaryDirectory() as folder:
                root=Path(folder);database=root/'x-ui.db';profile=root/'registration.json'
                profile.write_text(json.dumps(registration))
                original={'outbounds':[{'tag':'direct','protocol':'freedom'},
                    {'tag':'warp','protocol':'wireguard','settings':{'noKernelTun':True},'extension':True}],
                    'routing':{'rules':[]}}
                with closing(sqlite3.connect(database)) as connection:
                    connection.execute('CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT)')
                    connection.execute('INSERT INTO settings VALUES(?,?)',('xrayTemplateConfig',json.dumps(original)))
                    connection.commit()
                env={'XPAM_XUI_DB':str(database),'XPAM_WARP_REG_FILE':str(profile),
                     'XPAM_COMPAT_PATH':str(ROOT/'scripts/lib'),'XPAM_WARP_STORE_ACCOUNT':'yes'}
                with patch.dict(os.environ,env),patch('xpam_xray_compat.core_version',return_value=(26,11,9)),\
                     patch('xpam_xray_compat.probe_warp',side_effect=None if healthy else ValueError('fixture unreachable')) as probe,\
                     redirect_stdout(StringIO()):
                    if healthy:
                        exec(compile(code,'warp-import','exec'),{})
                    else:
                        with self.assertRaises(SystemExit):
                            exec(compile(code,'warp-import','exec'),{})
                    probe.assert_called_once()
                with closing(sqlite3.connect(database)) as connection:
                    account=connection.execute("SELECT value FROM settings WHERE key='warp'").fetchone()
                    current=json.loads(connection.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()[0])
                if healthy:
                    self.assertEqual(json.loads(account[0])['private_key'],registration['data']['private_key'])
                    self.assertTrue(current['outbounds'][1]['settings']['noKernelTun'])
                    self.assertTrue(current['outbounds'][1]['extension'])
                    self.assertEqual(current['outbounds'][1]['targetStrategy'],'ForceIPv4')
                else:
                    self.assertIsNone(account)
                    self.assertEqual(current,original)

    def test_warp_rollback_preserves_other_changes_and_rule_order(self):
        with tempfile.TemporaryDirectory() as folder:
            saved, live = Path(folder) / 'saved.db', Path(folder) / 'live.db'
            old = {'outbounds': [{'tag':'direct'}, {'tag':'warp','settings':{'secretKey':'<redacted>'}}],
                   'routing': {'rules': [{'outboundTag':'warp','domain':['first']},
                                         {'outboundTag':'blocked'},
                                         {'outboundTag':'warp','domain':['second']}]}}
            for database in (saved,live):
                with closing(sqlite3.connect(database)) as connection:
                    connection.execute('CREATE TABLE settings(key TEXT,value TEXT)')
                    connection.execute('CREATE TABLE inbounds(id INTEGER,protocol TEXT,settings TEXT,sniffing TEXT)')
                    connection.execute('CREATE TABLE counters(value INTEGER)')
                    connection.executemany('INSERT INTO settings VALUES (?,?)', [
                        ('warp','old-account'), ('xrayTemplateConfig',json.dumps(old))])
                    connection.execute('INSERT INTO inbounds VALUES (1,?,?,?)', ('vless','same-client','original-sniffing'))
                    connection.execute('INSERT INTO counters VALUES (1)')
                    connection.commit()
            current=copy.deepcopy(old)
            current['outbounds'][1]['settings']['secretKey']='changed'
            current['outbounds'].append({'tag':'operator-added'})
            current['routing']['rules']=[{'outboundTag':'blocked'}, {'outboundTag':'warp','domain':['changed']}]
            with closing(sqlite3.connect(live)) as connection:
                connection.execute("UPDATE settings SET value='new-account' WHERE key='warp'")
                connection.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(current),))
                connection.execute("UPDATE inbounds SET sniffing='changed'")
                connection.execute('UPDATE counters SET value=42')
                connection.commit()
            restore_warp_state(saved,live)
            with closing(sqlite3.connect(live)) as connection:
                restored=json.loads(connection.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()[0])
                self.assertEqual(restored['routing']['rules'],old['routing']['rules'])
                self.assertEqual(restored['outbounds'][1],old['outbounds'][1])
                self.assertEqual(restored['outbounds'][-1]['tag'],'operator-added')
                self.assertEqual(connection.execute('SELECT value FROM counters').fetchone()[0],42)
                self.assertEqual(connection.execute('SELECT sniffing FROM inbounds').fetchone()[0],'original-sniffing')
                self.assertEqual(connection.execute("SELECT value FROM settings WHERE key='warp'").fetchone()[0],'old-account')

    def test_shared_client_survives_inbound_cleanup(self):
        with tempfile.TemporaryDirectory() as folder:
            database = Path(folder) / 'panel.db'
            email = "operator's client"
            with closing(sqlite3.connect(database)) as connection:
                connection.execute('CREATE TABLE clients(id INTEGER,email TEXT)')
                connection.execute('CREATE TABLE client_inbounds(client_id INTEGER,inbound_id INTEGER)')
                connection.execute('INSERT INTO clients VALUES (?,?)', (1,email))
                connection.executemany('INSERT INTO client_inbounds VALUES (?,?)', [(1,10),(1,20)])
                connection.commit()
                self.assertFalse(client_is_unshared(database,email,10))
                connection.execute('DELETE FROM client_inbounds WHERE inbound_id=20')
                connection.commit()
                self.assertTrue(client_is_unshared(database,email,10))
                self.assertFalse(client_is_unshared(database,email,0))
                connection.execute('DELETE FROM client_inbounds')
                connection.commit()
                self.assertTrue(client_is_unshared(database,email,0))
                self.assertFalse(client_is_unshared(database,'missing',0))

    def test_ocsp_migration_is_scoped_idempotent_and_backed_up(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            database = folder / 'panel.db'
            raw = json.dumps({'tlsSettings': {'certificates': [
                {'certificateFile': 'no-ocsp.pem', 'keyFile': '<redacted>', 'ocspStapling': 3600},
                {'certificateFile': 'with-ocsp.pem', 'ocspStapling': 3600},
            ]}, 'extension': 'preserve'})
            with closing(sqlite3.connect(database)) as connection:
                connection.execute('CREATE TABLE inbounds(id INTEGER,protocol TEXT,listen TEXT,port INTEGER,stream_settings TEXT)')
                connection.executemany('INSERT INTO inbounds VALUES (?,?,?,?,?)', [
                    (1, 'vless', '127.0.0.1', 1443, raw),
                    (2, 'vless', '127.0.0.1', 2443, raw),
                ])
                connection.commit()
            probe = lambda path: path == 'with-ocsp.pem'
            self.assertTrue(reconcile_ocsp(database, 1443, folder / 'backups', probe))
            self.assertFalse(reconcile_ocsp(database, 1443, folder / 'backups', probe))
            with closing(sqlite3.connect(database)) as connection:
                changed, untouched = connection.execute('SELECT stream_settings FROM inbounds ORDER BY id').fetchall()
            changed = json.loads(changed[0])
            self.assertNotIn('ocspStapling', changed['tlsSettings']['certificates'][0])
            self.assertEqual(changed['tlsSettings']['certificates'][0]['keyFile'], '<redacted>')
            self.assertEqual(changed['tlsSettings']['certificates'][1]['ocspStapling'], 3600)
            self.assertEqual(changed['extension'], 'preserve')
            self.assertEqual(untouched[0], raw)
            backups = list((folder / 'backups').glob('x-ui.db.*'))
            self.assertEqual(len(backups), 1)
            with closing(sqlite3.connect(backups[0])) as saved:
                self.assertEqual(saved.execute('SELECT stream_settings FROM inbounds WHERE id=1').fetchone()[0], raw)

    def test_backup_contains_committed_wal_and_failure_preserves_destination(self):
        source = (ROOT / 'scripts/xpam-core.sh').read_text(encoding='utf-8')
        code = source.split("<<'PY_XPAM_DB_BACKUP'\n", 1)[1].split('\nPY_XPAM_DB_BACKUP', 1)[0]
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            live, backup = folder / 'live.db', folder / 'backup.db'
            connection = sqlite3.connect(live)
            try:
                connection.execute('PRAGMA journal_mode=WAL')
                connection.execute('CREATE TABLE settings (value TEXT)')
                connection.execute('INSERT INTO settings VALUES (?)', ('committed-in-wal',))
                connection.commit()
                result = subprocess.run([sys.executable, '-', str(live), str(backup)],
                                        input=code, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                with closing(sqlite3.connect(backup)) as saved:
                    self.assertEqual(saved.execute('SELECT value FROM settings').fetchone(),
                                     ('committed-in-wal',))
                old_bytes = backup.read_bytes()
                result = subprocess.run([sys.executable, '-', str(folder / 'missing.db'), str(backup)],
                                        input=code, text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(backup.read_bytes(), old_bytes)
                self.assertFalse(list(folder.glob('.xpam-db-*')))
            finally:
                connection.close()


@unittest.skipUnless(bash_binary(), 'bash required')
class ShellSafetyTests(unittest.TestCase):
    def run_shell(self, code):
        return subprocess.run([bash_binary(), '-s'], input=code,
                              text=True, capture_output=True)

    def test_spare_switch_failure_restores_previous_transport(self):
        function = shell_function('scripts/lib/xpam-alt-transport.sh', 'alt_transport_enable')
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ('etc/xpam-script', 'etc/x-ui', 'etc/nginx/sites-available',
                         'etc/nginx/sites-enabled', 'usr/local/sbin'):
                (root / name).mkdir(parents=True, exist_ok=True)
            original = {'etc/xpam-script/config.env': 'original-config',
                        'etc/x-ui/x-ui.db': 'original-database',
                        'etc/nginx/sites-available/xpam-alt.conf': 'original-front'}
            for name, content in original.items():
                (root/name).write_text(content)
            prefix = root.as_posix()
            function = re.sub(r'(?<![A-Za-z0-9_$}])/(etc|usr|opt|var|root)(?=/)',
                              lambda match: prefix + match.group(), function)
            waiter=root/'usr/local/sbin/wait-for-local-port.sh'
            waiter.write_bytes(b'#!/usr/bin/env bash\nexit 0\n');waiter.chmod(0o755)
            code='''SERVER_PREFIX=fixture
CONFIG_FILE="ROOT/etc/xpam-script/config.env"
XUI_PANEL_PORT=57827
load_config(){ :; }
warn(){ :; }
systemctl(){ :; }
nginx(){ :; }; haproxy(){ :; }; wait_for_xray_vless(){ :; }
prune_keep_latest(){ :; }
xui_db_safe_copy(){ cp "ROOT/etc/x-ui/x-ui.db" "$1"; }
alt_transport_enable_apply(){
  printf broken > "ROOT/etc/xpam-script/config.env"
  printf broken > "ROOT/etc/x-ui/x-ui.db"
  printf broken > "ROOT/etc/nginx/sites-available/xpam-alt.conf"
  printf newly-created > "ROOT/etc/nginx/sites-enabled/xpam-alt.conf"
  exit 9
}
'''.replace('ROOT',prefix)+function+'\nalt_transport_enable grpc\n'
            result=self.run_shell(code)
            self.assertEqual(result.returncode,9,result.stderr)
            for name,content in original.items():
                self.assertEqual((root/name).read_text(),content)
            self.assertFalse((root/'etc/nginx/sites-enabled/xpam-alt.conf').exists())

    def test_health_failure_is_not_success(self):
        function = shell_function('scripts/lib/xpam-maintenance.sh', 'run_health_quiet')
        with tempfile.TemporaryDirectory() as folder:
            prefix = Path(folder).as_posix()
            executable = Path(folder) / 'fixture-health'
            executable.write_text('#!/usr/bin/env bash\nexit 7\n', encoding='utf-8')
            executable.chmod(0o755)
            function = function.replace('/usr/local/sbin/', prefix + '/')
            function = function.replace('/var/log/xpam-script', prefix + '/logs')
            result = self.run_shell('SERVER_PREFIX=fixture\n'
                                    'prune_keep_latest(){ :; }; ok(){ :; }; warn(){ :; }; fail(){ exit 99; }\n'
                                    + function + '\nrun_health_quiet\nexit $?\n')
            self.assertEqual(result.returncode, 7, result.stderr)

    def test_update_snapshot_and_rollback_restore_files_and_database(self):
        names = ('xpam_update_snapshot_create', 'xpam_update_restore_path', 'xpam_update_rollback')
        functions = '\n'.join(shell_function('scripts/lib/xpam-update.sh', name) for name in names)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ('etc/xpam-script','etc/x-ui','opt/xpam-script','usr/local/sbin'):
                (root / name).mkdir(parents=True,exist_ok=True)
            waiter=root/'usr/local/sbin/wait-for-local-port.sh'
            waiter.write_bytes(b'#!/usr/bin/env bash\nexit 0\n');waiter.chmod(0o755)
            (root / 'etc/hosts').write_text('original-hosts')
            (root / 'opt/xpam-script/marker').write_text('original-kit')
            (root / 'etc/xpam-script/config.env').write_text('original-config')
            with closing(sqlite3.connect(root / 'etc/x-ui/x-ui.db')) as connection:
                connection.execute('CREATE TABLE fixture(value INTEGER)')
                connection.execute('INSERT INTO fixture VALUES (1)')
                connection.commit()
            prefix=root.as_posix()
            functions=re.sub(r'(?<![A-Za-z0-9_$}])/(etc|usr|opt|var|root)(?=/)',
                             lambda match: prefix + match.group(),functions)
            script='''set -e
SERVER_PREFIX=fixture
XUI_PANEL_PORT=57827
CONFIG_DIR="ROOT/etc/xpam-script"
RUNTIME_KIT_DIR="ROOT/opt/xpam-script"
XPAM_UPDATE_WORKDIR="ROOT/work"
load_config(){ :; }
warn(){ :; }
xpam_update_log(){ :; }
xpam_update_link_hashes_capture(){ mkdir -p "$2"; }
xpam_update_dh_mode_capture(){ :; }
xui_db_safe_copy(){ cp "ROOT/etc/x-ui/x-ui.db" "$1"; }
systemctl(){ case "$1" in is-active) echo active;; is-enabled) echo disabled; return 1;; esac; }
wait_for_xray_vless(){ :; }
'''.replace('ROOT',prefix)+functions+'''
xpam_update_snapshot_create
printf changed > "ROOT/etc/hosts"
printf changed > "ROOT/etc/xpam-script/config.env"
printf changed > "ROOT/opt/xpam-script/marker"
printf broken > "ROOT/etc/x-ui/x-ui.db"
mkdir -p "ROOT/usr/bin"
printf newly-created > "ROOT/usr/bin/x-ui"
xpam_update_rollback
'''.replace('ROOT',prefix)
            result=self.run_shell(script)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((root/'etc/hosts').read_text(),'original-hosts')
            self.assertEqual((root/'etc/xpam-script/config.env').read_text(),'original-config')
            self.assertEqual((root/'opt/xpam-script/marker').read_text(),'original-kit')
            self.assertFalse((root/'usr/bin/x-ui').exists())
            with closing(sqlite3.connect(root/'etc/x-ui/x-ui.db')) as connection:
                self.assertEqual(connection.execute('SELECT value FROM fixture').fetchone()[0],1)

    def test_link_hashes_include_second_link_and_ignore_order(self):
        function = shell_function('scripts/lib/xpam-update.sh', 'xpam_update_link_hashes_capture')
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            function = function.replace('/usr/local/sbin/', folder.as_posix() + '/')
            fixture = folder / 'fixture-links'
            fixture.write_text('#!/usr/bin/env bash\ncat "' + (folder / 'links').as_posix() + '"\n', encoding='utf-8')
            fixture.chmod(0o755)
            hashes = []
            for links in [('first', 'second'), ('second', 'first'), ('first', 'changed')]:
                # Synthetic identifiers are temporary data, not connection credentials.
                (folder / 'links').write_text(''.join('vless:' + '//' + x + '\n' for x in links), encoding='utf-8')
                result = self.run_shell(function + '\nxpam_update_link_hashes_capture fixture "'
                                        + (folder / 'result').as_posix() + '"\n')
                self.assertEqual(result.returncode, 0, result.stderr)
                hashes.append((folder / 'result/link-hashes.env').read_text())
            self.assertEqual(hashes[0], hashes[1])
            self.assertNotEqual(hashes[0], hashes[2])
            fixture.write_text('#!/usr/bin/env bash\nexit 1\n', encoding='utf-8')
            result = self.run_shell(function + '\nxpam_update_link_hashes_capture fixture "'
                                    + (folder / 'result').as_posix() + '"\n')
            self.assertNotEqual(result.returncode, 0)

    def test_postcheck_accepts_old_failure_but_rejects_crashed_or_empty_health(self):
        functions='\n'.join(shell_function('scripts/lib/xpam-update.sh',name) for name in
                            ('xpam_update_health_failures','xpam_update_postcheck'))
        for mode,expected in [('success',0),('existing',0),('new',1),('crashed',1),('empty',1)]:
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as folder:
                root=Path(folder)
                directory=root/'usr/local/sbin';directory.mkdir(parents=True)
                for name in ('fixture-xpam','fixture-links','fixture-repair','xpam-maint-common.sh'):
                    file=directory/name;file.write_text('#!/usr/bin/env bash\n:\n');file.chmod(0o755)
                health=directory/'fixture-health'
                health.write_text('''#!/usr/bin/env bash
case "MODE" in
empty) exit 0;;
crashed) echo '===== RESULT ====='; exit 7;;
existing) echo 'FAIL: existing'; echo '===== RESULT ====='; exit 1;;
new) echo 'FAIL: new'; echo '===== RESULT ====='; exit 1;;
success) echo '===== RESULT ====='; exit 0;;
esac
'''.replace('MODE',mode));health.chmod(0o755)
                (root/'work/pre-state').mkdir(parents=True)
                # The updater runs on Linux; keep its line-oriented snapshots LF
                # even when this regression harness is run on Windows.
                (root/'work/pre-state/health-failures.txt').write_bytes(b'FAIL: existing\n')
                (root/'work/pre-state/doublehop-mode.txt').write_bytes(b'off\n')
                prefix=root.as_posix()
                remapped=functions.replace('/usr/local/sbin/',prefix+'/usr/local/sbin/')
                code='''SERVER_PREFIX=fixture
XPAM_UPDATE_WORKDIR="ROOT/work"
load_config(){ :; }
xpam_update_log(){ :; }
xpam_update_compare_link_hashes(){ return 0; }
dh_detect_mode(){ echo off; }
'''.replace('ROOT',prefix)+remapped+'\nif xpam_update_postcheck; then exit 0; else exit $?; fi\n'
                result=self.run_shell(code)
                self.assertEqual(result.returncode,expected,result.stderr)


class PortSummaryTests(unittest.TestCase):
    def check_output(self, rules):
        source = (ROOT / 'templates/xpam-maint-common.sh.tpl').read_text(encoding='utf-8')
        code = source.split("<<'PY_PORT'\n", 1)[1].split('\nPY_PORT', 1)[0]
        tcp_ports = [22, 80, 443, 1443, 8080, 9443, 47827, 57827]
        tcp = '\n'.join('LISTEN 0 128 ' + ('0.0.0.0' if p in (22,80,443) else '127.0.0.1')
                        + ':' + str(p) + ' 0.0.0.0:*' for p in tcp_ports)
        udp = '\n'.join('UNCONN 0 0 0.0.0.0:' + str(p)
                        + ' 0.0.0.0:* users:(("xray-linux-amd6",pid=1,fd=4))' for p in range(20000,20250))
        def command(args, **kwargs):
            if args[0] == 'ufw':
                return 'Status: active\nDefault: deny (incoming), allow (outgoing)\n' + rules
            if '-6' in args:
                return ''
            if '-lnup' in args:
                return udp
            if '-lntup' in args:
                return tcp + '\n' + udp
            return tcp
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder) / 'config.env'
            config.write_text('SSH_PUBLIC_PORT=22\nHTTP_PUBLIC_PORT=80\nXRAY_PUBLIC_PORT=443\n'
                              'XRAY_LOCAL_PORT=1443\nSITE_BACKEND_PORT=8080\nSYNC_BACKEND_PORT=9443\n'
                              'MTPROTO_PORT=47827\nXUI_PANEL_PORT=57827\nMTPROTO_BACKEND=fixture\n')
            output = StringIO()
            with patch('subprocess.check_output', side_effect=command), patch.object(sys, 'argv', ['test', str(config)]), redirect_stdout(output):
                exec(compile(code, 'port-exposure-check', 'exec'), {})
            return output.getvalue()

    def test_many_closed_udp_sockets_have_compact_summary(self):
        output = self.check_output('22/tcp ALLOW IN Anywhere\n')
        self.assertIn('250 udp-сокетов xray', output)
        self.assertIn('OK: 250 Xray UDP socket(s)', output)
        self.assertLess(len(output.splitlines()), 45)
        self.assertNotIn('WARNING:', output)

    def test_udp_range_or_protocol_agnostic_rule_still_warns(self):
        for rule in ('20000:20249/udp ALLOW IN Anywhere\n', '20000 ALLOW IN Anywhere\n', 'Anywhere ALLOW IN Anywhere\n'):
            with self.subTest(rule=rule):
                output = self.check_output(rule)
                self.assertIn('WARNING: Xray UDP socket', output)


if __name__ == '__main__':
    unittest.main()
