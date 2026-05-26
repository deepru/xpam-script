global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 4096

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 1h
    timeout server 1h

frontend fe_tls_443
    bind 0.0.0.0:{{XRAY_PUBLIC_PORT}}
{{HAPROXY_IPV6_BIND}}
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    acl sni_sync req.ssl_sni -i {{SYNC_DOMAIN}}
    use_backend be_mtproto if sni_sync
    default_backend be_xray

backend be_xray
    mode tcp
    server xray 127.0.0.1:{{XRAY_LOCAL_PORT}} check

backend be_mtproto
    mode tcp
    server mtproto 127.0.0.1:{{MTPROTO_PORT}} check
