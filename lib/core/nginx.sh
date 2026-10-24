# Beszel-owned reverse proxy helpers.
# This module manages only the Beszel proxy directory and its own vhost.

DIR_NGINX="${DIR_NGINX:-/opt/beszel-proxy/}"
DIR_NGINX="${DIR_NGINX%/}/"
BESZEL_NGINX_CONTAINER="beszel-proxy"

_beszel_nginx_marker() {
    printf '%s/.beszel-proxy\n' "${DIR_NGINX%/}"
}

_beszel_nginx_is_managed() {
    local marker
    marker=$(_beszel_nginx_marker) || return 1
    [ -f "$marker" ] && [ ! -L "$marker" ] && \
        grep -qx 'MANAGED_BY=beszel' "$marker" 2>/dev/null
}

_beszel_nginx_claim_directory() {
    local root="${DIR_NGINX%/}" marker
    [ -n "$root" ] && [[ "$root" == */beszel-proxy ]] && [ ! -L "$root" ] || return 1
    [[ "$root" = /* ]] || return 1
    marker=$(_beszel_nginx_marker) || return 1

    if _beszel_nginx_is_managed; then
        return 0
    fi

    # Never adopt or rewrite an existing proxy configuration.
    if [ -e "${root}/docker-compose.yml" ] || [ -e "${root}/nginx.conf" ] || \
       [ -e "${root}/soft" ] || [ -L "$marker" ]; then
        return 1
    fi

    mkdir -p "$root" || return 1
    (umask 077; printf 'MANAGED_BY=beszel\n' > "$marker") || return 1
}

ensure_nginx() {
    _beszel_nginx_claim_directory || return 1
    mkdir -p "${DIR_NGINX}ssl" "${DIR_NGINX}soft" || return 1

    if [ -L "${DIR_NGINX}docker-compose.yml" ]; then
        return 1
    fi
    if [ ! -f "${DIR_NGINX}docker-compose.yml" ]; then
        cat > "${DIR_NGINX}docker-compose.yml" <<'COMPOSE'
name: beszel-proxy

services:
  nginx:
    image: nginx:1.28
    container_name: beszel-proxy
    restart: unless-stopped
    network_mode: host
    mem_limit: 256m
    mem_reservation: 64m
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./soft:/etc/nginx/conf.d:ro
      - ./ssl:/etc/nginx/ssl:ro
    healthcheck:
      test: ['CMD-SHELL', 'kill -0 $$(cat /run/nginx.pid) 2>/dev/null']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options:
        max-size: 30m
        max-file: 5
COMPOSE
    fi

    nginx_generate_minimal_conf
}

nginx_generate_minimal_conf() {
    _beszel_nginx_claim_directory || return 1
    mkdir -p "${DIR_NGINX}soft" "${DIR_NGINX}ssl" || return 1
    [ -L "${DIR_NGINX}nginx.conf" ] && return 1
    [ -e "${DIR_NGINX}nginx.conf" ] && return 0

    cat > "${DIR_NGINX}nginx.conf" <<'NGINX'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;

events {
    worker_connections 2048;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;
    sendfile on;
    keepalive_timeout 65;
    client_max_body_size 10m;
    log_format combined '$remote_addr - $remote_user [$time_local] "$request" '
                        '$status $body_bytes_sent "$http_referer" '
                        '"$http_user_agent" "$http_x_forwarded_for"';

    server {
        listen 80 default_server;
        server_name _;
        return 444;
    }

    server {
        listen 443 ssl default_server;
        server_name _;
        ssl_reject_handshake on;
    }

    include /etc/nginx/conf.d/*.conf;
}
NGINX
}

nginx_copy_cert() {
    local domain="${1:-}" le_base src dst
    [ -n "$domain" ] || return 1
    _beszel_nginx_claim_directory || return 1
    le_base="$domain"
    if declare -F le_live_basename >/dev/null 2>&1; then
        local resolved
        resolved=$(le_live_basename "$domain" 2>/dev/null) || resolved=""
        [ -z "$resolved" ] || le_base="$resolved"
    fi
    src="${BESZEL_LETSENCRYPT_DIR:-/etc/letsencrypt}/live/${le_base}"
    dst="${DIR_NGINX}ssl/${le_base}"
    [ -s "${src}/fullchain.pem" ] && [ -s "${src}/privkey.pem" ] || return 1
    mkdir -p "$dst" || return 1
    cp -fL "${src}/fullchain.pem" "${dst}/fullchain.pem" || return 1
    cp -fL "${src}/privkey.pem" "${dst}/privkey.pem" || return 1
    chmod 644 "${dst}/fullchain.pem" && chmod 600 "${dst}/privkey.pem"
}

nginx_add_server_block() {
    local name="${1^^}" content="${2:-}" target tmp
    [ "$name" = BESZEL ] && [ -n "$content" ] || return 1
    ensure_nginx || return 1
    target="${DIR_NGINX}soft/beszel.conf"
    if [ -e "$target" ] && {
        ! grep -qx '# BEGIN_BESZEL_BLOCK' "$target" 2>/dev/null ||
        ! grep -qx '# END_BESZEL_BLOCK' "$target" 2>/dev/null;
    }; then
        return 1
    fi
    tmp=$(mktemp "${DIR_NGINX}soft/.beszel.XXXXXX") || return 1
    {
        printf '# BEGIN_BESZEL_BLOCK\n'
        printf '%s\n' "$content"
        printf '# END_BESZEL_BLOCK\n'
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 644 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$target"
}

nginx_remove_server_block() {
    local name="${1^^}" target
    [ "$name" = BESZEL ] || return 1
    target="${DIR_NGINX}soft/beszel.conf"
    [ -e "$target" ] || return 0
    _beszel_nginx_is_managed || return 1
    grep -qx '# BEGIN_BESZEL_BLOCK' "$target" 2>/dev/null && \
        grep -qx '# END_BESZEL_BLOCK' "$target" 2>/dev/null || return 1
    rm -f "$target"
}

nginx_has_users() {
    local config
    [ -d "${DIR_NGINX}soft" ] || return 1
    for config in "${DIR_NGINX}soft/"*.conf; do
        [ -s "$config" ] || continue
        return 0
    done
    return 1
}

nginx_reload() {
    local project="" running=false
    ensure_nginx || return 1
    docker compose -f "${DIR_NGINX}docker-compose.yml" config >/dev/null 2>&1 || return 1

    if docker inspect "$BESZEL_NGINX_CONTAINER" >/dev/null 2>&1; then
        project=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' \
            "$BESZEL_NGINX_CONTAINER" 2>/dev/null || true)
        [ "$project" = beszel-proxy ] || return 1
        [ "$(docker inspect -f '{{.State.Running}}' "$BESZEL_NGINX_CONTAINER" 2>/dev/null || true)" = true ] && running=true
    fi

    if [ "$running" = true ]; then
        docker exec "$BESZEL_NGINX_CONTAINER" nginx -t >/dev/null 2>&1 || return 1
    else
        (cd "${DIR_NGINX}" && docker compose run --rm --no-deps --entrypoint nginx nginx -t >/dev/null 2>&1) || return 1
    fi

    (cd "${DIR_NGINX}" && docker compose up -d nginx >/dev/null 2>&1) || return 1
    docker exec "$BESZEL_NGINX_CONTAINER" nginx -s reload >/dev/null 2>&1
}

nginx_teardown() {
    local root="${DIR_NGINX%/}" project=""
    _beszel_nginx_is_managed || return 1
    if docker inspect "$BESZEL_NGINX_CONTAINER" >/dev/null 2>&1; then
        project=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' \
            "$BESZEL_NGINX_CONTAINER" 2>/dev/null || true)
        [ "$project" = beszel-proxy ] || return 1
    fi
    if [ -f "${DIR_NGINX}docker-compose.yml" ]; then
        (cd "${DIR_NGINX}" && docker compose down --remove-orphans >/dev/null 2>&1) || return 1
    fi
    case "$root" in */beszel-proxy) ;; *) return 1 ;; esac
    nginx_has_users && return 1
    rm -rf -- "$root"
}

nginx_ipv6_available() {
    if command -v ip >/dev/null 2>&1; then
        ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 '
        return $?
    fi
    [ -s /proc/net/if_inet6 ]
}
