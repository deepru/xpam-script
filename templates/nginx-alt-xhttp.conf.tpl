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
    # Secret xhttp path → plain (security=none) Xray xhttp inbound on loopback. Prefix match so
    # xhttp packet-up sub-paths (<path>/<session>/<seq>) are also proxied. Buffering off for streaming.
    location ^~ {{VLESS_ALT_PATH}} {
        proxy_pass http://127.0.0.1:{{XRAY_ALT_PORT}};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
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
