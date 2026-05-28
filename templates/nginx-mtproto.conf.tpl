server {
    listen {{HTTP_PUBLIC_PORT}} default_server;
    server_name _;
    location ^~ /.well-known/acme-challenge/ { root /var/www/letsencrypt; default_type "text/plain"; try_files $uri =404; access_log off; allow all; }
    location / { return 444; }
}
server {
    listen {{HTTP_PUBLIC_PORT}};
    server_name {{WEB_SERVER_NAMES}} {{SYNC_DOMAIN}};
    location ^~ /.well-known/acme-challenge/ { root /var/www/letsencrypt; default_type "text/plain"; try_files $uri =404; access_log off; allow all; }
    location / { return 301 https://$host$request_uri; }
}
server { listen 127.0.0.1:{{SITE_BACKEND_PORT}} default_server; server_name _; return 444; }
{{ROOT_SITE_BLOCK}}
server {
    listen 127.0.0.1:{{SITE_BACKEND_PORT}};
    server_name {{PRIMARY_DOMAIN}};
    root {{SERVICE_SITE_DIR}};
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
    error_log /var/log/nginx/{{SERVER_PREFIX}}.error.log;
    etag on;
    if_modified_since exact;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    location = /{{PANEL_PATH}} {
        return 308 https://$host/{{PANEL_PATH}}/;
    }
    location ^~ /{{PANEL_PATH}}/ {
        auth_basic "Restricted";
        auth_basic_user_file /etc/nginx/.htpasswd;
        proxy_pass https://127.0.0.1:{{XUI_PANEL_PORT}};
        proxy_ssl_server_name on;
        proxy_ssl_name {{PRIMARY_DOMAIN}};
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300;
        proxy_send_timeout 300;
        proxy_connect_timeout 60;
        gzip off;
        access_log off;
    }
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|webp|woff2?)$ {
        expires 7d;
        add_header Cache-Control "public, max-age=604800" always;
        access_log off;
    }
    location @same_domain_root { return 302 https://$host/; }
    location = /login {
        try_files /login.html @same_domain_root;
        add_header Cache-Control "no-store" always;
    }
    location = /docs {
        try_files /docs.html @same_domain_root;
        add_header Cache-Control "no-store" always;
    }
    location = /favicon.ico { try_files /favicon.ico =204; log_not_found off; access_log off; }
    location / {
        add_header Cache-Control "no-cache" always;
        try_files $uri $uri/ =404;
    }
    error_page 404 /404.html;
}
server {
    listen 127.0.0.1:{{SYNC_BACKEND_PORT}} ssl;
    server_name {{SYNC_DOMAIN}};
    root /var/www/{{SYNC_DOMAIN}};
    index index.html;
    ssl_certificate /etc/letsencrypt/live/{{SYNC_DOMAIN}}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{{SYNC_DOMAIN}}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;
    autoindex off;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy no-referrer always;
    add_header Cache-Control "no-store" always;
    location @sync_domain_root { return 302 https://$host/; }
    location @sync_service_index { default_type application/json; return 200 "{\"service\":\"sync\",\"status\":\"ok\",\"version\":\"1.0\",\"documentation\":\"/docs\"}\n"; }
    location @sync_not_found { default_type application/json; return 404 "{\"error\":\"not_found\"}\n"; }
    location = / { try_files /index.html @sync_service_index; }
    location = /health { default_type application/json; return 200 "{\"status\":\"ok\"}\n"; }
    location = /status { default_type application/json; return 200 "{\"service\":\"sync\",\"status\":\"operational\"}\n"; }
    location = /login { try_files /login.html @sync_domain_root; }
    location = /docs { try_files /docs.html @sync_domain_root; }
    location = /favicon.ico { try_files /favicon.ico =204; log_not_found off; access_log off; }
    location = /v1 { default_type application/json; add_header WWW-Authenticate 'Bearer realm="api"' always; return 401 "{\"error\":\"unauthorized\",\"message\":\"missing bearer token\"}\n"; }
    location ^~ /v1/ { default_type application/json; add_header WWW-Authenticate 'Bearer realm="api"' always; return 401 "{\"error\":\"unauthorized\",\"message\":\"missing bearer token\"}\n"; }
    include /etc/nginx/snippets/xpam-script-telegram-relay.conf;
    location / { try_files $uri $uri/ /index.html @sync_not_found; }
}
