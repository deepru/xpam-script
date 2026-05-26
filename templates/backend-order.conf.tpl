[Unit]
Wants=network-online.target nginx.service x-ui.service mtprotoproxy.service
After=network-online.target nginx.service x-ui.service mtprotoproxy.service

[Service]
ExecStartPre=/usr/local/sbin/wait-for-local-port.sh 127.0.0.1 {{XRAY_LOCAL_PORT}} 30 xray-local
ExecStartPre=/usr/local/sbin/wait-for-local-port.sh 127.0.0.1 {{MTPROTO_PORT}} 30 mtproto-local
