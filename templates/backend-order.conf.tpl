[Unit]
Wants={{HAPROXY_BACKEND_ORDER_UNITS}}
After={{HAPROXY_BACKEND_ORDER_UNITS}}

[Service]
ExecStartPre=/usr/local/sbin/wait-for-local-port.sh 127.0.0.1 {{XRAY_LOCAL_PORT}} 30 xray-local
ExecStartPre=/usr/local/sbin/wait-for-local-port.sh 127.0.0.1 {{MTPROTO_PORT}} 30 mtproto-local
