[Unit]
Description=XPAM post-reboot maintenance ({{SERVER_PREFIX_UP}}): second upgrade pass + health verify
Documentation=https://github.com/deepru/xpam-script
After=network-online.target x-ui.service nginx.service haproxy.service
Wants=network-online.target
ConditionPathExists=/usr/local/sbin/{{SERVER_PREFIX}}-post-reboot-maint.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/{{SERVER_PREFIX}}-post-reboot-maint.sh
Nice=19
IOSchedulingClass=idle
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
