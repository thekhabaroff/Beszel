#!/bin/sh
# Sync renewed certificates into the Beszel-owned proxy directory.

set -eu

SSL_DIR="${BESZEL_SSL_DIR:-/opt/beszel-proxy/ssl}"
LE_DIR="${BESZEL_LE_LIVE_DIR:-/etc/letsencrypt/live}"
NGINX_DIR="${BESZEL_NGINX_DIR:-/opt/beszel-proxy}"
NGINX_CONTAINER="beszel-proxy"

[ -f "${NGINX_DIR}/.beszel-proxy" ] || exit 0
grep -qx 'MANAGED_BY=beszel' "${NGINX_DIR}/.beszel-proxy" 2>/dev/null || exit 0

[ -d "$SSL_DIR" ] || exit 0
[ -d "$LE_DIR" ] || exit 0

lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

base_domain() {
    domain="$1"
    parts=$(printf '%s' "$domain" | awk -F. '{print NF}')
    if [ "$parts" -gt 2 ]; then
        printf '%s' "$domain" | awk -F. '{print $(NF-1)"."$NF}'
    else
        printf '%s' "$domain"
    fi
}

cert_matches_domain() {
    cert="$1"
    domain="$(lower "$2")"
    base="$(base_domain "$domain")"
    sans=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
    printf '%s' "$sans" | grep -q "dns:${domain}\\>" && return 0
    printf '%s' "$sans" | grep -q "dns:\\*\\.${base}\\>" && return 0
    return 1
}

find_lineage() {
    domain="$1"
    domain_l="$(lower "$domain")"
    base_l="$(base_domain "$domain_l")"

    for candidate in "$domain" "$domain_l" "$base_l"; do
        if [ -f "$LE_DIR/$candidate/fullchain.pem" ] && [ -f "$LE_DIR/$candidate/privkey.pem" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    for dir in "$LE_DIR"/*; do
        [ -d "$dir" ] || continue
        [ -f "$dir/fullchain.pem" ] || continue
        [ -f "$dir/privkey.pem" ] || continue
        if cert_matches_domain "$dir/fullchain.pem" "$domain_l"; then
            basename "$dir"
            return 0
        fi
    done

    return 1
}

changed=0

for dst in "$SSL_DIR"/*; do
    [ -d "$dst" ] || continue
    domain="$(basename "$dst")"
    lineage="$(find_lineage "$domain" 2>/dev/null || true)"
    [ -n "$lineage" ] || continue

    src="$LE_DIR/$lineage"
    tmp_full="$dst/fullchain.pem.tmp"
    tmp_key="$dst/privkey.pem.tmp"

    cp -fL "$src/fullchain.pem" "$tmp_full" || continue
    cp -fL "$src/privkey.pem" "$tmp_key" || {
        rm -f "$tmp_full"
        continue
    }
    chmod 644 "$tmp_full" 2>/dev/null || true
    chmod 600 "$tmp_key" 2>/dev/null || true

    if ! cmp -s "$tmp_full" "$dst/fullchain.pem" 2>/dev/null || \
       ! cmp -s "$tmp_key" "$dst/privkey.pem" 2>/dev/null; then
        mv -f "$tmp_full" "$dst/fullchain.pem"
        mv -f "$tmp_key" "$dst/privkey.pem"
        changed=1
    else
        rm -f "$tmp_full" "$tmp_key"
    fi
done

if [ "$changed" -eq 1 ] && [ -f "$NGINX_DIR/docker-compose.yml" ]; then
    # During standalone renewal the pre-hook deliberately stops Nginx. The
    # post-hook starts it after this deploy hook, so a second restart here
    # would only add downtime. For DNS renewals Nginx may still be running and
    # can reload the renewed files in place.
    if [ "$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$NGINX_CONTAINER" 2>/dev/null || true)" = "beszel-proxy" ] && \
       [ "$(docker inspect -f '{{.State.Running}}' "$NGINX_CONTAINER" 2>/dev/null || true)" = "true" ]; then
        docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null 2>&1 || \
            (cd "$NGINX_DIR" && docker compose restart nginx >/dev/null 2>&1) || true
    fi
fi

exit 0
