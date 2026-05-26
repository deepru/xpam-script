server {
    listen {{HTTP_PUBLIC_PORT}};
    server_name {{CERTONLY_SERVER_NAMES}};
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type "text/plain";
        try_files $uri =404;
        access_log off;
        allow all;
    }
    location / {
        root {{SERVICE_SITE_DIR}};
        index index.html;
        try_files $uri $uri/ /index.html;
    }
}
