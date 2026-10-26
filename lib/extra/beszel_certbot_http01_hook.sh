#!/usr/bin/env bash
# Certbot HTTP-01 lifecycle hook for the Beszel-owned Nginx.
#
# pre:  remember the current Nginx/firewall state, temporarily free and open
#       port 80, then make sure Certbot can bind it.
# post: restore exactly the state that existed before pre.

set -u

STATE_DIR="${BESZEL_HTTP01_STATE_DIR:-/run/beszel-certbot-http01}"
NGINX_DIR="${BESZEL_NGINX_DIR:-/opt/beszel-proxy}"
LE_DIR="${BESZEL_LETSENCRYPT_DIR:-/etc/letsencrypt}"
NGINX_CONTAINER="beszel-proxy"

_http01_port_is_busy() {
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn 'sport = :80' 2>/dev/null | grep -q .
        return $?
    fi
    if command -v fuser >/dev/null 2>&1; then
        fuser -s 80/tcp >/dev/null 2>&1
        return $?
    fi
    return 1
}

_http01_nginx_is_running() {
    [ -f "$NGINX_DIR/.beszel-proxy" ] || return 1
    grep -qx 'MANAGED_BY=beszel' "$NGINX_DIR/.beszel-proxy" 2>/dev/null || return 1
    command -v docker >/dev/null 2>&1 || return 1
    [ "$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$NGINX_CONTAINER" 2>/dev/null || true)" = beszel-proxy ] || return 1
    [ "$(docker inspect -f '{{.State.Running}}' "$NGINX_CONTAINER" 2>/dev/null || true)" = "true" ]
}

# Certbot's directory pre/post hooks run for unrelated certificate renewals
# too. Stop this proxy only when one of its own HTTP-01 certificates is due.
_http01_beszel_http_cert_due() {
    local cert_dir lineage renewal_file port
    for cert_dir in "$NGINX_DIR"/ssl/*; do
        [ -d "$cert_dir" ] && [ -s "$cert_dir/fullchain.pem" ] || continue
        lineage="${cert_dir##*/}"
        renewal_file="$LE_DIR/renewal/${lineage}.conf"
        [ -f "$renewal_file" ] || continue
        grep -Eq '^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*standalone[[:space:]]*$' \
            "$renewal_file" || continue
        port=$(awk -F= 'tolower($1) ~ /^[[:space:]]*http01_port[[:space:]]*$/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' \
            "$renewal_file")
        [ -z "$port" ] || [ "$port" = 80 ] || continue
        if ! openssl x509 -in "$cert_dir/fullchain.pem" -noout -checkend 2592000 >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

_http01_stop_nginx() {
    [ -f "$NGINX_DIR/docker-compose.yml" ] && _http01_nginx_is_running || return 1
    (cd "$NGINX_DIR" && docker compose stop nginx >/dev/null 2>&1) || \
        docker stop "$NGINX_CONTAINER" >/dev/null 2>&1
}

_http01_start_nginx() {
    [ -f "$NGINX_DIR/.beszel-proxy" ] && \
        grep -qx 'MANAGED_BY=beszel' "$NGINX_DIR/.beszel-proxy" 2>/dev/null || return 1
    [ -f "$NGINX_DIR/docker-compose.yml" ] || return 1
    (cd "$NGINX_DIR" && docker compose up -d nginx >/dev/null 2>&1)
}

_http01_ufw_is_active() {
    command -v ufw >/dev/null 2>&1 || return 1
    LC_ALL=C ufw status 2>/dev/null | head -1 | grep -Eqi '^Status:[[:space:]]+active([[:space:]]|$)'
}

_http01_ufw_has_allow() {
    LC_ALL=C ufw status numbered 2>/dev/null | grep -Eqi \
        '80(/tcp|[[:space:]]+TCP)([[:space:]]|$).*ALLOW'
}

_http01_open_firewall() {
    if _http01_ufw_is_active && ! _http01_ufw_has_allow; then
        if ufw allow 80/tcp comment 'beszel-certbot-http01' >/dev/null 2>&1; then
            : > "$STATE_DIR/ufw-added"
        elif ufw allow 80/tcp >/dev/null 2>&1; then
            : > "$STATE_DIR/ufw-plain-added"
        fi
        ufw reload >/dev/null 2>&1 || true
    fi

    if command -v iptables >/dev/null 2>&1 && \
       ! iptables -C INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1; then
        if iptables -I INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1; then
            : > "$STATE_DIR/iptables-added"
        fi
    fi
}

_http01_close_firewall() {
    if [ -f "$STATE_DIR/iptables-added" ] && command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || true
    fi

    if [ -f "$STATE_DIR/ufw-added" ] && command -v ufw >/dev/null 2>&1; then
        local line number
        local -a numbers=()
        while IFS= read -r line; do
            printf '%s\n' "$line" | grep -qF 'beszel-certbot-http01' || continue
            number=$(printf '%s\n' "$line" | grep -oP '^\[\s*\K\d+(?=\])' 2>/dev/null || true)
            [ -n "$number" ] && numbers+=("$number")
        done < <(LC_ALL=C ufw status numbered 2>/dev/null || true)
        local i
        for ((i=${#numbers[@]}-1; i>=0; i--)); do
            printf 'y\n' | ufw delete "${numbers[$i]}" >/dev/null 2>&1 || true
        done
        ufw reload >/dev/null 2>&1 || true
    elif [ -f "$STATE_DIR/ufw-plain-added" ] && command -v ufw >/dev/null 2>&1; then
        ufw delete allow 80/tcp >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
    fi
}

_http01_restore() {
    [ -d "$STATE_DIR" ] || return 0
    _http01_close_firewall
    if [ -f "$STATE_DIR/nginx-was-running" ]; then
        _http01_start_nginx || true
    fi
    rm -rf "$STATE_DIR"
}

_http01_prepare() {
    # Recover from an interrupted previous attempt before creating fresh state.
    if [ -d "$STATE_DIR" ]; then
        _http01_restore
    fi

    if [ "${BESZEL_HTTP01_FORCE_STOP:-0}" != 1 ] && ! _http01_beszel_http_cert_due; then
        return 0
    fi

    mkdir -p "$STATE_DIR"

    if _http01_nginx_is_running; then
        : > "$STATE_DIR/nginx-was-running"
        if ! _http01_stop_nginx; then
            printf '%s\n' 'Не удалось временно остановить Nginx Beszel.' >&2
            _http01_restore
            return 1
        fi
    fi

    if _http01_port_is_busy; then
        printf '%s\n' 'Порт 80 занят другим процессом после остановки Nginx Beszel.' >&2
        _http01_restore
        return 1
    fi

    _http01_open_firewall
    sleep "${BESZEL_HTTP01_FIREWALL_DELAY:-1}"
    return 0
}

case "${1:-}" in
    pre)  _http01_prepare ;;
    post) _http01_restore ;;
    *)
        printf 'Использование: %s pre|post\n' "${0##*/}" >&2
        exit 2
        ;;
esac
