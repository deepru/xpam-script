server {
    listen {{HTTP_PUBLIC_PORT}};
    server_name {{VLESS_ALT_DOMAIN}};
    location ^~ /.well-known/acme-challenge/ { root /var/www/letsencrypt; default_type "text/plain"; try_files $uri =404; access_log off; allow all; }
    location / { return 301 https://{{VLESS_ALT_DOMAIN}}$request_uri; }
}
