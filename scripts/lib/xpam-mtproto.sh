#!/usr/bin/env bash
# XPAM Script module. This file is sourced by scripts/xpam-core.sh.
# Keep functions side-effect free at source time.

mtproto_harden_config(){
  uses_mtproto || return 0
  local cfg="/opt/mtprotoproxy/config.py" backup
  [[ -f "$cfg" ]] || { warn "MTProto config not found; skipping hardening: $cfg"; return 0; }
  mkdir -p /root/manual-backups
  backup="/root/manual-backups/mtproto-config.py.$(date +%Y%m%d-%H%M%S).pre-hardening"
  cp -a "$cfg" "$backup" 2>/dev/null || warn "Could not backup MTProto config before hardening"
  chmod 600 "$backup" 2>/dev/null || true

  XPAM_MTPROTO_PORT="$MTPROTO_PORT" \
  XPAM_SYNC_DOMAIN="$SYNC_DOMAIN" \
  XPAM_SYNC_BACKEND_PORT="$SYNC_BACKEND_PORT" \
  python3 <<'PY_MTPROTO_HARDEN'
import importlib.util, os, pathlib, re, sys
path=pathlib.Path('/opt/mtprotoproxy/config.py')
expected_port=int(os.environ['XPAM_MTPROTO_PORT'])
expected_domain=os.environ['XPAM_SYNC_DOMAIN']
expected_mask_port=int(os.environ['XPAM_SYNC_BACKEND_PORT'])

spec=importlib.util.spec_from_file_location('mtproto_config', str(path))
cfg=importlib.util.module_from_spec(spec)
spec.loader.exec_module(cfg)
users=dict(getattr(cfg, 'USERS', {}))
if not users:
    print('ERROR: MTProto USERS is empty; refusing to harden config without users', file=sys.stderr)
    raise SystemExit(1)
for name, sec in users.items():
    if not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,32}', name):
        print('ERROR: bad MTProto user name in config', file=sys.stderr)
        raise SystemExit(1)
    if not isinstance(sec, str) or not re.fullmatch(r'[0-9a-fA-F]{32}', sec):
        print('ERROR: bad MTProto secret format in config', file=sys.stderr)
        raise SystemExit(1)

def py_dict(d):
    if not d:
        return '{  }'
    return '{ ' + ', '.join(f'{str(k)!r}: {v!r}' for k, v in d.items()) + ' }'

def replace_or_append(text, name, value):
    line=f'{name} = {value}'
    pattern=re.compile(rf'^{re.escape(name)}\s*=.*$', re.M)
    if pattern.search(text):
        return pattern.sub(line, text)
    return text.rstrip()+f'\n{line}\n'

text=path.read_text(encoding='utf-8')
text=replace_or_append(text, 'PORT', str(expected_port))
text=replace_or_append(text, 'USERS', py_dict(users))
text=replace_or_append(text, 'USER_MAX_TCP_CONNS', py_dict(dict(getattr(cfg, 'USER_MAX_TCP_CONNS', {}))))
if hasattr(cfg, 'USER_EXPIRATIONS'):
    text=replace_or_append(text, 'USER_EXPIRATIONS', py_dict(dict(getattr(cfg, 'USER_EXPIRATIONS', {}))))
if hasattr(cfg, 'USER_DATA_QUOTA'):
    text=replace_or_append(text, 'USER_DATA_QUOTA', py_dict(dict(getattr(cfg, 'USER_DATA_QUOTA', {}))))
text=replace_or_append(text, 'TLS_DOMAIN', repr(expected_domain))
text=replace_or_append(text, 'MODES', '{ "classic": False, "secure": False, "tls": True }')
text=replace_or_append(text, 'LISTEN_ADDR_IPV4', repr('127.0.0.1'))
text=replace_or_append(text, 'LISTEN_ADDR_IPV6', 'None')
text=replace_or_append(text, 'MASK', 'True')
text=replace_or_append(text, 'MASK_HOST', repr('127.0.0.1'))
text=replace_or_append(text, 'MASK_PORT', str(expected_mask_port))
text=replace_or_append(text, 'PREFER_IPV6', 'False')

path.write_text(text, encoding='utf-8')
path.chmod(0o600)
# Validate rewritten config without printing secrets.
spec=importlib.util.spec_from_file_location('mtproto_config_hardened', str(path))
new=importlib.util.module_from_spec(spec)
spec.loader.exec_module(new)
assert int(getattr(new, 'PORT')) == expected_port
assert getattr(new, 'TLS_DOMAIN') == expected_domain
assert getattr(new, 'MODES') == {'classic': False, 'secure': False, 'tls': True}
assert getattr(new, 'LISTEN_ADDR_IPV4') == '127.0.0.1'
assert getattr(new, 'LISTEN_ADDR_IPV6') in (None, '')
assert getattr(new, 'MASK') is True
assert getattr(new, 'MASK_HOST') == '127.0.0.1'
assert int(getattr(new, 'MASK_PORT')) == expected_mask_port
assert getattr(new, 'PREFER_IPV6') is False
assert isinstance(getattr(new, 'USERS'), dict) and getattr(new, 'USERS')
PY_MTPROTO_HARDEN
  chmod 600 "$cfg"
  ok "MTProto config hardening applied: MASK=True, PREFER_IPV6=False, users preserved"
}


install_mtproto(){
  uses_mtproto || return 0

  say "Подготовка MTProto proxy"
  mkdir -p /root/secure-notes
  chmod 700 /root/secure-notes

  local existing_ok="no" secret tag note backup_dir
  if [[ -f /opt/mtprotoproxy/config.py ]]; then
    if python3 - <<'PY_MTPROTO_VALIDATE' >/dev/null 2>&1
import importlib.util
p='/opt/mtprotoproxy/config.py'
spec=importlib.util.spec_from_file_location('mtproto_config', p)
mod=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
users=getattr(mod,'USERS',{})
assert isinstance(users, dict) and users
for k,v in users.items():
    assert isinstance(k,str) and k
    assert isinstance(v,str) and len(v)==32 and all(c in '0123456789abcdefABCDEF' for c in v)
PY_MTPROTO_VALIDATE
    then
      existing_ok="yes"
      ok "Найден существующий валидный MTProto config.py; USERS/secrets будут сохранены"
    else
      warn "Существующий /opt/mtprotoproxy/config.py не прошёл проверку; перед изменением будет создан backup"
    fi
  fi

  if [[ ! -x /opt/mtprotoproxy/mtprotoproxy.py ]]; then
    say "Установка Python mtprotoproxy из upstream repo"
    backup_dir="/root/manual-backups/mtprotoproxy-code-$(date +%Y%m%d-%H%M%S)"
    if [[ -d /opt/mtprotoproxy ]]; then
      mkdir -p "$backup_dir"
      cp -a /opt/mtprotoproxy "$backup_dir/" 2>/dev/null || true
      rm -rf /opt/mtprotoproxy
    fi
    git clone --depth 1 --branch "$MTPROTO_REPO_BRANCH" "$MTPROTO_REPO_URL" /opt/mtprotoproxy
    chmod 755 /opt/mtprotoproxy /opt/mtprotoproxy/mtprotoproxy.py
    rm -rf /opt/mtprotoproxy/.git /opt/mtprotoproxy/Dockerfile /opt/mtprotoproxy/docker-compose.yml || true
  else
    ok "MTProto upstream code already present: /opt/mtprotoproxy"
  fi

  if [[ "$existing_ok" != "yes" ]]; then
    [[ -f /opt/mtprotoproxy/config.py ]] && cp -a /opt/mtprotoproxy/config.py "/root/manual-backups/mtproto-config.py.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    secret="$(xxd -p -l 16 /dev/urandom)"
    tag="$(echo -n "$SYNC_DOMAIN" | xxd -p -c 256)"
    export MTPROTO_SECRET="$secret"
    export_vars
    render_template "$KIT_DIR/templates/mtprotoproxy-config.py.tpl" /opt/mtprotoproxy/config.py
    chmod 600 /opt/mtprotoproxy/config.py
    note="/root/secure-notes/${SERVER_PREFIX}-mtproto.txt"
    cat > "$note" <<EOF_MTPROTO_NOTE
MTProto proxy for XPAM Script
==================================================
Link: tg://proxy?server=${SYNC_DOMAIN}&port=443&secret=ee${secret}${tag}
EOF_MTPROTO_NOTE
    chmod 600 "$note"
  fi

  render_template "$KIT_DIR/templates/mtprotoproxy.service.tpl" /etc/systemd/system/mtprotoproxy.service
  mkdir -p /etc/systemd/system/mtprotoproxy.service.d

  cat > /etc/systemd/system/mtprotoproxy.service.d/logging.conf <<'EOF_MTPROTO_LOGGING'
[Service]
StandardOutput=null
StandardError=journal
EOF_MTPROTO_LOGGING

  cat > /etc/systemd/system/mtprotoproxy.service.d/override.conf <<EOF_MTPROTO_OVERRIDE
[Unit]
Wants=network-online.target nginx.service
After=network-online.target nginx.service

[Service]
ExecStartPre=
ExecStartPre=/usr/local/sbin/wait-for-local-port.sh 127.0.0.1 ${SYNC_BACKEND_PORT} 30 nginx-sync-backend
ExecStartPre=/bin/sleep 3
EOF_MTPROTO_OVERRIDE

  cat > /etc/systemd/system/mtprotoproxy.service.d/restart.conf <<'EOF_MTPROTO_RESTART'
[Service]
Restart=on-failure
RestartSec=5s
EOF_MTPROTO_RESTART

  mtproto_harden_config
  mtproto_python_update rewrite-notes >/dev/null 2>&1 || true
  systemctl daemon-reload
  systemctl enable mtprotoproxy
  systemctl restart mtprotoproxy
}


mtproto_require(){
  uses_mtproto || fail "MTProto не включён в текущем профиле сервера."
  [[ -f /opt/mtprotoproxy/config.py ]] || fail "MTProto config не найден: /opt/mtprotoproxy/config.py"
}


mtproto_valid_user_name(){
  [[ "${1:-}" =~ ^[A-Za-z0-9_-]{1,32}$ ]]
}


mtproto_backup(){
  local ts backup_dir
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_dir="/root/manual-backups/mtproto-users-${ts}"
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"
  cp -a /opt/mtprotoproxy/config.py "$backup_dir/config.py"
  cp -a /root/secure-notes/*mtproto* "$backup_dir/" 2>/dev/null || true
  prune_keep_latest /root/manual-backups 'mtproto-users-*' 4
  echo "$backup_dir"
}


mtproto_python_update(){
  local action="$1" user="${2:-}"
  XPAM_MTPROTO_ACTION="$action" XPAM_MTPROTO_USER="$user" XPAM_SYNC_DOMAIN="$SYNC_DOMAIN" XPAM_SERVER_PREFIX="$SERVER_PREFIX" python3 <<'PY_MTPROTO_USERS'
import importlib.util, os, pathlib, re, secrets, sys
from collections import OrderedDict

path=pathlib.Path('/opt/mtprotoproxy/config.py')
action=os.environ['XPAM_MTPROTO_ACTION']
user=os.environ.get('XPAM_MTPROTO_USER','')
domain=os.environ['XPAM_SYNC_DOMAIN']
prefix=os.environ['XPAM_SERVER_PREFIX']
notes=pathlib.Path('/root/secure-notes')
users_note=notes / f'{prefix}-mtproto-users.txt'
legacy_note=notes / f'{prefix}-mtproto.txt'

spec=importlib.util.spec_from_file_location('mtproto_config', str(path))
cfg=importlib.util.module_from_spec(spec)
spec.loader.exec_module(cfg)
users=OrderedDict((str(k), str(v)) for k,v in getattr(cfg,'USERS',{}).items())
limits=dict(getattr(cfg,'USER_MAX_TCP_CONNS',{}))
exp=dict(getattr(cfg,'USER_EXPIRATIONS',{}))
quota=dict(getattr(cfg,'USER_DATA_QUOTA',{}))

def fail(msg):
    print('ERROR:', msg, file=sys.stderr)
    sys.exit(1)

def validate_users():
    if not users:
        fail('USERS is empty; at least one MTProto user is required')
    for name, sec in users.items():
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,32}', name):
            fail(f'bad MTProto user name: {name}')
        if not re.fullmatch(r'[0-9a-fA-F]{32}', sec):
            fail(f'bad MTProto secret format for user {name}')

def py_dict(d):
    items=[]
    for k,v in d.items():
        items.append(f'{k!r}: {v!r}')
    return '{ ' + ', '.join(items) + ' }'

def replace_or_append(text, name, value):
    line=f'{name} = {value}'
    pattern=re.compile(rf'^{name}\s*=.*$', re.M)
    if pattern.search(text):
        return pattern.sub(line, text)
    return text.rstrip()+f'\n{line}\n'

def link_for(sec):
    return f'tg://proxy?server={domain}&port=443&secret=ee{sec}{domain.encode().hex()}'

def write_notes():
    notes.mkdir(mode=0o700, parents=True, exist_ok=True)
    body=['MTProto users for XPAM Script','==================================================','']
    for name, sec in users.items():
        body.append(f'User: {name}')
        body.append(f'Link: {link_for(sec)}')
        body.append('')
    users_note.write_text('\n'.join(body), encoding='utf-8')
    users_note.chmod(0o600)
    first_name = prefix if prefix in users else next(iter(users))
    legacy_note.write_text('MTProto proxy for XPAM Script\n==================================================\nLink: '+link_for(users[first_name])+'\n', encoding='utf-8')
    legacy_note.chmod(0o600)

if action == 'list':
    validate_users()
    for name, sec in users.items():
        print(f'{name}\t{sec[:4]}...[REDACTED]...{sec[-4:]}')
    sys.exit(0)

if action == 'show-link':
    validate_users()
    if user not in users:
        fail(f'MTProto user not found: {user}')
    print(link_for(users[user]))
    sys.exit(0)

if action == 'add':
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,32}', user):
        fail('bad user name; use letters, digits, underscore or dash, max 32 chars')
    if user in users:
        fail(f'MTProto user already exists: {user}')
    users[user]=secrets.token_hex(16)
elif action == 'delete':
    validate_users()
    if user not in users:
        fail(f'MTProto user not found: {user}')
    if len(users) <= 1:
        fail('cannot delete the last MTProto user')
    users.pop(user, None)
    limits.pop(user, None); exp.pop(user, None); quota.pop(user, None)
elif action == 'regen':
    validate_users()
    if user not in users:
        fail(f'MTProto user not found: {user}')
    users[user]=secrets.token_hex(16)
elif action == 'rewrite-notes':
    validate_users()
else:
    fail(f"unknown action: {action}")

validate_users()
text=path.read_text(encoding='utf-8')
text=replace_or_append(text, 'USERS', py_dict(users))
text=replace_or_append(text, 'USER_MAX_TCP_CONNS', py_dict(limits))
text=replace_or_append(text, 'USER_EXPIRATIONS', py_dict(exp))
text=replace_or_append(text, 'USER_DATA_QUOTA', py_dict(quota))
path.write_text(text, encoding='utf-8')
path.chmod(0o600)
# Import again after write to validate syntax/runtime.
spec=importlib.util.spec_from_file_location('mtproto_config_new', str(path))
new_cfg=importlib.util.module_from_spec(spec)
spec.loader.exec_module(new_cfg)
write_notes()
if action in {'add','regen'}:
    print(link_for(users[user]))
else:
    print('OK')
PY_MTPROTO_USERS
}


mtproto_restart_check(){
  systemctl restart mtprotoproxy
  systemctl is-active --quiet mtprotoproxy || fail "mtprotoproxy is not active after restart"
  ok "mtprotoproxy active"
  if [[ -x "/usr/local/sbin/${SERVER_PREFIX}-health" ]]; then
    run_health_quiet "mtproto-users"
  fi
}


mtproto_list_users(){
  need_root; load_config; validate_inputs; mtproto_require
  echo "MTProto пользователи:"
  echo
  local printed=0
  mtproto_python_update list | while IFS=$'\t' read -r name masked; do
    [[ -n "$name" ]] || continue
    if [[ "$printed" == "1" ]]; then
      echo
    fi
    printed=1
    echo "username: $name"
    echo "key: $masked"
  done
}


mtproto_add_user(){
  need_root; load_config; validate_inputs; mtproto_require
  local user backup_dir link
  read -r -p "Введите имя нового MTProto пользователя [a-z A-Z 0-9 _ -]: " user || true
  mtproto_valid_user_name "$user" || fail "Имя пользователя должно содержать только буквы, цифры, _ или -, максимум 32 символа"
  backup_dir="$(mtproto_backup)"
  ok "Backup MTProto config создан: $backup_dir"
  link="$(mtproto_python_update add "$user")"
  mtproto_restart_check
  echo
  warn "Это приватная ссылка подключения. Не отправляйте её в публичные чаты, тикеты, скриншоты и логи."
  echo "username: $user"
  echo "link: $link"
}


mtproto_show_user_link(){
  need_root; load_config; validate_inputs; mtproto_require
  mtproto_list_users
  local user link
  read -r -p "Введите имя MTProto пользователя: " user || true
  mtproto_valid_user_name "$user" || fail "Некорректное имя пользователя"
  link="$(mtproto_python_update show-link "$user")"
  echo
  warn "Это приватная ссылка подключения. Не отправляйте её в публичные чаты, тикеты, скриншоты и логи."
  echo "username: $user"
  echo "link: $link"
}


mtproto_delete_user(){
  need_root; load_config; validate_inputs; mtproto_require
  mtproto_list_users
  local user confirm backup_dir
  read -r -p "Введите имя MTProto пользователя для удаления: " user || true
  mtproto_valid_user_name "$user" || fail "Некорректное имя пользователя"
  read -r -p "Для подтверждения введите delete-${user}: " confirm || true
  [[ "$confirm" == "delete-${user}" ]] || fail "Удаление отменено"
  backup_dir="$(mtproto_backup)"
  ok "Backup MTProto config создан: $backup_dir"
  mtproto_python_update delete "$user" >/dev/null
  mtproto_restart_check
  ok "MTProto пользователь удалён: $user"
}


mtproto_regenerate_user_key(){
  need_root; load_config; validate_inputs; mtproto_require
  mtproto_list_users
  local user confirm backup_dir link
  read -r -p "Введите имя MTProto пользователя для замены ключа: " user || true
  mtproto_valid_user_name "$user" || fail "Некорректное имя пользователя"
  warn "Старый MTProto link этого пользователя перестанет работать."
  read -r -p "Для подтверждения введите regen-${user}: " confirm || true
  [[ "$confirm" == "regen-${user}" ]] || fail "Замена ключа отменена"
  backup_dir="$(mtproto_backup)"
  ok "Backup MTProto config создан: $backup_dir"
  link="$(mtproto_python_update regen "$user")"
  mtproto_restart_check
  echo
  warn "Это приватная ссылка подключения. Не отправляйте её в публичные чаты, тикеты, скриншоты и логи."
  echo "username: $user"
  echo "new link: $link"
}


print_tg_summary(){
  local mt_note mt_users_note
  mt_note="/root/secure-notes/${SERVER_PREFIX}-mtproto.txt"
  mt_users_note="/root/secure-notes/${SERVER_PREFIX}-mtproto-users.txt"
  echo
  echo "============================================================"
  echo "MTProto-подключение"
  echo "============================================================"
  echo
  echo "Эта команда по умолчанию НЕ печатает MTProto-ссылки, чтобы случайно не раскрыть доступ."
  echo
  echo "Файлы с MTProto-данными:"
  [[ -f "$mt_note" ]] && echo "  Основная ссылка:       $mt_note"
  [[ -f "$mt_users_note" ]] && echo "  Пользователи:          $mt_users_note"
  echo
  echo "Показать MTProto-ссылки на экран:"
  echo "  sudo ${SERVER_PREFIX}-tg --show"
  echo
  echo "Управлять MTProto-пользователями:"
  echo "  sudo ${SERVER_PREFIX}-tg --manage"
  echo
  echo "Проверить сервер:"
  echo "  sudo ${SERVER_PREFIX}-health"
  echo "============================================================"
}


mtproto_show_all_links(){
  need_root; load_config; validate_inputs; mtproto_require
  local mt_users_note mt_note
  mt_users_note="/root/secure-notes/${SERVER_PREFIX}-mtproto-users.txt"
  mt_note="/root/secure-notes/${SERVER_PREFIX}-mtproto.txt"
  warn "Ниже будут показаны приватные MTProto-ссылки. Не отправляйте их в публичные чаты, тикеты, скриншоты и логи."
  if [[ -s "$mt_users_note" ]]; then
    cat "$mt_users_note"
  elif [[ -s "$mt_note" ]]; then
    cat "$mt_note"
  else
    fail "MTProto note file не найден. Выполните health или repair."
  fi
}


stage_tg_direct(){
  need_root
  load_config
  validate_inputs
  mtproto_require
  case "${1:-}" in
    --show)
      mtproto_show_all_links
      ;;
    --manage)
      stage_mtproto_users_menu
      ;;
    --list)
      mtproto_list_users
      ;;
    ""|--help|-h)
      print_tg_summary
      ;;
    *)
      fail "Неизвестный параметр. Используйте: sudo ${SERVER_PREFIX}-tg, sudo ${SERVER_PREFIX}-tg --show или sudo ${SERVER_PREFIX}-tg --manage"
      ;;
  esac
}


stage_mtproto_users_menu(){
  need_root
  load_config
  validate_inputs
  mtproto_require
  echo "MTProto пользователи"
  echo "1) Показать список пользователей"
  echo "2) Добавить пользователя"
  echo "3) Показать ссылку пользователя"
  echo "4) Удалить пользователя"
  echo "5) Перегенерировать ключ пользователя"
  echo "6) Выйти"
  local choice
  read -r -p "Выберите пункт [1-6]: " choice || true
  case "$choice" in
    1) mtproto_list_users ;;
    2) mtproto_add_user ;;
    3) mtproto_show_user_link ;;
    4) mtproto_delete_user ;;
    5) mtproto_regenerate_user_key ;;
    6) return 0 ;;
    *) fail "Неизвестный пункт меню" ;;
  esac
}
