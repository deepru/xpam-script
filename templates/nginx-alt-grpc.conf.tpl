server {
    listen {{HTTP_PUBLIC_PORT}};
    server_name {{VLESS_ALT_DOMAIN}};
    location ^~ /.well-known/acme-challenge/ { root /var/www/letsencrypt; default_type "text/plain"; try_files $uri =404; access_log off; allow all; }
    location / { return 301 https://{{VLESS_ALT_DOMAIN}}$request_uri; }
}
server {
    listen 127.0.0.1:{{NGINX_ALT_TLS_PORT}} ssl http2 default_server;
    server_name _;
    ssl_certificate {{ALT_CERT}};
    ssl_certificate_key {{ALT_KEY}};
    ssl_protocols TLSv1.2 TLSv1.3;
    return 444;
}
server {
    listen 127.0.0.1:{{NGINX_ALT_TLS_PORT}} ssl http2;
    server_name {{VLESS_ALT_DOMAIN}};
    ssl_certificate {{ALT_CERT}};
    ssl_certificate_key {{ALT_KEY}};
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/{{VLESS_ALT_DOMAIN}};
    index index.html;
    server_tokens off;
    charset utf-8;
    autoindex off;
    gzip on;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_vary on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy no-referrer-when-downgrade always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
    add_header X-Permitted-Cross-Domain-Policies none always;
    access_log off;
    error_log /var/log/nginx/{{SERVER_PREFIX}}-alt.error.log;
    etag on;
    if_modified_since exact;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    # Secret gRPC serviceName → plain (security=none) Xray grpc inbound on loopback via grpc_pass (HTTP/2,
    # already enabled above). Prefix match with a LEADING slash: the serviceName is stored slash-less
    # ({{VLESS_ALT_PATH}} = e.g. v1/streams/<hex>), while the gRPC request path is /<serviceName>/Tun (or
    # /<serviceName>/TunMulti) — so ^~ /{{VLESS_ALT_PATH}} catches both. Everything else falls through to
    # the decoy on / (masking).
    location ^~ /{{VLESS_ALT_PATH}} {
        grpc_pass grpc://127.0.0.1:{{XRAY_ALT_PORT}};
        grpc_read_timeout 300s;
        grpc_send_timeout 300s;
        client_max_body_size 0;
        access_log off;
    }
    location @same_domain_root { return 302 https://$host/; }
    location = /license { try_files /license.html @same_domain_root; expires -1; }
    location = /docs { try_files /docs.html @same_domain_root; expires -1; }
    location = /favicon.ico { try_files /favicon.ico =204; log_not_found off; access_log off; }
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|webp|woff2?)$ {
        expires 7d;
        access_log off;
    }
    location / {
        expires -1;
        try_files $uri $uri/ =404;
    }
    error_page 404 /404.html;
}
