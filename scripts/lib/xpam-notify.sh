#!/usr/bin/env bash
# XPAM Script module. This file is sourced by scripts/xpam-core.sh.
# Keep functions side-effect free at source time.

write_telegram_https_relay_worker(){
  cat > /usr/local/sbin/telegram-https-relay.py <<'PYRELAY'
#!/usr/bin/env python3
import json
import os
import socket
import socketserver
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler

SOCKET_PATH = os.environ.get("TELEGRAM_RELAY_SOCKET", "/run/xpam-script-telegram-relay.sock")
NOTIFY_ENV = "/root/secure-notes/notify.env"
RELAY_ENV = "/root/secure-notes/notify-relay.env"
MAX_BODY = 4096


def read_env(path):
    data = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                    value = value[1:-1]
                data[key] = value
    except FileNotFoundError:
        pass
    return data


def send_telegram(text):
    notify = read_env(NOTIFY_ENV)
    token = notify.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = notify.get("TELEGRAM_CHAT_ID", "")
    if not token or not chat_id:
        return False, "direct Telegram token/chat_id are not configured on relay server"
    payload = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode("utf-8")
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=payload,
        method="POST",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            if 200 <= resp.status < 300:
                return True, "OK"
            return False, f"Telegram HTTP {resp.status}"
    except Exception as exc:
        return False, str(exc)


class Handler(BaseHTTPRequestHandler):
    server_version = "ServerInstallKitTelegramRelay/1.0"

    def log_message(self, fmt, *args):
        return

    def send_text(self, code, text):
        body = (text + "\n").encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        if code == 401:
            self.send_header("WWW-Authenticate", 'Bearer realm="telegram-relay"')
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        relay = read_env(RELAY_ENV)
        token = relay.get("TELEGRAM_HTTPS_RELAY_TOKEN", "")
        auth = self.headers.get("Authorization", "")
        return bool(token) and auth == f"Bearer {token}"

    def do_GET(self):
        if not self.authorized():
            return self.send_text(401, "unauthorized")
        return self.send_text(405, "method not allowed")

    def do_PUT(self):
        if not self.authorized():
            return self.send_text(401, "unauthorized")
        return self.send_text(405, "method not allowed")

    def do_DELETE(self):
        if not self.authorized():
            return self.send_text(401, "unauthorized")
        return self.send_text(405, "method not allowed")

    def do_POST(self):
        if not self.authorized():
            return self.send_text(401, "unauthorized")
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            length = 0
        if length <= 0:
            return self.send_text(400, "empty message")
        if length > MAX_BODY:
            return self.send_text(413, "message too large")
        raw = self.rfile.read(length)
        text = raw.decode("utf-8", "replace").strip()
        ctype = (self.headers.get("Content-Type") or "").lower()
        if "application/json" in ctype:
            try:
                obj = json.loads(text)
                text = str(obj.get("text") or obj.get("message") or "").strip()
            except Exception:
                return self.send_text(400, "invalid json")
        if not text:
            return self.send_text(400, "empty message")
        if len(text.encode("utf-8")) > MAX_BODY:
            text = text[:3500]
        ok, err = send_telegram(text)
        if ok:
            return self.send_text(200, "OK")
        return self.send_text(502, "telegram delivery failed")


class UnixHTTPServer(socketserver.UnixStreamServer):
    allow_reuse_address = True


def main():
    try:
        os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass
    os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
    server = UnixHTTPServer(SOCKET_PATH, Handler)
    try:
        import grp
        gid = grp.getgrnam("www-data").gr_gid
        os.chown(SOCKET_PATH, 0, gid)
        os.chmod(SOCKET_PATH, 0o660)
    except Exception:
        os.chmod(SOCKET_PATH, 0o666)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        try:
            os.unlink(SOCKET_PATH)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
PYRELAY
  chmod 700 /usr/local/sbin/telegram-https-relay.py
  python3 -m py_compile /usr/local/sbin/telegram-https-relay.py
}


ensure_telegram_relay_nginx_snippet(){
  mkdir -p /etc/nginx/snippets
  if [[ ! -f /etc/nginx/snippets/xpam-script-telegram-relay.conf ]]; then
    : > /etc/nginx/snippets/xpam-script-telegram-relay.conf
  fi
}



telegram_mask_token(){
  local t="${1:-}"
  local n=${#t}
  if (( n <= 10 )); then
    printf '%s' '[masked]'
  else
    printf '%s...%s' "${t:0:6}" "${t: -4}"
  fi
}

telegram_api_base(){ printf 'https://api.telegram.org/bot%s' "$1"; }

telegram_validate_token(){
  local token="$1" json ok username
  json="$(curl -4fsS --connect-timeout 5 --max-time 10 "$(telegram_api_base "$token")/getMe" 2>/dev/null || true)"
  [[ -n "$json" ]] || return 1
  ok="$(printf '%s' "$json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("true" if d.get("ok") is True else "false")' 2>/dev/null || echo false)"
  [[ "$ok" == "true" ]] || return 1
  username="$(printf '%s' "$json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("result",{}).get("username", ""))' 2>/dev/null || true)"
  [[ -n "$username" ]] && ok "Telegram bot token действителен: @${username}" || ok "Telegram bot token is valid"
  return 0
}

telegram_send_test(){
  local token="$1" chat="$2" text="$3"
  curl -4fsS --connect-timeout 5 --max-time 10 \
    -X POST "$(telegram_api_base "$token")/sendMessage" \
    -d "chat_id=${chat}" \
    --data-urlencode "text=${text}" \
    >/dev/null 2>&1
}

telegram_private_chat_id(){
  local token="$1"
  curl -4fsS --connect-timeout 5 --max-time 10 "$(telegram_api_base "$token")/getUpdates" 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); chats=[]
for u in d.get("result",[]):
    m=u.get("message") or u.get("edited_message") or {}
    c=m.get("chat") or {}
    if c.get("type")=="private" and c.get("id") is not None:
        chats.append(str(c.get("id")))
print(chats[-1] if chats else "")' 2>/dev/null || true
}


telegram_botfather_help(){
  cat <<'EOF_TG_BOT_HELP'
Подготовка Telegram-бота:

XPAM Script использует только личный чат один-на-один с вашим Telegram-ботом.
Группы, каналы и темы форумов в простой установке не используются.

Если у вас уже есть bot token:
  1. Используйте существующий token.
  2. Откройте чат с вашим созданным ботом.
  3. Отправьте боту /start, если ещё не делали этого раньше.
  4. Повторно отправить /start безопасно.

Если бота ещё нет:
  1. Откройте Telegram.
  2. Найдите @BotFather.
  3. Отправьте ему /newbot.
  4. Создайте имя и username бота.
  5. Скопируйте token, который выдаст BotFather.
  6. Откройте чат с вашим новым ботом, НЕ с @BotFather.
  7. Отправьте вашему новому боту /start.
  8. Вернитесь сюда и вставьте token в терминал.
EOF_TG_BOT_HELP
}



setup_direct_telegram_env(){
  local token chat direct_ok
  if [[ -f /etc/xpam-script/config.env ]]; then
    set +u
    . /etc/xpam-script/config.env
    set -u
  fi
  echo
  echo "Режим прямой отправки Telegram уведомлений."
  echo "Этот VPS сам отправляет сообщения в Telegram через вашего бота."
  echo "Relay-сервер в этом режиме не используется."
  echo
  telegram_botfather_help
  echo

  while true; do
    read -r -s -p "Введите Telegram bot token от @BotFather; пусто = отмена. Token сюда, в чат ChatGPT, не отправляйте: " token || true
    echo
    [[ -n "$token" ]] || { warn "Настройка Telegram отменена"; return 1; }
    say "Проверяем Telegram bot token: $(telegram_mask_token "$token")"
    telegram_validate_token "$token" && break
    warn "Telegram bot token не прошёл проверку. Проверьте token, который выдал @BotFather."
  done

  echo
  echo "Теперь откройте в Telegram чат с вашим созданным ботом, НЕ с @BotFather, и отправьте:"
  echo "  /start"
  echo
  echo "Если чат с ботом уже был запущен раньше, повторно отправить /start безопасно."
  echo
  read -r -p "Нажмите Enter после отправки /start вашему боту: " _tg_enter || true

  chat="$(telegram_private_chat_id "$token")"
  if [[ -z "$chat" ]]; then
    warn "Не удалось автоматически определить private chat_id. Убедитесь, что вы открыли созданного бота и отправили ему /start."
    read -r -p "Нажмите Enter, чтобы попробовать getUpdates ещё раз, или Ctrl+C для отмены: " _tg_retry || true
    chat="$(telegram_private_chat_id "$token")"
  fi
  [[ -n "$chat" ]] || fail "Private Telegram chat_id не найден. Отправьте /start вашему боту и запустите настройку Telegram снова."

  cat > /root/secure-notes/notify.env <<EOF_NOTIFY
TELEGRAM_MODE='direct'
TELEGRAM_BOT_TOKEN='${token}'
TELEGRAM_CHAT_ID='${chat}'
EOF_NOTIFY
  chmod 600 /root/secure-notes/notify.env

  say "Отправляем тестовое Telegram сообщение"
  direct_ok=no
  if telegram_send_test "$token" "$chat" "[${SERVER_PREFIX:-$(hostname -s)}] Проверка Telegram уведомлений: OK"; then
    ok "Telegram уведомления в личный чат работают напрямую"
    direct_ok=yes
  else
    warn "Прямая отправка Telegram с этого сервера не сработала. Используйте HTTPS Relay, если этот VPS не может достучаться до api.telegram.org."
  fi
  say "Telegram настройки сохранены в /root/secure-notes/notify.env с правами 600"
  [[ "$direct_ok" == "yes" ]]
}


setup_https_relay_client(){
  local relay_url relay_token
  if [[ -f /etc/xpam-script/config.env ]]; then
    set +u
    . /etc/xpam-script/config.env
    set -u
  fi
  echo
  echo "Режим отправки уведомлений через другой XPAM Script сервер."
  echo
  echo "Этот VPS будет клиентом Telegram Relay."
  echo "Он НЕ использует Telegram bot token и НЕ пишет в Telegram напрямую."
  echo "Он отправляет уведомления на основной XPAM Script сервер, где уже включён Telegram Relay."
  echo
  echo "Когда выбирать этот пункт:"
  echo "  - этот сервер дополнительный;"
  echo "  - основной сервер уже настроен как Telegram Relay через пункт 3;"
  echo "  - вы хотите, чтобы этот сервер отправлял уведомления через основной сервер."
  echo
  echo "Что нужно взять с основного Relay-сервера:"
  echo "  1. Relay URL"
  echo "  2. Relay token"
  echo
  echo "Где взять Relay URL:"
  echo "  На основном сервере выберите пункт 3:"
  echo "  Сделать этот сервер Telegram Relay для других серверов."
  echo "  После включения скрипт покажет Relay URL."
  echo
  echo "Где взять Relay token:"
  echo "  На основном Relay-сервере он хранится в:"
  echo "  /root/secure-notes/notify-relay.env"
  echo
  echo "Relay token — секрет. Не отправляйте его в чат, письма или публичные логи."
  echo "Relay URL лучше копировать с завершающим /. Если / забыли, XPAM Script добавит его сам."
  echo "Автоматического подставления Relay URL/token нет: пользователь вводит их вручную."
  echo
  ask relay_url "Введите Relay URL с основного Relay-сервера" ""
  read -r -s -p "Введите Relay token с основного Relay-сервера; пусто = отмена: " relay_token || true
  echo
  relay_url="$(normalize_https_relay_url "$relay_url")"
  [[ -n "$relay_token" ]] || { warn "Настройка HTTPS Relay отменена"; return 1; }
  echo "Relay URL будет сохранён как: ${relay_url}"

  say "Отправляем тестовое сообщение через HTTPS Relay"
  if curl -4fsS --connect-timeout 5 --max-time 12 \
      -X POST "$relay_url" \
      -H "Authorization: Bearer ${relay_token}" \
      --data-binary "[${SERVER_PREFIX:-$(hostname -s)}] Проверка отправки через HTTPS Relay: OK" \
      >/dev/null 2>&1; then
    ok "HTTPS Relay работает"
  else
    fail "Тест HTTPS Relay не прошёл. Проверьте Relay URL/token и то, что relay-сервер умеет отправлять Telegram уведомления."
  fi

  cat > /root/secure-notes/notify.env <<EOF_NOTIFY_RELAY
TELEGRAM_MODE='https_relay'
TELEGRAM_RELAY_URL='${relay_url}'
TELEGRAM_RELAY_TOKEN='${relay_token}'
EOF_NOTIFY_RELAY
  chmod 600 /root/secure-notes/notify.env
  ok "Настройки HTTPS Relay сохранены в /root/secure-notes/notify.env"
}


telegram_relay_wait_http_code(){
  local url="$1" expect="$2" token="${3:-}" code=""
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [[ -n "$token" ]]; then
      code="$(curl -4ksS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 -H "Authorization: Bearer ${token}" "$url" 2>/dev/null || true)"
    else
      code="$(curl -4ksS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)"
    fi
    [[ "$code" == "$expect" ]] && { echo "$code"; return 0; }
    sleep 1
  done
  echo "${code:-none}"
  return 1
}


telegram_relay_post_with_retry(){
  local url="$1" token="$2" message="$3"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -4fsS --connect-timeout 5 --max-time 12 \
        -X POST "$url" \
        -H "Authorization: Bearer ${token}" \
        --data-binary "$message" \
        >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}


setup_https_relay_server(){
  local relay_path relay_token relay_url code
  if [[ ! -f "$CONFIG_FILE" ]]; then
    fail "Server config not found. Finish server setup first, then enable HTTPS Telegram relay."
  fi
  load_config
  validate_inputs
  uses_mtproto || fail "HTTPS relay server mode requires a profile with MTProto domain behind HAProxy. This keeps public ports limited to 22/80/443."
  echo
  echo "Режим Telegram Relay-сервера."
  echo "Этот VPS будет принимать уведомления от других XPAM Script серверов и пересылать их в Telegram."
  echo "Новый внешний порт НЕ открывается. Используется существующий HTTPS 443 через HAProxy/nginx."
  echo "Так как именно этот сервер отправляет сообщения в Telegram, ему нужен Telegram bot token."
  echo "Если бота ещё нет, следующий шаг объяснит, как создать его через @BotFather."
  echo

  if [[ ! -s /root/secure-notes/notify.env ]]; then
    warn "Direct Telegram settings are required on the relay server. Configure them now."
    setup_direct_telegram_env || fail "Direct Telegram setup is required before enabling this server as relay."
  else
    # Relay server must have real Telegram bot token/chat_id locally. A relay-client-only notify.env is not enough.
    if ! bash -c '. /root/secure-notes/notify.env; [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]'; then
      warn "This server does not have direct Telegram bot token/chat_id. Configure direct Telegram now."
      setup_direct_telegram_env || fail "Direct Telegram setup is required before enabling this server as relay."
    else
      echo
      echo "Перед включением Telegram Relay нужно проверить, что этот сервер сам может отправлять сообщения в Telegram."
      echo "Сейчас будет отправлено тестовое сообщение в ваш Telegram."
      echo
      if ! bash -c '. /etc/xpam-script/config.env; . /usr/local/sbin/xpam-maint-common.sh; xpam_notify_send "[${SERVER_PREFIX:-$(hostname -s)}] Проверка перед включением Relay: прямая отправка в Telegram работает."'; then
        fail "Сохранённые прямые Telegram настройки не сработали. Сначала обновите Direct Telegram token через пункт 1."
      fi
    fi
  fi

  relay_path="$(normalize_path "${TELEGRAM_RELAY_PATH:-api/internal/notify-relay}")"
  read -r -p "Путь HTTPS Relay на ${SYNC_DOMAIN} [${relay_path}]: " _relay_path_ans || true
  relay_path="$(normalize_path "${_relay_path_ans:-$relay_path}")"
  [[ -n "$relay_path" ]] || fail "Relay path cannot be empty"
  [[ "$relay_path" =~ ^[A-Za-z0-9._~/-]+$ ]] || fail "Relay path contains unsupported characters"
  [[ "$relay_path" != *..* ]] || fail "Relay path must not contain .."
  relay_token="$(openssl rand -hex 32)"

  mkdir -p /root/secure-notes /etc/nginx/snippets
  chmod 700 /root/secure-notes
  cat > /root/secure-notes/notify-relay.env <<EOF_RELAY_ENV
TELEGRAM_HTTPS_RELAY_TOKEN='${relay_token}'
TELEGRAM_HTTPS_RELAY_PATH='${relay_path}'
TELEGRAM_HTTPS_RELAY_SOCKET='${TELEGRAM_RELAY_SOCKET}'
EOF_RELAY_ENV
  chmod 600 /root/secure-notes/notify-relay.env

  write_telegram_https_relay_worker
  cat > /etc/systemd/system/telegram-https-relay.service <<EOF_RELAY_SERVICE
[Unit]
Description=XPAM Script HTTPS Telegram relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=TELEGRAM_RELAY_SOCKET=${TELEGRAM_RELAY_SOCKET}
ExecStart=/usr/local/sbin/telegram-https-relay.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=false

[Install]
WantedBy=multi-user.target
EOF_RELAY_SERVICE

  cat > /etc/nginx/snippets/xpam-script-telegram-relay.conf <<EOF_RELAY_NGINX
location = /${relay_path} { return 308 /${relay_path}/; }
location ^~ /${relay_path}/ {
    client_max_body_size 8k;
    access_log off;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header Authorization \$http_authorization;
    proxy_set_header Content-Type \$content_type;
    proxy_pass http://unix:${TELEGRAM_RELAY_SOCKET}:/;
}
EOF_RELAY_NGINX

  systemctl daemon-reload
  systemctl enable --now telegram-https-relay.service
  nginx -t
  systemctl reload nginx || systemctl restart nginx

  relay_url="https://${SYNC_DOMAIN}/${relay_path}/"

  say "Проверяем HTTPS Relay endpoint без token; ожидается HTTP 401"
  code="$(telegram_relay_wait_http_code "$relay_url" "401" "" || true)"
  [[ "$code" == "401" ]] && ok "Relay endpoint без token возвращает HTTP 401" || fail "Relay endpoint без token вернул HTTP ${code:-none}; ожидался 401"

  say "Отправляем тестовое сообщение через HTTPS Relay"
  telegram_relay_post_with_retry "$relay_url" "$relay_token" "[${SERVER_PREFIX:-$(hostname -s)}] Проверка HTTPS Telegram Relay-сервера: OK" \
    || fail "HTTPS Relay self-test не прошёл"

  ok "HTTPS Telegram Relay-сервер включён"
  echo
  echo "ДАННЫЕ HTTPS RELAY — СОХРАНИТЕ ДЛЯ ДРУГИХ СЕРВЕРОВ"
  echo
  echo "Этот сервер теперь является основным Telegram Relay-сервером."
  echo "Другие XPAM Script серверы могут отправлять Telegram уведомления через него."
  echo
  echo "На дополнительных серверах выберите:"
  echo "  4) Настроить / проверить Telegram уведомления"
  echo "  2) Отправлять уведомления через другой XPAM Script сервер"
  echo
  echo "Relay URL:"
  echo "  ${relay_url}"
  echo
  echo "Relay token:"
  echo "  сохранён безопасно в /root/secure-notes/notify-relay.env"
  echo "  откройте этот файл на основном Relay-сервере и вручную скопируйте token"
  echo "  token нужен только при настройке дополнительных серверов через пункт 2"
  echo
  echo "Relay token не печатается в терминал и обычные install logs."
  echo "Relay token нельзя отправлять в чат, письма или публичные логи."
}

setup_notify_env(){
  write_common_library
  write_telegram_https_relay_worker
  mkdir -p /root/secure-notes
  chmod 700 /root/secure-notes

  local choice notify_profile relay_server_supported="no"
  notify_profile="${PROFILE:-}"
  if [[ -z "$notify_profile" && -f "$CONFIG_FILE" ]]; then
    notify_profile="$(bash -c '. "$1" 2>/dev/null; printf "%s" "${PROFILE:-}"' _ "$CONFIG_FILE" 2>/dev/null || true)"
  fi
  case "$notify_profile" in
    subdomains_mtproto|root_mtproto) relay_server_supported="yes" ;;
  esac

  echo
  printf '\033[0m'
  echo "============================================================"
  echo "Telegram-уведомления"
  echo "============================================================"
  echo
  echo "XPAM использует личный чат один-на-один с вашим Telegram-ботом."
  echo "Группы, каналы и темы форумов в простой установке не используются."
  echo
  echo "Что НЕ отправляется:"
  echo "  - пароли;"
  echo "  - VLESS/MTProto ссылки;"
  echo "  - Telegram token;"
  echo "  - WARP keys."
  echo
  echo "------------------------------------------------------------"
  echo "Выберите режим Telegram"
  echo "------------------------------------------------------------"
  echo "1) Отправлять уведомления напрямую с этого сервера в Telegram"
  echo "   Этот VPS сам пишет вам в Telegram. Нужен bot token от @BotFather."
  echo
  echo "2) Отправлять уведомления через другой XPAM Script сервер"
  echo "   Этот VPS НЕ использует bot token. Нужны только Relay URL и Relay token с другого сервера."
  echo
  if [[ "$relay_server_supported" == "yes" ]]; then
    echo "3) Сделать этот сервер Telegram Relay для других серверов"
    echo "   Этот VPS будет принимать уведомления от других серверов и пересылать их в Telegram."
    echo "   Нужен bot token от @BotFather. Новый внешний порт не открывается, используется HTTPS 443."
    echo
    echo "4) Проверить уже сохранённые Telegram настройки"
    echo "   Использует /root/secure-notes/notify.env. Ничего заново не настраивает."
    echo
    echo "5) Пропустить Telegram уведомления"
    read -r -p "Выберите пункт [1-5]: " choice || true
    choice="${choice:-5}"
  else
    echo "3) Проверить уже сохранённые Telegram настройки"
    echo "   Использует /root/secure-notes/notify.env. Ничего заново не настраивает."
    echo
    echo "4) Пропустить Telegram уведомления"
    read -r -p "Выберите пункт [1-4]: " choice || true
    choice="${choice:-4}"
  fi

  if [[ "$relay_server_supported" != "yes" ]]; then
    case "$choice" in
      1) setup_direct_telegram_env || true ;;
      2) setup_https_relay_client ;;
      3)
        if [[ -s /root/secure-notes/notify.env ]]; then
          chmod 600 /root/secure-notes/notify.env
          ok "Используем сохранённые Telegram настройки: /root/secure-notes/notify.env"
          bash -c '. /etc/xpam-script/config.env; . /usr/local/sbin/xpam-maint-common.sh; xpam_notify_send "[${SERVER_PREFIX:-$(hostname -s)}] Проверка сохранённых Telegram настроек из xpam-script: OK"' || warn "Не удалось отправить Telegram test с сохранёнными настройками"
        else
          warn "No existing /root/secure-notes/notify.env found"
        fi
        ;;
      4|*) warn "Telegram skipped" ;;
    esac
    return 0
  fi

  case "$choice" in
    1) setup_direct_telegram_env || true ;;
    2) setup_https_relay_client ;;
    3) setup_https_relay_server ;;
    4)
      if [[ -s /root/secure-notes/notify.env ]]; then
        chmod 600 /root/secure-notes/notify.env
        ok "Используем сохранённые Telegram настройки: /root/secure-notes/notify.env"
        bash -c '. /etc/xpam-script/config.env; . /usr/local/sbin/xpam-maint-common.sh; xpam_notify_send "[${SERVER_PREFIX:-$(hostname -s)}] Проверка сохранённых Telegram настроек из xpam-script: OK"' || warn "Не удалось отправить Telegram test с сохранёнными настройками"
      else
        warn "No existing /root/secure-notes/notify.env found"
      fi
      ;;
    5|*) warn "Telegram skipped" ;;
  esac
}



stage_notify(){ need_root; setup_notify_env; }
