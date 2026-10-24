# ═══════════════════════════════════════════════════════════════════════
# ОБНАРУЖЕНИЕ И УЧЁТ REVERSE PROXY
#
# Beszel может использовать собственный Nginx либо подключиться к уже
# работающему Caddy/Nginx. Существующие proxy-конфигурации изменяются только
# в ограниченном блоке Beszel и никогда не удаляются целиком.
# ═══════════════════════════════════════════════════════════════════════

BESZEL_PROXY_STATE_DIR="${BESZEL_PROXY_STATE_DIR:-/var/lib/beszel/proxy-apps}"
BESZEL_PROXY_STANDALONE_DIR="${BESZEL_PROXY_STANDALONE_DIR:-${DIR_NGINX:-/opt/beszel-proxy/}}"
BESZEL_PROXY_REMNAWAVE_DIR="${BESZEL_PROXY_REMNAWAVE_DIR:-/opt/remnawave/}"
BESZEL_PROXY_PREFLIGHT_ERROR=""

_beszel_proxy_mode_valid() {
    case "${1:-}" in standalone|caddy|nginx) return 0 ;; esac
    return 1
}

_beszel_proxy_app_valid() {
    [[ "${1:-}" =~ ^[a-z0-9][a-z0-9_-]{0,47}$ ]]
}

_beszel_component_root_valid() {
    [ -n "${1:-}" ] && [[ "$1" = /* ]] && [[ "$1" != *$'\n'* ]] && [[ "$1" != *$'\r'* ]]
}

beszel_component_marker_path() {
    _beszel_component_root_valid "${1:-}" || return 1
    printf '%s/.beszel\n' "${1%/}"
}

# Компонентный маркер отделяет созданные Manager файлы и контейнеры от
# сторонних установок в тех же стандартных каталогах. Он намеренно не
# наследует владение только по имени образа или контейнера.
beszel_component_mark() {
    local root="${1:-}" component="${2:-}" mode="${3:-}" marker tmp
    _beszel_component_root_valid "$root" || return 1
    _beszel_proxy_app_valid "$component" || return 1
    [ -z "$mode" ] || _beszel_proxy_mode_valid "$mode" || return 1
    mkdir -p "$root" || return 1
    marker=$(beszel_component_marker_path "$root") || return 1
    tmp=$(mktemp "${marker}.XXXXXX") || return 1
    {
        printf 'COMPONENT=%s\n' "$component"
        printf 'MANAGED_BY=beszel\n'
        [ -n "$mode" ] && printf 'PROXY_MODE=%s\n' "$mode"
    } > "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$marker"
}

beszel_component_compose_has_label() {
    local root="${1:-}" component="${2:-}" compose
    _beszel_component_root_valid "$root" || return 1
    _beszel_proxy_app_valid "$component" || return 1
    for compose in \
        "${root%/}/docker-compose.yml" "${root%/}/docker-compose.yaml" \
        "${root%/}/compose.yml" "${root%/}/compose.yaml"; do
        [ -f "$compose" ] || continue
        grep -Eq "com\\.beszel\\.component([=:][[:space:]]*|[[:space:]]*=[[:space:]]*)['\"]?${component}['\"]?([[:space:]]*$|[[:space:]]*#)" "$compose" && return 0
    done
    return 1
}

beszel_component_is_managed() {
    local root="${1:-}" component="${2:-}" marker marker_component marker_owner
    _beszel_component_root_valid "$root" || return 1
    _beszel_proxy_app_valid "$component" || return 1
    marker=$(beszel_component_marker_path "$root") || return 1
    if [ -f "$marker" ]; then
        marker_component=$(grep -m1 '^COMPONENT=' "$marker" 2>/dev/null | cut -d= -f2- | tr -d '\r\n')
        marker_owner=$(grep -m1 '^MANAGED_BY=' "$marker" 2>/dev/null | cut -d= -f2- | tr -d '\r\n')
        [ "$marker_component" = "$component" ] && [ "$marker_owner" = "beszel" ] && return 0
    fi
    beszel_component_compose_has_label "$root" "$component"
}

beszel_component_marker_get() {
    local root="${1:-}" key="${2:-}" marker value
    _beszel_component_root_valid "$root" || return 1
    case "$key" in
        COMPONENT|MANAGED_BY|PROXY_MODE|DOMAIN|NODE_PORT|INBOUND_PORT|INBOUND_UDP_PORTS) ;;
        *) return 1 ;;
    esac
    marker=$(beszel_component_marker_path "$root") || return 1
    [ -f "$marker" ] || return 1
    value=$(grep -m1 "^${key}=" "$marker" 2>/dev/null | cut -d= -f2- | tr -d '\r\n')
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

_beszel_proxy_state_file() {
    _beszel_proxy_app_valid "${1:-}" || return 1
    printf '%s/%s.env\n' "${BESZEL_PROXY_STATE_DIR%/}" "$1"
}

beszel_proxy_state_get() {
    local app="${1:-}" key="${2:-}" file value
    _beszel_proxy_app_valid "$app" || return 1
    case "$key" in
        PROXY_MODE|PROXY_OWNER|DOMAIN|CONFIG_PATH|COMPOSE_PATH|NETWORK) ;;
        *) return 1 ;;
    esac
    file=$(_beszel_proxy_state_file "$app") || return 1
    [ -f "$file" ] || return 1
    value=$(grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2- | tr -d '\r\n')
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

beszel_proxy_state_write() {
    local app="${1:-}" mode="${2:-}" owner="${3:-external}" domain="${4:-}"
    local config_path="${5:-}" compose_path="${6:-}" network="${7:-}"
    local file tmp
    _beszel_proxy_app_valid "$app" || return 1
    _beszel_proxy_mode_valid "$mode" || return 1
    case "$owner" in manager|external) ;; *) owner="external" ;; esac
    [[ "$domain" =~ ^[A-Za-z0-9.-]*$ ]] || return 1
    [[ "$config_path" != *$'\n'* && "$compose_path" != *$'\n'* && "$network" != *$'\n'* ]] || return 1
    mkdir -p "$BESZEL_PROXY_STATE_DIR"
    chmod 700 "$BESZEL_PROXY_STATE_DIR" 2>/dev/null || true
    file=$(_beszel_proxy_state_file "$app") || return 1
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    {
        printf 'PROXY_MODE=%s\n' "$mode"
        printf 'PROXY_OWNER=%s\n' "$owner"
        printf 'DOMAIN=%s\n' "$domain"
        printf 'CONFIG_PATH=%s\n' "$config_path"
        printf 'COMPOSE_PATH=%s\n' "$compose_path"
        printf 'NETWORK=%s\n' "$network"
    } > "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file"
}

beszel_proxy_state_remove() {
    local file
    file=$(_beszel_proxy_state_file "${1:-}") || return 0
    rm -f "$file" 2>/dev/null || true
}

beszel_proxy_config_path() {
    case "${1:-}" in
        standalone) printf '%snginx.conf\n' "${BESZEL_PROXY_STANDALONE_DIR%/}/" ;;
        caddy) printf '%scaddy/Caddyfile\n' "${BESZEL_PROXY_REMNAWAVE_DIR%/}/" ;;
        nginx) printf '%snginx/nginx.conf\n' "${BESZEL_PROXY_REMNAWAVE_DIR%/}/" ;;
        *) return 1 ;;
    esac
}

beszel_proxy_compose_path() {
    case "${1:-}" in
        standalone) printf '%sdocker-compose.yml\n' "${BESZEL_PROXY_STANDALONE_DIR%/}/" ;;
        caddy) printf '%scaddy/docker-compose.yml\n' "${BESZEL_PROXY_REMNAWAVE_DIR%/}/" ;;
        nginx) printf '%snginx/docker-compose.yml\n' "${BESZEL_PROXY_REMNAWAVE_DIR%/}/" ;;
        *) return 1 ;;
    esac
}

_beszel_proxy_mode_present() {
    local mode="${1:-}" config compose
    config=$(beszel_proxy_config_path "$mode" 2>/dev/null) || return 1
    compose=$(beszel_proxy_compose_path "$mode" 2>/dev/null) || return 1
    [ -s "$config" ] && [ -s "$compose" ]
}

_beszel_proxy_compose_running() {
    local compose="${1:-}" dir ids id
    [ -s "$compose" ] || return 1
    command -v docker >/dev/null 2>&1 || return 1
    dir=$(dirname "$compose")
    ids=$(cd "$dir" 2>/dev/null && docker compose -f "$compose" ps -q 2>/dev/null) || return 1
    [ -n "$ids" ] || return 1
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        [ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null)" = "true" ] && return 0
    done <<< "$ids"
    return 1
}

_beszel_proxy_mode_running() {
    local compose
    compose=$(beszel_proxy_compose_path "${1:-}" 2>/dev/null) || return 1
    _beszel_proxy_compose_running "$compose"
}

# Печатает standalone/caddy/nginx. Возвраты: 0 — найдено, 1 — не найдено,
# 2 — обнаружено несколько несовместимых конфигураций и нельзя выбрать.
beszel_proxy_detect() {
    local app="${1:-}" mode saved
    local -a present=() running=()

    if _beszel_proxy_app_valid "$app"; then
        saved=$(beszel_proxy_state_get "$app" PROXY_MODE 2>/dev/null || true)
        if _beszel_proxy_mode_valid "$saved" && _beszel_proxy_mode_present "$saved"; then
            printf '%s\n' "$saved"
            return 0
        fi
    fi

    mode="${BESZEL_REVERSE_PROXY_MODE:-}"
    if _beszel_proxy_mode_valid "$mode" && _beszel_proxy_mode_present "$mode"; then
        printf '%s\n' "$mode"
        return 0
    fi

    # Prefer the configured Caddy/Nginx when the Hub uses its Docker network.
    for mode in caddy nginx; do
        _beszel_proxy_mode_present "$mode" && present+=("$mode")
    done
    if [ "${#present[@]}" -eq 1 ]; then
        printf '%s\n' "${present[0]}"
        return 0
    fi
    if [ "${#present[@]}" -gt 1 ]; then
        for mode in "${present[@]}"; do
            _beszel_proxy_mode_running "$mode" && running+=("$mode")
        done
        if [ "${#running[@]}" -eq 1 ]; then
            printf '%s\n' "${running[0]}"
            return 0
        fi
        return 2
    fi

    _beszel_proxy_mode_present standalone || return 1
    printf 'standalone\n'
}

# При отсутствии reverse proxy Beszel может создать собственный Nginx.
# Несколько найденных схем всегда требуют
# явного выбора: угадывать в такой ситуации небезопасно.
beszel_proxy_resolve_for_install() {
    local app="${1:-}" mode rc
    mode=$(beszel_proxy_detect "$app" 2>/dev/null)
    rc=$?
    case "$rc" in
        0) printf '%s\n' "$mode" ;;
        1) printf 'standalone\n' ;;
        *) return 2 ;;
    esac
}

# Проверяет выбранную схему до изменения файлов приложения. Для чистого
# сервера разрешено создать автономный Nginx; найденная схема должна
# быть целой, иметь валидный compose и (для официальных вариантов) общую
# сеть Remnawave.
beszel_proxy_preflight() {
    local mode="${1:-}" allow_create="${2:-false}" config compose
    BESZEL_PROXY_PREFLIGHT_ERROR=""
    _beszel_proxy_mode_valid "$mode" || {
        BESZEL_PROXY_PREFLIGHT_ERROR="Неизвестный вариант reverse proxy."
        return 1
    }
    config=$(beszel_proxy_config_path "$mode" 2>/dev/null) || return 1
    compose=$(beszel_proxy_compose_path "$mode" 2>/dev/null) || return 1

    if [ ! -e "$config" ] && [ ! -e "$compose" ] && \
       [ "$mode" = "standalone" ] && [ "$allow_create" = "true" ]; then
        local _port
        for _port in 80 443; do
            local _port_busy=false
            if command -v ss >/dev/null 2>&1; then
                ss -H -ltn "sport = :${_port}" 2>/dev/null | grep -q . && _port_busy=true
            elif command -v fuser >/dev/null 2>&1; then
                fuser -s "${_port}/tcp" >/dev/null 2>&1 && _port_busy=true
            fi
            if [ "$_port_busy" = true ]; then
                BESZEL_PROXY_PREFLIGHT_ERROR="Порт ${_port} уже занят. Автономный Nginx Beszel не будет менять или останавливать стороннюю службу."
                return 1
            fi
        done
        if command -v docker >/dev/null 2>&1 && docker inspect beszel-proxy >/dev/null 2>&1; then
            local _project
            _project=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' beszel-proxy 2>/dev/null || true)
            if [ "$_project" != beszel-proxy ]; then
                BESZEL_PROXY_PREFLIGHT_ERROR="Контейнер beszel-proxy уже существует и принадлежит другой установке."
                return 1
            fi
        fi
        return 0
    fi
    if [ ! -s "$config" ] || [ ! -s "$compose" ]; then
        BESZEL_PROXY_PREFLIGHT_ERROR="Конфигурация $(beszel_proxy_mode_label "$mode") неполная: нужны и конфиг, и docker-compose.yml."
        return 1
    fi
    if ! command -v docker >/dev/null 2>&1; then
        BESZEL_PROXY_PREFLIGHT_ERROR="Docker не найден, хотя конфигурация reverse proxy уже существует."
        return 1
    fi
    if ! docker compose -f "$compose" config >/dev/null 2>&1; then
        BESZEL_PROXY_PREFLIGHT_ERROR="docker-compose.yml выбранного reverse proxy содержит ошибку."
        return 1
    fi
    case "$mode" in
        caddy|nginx)
            if ! grep -q 'remnawave-network' "$compose" 2>/dev/null; then
                BESZEL_PROXY_PREFLIGHT_ERROR="Reverse proxy не подключён к сети remnawave-network."
                return 1
            fi
            if ! docker network inspect remnawave-network >/dev/null 2>&1; then
                BESZEL_PROXY_PREFLIGHT_ERROR="Сеть remnawave-network не найдена. Подключите выбранный reverse proxy к сети хаба."
                return 1
            fi
            ;;
    esac
    return 0
}

beszel_proxy_owner() {
    local mode="${1:-}" marker
    case "$mode" in
        standalone) printf 'manager\n'; return 0 ;;
        caddy|nginx)
            if beszel_component_is_managed "${BESZEL_PROXY_REMNAWAVE_DIR%/}" remnawave || \
               beszel_component_compose_has_label "${BESZEL_PROXY_REMNAWAVE_DIR%/}/${mode}" remnawave-proxy; then
                printf 'manager\n'
                return 0
            fi
            printf 'external\n'
            return 0
            ;;
    esac
    return 1
}

beszel_proxy_mode_label() {
    case "${1:-}" in
        caddy) printf 'официальный Caddy Remnawave\n' ;;
        nginx) printf 'официальный Nginx Remnawave\n' ;;
        standalone) printf 'Автономный Nginx Beszel\n' ;;
        *) printf 'не определён\n' ;;
    esac
}

# Короткое название для строк мастера установки. Технические описания выше
# остаются подробными для диагностических сообщений.
beszel_proxy_install_variant_label() {
    case "${1:-}" in
        caddy) printf 'Стандартный Caddy\n' ;;
        nginx) printf 'Стандартный Nginx\n' ;;
        standalone) printf 'Автономный Nginx Beszel\n' ;;
        *) printf 'Не определён\n' ;;
    esac
}

beszel_proxy_network_gateway() {
    local network="${1:-remnawave-network}" gateway
    command -v docker >/dev/null 2>&1 || return 1
    gateway=$(docker network inspect "$network" \
        --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null | head -1 | tr -d '[:space:]')
    [[ "$gateway" =~ ^[0-9]+.[0-9]+.[0-9]+.[0-9]+$ ]] || return 1
    printf '%s\n' "$gateway"
}

_beszel_proxy_compose_service() {
    local compose="${1:-}" dir service
    [ -s "$compose" ] || return 1
    dir=$(dirname "$compose")
    service=$(cd "$dir" 2>/dev/null && docker compose -f "$compose" config --services 2>/dev/null | head -1)
    [ -n "$service" ] || return 1
    printf '%s\n' "$service"
}

_beszel_proxy_container_id() {
    local compose="${1:-}" service dir id
    service=$(_beszel_proxy_compose_service "$compose") || return 1
    dir=$(dirname "$compose")
    id=$(cd "$dir" 2>/dev/null && docker compose -f "$compose" ps -q "$service" 2>/dev/null | head -1)
    [ -n "$id" ] || return 1
    printf '%s\n' "$id"
}

beszel_proxy_reload() {
    local mode="${1:-}" compose service id dir
    compose=$(beszel_proxy_compose_path "$mode" 2>/dev/null) || return 1
    service=$(_beszel_proxy_compose_service "$compose") || return 1
    dir=$(dirname "$compose")
    case "$mode" in
        caddy)
            (cd "$dir" && docker compose -f "$compose" run --rm --no-deps "$service" \
                validate --config /etc/caddy/Caddyfile >/dev/null 2>&1) || return 1
            (cd "$dir" && docker compose -f "$compose" up -d "$service" >/dev/null 2>&1) || return 1
            id=$(_beszel_proxy_container_id "$compose") || return 1
            docker exec "$id" caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1
            ;;
        nginx)
            (cd "$dir" && docker compose -f "$compose" run --rm --no-deps "$service" \
                nginx -t >/dev/null 2>&1) || return 1
            (cd "$dir" && docker compose -f "$compose" up -d "$service" >/dev/null 2>&1) || return 1
            id=$(_beszel_proxy_container_id "$compose") || return 1
            docker exec "$id" nginx -s reload >/dev/null 2>&1
            ;;
        standalone)
            if declare -F nginx_reload >/dev/null 2>&1; then nginx_reload; else return 1; fi
            ;;
        *) return 1 ;;
    esac
}

_beszel_proxy_marker_token() {
    printf '%s_%s' "${1:-APP}" "${2:-DOMAIN}" | tr '[:lower:].-' '[:upper:]__' | tr -cd 'A-Z0-9_'
}

_beszel_proxy_remove_marked_block() {
    local file="${1:-}" begin="${2:-}" end="${3:-}" tmp
    [ -f "$file" ] || return 0
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod --reference="$file" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file"
}

# Транзакционно добавляет полностью сформированный Caddy-блок.
beszel_proxy_caddy_apply_block() {
    local app="${1:-}" domain="${2:-}" block="${3:-}" config compose owner token begin end backup old_domain old_token
    _beszel_proxy_app_valid "$app" || return 1
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    config=$(beszel_proxy_config_path caddy) || return 1
    compose=$(beszel_proxy_compose_path caddy) || return 1
    [ -s "$config" ] && [ -s "$compose" ] || return 1
    token=$(_beszel_proxy_marker_token "$app" "$domain")
    begin="# BEGIN_BESZEL_${token}"
    end="# END_BESZEL_${token}"
    backup=$(mktemp) || return 1
    cp -f "$config" "$backup" || { rm -f "$backup"; return 1; }
    old_domain=$(beszel_proxy_state_get "$app" DOMAIN 2>/dev/null || true)
    if [ -n "$old_domain" ] && [ "$old_domain" != "$domain" ]; then
        old_token=$(_beszel_proxy_marker_token "$app" "$old_domain")
        _beszel_proxy_remove_marked_block "$config" "# BEGIN_BESZEL_${old_token}" "# END_BESZEL_${old_token}" || {
            cp -f "$backup" "$config"; rm -f "$backup"; return 1;
        }
    fi
    _beszel_proxy_remove_marked_block "$config" "$begin" "$end" || {
        cp -f "$backup" "$config"; rm -f "$backup"; return 1;
    }
    if grep -Eq "^[[:space:]]*(https://)?${domain//./\\.}[[:space:]]*\\{" "$config" 2>/dev/null; then
        cp -f "$backup" "$config"
        rm -f "$backup"
        return 2
    fi
    {
        printf '\n%s\n' "$begin"
        printf '%s\n' "$block"
        printf '%s\n' "$end"
    } >> "$config"
    if ! beszel_proxy_reload caddy; then
        cp -f "$backup" "$config"
        beszel_proxy_reload caddy >/dev/null 2>&1 || true
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
    owner=$(beszel_proxy_owner caddy)
    beszel_proxy_state_write "$app" caddy "$owner" "$domain" "$config" "$compose" remnawave-network
}

beszel_proxy_caddy_remove_block() {
    local app="${1:-}" domain="${2:-}" config token begin end backup
    [ -n "$domain" ] || domain=$(beszel_proxy_state_get "$app" DOMAIN 2>/dev/null || true)
    _beszel_proxy_app_valid "$app" || return 0
    [ -n "$domain" ] || { beszel_proxy_state_remove "$app"; return 0; }
    config=$(beszel_proxy_config_path caddy 2>/dev/null) || return 0
    [ -f "$config" ] || { beszel_proxy_state_remove "$app"; return 0; }
    token=$(_beszel_proxy_marker_token "$app" "$domain")
    begin="# BEGIN_BESZEL_${token}"
    end="# END_BESZEL_${token}"
    backup=$(mktemp) || return 1
    cp -f "$config" "$backup" || { rm -f "$backup"; return 1; }
    _beszel_proxy_remove_marked_block "$config" "$begin" "$end" || { rm -f "$backup"; return 1; }
    if ! beszel_proxy_reload caddy; then
        cp -f "$backup" "$config"
        beszel_proxy_reload caddy >/dev/null 2>&1 || true
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
    beszel_proxy_state_remove "$app"
}

beszel_proxy_nginx_ensure_ssl_mount() {
    local compose service_line="      - ./beszel-app-ssl:/etc/nginx/beszel-app-ssl:ro" tmp
    compose=$(beszel_proxy_compose_path nginx) || return 1
    [ -s "$compose" ] || return 1
    grep -qF './beszel-app-ssl:/etc/nginx/beszel-app-ssl:ro' "$compose" 2>/dev/null && return 0
    tmp=$(mktemp) || return 1
    awk -v mount="$service_line" '
        { print }
        !done && /^[[:space:]]*-[[:space:]]+.*nginx\.conf:.*nginx.*conf/ { print mount; done=1 }
        END { if (!done) exit 42 }
    ' "$compose" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod --reference="$compose" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$compose"
}

_beszel_proxy_nginx_acme_ufw_cleanup() {
    if [ "${BESZEL_PROXY_NGINX_ACME_UFW_ADDED:-false}" = true ]; then
        beszel_ufw_remove_rules_by_comment "Beszel ACME TLS-ALPN" 8443 || true
        BESZEL_PROXY_NGINX_ACME_UFW_ADDED=false
    fi
}

beszel_proxy_nginx_issue_certificate() {
    local app="${1:-}" domain="${2:-}" email="${3:-admin@localhost}" root cert_dir acme_sh compose service
    local _ufw_rule_added=false _issue_rc
    _beszel_proxy_app_valid "$app" || return 1
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    root="${BESZEL_PROXY_REMNAWAVE_DIR%/}/nginx/beszel-app-ssl"
    cert_dir="${root}/${app}/${domain}"
    mkdir -p "$cert_dir"
    if [ -s "${cert_dir}/fullchain.pem" ] && [ -s "${cert_dir}/privkey.pem" ] && \
       openssl x509 -checkend 2592000 -noout -in "${cert_dir}/fullchain.pem" >/dev/null 2>&1; then
        beszel_proxy_nginx_ensure_ssl_mount
        return $?
    fi
    acme_sh="${HOME:-/root}/.acme.sh/acme.sh"
    if [ ! -x "$acme_sh" ]; then
        local installer
        installer=$(mktemp) || return 1
        curl -fsSL --connect-timeout 20 --max-time 120 https://get.acme.sh -o "$installer" || { rm -f "$installer"; return 1; }
        sh "$installer" email="$email" >/dev/null 2>&1 || { rm -f "$installer"; return 1; }
        rm -f "$installer"
    fi
    if command -v ufw >/dev/null 2>&1 && \
       [ "$(ufw status 2>/dev/null | sed -n '1p')" = "Status: active" ] && \
       ! beszel_ufw_has_allow_tcp 8443; then
        beszel_ufw_allow_tcp 8443 "Beszel ACME TLS-ALPN" || return 1
        _ufw_rule_added=true
        BESZEL_PROXY_NGINX_ACME_UFW_ADDED=true
        trap '_beszel_proxy_nginx_acme_ufw_cleanup' EXIT
    fi
    "$acme_sh" --issue --standalone --alpn --tlsport 8443 --server letsencrypt -d "$domain" >/dev/null 2>&1
    _issue_rc=$?
    if [ "$_ufw_rule_added" = true ]; then
        _beszel_proxy_nginx_acme_ufw_cleanup
        trap - EXIT
    fi
    [ "$_issue_rc" -eq 0 ] || return 1
    compose=$(beszel_proxy_compose_path nginx) || return 1
    service=$(_beszel_proxy_compose_service "$compose") || return 1
    "$acme_sh" --install-cert -d "$domain" \
        --key-file "${cert_dir}/privkey.pem" \
        --fullchain-file "${cert_dir}/fullchain.pem" \
        --reloadcmd "docker compose -f ${compose} exec -T ${service} nginx -s reload >/dev/null 2>&1 || true" \
        >/dev/null 2>&1 || return 1
    chmod 600 "${cert_dir}/privkey.pem" 2>/dev/null || true
    beszel_proxy_nginx_ensure_ssl_mount
}

# Транзакционно добавляет полностью сформированный Nginx server-блок.
beszel_proxy_nginx_apply_block() {
    local app="${1:-}" domain="${2:-}" block="${3:-}" config compose owner token begin end backup compose_backup old_domain old_token
    _beszel_proxy_app_valid "$app" || return 1
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    config=$(beszel_proxy_config_path nginx) || return 1
    compose=$(beszel_proxy_compose_path nginx) || return 1
    [ -s "$config" ] && [ -s "$compose" ] || return 1
    token=$(_beszel_proxy_marker_token "$app" "$domain")
    begin="# BEGIN_BESZEL_${token}"
    end="# END_BESZEL_${token}"
    backup=$(mktemp) || return 1
    compose_backup=$(mktemp) || { rm -f "$backup"; return 1; }
    cp -f "$config" "$backup" && cp -f "$compose" "$compose_backup" || { rm -f "$backup" "$compose_backup"; return 1; }
    old_domain=$(beszel_proxy_state_get "$app" DOMAIN 2>/dev/null || true)
    if [ -n "$old_domain" ] && [ "$old_domain" != "$domain" ]; then
        old_token=$(_beszel_proxy_marker_token "$app" "$old_domain")
        _beszel_proxy_remove_marked_block "$config" "# BEGIN_BESZEL_${old_token}" "# END_BESZEL_${old_token}" || {
            cp -f "$backup" "$config"; rm -f "$backup" "$compose_backup"; return 1;
        }
    fi
    _beszel_proxy_remove_marked_block "$config" "$begin" "$end" || {
        cp -f "$backup" "$config"; cp -f "$compose_backup" "$compose"; rm -f "$backup" "$compose_backup"; return 1;
    }
    if grep -Eq "server_name[[:space:]]+${domain//./\\.}([[:space:];]|$)" "$config" 2>/dev/null; then
        cp -f "$backup" "$config"
        rm -f "$backup" "$compose_backup"
        return 2
    fi
    beszel_proxy_nginx_ensure_ssl_mount || { cp -f "$backup" "$config"; cp -f "$compose_backup" "$compose"; rm -f "$backup" "$compose_backup"; return 1; }
    {
        printf '\n%s\n' "$begin"
        printf '%s\n' "$block"
        printf '%s\n' "$end"
    } >> "$config"
    if ! beszel_proxy_reload nginx; then
        cp -f "$backup" "$config"
        cp -f "$compose_backup" "$compose"
        beszel_proxy_reload nginx >/dev/null 2>&1 || true
        rm -f "$backup" "$compose_backup"
        return 1
    fi
    rm -f "$backup" "$compose_backup"
    owner=$(beszel_proxy_owner nginx)
    beszel_proxy_state_write "$app" nginx "$owner" "$domain" "$config" "$compose" remnawave-network
}

beszel_proxy_nginx_remove_block() {
    local app="${1:-}" domain="${2:-}" config token begin end backup
    [ -n "$domain" ] || domain=$(beszel_proxy_state_get "$app" DOMAIN 2>/dev/null || true)
    _beszel_proxy_app_valid "$app" || return 0
    [ -n "$domain" ] || { beszel_proxy_state_remove "$app"; return 0; }
    config=$(beszel_proxy_config_path nginx 2>/dev/null) || return 0
    [ -f "$config" ] || { beszel_proxy_state_remove "$app"; return 0; }
    token=$(_beszel_proxy_marker_token "$app" "$domain")
    begin="# BEGIN_BESZEL_${token}"
    end="# END_BESZEL_${token}"
    backup=$(mktemp) || return 1
    cp -f "$config" "$backup" || { rm -f "$backup"; return 1; }
    _beszel_proxy_remove_marked_block "$config" "$begin" "$end" || { rm -f "$backup"; return 1; }
    if ! beszel_proxy_reload nginx; then
        cp -f "$backup" "$config"
        beszel_proxy_reload nginx >/dev/null 2>&1 || true
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
    rm -rf "${BESZEL_PROXY_REMNAWAVE_DIR%/}/nginx/beszel-app-ssl/${app}" 2>/dev/null || true
    beszel_proxy_state_remove "$app"
}

beszel_proxy_remove_app() {
    local app="${1:-}" mode domain
    mode=$(beszel_proxy_state_get "$app" PROXY_MODE 2>/dev/null || true)
    domain=$(beszel_proxy_state_get "$app" DOMAIN 2>/dev/null || true)
    case "$mode" in
        caddy) beszel_proxy_caddy_remove_block "$app" "$domain" ;;
        nginx) beszel_proxy_nginx_remove_block "$app" "$domain" ;;
        *) beszel_proxy_state_remove "$app" ;;
    esac
}
