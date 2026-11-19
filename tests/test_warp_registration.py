"""WARP registration egress uses temporary fixtures, never operator credentials."""

from contextlib import closing
import copy
import json
from pathlib import Path
import sqlite3
import os
import select
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/lib'))
import xpam_warp_registration as registration
import test_compatibility as compatibility
shell_function = compatibility.shell_function


@unittest.skipUnless(os.name == 'posix', 'interactive shell fixture requires a PTY')
class RegistrationMenuTests(unittest.TestCase):
    def test_dh_off_and_existing_or_custom_link_with_dh_on(self):
        import pty
        import time
        for mode, choice in [('off', None), ('all', '1'), ('vless-only', '2')]:
            with self.subTest(mode=mode, choice=choice), tempfile.TemporaryDirectory() as folder:
                root=Path(folder)
                saved='vless://'+str(uuid.uuid4())+'@saved.example.com:443?security=tls'
                custom='vless://'+str(uuid.uuid4())+'@custom.example.com:443?security=tls'
                (root/'dh.link').write_text(saved)
                (root/'error').write_text('Post "https://api.cloudflareclient.com/v0a4005/reg": TLS handshake timeout')
                for name,content in [('x-ui','echo 3.11.0'),('wait',':')]:
                    file=root/name;file.write_text('#!/usr/bin/env bash\n'+content+'\n');file.chmod(0o755)
                function=shell_function('scripts/lib/xpam-xui.sh','warp_offer_vless_registration')
                function=function.replace('/usr/local/x-ui/x-ui',str(root/'x-ui')).replace('/usr/local/sbin/wait-for-local-port.sh',str(root/'wait'))
                code='''#!/usr/bin/env bash
set -euo pipefail
KIT_DIR="KIT"
XUI_PANEL_PORT=62111
warn(){ echo "$*"; }; say(){ echo "$*"; }; ok(){ echo "$*"; }
confirm(){ return 0; }
dh_detect_mode(){ echo MODE; }
dh_exit_link_file(){ echo "FOLDER/dh.link"; }
xui_api_token(){ echo fixture-token; }
xpam_xui_panel_base_url(){ echo https://127.0.0.1:62111/validation; }
wait_for_xray_vless(){ :; }
xpam_warp_write_recovery_unit(){ :; }
python3(){
 if [[ "${1:-}" == *xpam_warp_registration.py ]]; then
  cat > "FOLDER/captured"
  printf '{}' > "$3"
 else
  command python3 "$@"
 fi
}
'''.replace('"KIT"','"'+str(ROOT)+'"').replace('MODE',mode).replace('FOLDER',str(root))+function+'\nwarp_offer_vless_registration "'+str(root/'output')+'" "'+str(root/'error')+'"\n'
                file=root/'menu.sh';file.write_text(code)
                master,slave=pty.openpty()
                process=subprocess.Popen(['bash',str(file)],stdin=slave,stdout=slave,stderr=slave,close_fds=True)
                os.close(slave)
                output=b'';sent_choice=False;sent_link=False
                deadline=time.monotonic()+12
                try:
                    while time.monotonic()<deadline:
                        readable,_,_=select.select([master],[],[],.1)
                        if readable:
                            try:chunk=os.read(master,65536)
                            except OSError:break
                            if not chunk:break
                            output+=chunk
                        if choice and not sent_choice and 'Выберите пункт'.encode() in output:
                            os.write(master,(choice+'\n').encode());sent_choice=True
                        if (choice is None or choice=='2') and not sent_link and 'Введите VLESS-ссылку'.encode() in output:
                            os.write(master,(custom+'\n').encode());sent_link=True
                        if process.poll() is not None and not readable:break
                    if process.poll() is None:process.kill()
                    process.wait(timeout=3)
                finally:os.close(master)
                self.assertEqual(process.returncode,0,output.decode(errors='replace'))
                self.assertNotIn(saved.encode(),output)
                self.assertNotIn(custom.encode(),output)
                self.assertEqual((root/'captured').read_text(),saved if choice=='1' else custom)
                self.assertEqual((root/'dh.link').read_text(),saved)
                if mode=='off':self.assertNotIn('Использовать существующую ссылку'.encode(),output)


class RegistrationTests(unittest.TestCase):
    def test_registration_cache_is_reusable_without_duplicate_credentials(self):
        with tempfile.TemporaryDirectory() as folder:
            database=Path(folder)/'db'
            self.database(database)
            envelope=compatibility.WarpPolicyTests().registration()
            account,_=registration.validated_warp_registration(envelope)
            with closing(sqlite3.connect(database)) as connection:
                connection.execute("INSERT INTO settings(key,value) VALUES('warp',?)",(json.dumps(account),))
                connection.commit()
            registration.cache_registration(database,envelope)
            cached=registration.cached_registration(database)
            self.assertEqual(cached['data'],account)
            registration.validated_warp_registration(cached)
            with closing(sqlite3.connect(database)) as connection:
                raw=connection.execute("SELECT value FROM settings WHERE key='xpamWarpRegistrationConfig'").fetchone()[0]
                self.assertNotIn('private_key',raw)
                self.assertNotIn('access_token',raw)
                account['device_id']='rotated'
                connection.execute("UPDATE settings SET value=? WHERE key='warp'",(json.dumps(account),))
                connection.commit()
            self.assertIsNone(registration.cached_registration(database))

    def test_boot_recovery_removes_route_and_temporary_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);database=root/'db';journal=root/'journal';runtime=root/'runtime'
            original=self.database(database,'operator-egress')
            credentials=runtime/'operation-test';credentials.mkdir(parents=True)
            (credentials/'client.json').write_text('<temporary-private-fixture>')
            registration.begin_egress(database,journal,12345,{'pid':-1},credentials)
            with patch.object(registration,'DATABASE',database),patch.object(registration,'JOURNAL',journal),\
                 patch.object(registration,'RUNTIME',runtime),patch.object(registration,'owner_alive',return_value=False):
                registration.recover(restart=False,locked=True)
            self.assertFalse(journal.exists())
            self.assertFalse(credentials.exists())
            with closing(sqlite3.connect(database)) as connection:
                current=json.loads(connection.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()[0])
                self.assertEqual(current,original)
                self.assertEqual(connection.execute("SELECT value FROM settings WHERE key='panelOutbound'").fetchone(),('operator-egress',))

    def link(self, query='security=tls&type=tcp&encryption=none'):
        return 'vless://' + str(uuid.uuid4()) + '@exit.example.com:443?' + query

    def test_transports_and_security_are_preserved(self):
        for network in ('tcp', 'ws', 'grpc', 'xhttp'):
            with self.subTest(network=network):
                result = registration.parse_vless(self.link('security=tls&type=' + network + '&sni=exit.example.com&fp=firefox&path=%2Ftransport&serviceName=transport&alpn=h2'))
                self.assertEqual(result['streamSettings']['network'], network)
                self.assertEqual(result['streamSettings']['tlsSettings']['fingerprint'], 'firefox')
                self.assertNotIn('allowInsecure', result['streamSettings']['tlsSettings'])
        result = registration.parse_vless(self.link('security=reality&type=tcp&pbk=public&sid=00&fp=chrome'))
        self.assertEqual(result['streamSettings']['realitySettings']['shortId'], '00')

    def test_invalid_links_do_not_silently_change_transport(self):
        for link in ('', 'https://example.com', self.link('type=invalid'),
                     self.link('security=reality'), self.link('allowInsecure=1'),
                     self.link('encryption=unsupported'), self.link('type=tcp&type=ws')):
            with self.subTest(case=len(link)), self.assertRaises((ValueError, TypeError)):
                registration.parse_vless(link)

    def test_fallback_is_limited_to_cloudflare_access_failures(self):
        self.assertTrue(registration.registration_network_failure('Post "https://api.cloudflareclient.com/v0a4005/reg": net/http: TLS handshake timeout'))
        self.assertTrue(registration.registration_network_failure('warp api POST /reg returned status 403'))
        for message in ('HTTP error 401', 'invalid private key', 'http://127.0.0.1 timeout',
                        'WARP tunnel or egress check failed', 'license invalid'):
            self.assertFalse(registration.registration_network_failure(message))

    def database(self, path, previous=None, script=False):
        config = {'outbounds': [{'tag': 'direct', 'protocol': 'freedom'},
                               {'tag': 'xpam-dh-exit', 'protocol': 'vless', 'settings': {'id': '<redacted>'}}],
                  'routing': {'rules': [{'inboundTag': ['entry'], 'outboundTag': 'xpam-dh-exit'}]}}
        if script:
            config['routing']['script'] = '<operator-script>'
        with closing(sqlite3.connect(path)) as connection:
            # Real 3x-ui uses an indexed key, not a UNIQUE key.
            connection.execute('CREATE TABLE settings(id INTEGER PRIMARY KEY,key TEXT,value TEXT)')
            connection.execute('CREATE INDEX idx_settings_key ON settings(key)')
            connection.execute('INSERT INTO settings(key,value) VALUES(?,?)', ('xrayTemplateConfig', json.dumps(config)))
            if previous is not None:
                connection.execute('INSERT INTO settings(key,value) VALUES(?,?)', ('panelOutbound', previous))
            connection.commit()
        return config

    def test_restore_preserves_doublehop_clients_and_concurrent_config(self):
        for previous in (None, '', 'operator-egress'):
            with self.subTest(previous=previous), tempfile.TemporaryDirectory() as folder:
                database, journal = Path(folder)/'db', Path(folder)/'journal'
                original = self.database(database, previous)
                record = registration.begin_egress(database, journal, 12345)
                self.assertNotIn('exit.example.com', journal.read_text())
                with closing(sqlite3.connect(database)) as connection:
                    config = json.loads(connection.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()[0])
                    self.assertEqual(config['outbounds'][-1]['protocol'], 'socks')
                    self.assertEqual(config['routing'], original['routing'])
                    config['operator-change'] = True
                    connection.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (json.dumps(config),))
                    connection.commit()
                registration.restore_egress(database, record)
                with closing(sqlite3.connect(database)) as connection:
                    config = json.loads(connection.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()[0])
                    panel = connection.execute("SELECT value FROM settings WHERE key='panelOutbound'").fetchone()
                self.assertTrue(config.pop('operator-change'))
                self.assertEqual(config, original)
                self.assertEqual(panel, None if previous is None else (previous,))
                # Recovery is idempotent.
                registration.restore_egress(database, record)

    def test_restore_does_not_overwrite_concurrent_panel_setting(self):
        with tempfile.TemporaryDirectory() as folder:
            database, journal = Path(folder)/'db', Path(folder)/'journal'
            self.database(database, 'original')
            record = registration.begin_egress(database, journal, 12345)
            with closing(sqlite3.connect(database)) as connection:
                connection.execute("UPDATE settings SET value='operator-new' WHERE key='panelOutbound'")
                connection.commit()
            registration.restore_egress(database, record)
            with closing(sqlite3.connect(database)) as connection:
                self.assertEqual(connection.execute("SELECT value FROM settings WHERE key='panelOutbound'").fetchone(), ('operator-new',))

    def test_script_refuses_mutation_before_journal(self):
        with tempfile.TemporaryDirectory() as folder:
            database, journal = Path(folder)/'db', Path(folder)/'journal'
            self.database(database, script=True)
            with self.assertRaises(ValueError):
                registration.begin_egress(database, journal, 12345)
            self.assertFalse(journal.exists())

    def test_bridge_must_exist_and_match_to_prevent_direct_fallback(self):
        config = {'outbounds': [{'protocol': 'socks', 'tag': 'temporary', 'settings': {'address': '127.0.0.1', 'port': 12345}}],
                  'inbounds': [{'tag': 'panel-egress', 'protocol': 'socks', 'listen': '127.0.0.1', 'port': 23456}],
                  'routing': {'rules': [{'inboundTag': ['panel-egress'], 'outboundTag': 'temporary'}]}}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'generated'
            path.write_text(json.dumps(config))
            with patch('socket.create_connection'):
                registration.verify_bridge(path, 'temporary', 12345)
            for field in ('inbounds', 'outbounds', 'routing'):
                candidate = copy.deepcopy(config);candidate.pop(field)
                path.write_text(json.dumps(candidate))
                with self.assertRaises((ValueError, StopIteration)):
                    registration.verify_bridge(path, 'temporary', 12345)


if __name__ == '__main__':
    unittest.main()
