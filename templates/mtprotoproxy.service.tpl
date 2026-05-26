[Unit]
Description = MTProto Proxy Service
After=network.target

[Service]
Type = simple
ExecStart = /usr/bin/python3 /opt/mtprotoproxy/mtprotoproxy.py
StartLimitBurst=0

[Install]
WantedBy = multi-user.target
