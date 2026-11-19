[Unit]
Description=XPAM restore interrupted WARP registration egress
Before=x-ui.service
ConditionPathExists=/var/lib/xpam-script/warp-registration-egress.json

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/xpam-script/scripts/lib/xpam_warp_registration.py recover
TimeoutStartSec=30
UMask=0077

[Install]
WantedBy=multi-user.target
