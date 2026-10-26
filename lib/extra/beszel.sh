# ═══════════════════════════════════════════════════
# BESZEL — МОНИТОРИНГ СЕРВЕРА
# ═══════════════════════════════════════════════════

# Tests and embedded callers may override these paths before sourcing this
# module. Keep production defaults without replacing an explicit sandbox path.
DIR_BESZEL="${DIR_BESZEL:-/opt/beszel-hub/}"
DIR_BESZEL_AGENT="${DIR_BESZEL_AGENT:-/opt/beszel-agent/}"

_beszel_valid_host() {
    local host="${1,,}" label octet value
    local -a parts=()
    [ -n "$host" ] && [ "${#host}" -le 253 ] || return 1
    [[ "$host" != *$'\n'* && "$host" != *$'\r'* && "$host" != *$' '* ]] || return 1

    if [[ "$host" =~ ^[0-9.]+$ ]]; then
        IFS='.' read -r -a parts <<< "$host"
        [ "${#parts[@]}" -eq 4 ] || return 1
        for octet in "${parts[@]}"; do
            [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
            value=$((10#$octet))
            [ "$value" -le 255 ] || return 1
        done
        return 0
    fi

    [[ "$host" =~ ^[A-Za-z0-9.-]+$ && "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
    IFS='.' read -r -a parts <<< "$host"
    for label in "${parts[@]}"; do
        [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
    return 0
}

_beszel_normalize_hub_url() {
    local url="${1:-}" scheme host port
    [[ "$url" == http://* || "$url" == https://* ]] || url="https://${url}"
    [[ "$url" =~ ^(https?)://([A-Za-z0-9.-]+)(:([0-9]{1,5}))?/?$ ]] || return 1
    scheme="${BASH_REMATCH[1]}"
    host="${BASH_REMATCH[2],,}"
    port="${BASH_REMATCH[4]}"
    _beszel_valid_host "$host" || return 1
    if [ -n "$port" ]; then
        [ "$((10#$port))" -ge 1 ] && [ "$((10#$port))" -le 65535 ] || return 1
        port=":$((10#$port))"
    fi
    printf '%s://%s%s\n' "$scheme" "$host" "$port"
}

_beszel_resolve_hub_ips() {
    local hub_url="${1:-}" normalized host
    normalized=$(_beszel_normalize_hub_url "$hub_url") || return 1
    host="${normalized#*://}"
    host="${host%%:*}"

    if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        printf '%s\n' "$host"
        return 0
    fi

    command -v getent >/dev/null 2>&1 || return 1
    getent ahosts "$host" 2>/dev/null | awk 'NF && $1 ~ /^[0-9A-Fa-f:.]+$/ { print $1 }' | sort -u
}

_beszel_generate_self_signed_cert() {
    local host="${1:-}" output_dir="${2:-}" cfg rc
    _beszel_valid_host "$host" || return 1
    [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
    [ -d "$output_dir" ] || return 1
    cfg=$(mktemp) || return 1
    {
        printf '[req]\ndistinguished_name = req_dn\nx509_extensions = v3_req\nprompt = no\n\n'
        printf '[req_dn]\nCN = %s\n\n[v3_req]\nsubjectAltName = IP:%s\n' "$host" "$host"
    } > "$cfg" || { rm -f "$cfg"; return 1; }
    openssl req -x509 -nodes -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${output_dir}/privkey.pem" \
        -out "${output_dir}/fullchain.pem" \
        -config "$cfg" >/dev/null 2>&1
    rc=$?
    rm -f "$cfg"
    [ "$rc" -eq 0 ] && [ -s "${output_dir}/fullchain.pem" ] && [ -s "${output_dir}/privkey.pem" ] || {
        rm -f "${output_dir}/fullchain.pem" "${output_dir}/privkey.pem"
        return 1
    }
    chmod 600 "${output_dir}/privkey.pem"
}

_beszel_copy_cert() {
    local source_chain="${1:-}" source_key="${2:-}" destination="${3:-}"
    local staging
    [ -s "$source_chain" ] && [ -s "$source_key" ] || return 1
    [ -n "$destination" ] || return 1
    case "${destination%/}" in
        "${DIR_NGINX%/}"/ssl/*) _beszel_nginx_claim_directory || return 1 ;;
    esac
    mkdir -p "$destination" || return 1
    staging=$(mktemp -d "${destination}/.beszel-cert.XXXXXX") || return 1
    if ! cp -fL "$source_chain" "${staging}/fullchain.pem" || \
       ! cp -fL "$source_key" "${staging}/privkey.pem" || \
       ! chmod 644 "${staging}/fullchain.pem" || \
       ! chmod 600 "${staging}/privkey.pem" || \
       ! mv -f "${staging}/fullchain.pem" "${destination}/fullchain.pem" || \
       ! mv -f "${staging}/privkey.pem" "${destination}/privkey.pem"; then
        rm -rf "$staging"
        return 1
    fi
    rmdir "$staging"
}

_beszel_yaml_quote() {
    local value="${1:-}"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//\$/\$\$}
    printf '"%s"' "$value"
}

_beszel_compose_env_set() {
    local compose="${1:-}" key="${2:-}" raw_value="${3:-}" yaml_value
    [ -f "$compose" ] || return 1
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    yaml_value=$(_beszel_yaml_quote "$raw_value") || return 1
    python3 - "$compose" "$key" "$yaml_value" <<'PY'
import os, stat, sys, tempfile

path, key, value = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    lines = stream.readlines()
matches = 0
for index, line in enumerate(lines):
    stripped = line.lstrip()
    if stripped.startswith(key + ":"):
        indent = line[:len(line) - len(stripped)]
        lines[index] = f"{indent}{key}: {value}\n"
        matches += 1
if matches != 1:
    raise SystemExit(1)
mode = stat.S_IMODE(os.stat(path).st_mode)
fd, temporary = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.writelines(lines)
    os.chmod(temporary, mode)
    os.replace(temporary, path)
except BaseException:
    try:
        os.unlink(temporary)
    except OSError:
        pass
    raise
PY
}

_beszel_compose_env_get() {
    local compose="${1:-}" key="${2:-}"
    [ -f "$compose" ] || return 1
    python3 - "$compose" "$key" <<'PY'
import json, sys

path, key = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    matches = [line.lstrip()[len(key) + 1:].strip() for line in stream
               if line.lstrip().startswith(key + ":")]
if len(matches) != 1:
    raise SystemExit(1)
value = matches[0]
if value.startswith('"'):
    try:
        value = json.loads(value.replace('$$', '$'))
    except json.JSONDecodeError:
        value = value[1:-1] if value.endswith('"') else value[1:]
elif value.startswith("'") and value.endswith("'"):
    value = value[1:-1]
print(value)
PY
}

_beszel_update_agent_hub_url() {
    local compose="${DIR_BESZEL_AGENT}docker-compose.yml" new_url="${1:-}" backup
    [ -f "$compose" ] || return 1
    new_url=$(_beszel_normalize_hub_url "$new_url") || return 1
    backup=$(mktemp) || return 1
    cp -p "$compose" "$backup" || { rm -f "$backup"; return 1; }

    if _beszel_compose_env_set "$compose" HUB_URL "$new_url" && \
       (cd "$DIR_BESZEL_AGENT" && docker compose up -d --force-recreate >/dev/null 2>&1); then
        rm -f "$backup"
        return 0
    fi

    cp -p "$backup" "$compose" || {
        rm -f "$backup"
        return 1
    }
    (cd "$DIR_BESZEL_AGENT" && docker compose up -d --force-recreate >/dev/null 2>&1) || true
    rm -f "$backup"
    return 1
}

_beszel_write_agent_compose() {
    local port="${1:-}" key="${2:-}" token="${3:-}" hub_url="${4:-}" system_name="${5:-}" disable_ssh="${6:-false}"
    local key_value token_value url_value name_line disable_ssh_line saved_umask rc compose_tmp
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    [ -n "$key" ] && [ -n "$token" ] || return 1
    hub_url=$(_beszel_normalize_hub_url "$hub_url") || return 1
    key_value=$(_beszel_yaml_quote "$key") || return 1
    token_value=$(_beszel_yaml_quote "$token") || return 1
    url_value=$(_beszel_yaml_quote "$hub_url") || return 1
    name_line=""
    if [ -n "$system_name" ]; then
        name_line="      SYSTEM_NAME: $(_beszel_yaml_quote "$system_name")"
    fi
    disable_ssh_line=""
    if [ "$disable_ssh" = "true" ]; then
        disable_ssh_line='      DISABLE_SSH: "true"'
    fi

    saved_umask=$(umask)
    umask 077
    mkdir -p "$DIR_BESZEL_AGENT" || {
        umask "$saved_umask"
        return 1
    }
    compose_tmp=$(mktemp "${DIR_BESZEL_AGENT}.docker-compose.yml.XXXXXX") || {
        umask "$saved_umask"
        return 1
    }
    cat > "$compose_tmp" <<YAML
name: beszel-agent

services:
  beszel-agent:
    image: henrygd/beszel-agent:latest
    container_name: beszel-agent
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "30m"
        max-file: "5"
    labels:
      - com.beszel.managed=true
      - com.beszel.component=beszel-agent
    network_mode: host
    volumes:
      - beszel-agent-data:/var/lib/beszel-agent
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro
    environment:
      LISTEN: "${port}"
      KEY: ${key_value}
      TOKEN: ${token_value}
      HUB_URL: ${url_value}
${name_line}
${disable_ssh_line}
    healthcheck:
      test: ["CMD", "/agent", "health"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  beszel-agent-data:
YAML
    rc=$?
    umask "$saved_umask"
    if [ "$rc" -ne 0 ] || ! chmod 600 "$compose_tmp" || ! mv -f "$compose_tmp" "${DIR_BESZEL_AGENT}docker-compose.yml"; then
        rm -f "$compose_tmp"
        return 1
    fi
    beszel_component_mark "$DIR_BESZEL_AGENT" beszel-agent
}

_beszel_hub_present() {
    [ -f "${DIR_BESZEL}docker-compose.yml" ] || \
        docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'beszel-hub'
}

_beszel_agent_present() {
    [ -f "${DIR_BESZEL_AGENT}docker-compose.yml" ] || \
        docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'beszel-agent'
}

_beszel_existing_hub_volume() {
    local volume
    for volume in beszel_beszel-data beszel_beszel-socket; do
        docker volume inspect "$volume" >/dev/null 2>&1 && {
            printf '%s\n' "$volume"
            return 0
        }
    done
    return 1
}

_beszel_existing_agent_volume() {
    docker volume inspect beszel-agent_beszel-agent-data >/dev/null 2>&1
}

_beszel_managed_by_beszel() {
    beszel_component_is_managed "$DIR_BESZEL" beszel-hub
}

_beszel_agent_managed_by_beszel() {
    beszel_component_is_managed "$DIR_BESZEL_AGENT" beszel-agent
}

_beszel_show_external_install() {
    local title="${1:-Beszel}"
    clear
    show_screen_header "⚠️  Внешняя установка ${title}" "$YELLOW"
    echo -e "${WHITE}Компонент не отмечен как установленный Beszel Manager.${NC}"
    echo -e "${DARKGRAY}Его контейнеры, файлы, порты и reverse proxy останутся без изменений.${NC}"
    show_continue_prompt || true
}

_beszel_proxy_mode_file() {
    printf '%s.beszel-proxy-mode\n' "$DIR_BESZEL"
}

_beszel_proxy_domain_file() {
    printf '%s.beszel-proxy-domain\n' "$DIR_BESZEL"
}

_beszel_proxy_mode() {
    local mode="" rc
    [ -s "$(_beszel_proxy_mode_file)" ] && mode=$(tr -d '[:space:]' < "$(_beszel_proxy_mode_file)" 2>/dev/null || true)
    if [ -n "$mode" ]; then
        case "$mode" in standalone|caddy|nginx) printf '%s\n' "$mode"; return 0 ;; esac
        printf 'Сохранённый режим reverse proxy не поддерживается этой версией.\n' >&2
        return 2
    fi
    mode=$(beszel_proxy_state_get beszel PROXY_MODE 2>/dev/null || true)
    if [ -n "$mode" ]; then
        case "$mode" in standalone|caddy|nginx) ;; *)
            printf 'Сохранённая схема reverse proxy требует ручной миграции.\n' >&2
            return 2
            ;;
        esac
    fi
    if declare -F beszel_proxy_resolve_for_install >/dev/null 2>&1; then
        mode=$(beszel_proxy_resolve_for_install beszel 2>/dev/null)
        rc=$?
        [ "$rc" -eq 0 ] || return "$rc"
        printf '%s\n' "$mode"
        return 0
    fi
    printf 'standalone\n'
}

_beszel_proxy_removal() {
    local mode="${1:-}" domain="${2:-}"
    [ -n "$mode" ] || mode=$(_beszel_proxy_mode 2>/dev/null || printf 'standalone')
    [ -n "$domain" ] || domain=$(beszel_proxy_state_get beszel DOMAIN 2>/dev/null || true)
    [ -n "$domain" ] || { [ -s "$(_beszel_proxy_domain_file)" ] && domain=$(tr -d '[:space:]' < "$(_beszel_proxy_domain_file)"); }
    case "$mode" in
        caddy) beszel_proxy_caddy_remove_block beszel "$domain" >/dev/null 2>&1 || return 1 ;;
        nginx) beszel_proxy_nginx_remove_block beszel "$domain" >/dev/null 2>&1 || return 1 ;;
        *) nginx_remove_server_block "BESZEL" >/dev/null 2>&1 || true ;;
    esac
    beszel_proxy_state_remove beszel
    return 0
}

_beszel_write_compose() {
    local mode="${1:-standalone}" domain="${2:-}" network_block="" service_network="" app_url
    _beszel_valid_host "$domain" || return 1
    case "$mode" in standalone|caddy|nginx) ;; *) return 1 ;; esac
    app_url=$(_beszel_yaml_quote "https://${domain}") || return 1
    if [ "$mode" = "caddy" ] || [ "$mode" = "nginx" ]; then
        service_network=$'    networks:\n      - remnawave-network'
        network_block=$'\nnetworks:\n  remnawave-network:\n    name: remnawave-network\n    external: true'
    fi
    mkdir -p "$DIR_BESZEL"
cat > "${DIR_BESZEL}docker-compose.yml" <<YAML
name: beszel

services:
  beszel-hub:
    image: henrygd/beszel:latest
    container_name: beszel-hub
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "30m"
        max-file: "5"
    labels:
      - com.beszel.managed=true
      - com.beszel.component=beszel-hub
    environment:
      APP_URL: ${app_url}
    ports:
      - "127.0.0.1:8090:8090"
${service_network}
    volumes:
      - beszel-data:/beszel_data
      - beszel-socket:/beszel_socket
    healthcheck:
      test: ["CMD", "/beszel", "health", "--url", "http://127.0.0.1:8090"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  beszel-data:
  beszel-socket:
${network_block}
YAML
    printf '%s\n' "$mode" > "$(_beszel_proxy_mode_file)"
    beszel_component_mark "$DIR_BESZEL" beszel-hub "$mode"
}

_beszel_external_block() {
    local mode="${1:-}" domain="${2:-}"
    _beszel_valid_host "$domain" || return 1
    case "$mode" in
        caddy)
            cat <<CADDY
https://${domain} {
    request_body {
        max_size 10MB
    }
    reverse_proxy http://beszel-hub:8090 {
        transport http {
            read_timeout 360s
        }
    }
}
CADDY
            ;;
        nginx)
            cat <<NGINX
server {
    server_name ${domain};
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    ssl_certificate /etc/nginx/beszel-app-ssl/beszel/${domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/beszel-app-ssl/beszel/${domain}/privkey.pem;
    client_max_body_size 10m;

    resolver 127.0.0.11 valid=10s ipv6=off;
    set \$beszel_upstream http://beszel-hub:8090;
    location / {
        proxy_pass \$beszel_upstream;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 360s;
    }
}
NGINX
            ;;
        *) return 1 ;;
    esac
}

_beszel_proxy_apply() {
    local mode="${1:-}" domain="${2:-}" block
    case "$mode" in
        caddy)
            block=$(_beszel_external_block caddy "$domain") || return 1
            beszel_proxy_caddy_apply_block beszel "$domain" "$block" || return $?
            ;;
        nginx)
            block=$(_beszel_external_block nginx "$domain") || return 1
            beszel_proxy_nginx_apply_block beszel "$domain" "$block" || return $?
            ;;
        standalone)
            nginx_add_server_block "BESZEL" "${3:-}" || return 1
            beszel_proxy_state_write beszel standalone manager "$domain" \
                "${DIR_NGINX}nginx.conf" "${DIR_NGINX}docker-compose.yml" "" >/dev/null 2>&1 || true
            ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$mode" > "$(_beszel_proxy_mode_file)"
    printf '%s\n' "$domain" > "$(_beszel_proxy_domain_file)"
}

# После спиннера: clear, тот же заголовок что в confirm_nav --delete (красный, по центру в 38),
# центрированное зелёное сообщение, подсказка Enter/Esc.
# $1 — заголовок (как в confirm), $2 — строка успеха (с эмодзи ✅).
_beszel_post_delete_success_screen() {
    local _title="$1" _msg="$2"
    local _tc _p _pad
    clear
    echo -e "${BLUE}══════════════════════════════════════${NC}"
    _tc=$(printf '%b' "$_title" | sed 's/\x1b\[[0-9;]*m//g')
    _p=$(( (38 - ${#_tc}) / 2 ))
    [ "$_p" -lt 0 ] && _p=0
    _pad=$(printf "%${_p}s" "")
    printf "%s" "$_pad"
    echo -e "${RED}${_title}${NC}"
    echo -e "${BLUE}══════════════════════════════════════${NC}"
    echo
    echo -e "$(center "$_msg" "$GREEN")"
    show_continue_prompt || return 0
}

# HTTP-вызов через python3
# Использование: _beszel_http METHOD url [body] [auth_token]
_beszel_http() {
    local method="$1" url="$2" body="${3:-}" token="${4:-}"
    _BZURL="$url" _BZBODY="$body" _BZMETHOD="$method" _BZTOKEN="$token" \
    python3 - <<'PYEOF' 2>/dev/null
import urllib.request, urllib.error, os, sys
url    = os.environ.get('_BZURL','')
body   = os.environ.get('_BZBODY','')
method = os.environ.get('_BZMETHOD','GET')
token  = os.environ.get('_BZTOKEN','')
req = urllib.request.Request(url, method=method)
req.add_header('Content-Type', 'application/json')
if token:
    req.add_header('Authorization', token)
data = body.encode() if body else None
try:
    with urllib.request.urlopen(req, data=data, timeout=15) as r:
        sys.stdout.write(r.read().decode())
        sys.exit(0)
except urllib.error.HTTPError as e:
    sys.stdout.write(e.read().decode())
    sys.exit(e.code)
except Exception as e:
    sys.stderr.write(str(e)+'\n')
    sys.exit(1)
PYEOF
}

# Ждёт, пока Beszel API поднимется (до 60 сек)
_beszel_wait_api() {
    local i
    for i in $(seq 1 30); do
        if _beszel_http GET "http://127.0.0.1:8090/api/beszel/first-run" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# Восстанавливает first-run состояние Beszel после авто-настройки агента.
# Удаляет временного пользователя и возвращает суперадмина _@b.b.
# Аргументы: <hub_url> <email> <password>
_beszel_restore_firstrun() {
    local HUB_URL="$1" EMAIL="$2" PASS="$3"
    _BZ_HUB="$HUB_URL" _BZ_EMAIL="$EMAIL" _BZ_PASS="$PASS" \
    python3 - <<'PYEOF' 2>/dev/null
import urllib.request, urllib.parse, urllib.error, json, os, secrets
hub   = os.environ['_BZ_HUB']
email = os.environ['_BZ_EMAIL']
pw    = os.environ['_BZ_PASS']

def api(method, path, body=None, token=None):
    req = urllib.request.Request(hub + path, method=method)
    req.add_header('Content-Type', 'application/json')
    if token:
        req.add_header('Authorization', token)
    data = json.dumps(body).encode() if body else None
    try:
        with urllib.request.urlopen(req, data=data, timeout=10) as r:
            return json.loads(r.read().decode() or '{}')
    except Exception:
        raise

# Авторизуемся как суперпользователь
su = api('POST', '/api/collections/_superusers/auth-with-password',
         {'identity': email, 'password': pw})
su_token = su.get('token', '')
if not su_token:
    raise SystemExit(1)

# Восстанавливаем временного суперадмина _@b.b для first-run UI
tmp_pw = secrets.token_urlsafe(24)
try:
    api('POST', '/api/collections/_superusers/records',
        {'email': '_@b.b', 'password': tmp_pw, 'passwordConfirm': tmp_pw}, su_token)
except urllib.error.HTTPError:
    default_filter = urllib.parse.urlencode({'filter': "email='_@b.b'", 'perPage': '1'})
    defaults = api('GET', f'/api/collections/_superusers/records?{default_filter}', token=su_token)
    if not defaults.get('items'):
        raise

# Удаляем временного обычного пользователя
filt = urllib.parse.urlencode({'filter': f"email='{email}'", 'perPage': '1'})
users = api('GET', f'/api/collections/users/records?{filt}', token=su_token)
if not isinstance(users, dict) or not isinstance(users.get('items', []), list):
    raise SystemExit(1)
for u in users.get('items', []):
    api('DELETE', f'/api/collections/users/records/{u["id"]}', token=su_token)

# Удаляем временного суперпользователя (последним — инвалидирует токен)
sus = api('GET', f'/api/collections/_superusers/records?{filt}', token=su_token)
if not isinstance(sus, dict) or not isinstance(sus.get('items', []), list):
    raise SystemExit(1)
for s in sus.get('items', []):
    api('DELETE', f'/api/collections/_superusers/records/{s["id"]}', token=su_token)
PYEOF
}

_beszel_finish_auto_install() {
    local hub_url="${1:-}" email="${2:-}" password="${3:-}" recovery_file="${4:-}"
    if _beszel_restore_firstrun "$hub_url" "$email" "$password"; then
        rm -f "$recovery_file" || return 1
        return 0
    fi
    [ -n "$recovery_file" ] && chmod 600 "$recovery_file" 2>/dev/null || true
    return 1
}

# Настраивает правила в уже активном UFW. Не устанавливает и не включает
# firewall и не меняет его политики по умолчанию.
# Вызов: _beszel_setup_firewall standalone — открыть только веб-порты Beszel.
#         _beszel_setup_firewall --agent-node 45876 IP... — разрешить Agent только с IP Hub.
_beszel_setup_firewall() {
    local _with_http=true _mode=standalone
    if [ "${1:-}" = "--agent-node" ]; then
        shift
        local _agent_port="${1:-}"
        shift || true
        local -a _hub_ips=("$@")
        [[ "$_agent_port" =~ ^[0-9]+$ ]] && [ "$_agent_port" -ge 1 ] && [ "$_agent_port" -le 65535 ] || return 1
        [ "${#_hub_ips[@]}" -gt 0 ] || return 1
        command -v ufw >/dev/null 2>&1 || return 2
        [ "$(ufw status 2>/dev/null | sed -n '1p')" = "Status: active" ] || return 2

        # Убираем правила этой и предыдущих версий, затем добавляем разрешения от IP Hub.
        beszel_ufw_remove_rules_by_comment "BESZEL" "$_agent_port" || return 1
        beszel_ufw_remove_rules_by_comment "Beszel Agent" "$_agent_port" || return 1
        local _ip
        for _ip in "${_hub_ips[@]}"; do
            beszel_ufw_allow_tcp_from "$_agent_port" "$_ip" "BESZEL" || return 1
        done
        return 0
    else
        _mode="${1:-standalone}"
        shift || true
    fi
    local -a _extra_ports=("$@")
    local _ufw_status
    command -v ufw >/dev/null 2>&1 || return 0
    _ufw_status=$(ufw status 2>/dev/null | sed -n '1p')
    [ "$_ufw_status" = "Status: active" ] || return 0

    # Локальный Agent на Hub работает через WebSocket и не нуждается в
    # глобально открытом SSH-порту, который создавали старые версии.
    beszel_ufw_remove_open_tcp_rules_by_comment "Beszel Agent" 45876 || return 1

    if [ "$_with_http" = true ] && [ "$_mode" = "standalone" ]; then
        beszel_ufw_allow_tcp 80 "Beszel Web" || return 1
        beszel_ufw_allow_tcp 443 "Beszel Web" || return 1
    fi

    local _p
    for _p in "${_extra_ports[@]}"; do
        [ -z "$_p" ] && continue
        [[ "$_p" =~ ^[0-9]+$ ]] || continue
        [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ] || continue
        beszel_ufw_allow_tcp "$_p" "Beszel Agent" || return 1
    done
}

# Авто-установка агента на локальной машине после запуска хаба.
_beszel_auto_install_agent() {
    local AGENT_PORT="45876"
    local HUB_URL="http://127.0.0.1:8090"

    # 1. Генерируем временные учётные данные
    local ADMIN_EMAIL ADMIN_PASS RECOVERY_FILE
    ADMIN_EMAIL="admin@beszel.local"
    ADMIN_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20)
    [ "${#ADMIN_PASS}" -ge 20 ] || return 1
    RECOVERY_FILE="${DIR_BESZEL}first-run-recovery.txt"
    (umask 077; printf 'email=%s\npassword=%s\n' "$ADMIN_EMAIL" "$ADMIN_PASS" > "$RECOVERY_FILE") || return 1
    chmod 600 "$RECOVERY_FILE" || return 1

    # 2. Создаём первого пользователя через first-run API
    local CREATE_BODY
    CREATE_BODY=$(_EMAIL="$ADMIN_EMAIL" _PASS="$ADMIN_PASS" \
        python3 -c "import json,os; print(json.dumps({'email':os.environ['_EMAIL'],'password':os.environ['_PASS']}))" 2>/dev/null)
    _beszel_http POST "${HUB_URL}/api/beszel/create-user" "$CREATE_BODY" >/dev/null 2>&1

    # 3. Авторизуемся как пользователь
    local AUTH_BODY AUTH_RESP AUTH_TOKEN
    AUTH_BODY=$(_EMAIL="$ADMIN_EMAIL" _PASS="$ADMIN_PASS" \
        python3 -c "import json,os; print(json.dumps({'identity':os.environ['_EMAIL'],'password':os.environ['_PASS']}))" 2>/dev/null)
    AUTH_RESP=$(_beszel_http POST "${HUB_URL}/api/collections/users/auth-with-password" "$AUTH_BODY")
    AUTH_TOKEN=$(echo "$AUTH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null)
    if [ -z "$AUTH_TOKEN" ]; then
        _beszel_finish_auto_install "$HUB_URL" "$ADMIN_EMAIL" "$ADMIN_PASS" "$RECOVERY_FILE" || true
        return 1
    fi

    # 4. Получаем публичный ключ через /api/beszel/getkey
    # Примечание: /api/beszel/info не работает в Beszel 0.18+ (возвращает HTML вместо JSON).
    # /api/beszel/getkey — deprecated alias, но работает корректно.
    local KEY_RESP BESZEL_KEY
    KEY_RESP=$(_beszel_http GET "${HUB_URL}/api/beszel/getkey" "" "$AUTH_TOKEN")
    BESZEL_KEY=$(echo "$KEY_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('key',''))" 2>/dev/null)
    if [ -z "$BESZEL_KEY" ]; then
        _beszel_finish_auto_install "$HUB_URL" "$ADMIN_EMAIL" "$ADMIN_PASS" "$RECOVERY_FILE" || true
        return 1
    fi

    # 5. Создаём постоянный universal token
    local TOKEN_RESP UNIVERSAL_TOKEN
    TOKEN_RESP=$(_beszel_http GET "${HUB_URL}/api/beszel/universal-token?enable=1&permanent=1" "" "$AUTH_TOKEN")
    UNIVERSAL_TOKEN=$(echo "$TOKEN_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null)
    if [ -z "$UNIVERSAL_TOKEN" ]; then
        _beszel_finish_auto_install "$HUB_URL" "$ADMIN_EMAIL" "$ADMIN_PASS" "$RECOVERY_FILE" || true
        return 1
    fi

    # 6. Запускаем локальный агент только через WebSocket, без SSH listener.
    if ! _beszel_write_agent_compose "$AGENT_PORT" "$BESZEL_KEY" "$UNIVERSAL_TOKEN" "$HUB_URL" "Beszel" true || \
       ! (cd "${DIR_BESZEL_AGENT}" && docker compose up -d >/dev/null 2>&1); then
        _beszel_finish_auto_install "$HUB_URL" "$ADMIN_EMAIL" "$ADMIN_PASS" "$RECOVERY_FILE" || true
        return 1
    fi

    # 7. Ждём регистрации агента в хабе (до 120 сек).
    local i
    for i in $(seq 1 60); do
        local cnt
        cnt=$(_beszel_http GET "${HUB_URL}/api/collections/systems/records?perPage=1" "" "$AUTH_TOKEN" \
            | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('totalItems',0))" 2>/dev/null)
        [ "${cnt:-0}" -gt 0 ] && break
        sleep 2
    done

    # 8. Записываем daemon-скрипт переподключения агента.
    # Проблема: systems.users имеет cascadeDelete=true — удаление временного пользователя
    # каскадно удаляет systems + fingerprints + universal_tokens. Агент теряет регистрацию.
    # Решение: daemon ждёт создания реального аккаунта (firstRun→false), затем напрямую
    # через SQLite создаёт новый universal token для нового администратора и перезапускает
    # агент, который автоматически перерегистрируется под новым владельцем.
    local _PROJ _DB_DIR _DAEMON
    _PROJ=beszel
    _DB_DIR=$(docker volume inspect "${_PROJ}_beszel-data" \
        --format '{{.Mountpoint}}' 2>/dev/null || echo "/var/lib/docker/volumes/${_PROJ}_beszel-data/_data")
    _DAEMON="${DIR_BESZEL}.agent-daemon.py"
    cat > "$_DAEMON" <<PYEOF
#!/usr/bin/env python3
"""Beszel agent reconnect daemon.

После _beszel_restore_firstrun (удаления временного пользователя) ждёт,
пока реальный администратор создаст аккаунт через firstRun UI.
Затем создаёт universal token в SQLite и перезапускает агент.
Beszel проверяет universal_tokens по базе данных при каждом подключении агента,
поэтому прямая запись в SQLite работает без перезапуска хаба.
"""
import os, re, random, sqlite3, string, subprocess, sys, time, uuid

DB      = "${_DB_DIR}/data.db"
COMPOSE = "${DIR_BESZEL_AGENT}docker-compose.yml"

def rand_id(n=15):
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=n))

# Ждём до 24 часов пока в таблице users не появится реальный пользователь
uid = None
for _ in range(17280):
    try:
        with sqlite3.connect(DB, timeout=5) as cx:
            row = cx.execute("SELECT id FROM users LIMIT 1").fetchone()
            if row:
                uid = row[0]
                break
    except Exception:
        pass
    time.sleep(5)

if uid is None:
    sys.exit(0)

time.sleep(2)  # даём PocketBase завершить транзакцию

# Создаём universal token для нового администратора напрямую в SQLite
new_token = str(uuid.uuid4())
try:
    with sqlite3.connect(DB, timeout=10) as cx:
        cx.execute(
            "INSERT INTO universal_tokens (id, created, user, token) "
            "VALUES (?, datetime('now'), ?, ?)",
            (rand_id(), uid, new_token),
        )
except Exception:
    sys.exit(1)

# Обновляем TOKEN в docker-compose агента (KEY остаётся тем же)
try:
    with open(COMPOSE) as f:
        content = f.read()
    content = re.sub(r'TOKEN:.*', 'TOKEN: "' + new_token + '"', content)
    with open(COMPOSE, 'w') as f:
        f.write(content)
except Exception:
    sys.exit(1)

# Перезапускаем агент — он подключится с новым токеном и автоматически
# создаст запись systems под реальным администратором
subprocess.run(
    ["docker", "compose", "-f", COMPOSE, "up", "-d"],
    capture_output=True,
)

# Удаляем этот скрипт
try:
    os.unlink(os.path.abspath(__file__))
except Exception:
    pass
PYEOF
    local _daemon_write_status=$?
    if [ "$_daemon_write_status" -ne 0 ] || ! chmod 600 "$_DAEMON"; then
        _beszel_finish_auto_install "$HUB_URL" "$ADMIN_EMAIL" "$ADMIN_PASS" "$RECOVERY_FILE" || true
        return 1
    fi

    # 9. Восстанавливаем first-run состояние (каскадно удаляет systems/tokens временного пользователя).
    if ! _beszel_finish_auto_install "$HUB_URL" "$ADMIN_EMAIL" "$ADMIN_PASS" "$RECOVERY_FILE"; then
        return 1
    fi

    # 10. Запускаем daemon в фоне, отвязанным от текущего подпроцесса.
    nohup python3 "$_DAEMON" >/dev/null 2>&1 &
    disown $! 2>/dev/null || true
}

is_beszel_installed() {
    _beszel_managed_by_beszel && _beszel_hub_present
}

is_beszel_agent_installed() {
    _beszel_agent_managed_by_beszel && _beszel_agent_present
}

_beszel_component_update_label() {
    printf '🔄  Обновить образы Beszel\n'
}

_beszel_clear_component_update_entry() { :; }

manage_delete_components() {
    local -a items=() actions=()
    is_beszel_installed && { items+=("📊  Панель Beszel"); actions+=("hub"); }
    is_beszel_agent_installed && { items+=("🖥️   Агент Beszel"); actions+=("agent"); }
    if [ "${#actions[@]}" -eq 0 ]; then
        show_screen_header "🗑️  Удаление Beszel" "$RED"
        print_warning "Компоненты Beszel не установлены"
        show_continue_prompt || true
        return 0
    fi
    items+=("──────────────────────────────────────" "⬅️   Назад")
    actions+=("sep" "back")
    show_arrow_menu "🗑️  Удаление Beszel" "${items[@]}"
    case "${actions[$?]:-back}" in
        hub) uninstall_beszel ;;
        agent) uninstall_beszel_agent ;;
    esac
}

_beszel_do_update() {
    local has_hub=false has_agent=false
    is_beszel_installed && has_hub=true
    is_beszel_agent_installed && has_agent=true

    show_screen_header "🔄 Обновление Beszel" "$BLUE"
    if [ "$has_hub" = false ] && [ "$has_agent" = false ]; then
        print_error "Установка Beszel не найдена."
        show_continue_prompt "Назад" || true
        return 1
    fi

    (
        local rc=0
        if [ "$has_hub" = true ]; then
            cd "$DIR_BESZEL" || exit 1
            docker compose pull >/dev/null 2>&1 || rc=1
            docker compose up -d --remove-orphans >/dev/null 2>&1 || rc=1
        fi
        if [ "$has_agent" = true ]; then
            cd "$DIR_BESZEL_AGENT" || exit 1
            docker compose pull >/dev/null 2>&1 || rc=1
            docker compose up -d --remove-orphans >/dev/null 2>&1 || rc=1
        fi
        exit "$rc"
    ) </dev/null &
    if show_spinner --step "Загрузка и применение обновления"; then
        echo
        print_success "Beszel успешно обновлён"
        show_continue_prompt "Назад" || true
        return 0
    fi

    echo
    print_error "Не удалось обновить Beszel. Проверьте журналы Docker."
    show_continue_prompt "Назад" || true
    return 1
}

_beszel_update_script_from_github() {
    local repo_dir="${SCRIPT_DIR:-}" remote_url="" temp_dir="" source_dir="" backup_dir="" parent_dir="" base_name=""
    [ -n "$repo_dir" ] && [ -d "$repo_dir" ] || return 1

    if [ -e "${repo_dir}/.git" ]; then
        command -v git >/dev/null 2>&1 || return 1
        remote_url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null) || return 1
        remote_url="${remote_url%/}"
        remote_url="${remote_url%.git}"
        case "$remote_url" in
            https://github.com/thekhabaroff/Beszel|git@github.com:thekhabaroff/Beszel|ssh://git@github.com/thekhabaroff/Beszel) ;;
            *) return 1 ;;
        esac
        git -C "$repo_dir" pull --ff-only origin master >/dev/null 2>&1 || return 1
        [ -f "${repo_dir}/beszel.sh" ] && [ -f "${repo_dir}/bin/beszel" ] || return 1
        chmod +x "${repo_dir}/beszel.sh" "${repo_dir}/bin/beszel" || return 1
        return 0
    fi

    command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 || return 1
    parent_dir=$(dirname "$repo_dir")
    base_name=$(basename "$repo_dir")
    temp_dir=$(mktemp -d "${parent_dir}/.${base_name}.update.XXXXXX") || return 1
    source_dir="${temp_dir}/source"
    mkdir -p "$source_dir" || { rm -rf "$temp_dir"; return 1; }

    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 \
        "https://github.com/thekhabaroff/Beszel/archive/refs/heads/master.tar.gz" \
        -o "${temp_dir}/source.tar.gz" || \
       ! tar -xzf "${temp_dir}/source.tar.gz" --strip-components=1 -C "$source_dir" || \
       [ ! -f "${source_dir}/beszel.sh" ] || [ ! -f "${source_dir}/bin/beszel" ] || \
       [ ! -d "${source_dir}/lib" ]; then
        rm -rf "$temp_dir"
        return 1
    fi
    cp -a --update=none "${repo_dir}/." "$source_dir/" || {
        rm -rf "$temp_dir"
        return 1
    }
    chmod +x "${source_dir}/beszel.sh" "${source_dir}/bin/beszel" || {
        rm -rf "$temp_dir"
        return 1
    }

    backup_dir=$(mktemp -d "${parent_dir}/.${base_name}.backup.XXXXXX") || {
        rm -rf "$temp_dir"
        return 1
    }
    rmdir "$backup_dir" || {
        rm -rf "$temp_dir" "$backup_dir"
        return 1
    }
    trap 'if [ -d "$backup_dir" ]; then rm -rf "$repo_dir"; mv "$backup_dir" "$repo_dir" || true; fi; rm -rf "$temp_dir"; exit 130' INT TERM HUP
    if ! mv "$repo_dir" "$backup_dir"; then
        trap - INT TERM HUP
        rm -rf "$temp_dir"
        return 1
    fi
    if ! mv "$source_dir" "$repo_dir"; then
        mv "$backup_dir" "$repo_dir" || true
        trap - INT TERM HUP
        rm -rf "$temp_dir"
        return 1
    fi

    trap - INT TERM HUP
    rm -rf "$backup_dir" "$temp_dir"
    return 0
}

_beszel_do_script_update() {
    show_screen_header "🔂 Обновление скрипта Beszel" "$BLUE"
    (
        _beszel_update_script_from_github
    ) </dev/null &
    if show_spinner --step "Загрузка изменений с GitHub"; then
        echo
        print_success "Скрипт Beszel обновлён. Перезапускаю меню."
        sleep 1
        exec "${SCRIPT_DIR}/bin/beszel"
    fi

    echo
    print_error "Не удалось обновить скрипт Beszel. Проверьте подключение к GitHub и локальные изменения."
    show_continue_prompt "Назад" || true
    return 1
}

manage_beszel() {
    while true; do
        local -a items=()
        local -a actions=()

        if _beszel_hub_present && ! _beszel_managed_by_beszel; then
            items+=("⚠️   Внешняя панель Beszel — без изменений"); actions+=("external_hub")
        elif ! is_beszel_installed; then
            items+=("📊  Установить панель Beszel"); actions+=("install_hub")
        else
            items+=("🌐  Изменить домен для панели Beszel"); actions+=("change_domain")
        fi

        if _beszel_agent_present && ! _beszel_agent_managed_by_beszel; then
            items+=("⚠️   Внешний агент Beszel — без изменений"); actions+=("external_agent")
        elif ! is_beszel_agent_installed; then
            items+=("🖥️   Подключить ноду"); actions+=("install_agent")
        elif ! is_beszel_installed; then
            # Агент есть, хаба нет — меняем адрес хаба у агента
            items+=("🔗  Изменить адрес хаба агента"); actions+=("change_agent_hub")
        fi

        if is_beszel_installed || is_beszel_agent_installed; then
            items+=("──────────────────────────────────────"); actions+=("sep")
            local update_label=""
            if update_label=$(_beszel_component_update_label beszel "Beszel"); then
                items+=("$update_label"); actions+=("update")
            fi
            items+=("🔂  Обновить скрипт"); actions+=("update_script")
            items+=("──────────────────────────────────────"); actions+=("sep")
            items+=("🗑️   Удалить"); actions+=("delete")
        else
            items+=("──────────────────────────────────────"); actions+=("sep")
            items+=("🔂  Обновить скрипт"); actions+=("update_script")
        fi

        items+=("──────────────────────────────────────"); actions+=("sep")
        items+=("🔥  UFW - Firewall");                    actions+=("firewall")
        items+=("⚙️   Оптимизация сервера");               actions+=("server_optimization")
        items+=("⚡  Тест скорости сети");                 actions+=("speed_test")
        items+=("🌐  Сетевая диагностика");               actions+=("network_diagnostics")
        items+=("──────────────────────────────────────"); actions+=("sep")
        items+=("⬅️   Выход");                             actions+=("back")

        local choice action
        show_arrow_menu "📊 Мониторинг Beszel" "${items[@]}"
        choice=$?
        action="${actions[$choice]:-back}"

        case "$action" in
            install_hub)       install_beszel ;;
            change_domain)     change_domain_beszel ;;
            install_agent)     install_beszel_agent ;;
            change_agent_hub)  change_agent_hub_url ;;
            external_hub)      _beszel_show_external_install "Beszel" ;;
            external_agent)    _beszel_show_external_install "Beszel Agent" ;;
            update)
                _beszel_do_update
                _beszel_clear_component_update_entry beszel
                ;;
            update_script) _beszel_do_script_update ;;
            delete)            manage_delete_components beszel ;;
            firewall)          manage_beszel_ufw ;;
            server_optimization) manage_beszel_server_optimization ;;
            speed_test)        run_beszel_speed_test ;;
            network_diagnostics) run_beszel_network_diagnostics ;;
            back)
                clear 2>/dev/null || true
                return 0
                ;;
            *)
                clear 2>/dev/null || true
                return 0
                ;;
        esac
    done
}

install_beszel() {
    local _agent_volume_conflict=false
    local _agent_setup_failed=false
    # Между спиннерами курсор не показываем; перед вводом reading_inline сам делает cnorm.
    KEEP_CURSOR_HIDDEN=1
    trap 'KEEP_CURSOR_HIDDEN=; tput civis 2>/dev/null || true; stty sane 2>/dev/null || true; trap - RETURN' RETURN

    show_screen_header "📊 Установка панели Beszel" "$BLUE"

    if _beszel_hub_present && ! _beszel_managed_by_beszel; then
        _beszel_show_external_install "Beszel"
        return 1
    fi
    if is_beszel_installed; then
        KEEP_CURSOR_HIDDEN=
        trap - RETURN
        echo
        print_success "Панель Beszel уже установлена"
        show_continue_prompt || return 0
        return 0
    fi

    if [ -d "$DIR_BESZEL" ] && ! _beszel_managed_by_beszel; then
        local _existing_hub_entry
        _existing_hub_entry=$(find "$DIR_BESZEL" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)
        if [ -n "$_existing_hub_entry" ]; then
            print_error "В ${DIR_BESZEL} уже есть файлы, не принадлежащие Beszel Manager."
            echo -e "${DARKGRAY}Установка остановлена, чтобы не перезаписать данные.${NC}"
            show_continue_prompt || true
            return 1
        fi
    fi

    if ! _beszel_hub_present; then
        local _existing_volume
        _existing_volume=$(_beszel_existing_hub_volume 2>/dev/null || true)
        if [ -n "$_existing_volume" ]; then
            print_error "Найден Docker volume ${_existing_volume}, но конфигурация Hub отсутствует."
            echo -e "${DARKGRAY}Установка остановлена, чтобы не затронуть существующие данные Beszel.${NC}"
            show_continue_prompt || true
            return 1
        fi
    fi

    # ─── Домен или IP (Enter — внешний IP сервера) ───
    local BESZEL_DOMAIN
    local _server_ip
    _server_ip=$(get_server_ip 2>/dev/null)
    local _is_ip_mode=false

    while true; do
        reading_inline --no-eol "${YELLOW}Домен/IP для Beszel ${DARKGRAY}[Enter для ${_server_ip}]:${NC}" BESZEL_DOMAIN
        local _domain_rc=$?

        if [ "$_domain_rc" -eq 2 ]; then
            KEEP_CURSOR_HIDDEN=
            trap - RETURN
            return 0
        fi

        if [ -z "$BESZEL_DOMAIN" ]; then
            if ! _beszel_valid_host "$_server_ip"; then
                print_error "Не удалось определить публичный IP. Введите домен или IP вручную."
                continue
            fi
            BESZEL_DOMAIN="${_server_ip,,}"
            _is_ip_mode=true
            break
        fi

        if ! _beszel_valid_host "$BESZEL_DOMAIN"; then
            print_error "Введите корректное имя хоста или IPv4 адрес без URL и порта."
            continue
        fi
        BESZEL_DOMAIN="${BESZEL_DOMAIN,,}"
        if [[ "$BESZEL_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            _is_ip_mode=true
            break
        fi

        local _chk_out_f _chk_rc_f
        _chk_out_f=$(mktemp)
        _chk_rc_f=$(mktemp)
        (
            set +e
            check_domain "$BESZEL_DOMAIN" > "$_chk_out_f" 2>&1
            local _beszel_domain_rc=$?
            echo "$_beszel_domain_rc" > "$_chk_rc_f"
            exit 0
         ) </dev/null &        local _chk_pid=$!
        beszel_domain_check_wait_inline "$_chk_pid"
        local _chk_rc _chk_out
        _chk_rc=$(cat "$_chk_rc_f" 2>/dev/null)
        [[ "$_chk_rc" =~ ^[0-9]+$ ]] || _chk_rc=1
        _chk_out=$(cat "$_chk_out_f" 2>/dev/null)
        rm -f "$_chk_out_f" "$_chk_rc_f"

        if [ "$_chk_rc" = "0" ]; then
            break
        fi

        echo
        local _out_lines=0
        if [ -n "$_chk_out" ]; then
            printf "%s\n" "$_chk_out"
            _out_lines=$(echo "$_chk_out" | wc -l)
        fi

        echo
        echo -e "${BLUE}══════════════════════════════════════${NC}"
        echo -e "${BLUE}Enter${DARKGRAY}: Повторить   ${BLUE}S${DARKGRAY}: Пропустить   ${BLUE}Esc${DARKGRAY}: Назад${NC}"

        local _total_lines=$((_out_lines + 5))
        tput civis 2>/dev/null || true
        local _nav_key
        while true; do
            read -s -n 1 _nav_key
            if [[ "$_nav_key" == $'\x1b' ]]; then
                if _beszel_after_esc_is_bare; then
                    tput civis 2>/dev/null || true
                    echo
                    KEEP_CURSOR_HIDDEN=
                    trap - RETURN
                    return 0
                fi
                continue
            elif [[ "$_nav_key" == "s" || "$_nav_key" == "S" ]]; then
                tput civis 2>/dev/null || true
                echo
                local _skip_lines=$((_total_lines))
                for (( _l=0; _l<_skip_lines; _l++ )); do
                    tput cuu1 2>/dev/null; tput el 2>/dev/null
                done
                break 2
            elif [[ "$_nav_key" == "" ]]; then
                tput civis 2>/dev/null || true
                for (( _l=0; _l<_total_lines; _l++ )); do
                    tput cuu1 2>/dev/null; tput el 2>/dev/null
                done
                break
            fi
        done
    done
    if [ -n "${KEEP_CURSOR_HIDDEN:-}" ]; then
        tput civis 2>/dev/null || true
    fi
    echo
    echo

    if [[ ! "$BESZEL_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        BESZEL_DOMAIN=$(printf '%s' "$BESZEL_DOMAIN" | tr '[:upper:]' '[:lower:]')
    fi

    local BESZEL_PROXY_MODE _proxy_detect_rc
    BESZEL_PROXY_MODE=$(_beszel_proxy_mode 2>/dev/null)
    _proxy_detect_rc=$?
    if [ "$_proxy_detect_rc" -ne 0 ]; then
        print_error "Найдено несколько активных reverse proxy. Автоматический выбор небезопасен."
        echo -e "${DARKGRAY}Остановите неиспользуемый Caddy/Nginx или удалите его старую конфигурацию.${NC}"
        show_continue_prompt || true
        return 1
    fi
    if declare -F beszel_proxy_preflight >/dev/null 2>&1 && \
       ! beszel_proxy_preflight "$BESZEL_PROXY_MODE" true; then
        print_error "${BESZEL_PROXY_PREFLIGHT_ERROR:-Не удалось проверить reverse proxy.}"
        show_continue_prompt || true
        return 1
    fi
    if ss -H -ltn 'sport = :8090' 2>/dev/null | grep -q .; then
        print_error "Локальный порт 8090 уже занят другим приложением."
        echo -e "${DARKGRAY}Beszel ещё не изменял конфигурацию reverse proxy; освободите порт и повторите установку.${NC}"
        show_continue_prompt || true
        return 1
    fi
    if [ "$_is_ip_mode" = true ] && [ "$BESZEL_PROXY_MODE" != "standalone" ]; then
        print_error "Для существующего $(beszel_proxy_mode_label "$BESZEL_PROXY_MODE") нужен домен Beszel."
        echo -e "${DARKGRAY}Официальный reverse proxy уже занимает 443 и выпускает сертификаты по домену.${NC}"
        show_continue_prompt || true
        return 1
    fi
    print_prompt_value "Вариант установки" "$(beszel_proxy_install_variant_label "$BESZEL_PROXY_MODE")"
    echo

    # ─── Сертификат ───
    local BESZEL_PORT="8090"
    local SSL_CERT SSL_KEY CERT_DOMAIN CERT_HOST_FULLCHAIN CERT_HOST_KEY
    local base_domain
    if [ "$_is_ip_mode" = true ]; then
        base_domain="$BESZEL_DOMAIN"
    else
        base_domain=$(extract_domain "$BESZEL_DOMAIN")
    fi

    local _le_found
    if [ "$BESZEL_PROXY_MODE" = "caddy" ]; then
        CERT_DOMAIN="$BESZEL_DOMAIN"
    elif [ "$BESZEL_PROXY_MODE" = "nginx" ]; then
        local BESZEL_EMAIL="admin@${base_domain}"
        reading_inline "Email для Let's Encrypt ${DARKGRAY}[${BESZEL_EMAIL}]${NC}:" BESZEL_EMAIL "$BESZEL_EMAIL"
        [[ $? -eq 2 ]] && return 1
        (
            beszel_proxy_nginx_issue_certificate beszel "$BESZEL_DOMAIN" "$BESZEL_EMAIL"
        ) </dev/null &
        if ! show_spinner --step "Получение сертификата Beszel"; then
            print_error "Не удалось получить сертификат для ${BESZEL_DOMAIN}"
            show_continue_prompt || true
            return 1
        fi
        CERT_DOMAIN="$BESZEL_DOMAIN"
    else
        _le_found=$(le_live_basename "$BESZEL_DOMAIN" 2>/dev/null) || _le_found=""
        if [ -n "$_le_found" ]; then
        print_cert_exists "${BESZEL_DOMAIN}"
        CERT_DOMAIN="$_le_found"
        CERT_HOST_FULLCHAIN="/etc/letsencrypt/live/${CERT_DOMAIN}/fullchain.pem"
        CERT_HOST_KEY="/etc/letsencrypt/live/${CERT_DOMAIN}/privkey.pem"
    elif _le_found=$(le_live_basename "$base_domain" 2>/dev/null) && [ -n "$_le_found" ]; then
        print_cert_exists "${base_domain}"
        CERT_DOMAIN="$_le_found"
        CERT_HOST_FULLCHAIN="/etc/letsencrypt/live/${CERT_DOMAIN}/fullchain.pem"
        CERT_HOST_KEY="/etc/letsencrypt/live/${CERT_DOMAIN}/privkey.pem"
    elif [ "$_is_ip_mode" = true ]; then
        local SELF_SIGNED_DIR
        SELF_SIGNED_DIR=$(mktemp -d) || return 1
        ( _beszel_generate_self_signed_cert "$BESZEL_DOMAIN" "$SELF_SIGNED_DIR" ) </dev/null &
        if ! show_spinner --step "Генерация самоподписанного сертификата" || \
           [ ! -s "${SELF_SIGNED_DIR}/fullchain.pem" ] || [ ! -s "${SELF_SIGNED_DIR}/privkey.pem" ]; then
            rm -rf "$SELF_SIGNED_DIR"
            print_error "Не удалось создать самоподписанный сертификат"
            show_continue_prompt || true
            return 1
        fi
        CERT_DOMAIN="$BESZEL_DOMAIN"
        CERT_HOST_FULLCHAIN="${SELF_SIGNED_DIR}/fullchain.pem"
        CERT_HOST_KEY="${SELF_SIGNED_DIR}/privkey.pem"
    else
        show_arrow_menu "${BLUE}🔒  Получение SSL сертификата${NC}" \
            "🌐  ACME (Let's Encrypt HTTP-01)" \
            "☁️   Cloudflare (DNS-01 Wildcard)" \
            "🔷  Gcore (DNS-01 Wildcard)" \
            "──────────────────────────────────────" \
            "❌  Отмена"
        local cert_choice=$?
        [[ $cert_choice -eq 255 ]] && return 0

        case $cert_choice in
            0) # ACME
                reading_inline "Email для Let's Encrypt:" BESZEL_EMAIL
                [[ $? -eq 2 ]] && return 1
                if [ -z "$BESZEL_EMAIL" ]; then
                    print_error "Email не может быть пустым"
                    show_continue_prompt || return 0
                    return 0
                fi
                echo
                if ! get_cert_acme "$BESZEL_DOMAIN" "$BESZEL_EMAIL"; then
                    echo
                    show_certificate_failure_prompt
                    return 0
                fi
                _le_found=$(le_live_basename "$BESZEL_DOMAIN" 2>/dev/null) || _le_found=""
                if [ -n "$_le_found" ]; then
                    CERT_DOMAIN="$_le_found"
                else
                    CERT_DOMAIN=$(printf '%s' "$BESZEL_DOMAIN" | tr '[:upper:]' '[:lower:]')
                fi
                CERT_HOST_FULLCHAIN="/etc/letsencrypt/live/${CERT_DOMAIN}/fullchain.pem"
                CERT_HOST_KEY="/etc/letsencrypt/live/${CERT_DOMAIN}/privkey.pem"
                ;;
            1) # Cloudflare
                reading_inline "Email для Let's Encrypt:" BESZEL_EMAIL
                [[ $? -eq 2 ]] && return 1
                if [ -z "$BESZEL_EMAIL" ]; then
                    print_error "Email не может быть пустым"
                    show_continue_prompt || return 0
                    return 0
                fi
                if [ ! -f "/etc/letsencrypt/cloudflare.ini" ]; then
                    setup_cloudflare_credentials || return 1
                fi
                echo
                if ! get_cert_cloudflare "$base_domain" "$BESZEL_EMAIL"; then
                    echo
                    show_certificate_failure_prompt
                    return 0
                fi
                echo
                _le_found=$(le_live_basename "$base_domain" 2>/dev/null) || _le_found=""
                if [ -n "$_le_found" ]; then
                    CERT_DOMAIN="$_le_found"
                else
                    CERT_DOMAIN=$(printf '%s' "$base_domain" | tr '[:upper:]' '[:lower:]')
                fi
                CERT_HOST_FULLCHAIN="/etc/letsencrypt/live/${CERT_DOMAIN}/fullchain.pem"
                CERT_HOST_KEY="/etc/letsencrypt/live/${CERT_DOMAIN}/privkey.pem"
                ;;
            2) # Gcore
                reading_inline "Email для Let's Encrypt:" BESZEL_EMAIL
                [[ $? -eq 2 ]] && return 1
                if [ -z "$BESZEL_EMAIL" ]; then
                    print_error "Email не может быть пустым"
                    show_continue_prompt || return 0
                    return 0
                fi
                if [ ! -f "/etc/letsencrypt/gcore.ini" ]; then
                    setup_gcore_credentials || return 1
                fi
                echo
                if ! get_cert_gcore "$base_domain" "$BESZEL_EMAIL"; then
                    echo
                    show_certificate_failure_prompt
                    return 0
                fi
                echo
                _le_found=$(le_live_basename "$base_domain" 2>/dev/null) || _le_found=""
                if [ -n "$_le_found" ]; then
                    CERT_DOMAIN="$_le_found"
                else
                    CERT_DOMAIN=$(printf '%s' "$base_domain" | tr '[:upper:]' '[:lower:]')
                fi
                CERT_HOST_FULLCHAIN="/etc/letsencrypt/live/${CERT_DOMAIN}/fullchain.pem"
                CERT_HOST_KEY="/etc/letsencrypt/live/${CERT_DOMAIN}/privkey.pem"
                ;;
            *) return 0 ;;
        esac
        fi
    fi
    echo

    # Сразу после сообщения о сертификате показываем спиннер «Подготовка файлов»,
    # пока идут копирование сертификата в ssl/, firewall, при необходимости Docker и запись compose.
    local _BZ_ABORT=false
    local _bz_block_tmp _bz_prep_err
    _bz_block_tmp=$(mktemp)
    _bz_prep_err=$(mktemp)
    trap 'kill $(jobs -p) 2>/dev/null || true; _BZ_ABORT=true' INT

    (
        local NGINX_SSL_CERT NGINX_SSL_KEY
        local BESZEL_BLOCK=""
        if [ "$BESZEL_PROXY_MODE" = "standalone" ]; then
            # ─── SSL-пути автономного Nginx Beszel ───
            if [[ "$CERT_HOST_FULLCHAIN" == /etc/letsencrypt/* ]]; then
                nginx_copy_cert "$CERT_DOMAIN" || {
                    printf 'certificate' > "$_bz_prep_err"
                    exit 1
                }
                NGINX_SSL_CERT="/etc/nginx/ssl/${CERT_DOMAIN}/fullchain.pem"
                NGINX_SSL_KEY="/etc/nginx/ssl/${CERT_DOMAIN}/privkey.pem"
            else
                _beszel_copy_cert "$CERT_HOST_FULLCHAIN" "$CERT_HOST_KEY" "${DIR_NGINX}ssl/${CERT_DOMAIN}" || {
                    printf 'certificate' > "$_bz_prep_err"
                    exit 1
                }
                NGINX_SSL_CERT="/etc/nginx/ssl/${CERT_DOMAIN}/fullchain.pem"
                NGINX_SSL_KEY="/etc/nginx/ssl/${CERT_DOMAIN}/privkey.pem"
                rm -rf "${SELF_SIGNED_DIR:-}" 2>/dev/null || true
            fi

            local LISTEN_BLOCK="    listen 443 ssl;"
            nginx_ipv6_available && LISTEN_BLOCK+=$'\n    listen [::]:443 ssl;'

            local BESZEL_HTTP_BLOCK=""
            BESZEL_HTTP_BLOCK=$(cat <<NGINX
server {
    server_name ${BESZEL_DOMAIN};
    listen 80;
$(nginx_ipv6_available && printf '    listen [::]:80;\n')
    return 301 https://\$host\$request_uri;
}
NGINX
)

            BESZEL_BLOCK=$(cat <<NGINX
${BESZEL_HTTP_BLOCK}
server {
    server_name ${BESZEL_DOMAIN};
$(echo -e "$LISTEN_BLOCK")
    http2 on;

    ssl_certificate     ${NGINX_SSL_CERT};
    ssl_certificate_key ${NGINX_SSL_KEY};
    ssl_trusted_certificate ${NGINX_SSL_CERT};

    access_log /dev/stdout combined;

    location / {
        proxy_pass http://127.0.0.1:8090;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 360s;
        client_max_body_size 10m;
    }
}
NGINX
)
        else
            BESZEL_BLOCK=$(_beszel_external_block "$BESZEL_PROXY_MODE" "$BESZEL_DOMAIN") || exit 1
        fi

        if ! _beszel_setup_firewall "$BESZEL_PROXY_MODE"; then
            printf 'firewall' > "$_bz_prep_err"
            exit 1
        fi

        if ! { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; then
            export DEBIAN_FRONTEND=noninteractive
            local DPKG_OPTS='-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'
            systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
            local _lw=0
            while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock \
                  /var/cache/apt/archives/lock /var/lib/dpkg/lock-frontend \
                  >/dev/null 2>&1; do
                sleep 2; _lw=$(( _lw + 2 )); [ "$_lw" -ge 120 ] && break
            done
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq $DPKG_OPTS ca-certificates curl >/dev/null 2>&1
            beszel_install_docker_engine_official >/dev/null 2>&1 || true
            if ! { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; then
                printf 'docker' > "$_bz_prep_err"
                exit 1
            fi
        fi

        _beszel_write_compose "$BESZEL_PROXY_MODE" "$BESZEL_DOMAIN" || exit 1
        if [ "$BESZEL_PROXY_MODE" = "standalone" ]; then
            ensure_nginx
            if [ ! -f "${DIR_NGINX}nginx.conf" ]; then
                nginx_generate_minimal_conf
            fi
        fi

        printf '%s' "$BESZEL_BLOCK" > "$_bz_block_tmp"
     ) </dev/null &    if ! show_spinner "Подготовка файлов"; then
        local _prep_fail
        _prep_fail=$(cat "$_bz_prep_err" 2>/dev/null || true)
        rm -f "$_bz_prep_err" "$_bz_block_tmp"
        if [ "$_BZ_ABORT" = true ]; then
            echo
            echo -e "${YELLOW}⚠  Установка прервана — откат изменений...${NC}"
            _beszel_proxy_removal "$BESZEL_PROXY_MODE" "$BESZEL_DOMAIN" >/dev/null 2>&1 || true
            rm -rf "${DIR_BESZEL}" 2>/dev/null || true
            beszel_restore_interrupt_traps
            return 0
        fi
        beszel_restore_interrupt_traps
        if [ "$_prep_fail" = "docker" ]; then
            print_error "Docker не удалось установить"
            show_continue_prompt || return 0
            return 0
        fi
        if [ "$_prep_fail" = "firewall" ]; then
            print_error "Не удалось добавить правила Beszel в активный UFW."
            show_continue_prompt || return 0
            return 1
        fi
        if [ "$_prep_fail" = "certificate" ]; then
            rm -rf "${SELF_SIGNED_DIR:-}" 2>/dev/null || true
            print_error "Не удалось скопировать сертификат в конфигурацию автономного Nginx Beszel."
            show_continue_prompt || return 0
            return 1
        fi
        print_error "Не удалось подготовить файлы установки"
        show_continue_prompt || return 0
        return 0
    fi
    rm -f "$_bz_prep_err"

    local BESZEL_BLOCK
    BESZEL_BLOCK=$(cat "$_bz_block_tmp" 2>/dev/null || true)
    rm -f "$_bz_block_tmp"
    if [ -z "$BESZEL_BLOCK" ]; then
        beszel_restore_interrupt_traps
        print_error "Не удалось подготовить конфигурацию Beszel"
        show_continue_prompt || return 0
        return 0
    fi

    # Применяем только собственный маркированный блок. Внешний proxy проходит
    # проверку конфигурации до reload; при ошибке исходный файл восстанавливается.
    if ! _beszel_proxy_apply "$BESZEL_PROXY_MODE" "$BESZEL_DOMAIN" "$BESZEL_BLOCK"; then
        print_error "Не удалось безопасно добавить Beszel в $(beszel_proxy_mode_label "$BESZEL_PROXY_MODE")"
        rm -rf "${DIR_BESZEL}" 2>/dev/null || true
        beszel_restore_interrupt_traps
        show_continue_prompt || true
        return 1
    fi

    if [ "$_BZ_ABORT" = true ]; then
        echo
        echo -e "${YELLOW}⚠  Установка прервана — откат изменений...${NC}"
        _beszel_proxy_removal "$BESZEL_PROXY_MODE" "$BESZEL_DOMAIN" >/dev/null 2>&1 || true
        rm -rf "${DIR_BESZEL}" 2>/dev/null || true
        beszel_restore_interrupt_traps
        return 0
    fi

    # ─── Запускаем Beszel ───
    local _bz_install_log
    _bz_install_log=$(mktemp)
    (
        cd "${DIR_BESZEL}" && docker compose up -d > "$_bz_install_log" 2>&1
     ) </dev/null &    if ! show_spinner "Установка панели Beszel"; then
        if [ "$_BZ_ABORT" = true ]; then
            echo
            echo -e "${YELLOW}⚠  Установка прервана — откат изменений...${NC}"
            docker compose -f "${DIR_BESZEL}docker-compose.yml" down --volumes >/dev/null 2>&1 || true
            rm -rf "${DIR_BESZEL}" 2>/dev/null || true
            _beszel_proxy_removal "$BESZEL_PROXY_MODE" "$BESZEL_DOMAIN" >/dev/null 2>&1 || true
            beszel_restore_interrupt_traps
            return 0
        fi
        echo
        local _bz_err_detail
        _bz_err_detail=$(tail -40 "$_bz_install_log" 2>/dev/null)
        if [ -z "$_bz_err_detail" ] && [ -f "${DIR_BESZEL}docker-compose.yml" ]; then
            _bz_err_detail=$(cd "${DIR_BESZEL}" && docker compose logs --no-log-prefix 2>&1 | tail -40) || true
        fi
        rm -f "$_bz_install_log"
        if [ -n "$_bz_err_detail" ]; then
            echo -e "${DARKGRAY}── Подробности ──────────────────────────${NC}"
            echo "$_bz_err_detail"
            echo -e "${DARKGRAY}────────────────────────────────────────${NC}"
        fi
        show_continue_prompt || return 0
        return 0
    fi
    rm -f "$_bz_install_log"

    # Не перезаписываем уже существующий локальный агент, даже если его
    # конфигурация не принадлежит этому менеджеру.
    if ! _beszel_agent_present; then
        if _beszel_existing_agent_volume; then
            _agent_volume_conflict=true
        else
            (
                _beszel_wait_api && _beszel_auto_install_agent
            ) </dev/null &
            if ! show_spinner "Подключение агента мониторинга"; then
                _agent_setup_failed=true
            fi
        fi
    fi

    if [ "$_BZ_ABORT" = true ]; then
        echo
        echo -e "${YELLOW}⚠  Установка прервана — откат изменений...${NC}"
        docker compose -f "${DIR_BESZEL}docker-compose.yml" down --volumes >/dev/null 2>&1 || true
        rm -rf "${DIR_BESZEL}" 2>/dev/null || true
        _beszel_proxy_removal "$BESZEL_PROXY_MODE" "$BESZEL_DOMAIN" >/dev/null 2>&1 || true
        beszel_restore_interrupt_traps
        return 0
    fi

    if [ "$BESZEL_PROXY_MODE" = "standalone" ]; then
        (nginx_reload ) </dev/null &
        if ! show_spinner "Запуск Nginx"; then
            KEEP_CURSOR_HIDDEN=
            trap - RETURN
            print_error "Hub установлен, но автономный Nginx Beszel не применил конфигурацию."
            echo -e "${DARKGRAY}Проверьте конфигурацию: cd ${DIR_NGINX} && docker compose logs nginx${NC}"
            show_continue_prompt || true
            return 1
        fi
    fi

    KEEP_CURSOR_HIDDEN=
    trap - RETURN

    clear
    echo -e "${BLUE}══════════════════════════════════════${NC}"
    echo -e "$(center "📊 Панель Beszel успешно установлена!" "$GREEN")"
    echo -e "${BLUE}══════════════════════════════════════${NC}"
    echo
    echo -e "${YELLOW}🔗 Панель мониторинга: ${WHITE}https://${BESZEL_DOMAIN}${NC}"
    if [ "$_agent_volume_conflict" = true ]; then
        echo
        print_warning "Локальный агент пропущен: найден Docker volume без конфигурации Beszel Manager."
    elif [ "$_agent_setup_failed" = true ]; then
        echo
        print_warning "Hub установлен, но локальный Agent не подключился автоматически. Проверьте статус: beszel agent status"
        if [ -s "${DIR_BESZEL}first-run-recovery.txt" ]; then
            print_warning "Временный доступ для восстановления сохранён в ${DIR_BESZEL}first-run-recovery.txt (права 0600). Удалите файл после входа и смены пароля."
        fi
    fi
    echo
    echo -e "${DARKGRAY}──────────────────────────────────────${NC}"
    echo
    echo -e "${DARKGRAY}При первом входе создайте свою учётную запись администратора.${NC}"
    echo
    echo -e "${BLUE}══════════════════════════════════════${NC}"
    beszel_restore_interrupt_traps
    show_install_complete_prompt || return 0
}

# ─── Изменение домена Beszel ───
change_domain_beszel() {
    if ! is_beszel_installed; then
        print_error "Beszel не установлен"
        return 1
    fi

    KEEP_CURSOR_HIDDEN=1
    trap 'KEEP_CURSOR_HIDDEN=; tput civis 2>/dev/null || true; stty sane 2>/dev/null || true; trap - RETURN' RETURN

    clear
    echo -e "${BLUE}══════════════════════════════════════${NC}"
    echo -e "$(center "🌐 Изменить домен для панели Beszel" "$BLUE")"
    echo -e "${BLUE}══════════════════════════════════════${NC}"
    echo

    local NEW_DOMAIN
    prompt_domain_with_retry \
        "${YELLOW}Новый домен или IP для Beszel ${DARKGRAY}[например beszel.com]:${NC}" \
        NEW_DOMAIN true false false true || return 1
    if ! _beszel_valid_host "$NEW_DOMAIN"; then
        print_error "Введите корректное имя хоста или IPv4 адрес без URL и порта."
        show_continue_prompt || true
        return 1
    fi
    if [ -n "${KEEP_CURSOR_HIDDEN:-}" ]; then
        tput civis 2>/dev/null || true
    fi
    local _cd_ip=false
    if [[ "$NEW_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _cd_ip=true
    else
        NEW_DOMAIN=$(printf '%s' "$NEW_DOMAIN" | tr '[:upper:]' '[:lower:]')
    fi
    echo
    echo

    local _change_proxy_mode _change_mode_rc
    _change_proxy_mode=$(_beszel_proxy_mode 2>/dev/null)
    _change_mode_rc=$?
    if [ "$_change_mode_rc" -ne 0 ]; then
        print_error "Схема reverse proxy этой установки требует ручной миграции. Домен не изменён."
        show_continue_prompt || true
        return 1
    fi
    if [ "$_change_proxy_mode" = "caddy" ] || [ "$_change_proxy_mode" = "nginx" ]; then
        if [ "$_cd_ip" = true ]; then
            print_error "Для $(beszel_proxy_mode_label "$_change_proxy_mode") укажите домен, а не IP."
            show_continue_prompt || true
            return 1
        fi
        local _old_domain _external_block _agent_update_failed=false
        _old_domain=$(beszel_proxy_state_get beszel DOMAIN 2>/dev/null || true)
        if [ "$_change_proxy_mode" = "nginx" ]; then
            local BESZEL_EMAIL="admin@$(extract_domain "$NEW_DOMAIN")"
            reading_inline "Email для Let's Encrypt ${DARKGRAY}[${BESZEL_EMAIL}]${NC}:" BESZEL_EMAIL "$BESZEL_EMAIL"
            [[ $? -eq 2 ]] && return 1
            (beszel_proxy_nginx_issue_certificate beszel "$NEW_DOMAIN" "$BESZEL_EMAIL") </dev/null &
            if ! show_spinner --step "Получение сертификата Beszel"; then
                print_error "Не удалось получить сертификат для ${NEW_DOMAIN}"
                show_continue_prompt || true
                return 1
            fi
        fi
        _external_block=$(_beszel_external_block "$_change_proxy_mode" "$NEW_DOMAIN") || return 1
        if [ "$_change_proxy_mode" = "caddy" ]; then
            beszel_proxy_caddy_apply_block beszel "$NEW_DOMAIN" "$_external_block"
        else
            beszel_proxy_nginx_apply_block beszel "$NEW_DOMAIN" "$_external_block"
        fi
        if [ $? -ne 0 ]; then
            print_error "Новая конфигурация не прошла проверку. Старый домен сохранён."
            show_continue_prompt || true
            return 1
        fi
        if ! _beszel_compose_env_set "${DIR_BESZEL}docker-compose.yml" APP_URL "https://${NEW_DOMAIN}" || \
           ! (cd "$DIR_BESZEL" && docker compose up -d >/dev/null 2>&1); then
            print_error "Reverse proxy переключён, но не удалось обновить APP_URL Hub."
            echo -e "${DARKGRAY}Проверьте ${DIR_BESZEL}docker-compose.yml и повторите docker compose up -d.${NC}"
            show_continue_prompt || true
            return 1
        fi
        if [ "$_change_proxy_mode" = "nginx" ] && [ -n "$_old_domain" ] && [ "$_old_domain" != "$NEW_DOMAIN" ]; then
            rm -rf "${BESZEL_PROXY_REMNAWAVE_DIR%/}/nginx/beszel-app-ssl/beszel/${_old_domain}" 2>/dev/null || true
        fi
        printf '%s\n' "$_change_proxy_mode" > "$(_beszel_proxy_mode_file)"
        if is_beszel_agent_installed; then
            local _AGENT_HUB
            _AGENT_HUB=$(_beszel_compose_env_get "${DIR_BESZEL_AGENT}docker-compose.yml" HUB_URL 2>/dev/null || true)
            if [[ "$_AGENT_HUB" != "http://127.0.0.1"* ]] && [ -n "$_AGENT_HUB" ]; then
                _beszel_update_agent_hub_url "https://${NEW_DOMAIN}" || _agent_update_failed=true
            fi
        fi
        KEEP_CURSOR_HIDDEN=
        trap - RETURN
        print_success "Домен Beszel изменён"
        if [ "$_agent_update_failed" = true ]; then
            print_warning "Hub работает на новом домене, но HUB_URL агента не удалось обновить. Проверьте /opt/beszel-agent/docker-compose.yml."
        fi
        echo
        echo -e "${YELLOW}🔗 Новый адрес панели:${NC}"
        echo -e "${WHITE}https://${NEW_DOMAIN}${NC}"
        show_continue_prompt || return 0
        return 0
    fi

    # Получаем сертификат
    local CERT_DOMAIN CERT_HOST_FULLCHAIN CERT_HOST_KEY
    local base_domain
    if [ "$_cd_ip" = true ]; then
        base_domain="$NEW_DOMAIN"
    else
        base_domain=$(extract_domain "$NEW_DOMAIN")
    fi

    if [ "$_cd_ip" = true ]; then
        local SELF_SIGNED_DIR
        SELF_SIGNED_DIR=$(mktemp -d) || return 1
        ( _beszel_generate_self_signed_cert "$NEW_DOMAIN" "$SELF_SIGNED_DIR" ) </dev/null &
        if ! show_spinner --step "Генерация самоподписанного сертификата" || \
           [ ! -s "${SELF_SIGNED_DIR}/fullchain.pem" ] || [ ! -s "${SELF_SIGNED_DIR}/privkey.pem" ]; then
            rm -rf "$SELF_SIGNED_DIR"
            print_error "Не удалось создать самоподписанный сертификат"
            show_continue_prompt || true
            return 1
        fi
        CERT_DOMAIN="$NEW_DOMAIN"
        CERT_HOST_FULLCHAIN="${SELF_SIGNED_DIR}/fullchain.pem"
        CERT_HOST_KEY="${SELF_SIGNED_DIR}/privkey.pem"
    else
        local _le_found
        _le_found=$(le_live_basename "$NEW_DOMAIN" 2>/dev/null) || _le_found=""
        if [ -n "$_le_found" ]; then
            print_cert_exists "${NEW_DOMAIN}"
            CERT_DOMAIN="$_le_found"
            CERT_HOST_FULLCHAIN="/etc/letsencrypt/live/${CERT_DOMAIN}/fullchain.pem"
            CERT_HOST_KEY="/etc/letsencrypt/live/${CERT_DOMAIN}/privkey.pem"
        elif _le_found=$(le_live_basename "$base_domain" 2>/dev/null) && [ -n "$_le_found" ]; then
            print_cert_exists "${base_domain}"
            CERT_DOMAIN="$_le_found"
            CERT_HOST_FULLCHAIN="/etc/letsencrypt/live/${CERT_DOMAIN}/fullchain.pem"
            CERT_HOST_KEY="/etc/letsencrypt/live/${CERT_DOMAIN}/privkey.pem"
        else
            show_arrow_menu "${BLUE}🔒  Получение SSL сертификата${NC}" \
            "🌐  ACME (Let's Encrypt HTTP-01)" \
            "☁️   Cloudflare (DNS-01 Wildcard)" \
            "🔷  Gcore (DNS-01 Wildcard)" \
            "──────────────────────────────────────" \
            "❌  Отмена"
        local cert_choice=$?
        [[ $cert_choice -eq 255 ]] && return 0

        case $cert_choice in
            0)
                reading_inline "Email для Let's Encrypt:" BESZEL_EMAIL
                [[ $? -eq 2 ]] && return 1
                if [ -z "$BESZEL_EMAIL" ]; then
                    print_error "Email не может быть пустым"
                    show_continue_prompt || return 0
                    return 0
                fi
                if ! get_cert_acme "$NEW_DOMAIN" "$BESZEL_EMAIL"; then
                    echo
                    show_certificate_failure_prompt
                    return 0
                fi
                _le_found=$(le_live_basename "$NEW_DOMAIN" 2>/dev/null) || _le_found=""
                if [ -n "$_le_found" ]; then
                    CERT_DOMAIN="$_le_found"
                else
                    CERT_DOMAIN=$(printf '%s' "$NEW_DOMAIN" | tr '[:upper:]' '[:lower:]')
                fi
                CERT_HOST_FULLCHAIN="/etc/letsencrypt/live/${CERT_DOMAIN}/fullchain.pem"
                CERT_HOST_KEY="/etc/letsencrypt/live/${CERT_DOMAIN}/privkey.pem"
                ;;
            1)
                reading_inline "Email для Let's Encrypt:" BESZEL_EMAIL
                [[ $? -eq 2 ]] && return 1
                if [ -z "$BESZEL_EMAIL" ]; then
                    print_error "Email не может быть пустым"
                    show_continue_prompt || return 0
                    return 0
                fi
                if [ ! -f "/etc/letsencrypt/cloudflare.ini" ]; then
                    setup_cloudflare_credentials || return 1
                fi
                if ! get_cert_cloudflare "$base_domain" "$BESZEL_EMAIL"; then
                    echo
                    show_certificate_failure_prompt
                    return 0
                fi
                echo
                _le_found=$(le_live_basename "$base_domain" 2>/dev/null) || _le_found=""
                if [ -n "$_le_found" ]; then
                    CERT_DOMAIN="$_le_found"
                else
                    CERT_DOMAIN=$(printf '%s' "$base_domain" | tr '[:upper:]' '[:lower:]')
                fi
                CERT_HOST_FULLCHAIN="/etc/letsencrypt/live/${CERT_DOMAIN}/fullchain.pem"
                CERT_HOST_KEY="/etc/letsencrypt/live/${CERT_DOMAIN}/privkey.pem"
                ;;
            2)
                reading_inline "Email для Let's Encrypt:" BESZEL_EMAIL
                [[ $? -eq 2 ]] && return 1
                if [ -z "$BESZEL_EMAIL" ]; then
                    print_error "Email не может быть пустым"
                    show_continue_prompt || return 0
                    return 0
                fi
                if [ ! -f "/etc/letsencrypt/gcore.ini" ]; then
                    setup_gcore_credentials || return 1
                fi
                if ! get_cert_gcore "$base_domain" "$BESZEL_EMAIL"; then
                    echo
                    show_certificate_failure_prompt
                    return 0
                fi
                echo
                _le_found=$(le_live_basename "$base_domain" 2>/dev/null) || _le_found=""
                if [ -n "$_le_found" ]; then
                    CERT_DOMAIN="$_le_found"
                else
                    CERT_DOMAIN=$(printf '%s' "$base_domain" | tr '[:upper:]' '[:lower:]')
                fi
                CERT_HOST_FULLCHAIN="/etc/letsencrypt/live/${CERT_DOMAIN}/fullchain.pem"
                CERT_HOST_KEY="/etc/letsencrypt/live/${CERT_DOMAIN}/privkey.pem"
                ;;
            *) return 0 ;;
        esac
        fi
    fi

    local NGINX_SSL_CERT NGINX_SSL_KEY
    if [[ "$CERT_HOST_FULLCHAIN" == /etc/letsencrypt/* ]]; then
        if ! nginx_copy_cert "$CERT_DOMAIN"; then
            print_error "Не удалось скопировать сертификат Let's Encrypt для автономного Nginx Beszel."
            show_continue_prompt || true
            return 1
        fi
        NGINX_SSL_CERT="/etc/nginx/ssl/${CERT_DOMAIN}/fullchain.pem"
        NGINX_SSL_KEY="/etc/nginx/ssl/${CERT_DOMAIN}/privkey.pem"
    else
        if ! _beszel_copy_cert "$CERT_HOST_FULLCHAIN" "$CERT_HOST_KEY" "${DIR_NGINX}ssl/${CERT_DOMAIN}"; then
            rm -rf "${SELF_SIGNED_DIR:-}" 2>/dev/null || true
            print_error "Не удалось скопировать сертификат для автономного Nginx Beszel."
            show_continue_prompt || true
            return 1
        fi
        NGINX_SSL_CERT="/etc/nginx/ssl/${CERT_DOMAIN}/fullchain.pem"
        NGINX_SSL_KEY="/etc/nginx/ssl/${CERT_DOMAIN}/privkey.pem"
        rm -rf "${SELF_SIGNED_DIR:-}" 2>/dev/null || true
    fi

    local LISTEN_BLOCK="    listen 443 ssl;"
    nginx_ipv6_available && LISTEN_BLOCK+=$'\n    listen [::]:443 ssl;'

    local BESZEL_HTTP_BLOCK=""
    BESZEL_HTTP_BLOCK=$(cat <<NGINX
server {
    server_name ${NEW_DOMAIN};
    listen 80;
$(nginx_ipv6_available && printf '    listen [::]:80;\n')
    return 301 https://\$host\$request_uri;
}
NGINX
)

    local BESZEL_BLOCK
    BESZEL_BLOCK=$(cat <<NGINX
${BESZEL_HTTP_BLOCK}
server {
    server_name ${NEW_DOMAIN};
$(echo -e "$LISTEN_BLOCK")
    http2 on;

    ssl_certificate     ${NGINX_SSL_CERT};
    ssl_certificate_key ${NGINX_SSL_KEY};
    ssl_trusted_certificate ${NGINX_SSL_CERT};

    access_log /dev/stdout combined;

    location / {
        proxy_pass http://127.0.0.1:8090;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX
)

    nginx_add_server_block "BESZEL" "$BESZEL_BLOCK"

    (nginx_reload ) </dev/null &
    if ! show_spinner "Перезапуск Nginx"; then
        KEEP_CURSOR_HIDDEN=
        trap - RETURN
        print_error "Nginx не применил новую конфигурацию Beszel."
        show_continue_prompt || true
        return 1
    fi

    if ! _beszel_compose_env_set "${DIR_BESZEL}docker-compose.yml" APP_URL "https://${NEW_DOMAIN}" || \
       ! (cd "$DIR_BESZEL" && docker compose up -d >/dev/null 2>&1); then
        KEEP_CURSOR_HIDDEN=
        trap - RETURN
        print_error "Не удалось обновить APP_URL Hub. Reverse proxy уже настроен на новый домен."
        show_continue_prompt || true
        return 1
    fi

    # Если агент использует публичный домен (не localhost) — обновляем его HUB_URL
    local _agent_update_failed=false
    if is_beszel_agent_installed; then
        local _AGENT_HUB
        _AGENT_HUB=$(_beszel_compose_env_get "${DIR_BESZEL_AGENT}docker-compose.yml" HUB_URL 2>/dev/null || true)
        if [[ "$_AGENT_HUB" != "http://127.0.0.1"* ]] && [ -n "$_AGENT_HUB" ]; then
            ( _beszel_update_agent_hub_url "https://${NEW_DOMAIN}" ) </dev/null &
            if ! show_spinner "Обновление адреса агента"; then
                _agent_update_failed=true
            fi
        fi
    fi
    KEEP_CURSOR_HIDDEN=
    trap - RETURN

    echo
    print_success "Домен Beszel изменён"
    if [ "$_agent_update_failed" = true ]; then
        print_warning "Hub работает на новом домене, но HUB_URL агента не удалось обновить. Проверьте /opt/beszel-agent/docker-compose.yml."
    fi
    echo
    echo -e "${YELLOW}🔗 Новый адрес панели:${NC}"
    echo -e "${WHITE}https://${NEW_DOMAIN}${NC}"
    show_continue_prompt || return 0
}

# ─── Изменение адреса хаба для локального агента ───
change_agent_hub_url() {
    clear
    echo -e "${BLUE}══════════════════════════════════════${NC}"
    echo -e "${GREEN}    🔗  Изменить адрес хаба агента${NC}"
    echo -e "${BLUE}══════════════════════════════════════${NC}"
    echo

    if ! is_beszel_agent_installed; then
        print_error "Агент Beszel не установлен"
        return 1
    fi

    local CURRENT_HUB_URL
    CURRENT_HUB_URL=$(_beszel_compose_env_get "${DIR_BESZEL_AGENT}docker-compose.yml" HUB_URL 2>/dev/null || true)

    echo -e "${DARKGRAY}Текущий адрес хаба: ${WHITE}${CURRENT_HUB_URL:-не указан}${NC}"
    echo

    local NEW_HUB_URL
    reading_inline "Новый домен/ip хаба ${DARKGRAY}(например example.com)${YELLOW}:" NEW_HUB_URL
    [[ $? -eq 2 ]] && return 1
    if [ -z "$NEW_HUB_URL" ]; then
        print_error "Адрес не может быть пустым"
        echo; show_continue_prompt || return 1; return 1
    fi

    NEW_HUB_URL=$(_beszel_normalize_hub_url "$NEW_HUB_URL") || {
        print_error "Укажите домен/IP с необязательным портом, без пути и параметров."
        show_continue_prompt || true
        return 1
    }

    echo

    local CURRENT_KEY CURRENT_TOKEN
    CURRENT_KEY=$(_beszel_compose_env_get "${DIR_BESZEL_AGENT}docker-compose.yml" KEY 2>/dev/null || true)
    CURRENT_TOKEN=$(_beszel_compose_env_get "${DIR_BESZEL_AGENT}docker-compose.yml" TOKEN 2>/dev/null || true)

    # ─── Новый ключ ───
    local NEW_KEY
    reading_inline "Новый публичный ключ (Enter оставить без изменений):" NEW_KEY
    [[ $? -eq 2 ]] && return 1
    [ -z "$NEW_KEY" ] && NEW_KEY="$CURRENT_KEY"

    echo

    # ─── Новый токен ───
    local NEW_TOKEN
    reading_inline "Новый токен (Enter оставить без изменений):" NEW_TOKEN
    [[ $? -eq 2 ]] && return 1
    [ -z "$NEW_TOKEN" ] && NEW_TOKEN="$CURRENT_TOKEN"

    echo
    echo

    local _agent_compose_backup
    _agent_compose_backup=$(mktemp) || return 1
    cp -p "${DIR_BESZEL_AGENT}docker-compose.yml" "$_agent_compose_backup" || {
        rm -f "$_agent_compose_backup"
        return 1
    }
    (
        _beszel_compose_env_set "${DIR_BESZEL_AGENT}docker-compose.yml" HUB_URL "$NEW_HUB_URL" &&
        _beszel_compose_env_set "${DIR_BESZEL_AGENT}docker-compose.yml" KEY "$NEW_KEY" &&
        _beszel_compose_env_set "${DIR_BESZEL_AGENT}docker-compose.yml" TOKEN "$NEW_TOKEN" &&
        chmod 600 "${DIR_BESZEL_AGENT}docker-compose.yml" &&
        cd "${DIR_BESZEL_AGENT}" && docker compose up -d --force-recreate >/dev/null 2>&1
    ) </dev/null &
    if ! show_spinner "Применение настроек агента"; then
        cp -p "$_agent_compose_backup" "${DIR_BESZEL_AGENT}docker-compose.yml"
        rm -f "$_agent_compose_backup"
        print_error "Не удалось применить настройки агента. Старая конфигурация восстановлена."
        show_continue_prompt || true
        return 1
    fi
    rm -f "$_agent_compose_backup"

    echo
    echo -e "${YELLOW}🔗 Новый адрес хаба:${NC}"
    echo -e "${WHITE}${NEW_HUB_URL}${NC}"
    show_continue_prompt || return 0
}

uninstall_beszel() {
    local _force=false
    [[ "${1:-}" == "--force" ]] && _force=true
    if _beszel_hub_present && ! _beszel_managed_by_beszel; then
        [ "$_force" = true ] && return 2
        _beszel_show_external_install "Beszel"
        return 2
    fi
    local _beszel_proxy_mode_value _proxy_mode_rc
    _beszel_proxy_mode_value=$(_beszel_proxy_mode 2>/dev/null)
    _proxy_mode_rc=$?
    if [ "$_proxy_mode_rc" -ne 0 ]; then
        print_error "Схема reverse proxy этой установки требует ручной миграции. Hub не удалён."
        show_continue_prompt || true
        return 1
    fi

    if [ "$_force" = false ]; then
        if ! confirm_nav --delete "🗑️  Удаление панели Beszel"; then
            return
        fi
    fi

    KEEP_CURSOR_HIDDEN=1
    trap 'KEEP_CURSOR_HIDDEN=; tput civis 2>/dev/null || true; trap - RETURN' RETURN

    (
        cd "${DIR_BESZEL}" 2>/dev/null &&
            docker compose down -v --rmi all >/dev/null 2>&1
    ) </dev/null &
    if ! show_spinner "Удаление контейнеров панели Beszel"; then
        KEEP_CURSOR_HIDDEN=
        trap - RETURN
        print_error "Не удалось удалить контейнер Hub. Конфигурация сохранена. Проверьте Docker и повторите."
        show_continue_prompt || true
        return 1
    fi

    _beszel_proxy_removal "$_beszel_proxy_mode_value" >/dev/null 2>&1 || true

    # Перезапускаем или удаляем nginx
    if [ "$_beszel_proxy_mode_value" = "standalone" ]; then
        if nginx_has_users; then
            (nginx_reload ) </dev/null &        show_spinner "Перезапуск Nginx"
        else
            (nginx_teardown ) </dev/null &        show_spinner "Удаление Nginx"
        fi
    fi

    rm -rf "${DIR_BESZEL}"

    [ "$_force" = true ] && return 0

    KEEP_CURSOR_HIDDEN=
    trap - RETURN

    _beszel_post_delete_success_screen "🗑️  Удаление панели Beszel" "✅ Панель Beszel была успешно удалёна!"
}

install_beszel_agent() {
    show_screen_header "🖥️  Подключение агента Beszel" "$BLUE"

    if _beszel_agent_present && ! _beszel_agent_managed_by_beszel; then
        _beszel_show_external_install "Beszel Agent"
        return 1
    fi
    if is_beszel_agent_installed; then
        echo
        print_success "Агент Beszel уже установлен"
        show_continue_prompt || return 0
        return 0
    fi
    if ! _beszel_agent_present && _beszel_existing_agent_volume; then
        print_error "Найден Docker volume агента без конфигурации Beszel Manager."
        echo -e "${DARKGRAY}Установка остановлена, чтобы не переназначить существующие данные.${NC}"
        show_continue_prompt || true
        return 1
    fi

    local BESZEL_HUB_URL BESZEL_AGENT_PORT BESZEL_KEY BESZEL_TOKEN
    BESZEL_HUB_URL=""
    BESZEL_AGENT_PORT="45876"
    BESZEL_KEY=""
    BESZEL_TOKEN=""
    local _step=1

    while [ "$_step" -le 4 ]; do
        show_screen_header "🖥️  Подключение агента Beszel" "$BLUE"
        echo -e "${DARKGRAY}В панели Beszel нажмите «Добавить систему», затем скопируйте ключ и токен.${NC}"
        echo
        [ "$_step" -gt 1 ] && print_prompt_value "Домен панели Beszel" "$BESZEL_HUB_URL"
        [ "$_step" -gt 2 ] && print_prompt_value "Порт агента" "$BESZEL_AGENT_PORT"
        [ "$_step" -gt 3 ] && print_prompt_value "Ключ" "$BESZEL_KEY"
        case $_step in
            1) # URL
                _mt_read_input BESZEL_HUB_URL "Домен панели Beszel ${DARKGRAY}(например monitor.example.com):" ""
                if [ $? -eq 0 ]; then
                    if [ -z "$BESZEL_HUB_URL" ]; then
                        continue
                    else
                        (( _step++ ))
                    fi
                else
                    return 0   # Esc на 1-м шаге — выход в меню Beszel
                fi ;;
            2) # Порт
                _mt_read_input BESZEL_AGENT_PORT "Порт агента ${DARKGRAY}(по умолчанию 45876):" "45876"
                if [ $? -eq 0 ]; then
                    [ -z "$BESZEL_AGENT_PORT" ] && BESZEL_AGENT_PORT="45876"
                    if [[ "$BESZEL_AGENT_PORT" =~ ^[0-9]+$ ]] && [ "$BESZEL_AGENT_PORT" -ge 1 ] && [ "$BESZEL_AGENT_PORT" -le 65535 ]; then
                        BESZEL_AGENT_PORT=$((10#$BESZEL_AGENT_PORT))
                        (( _step++ ))
                    else
                        echo
                        print_error "Порт должен быть числом от 1 до 65535"
                        CONTINUE_ENTER_LABEL="Повторить" show_continue_prompt "Назад"
                        [ $? -eq 0 ] || (( _step-- ))
                    fi
                else
                    (( _step-- ))
                fi ;;
            3) # Ключ
                _mt_read_input BESZEL_KEY "Ключ ${DARKGRAY}(публичный ключ из панели):" ""
                if [ $? -eq 0 ]; then
                    if [ -z "$BESZEL_KEY" ]; then
                        continue
                    else
                        (( _step++ ))
                    fi
                else
                    (( _step-- ))
                fi ;;
            4) # Токен
                _mt_read_input BESZEL_TOKEN "Токен ${DARKGRAY}(токен из панели):" ""
                if [ $? -eq 0 ]; then
                    if [ -z "$BESZEL_TOKEN" ]; then
                        continue
                    else
                        (( _step++ ))
                    fi
                else
                    (( _step-- ))
                fi ;;
        esac
    done

    BESZEL_HUB_URL=$(_beszel_normalize_hub_url "$BESZEL_HUB_URL") || {
        print_error "Укажите домен/IP с необязательным портом, без пути и параметров."
        show_continue_prompt || true
        return 1
    }

    local -a BESZEL_HUB_IPS=()
    mapfile -t BESZEL_HUB_IPS < <(_beszel_resolve_hub_ips "$BESZEL_HUB_URL")
    if [ "${#BESZEL_HUB_IPS[@]}" -eq 0 ]; then
        print_error "Не удалось получить IP панели из адреса ${BESZEL_HUB_URL}. Проверьте DNS и повторите установку."
        show_continue_prompt || true
        return 1
    fi
    echo
    echo -e "${DARKGRAY}IP панели для правила входящего доступа: ${BESZEL_HUB_IPS[*]}${NC}"
    echo -e "${DARKGRAY}Домен должен указывать напрямую на сервер Hub, без CDN или прокси.${NC}"

    echo
    echo

    KEEP_CURSOR_HIDDEN=1
    trap 'KEEP_CURSOR_HIDDEN=; tput civis 2>/dev/null || true; stty sane 2>/dev/null || true; trap - RETURN' RETURN

    # ─── Шаг 1: Обновление системы и установка пакетов ───
    (
        export DEBIAN_FRONTEND=noninteractive
        local DPKG_OPTS='-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'

        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq $DPKG_OPTS ca-certificates curl wget >/dev/null 2>&1
        if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
            beszel_install_docker_engine_official >/dev/null 2>&1 || true
        fi
     ) </dev/null &    show_spinner --step "Обновление пакетов системы"
    echo

    # ─── Правило для агента — только если UFW уже активен ───
    local FIREWALL_RC=0
    _beszel_setup_firewall --agent-node "${BESZEL_AGENT_PORT}" "${BESZEL_HUB_IPS[@]}" || FIREWALL_RC=$?
    if [ "$FIREWALL_RC" -ne 0 ]; then
        KEEP_CURSOR_HIDDEN=
        trap - RETURN
        case "$FIREWALL_RC" in
            2) print_error "UFW не активен. Включите UFW с сохранённым доступом по SSH и повторите установку Agent." ;;
            *) print_error "Не удалось безопасно ограничить порт агента правилами UFW." ;;
        esac
        show_continue_prompt || true
        return 1
    fi

    # ─── Шаг 2: Создаём файлы ───
    (
        _beszel_write_agent_compose "$BESZEL_AGENT_PORT" "$BESZEL_KEY" "$BESZEL_TOKEN" "$BESZEL_HUB_URL"
     ) </dev/null &    show_spinner --step "Подготовка файлов"

    (
        cd "${DIR_BESZEL_AGENT}" && docker compose up -d >/dev/null 2>&1
     ) </dev/null &    if ! show_spinner --step "Добавление агента Beszel"; then
        KEEP_CURSOR_HIDDEN=
        trap - RETURN
        echo
        print_error "Не удалось запустить агент. Проверьте логи: cd ${DIR_BESZEL_AGENT} && docker compose logs"
        show_continue_prompt || return 0
        return 0
    fi

    KEEP_CURSOR_HIDDEN=
    trap - RETURN

    echo
    echo -e "${GREEN}✅ Агент Beszel успешно установлен!${NC}"
    echo
    echo -e "${BLUE}══════════════════════════════════════${NC}"
    show_install_complete_prompt || return 0
}

uninstall_beszel_agent() {
    local _force=false
    [[ "${1:-}" == "--force" ]] && _force=true

    if _beszel_agent_present && ! _beszel_agent_managed_by_beszel; then
        [ "$_force" = true ] && return 2
        _beszel_show_external_install "Beszel Agent"
        return 2
    fi

    if [ "$_force" = false ]; then
        if ! confirm_nav --delete "🗑️  Удаление агента Beszel"; then
            return
        fi
    fi

    KEEP_CURSOR_HIDDEN=1
    trap 'KEEP_CURSOR_HIDDEN=; tput civis 2>/dev/null || true; trap - RETURN' RETURN

    local AGENT_PORT_STORED
    AGENT_PORT_STORED=$(_beszel_compose_env_get "${DIR_BESZEL_AGENT}docker-compose.yml" LISTEN 2>/dev/null || true)

    (
        cd "${DIR_BESZEL_AGENT}" 2>/dev/null &&
            docker compose down -v --rmi all >/dev/null 2>&1
    ) </dev/null &
    if ! show_spinner --step "Удаление агента Beszel"; then
        KEEP_CURSOR_HIDDEN=
        trap - RETURN
        print_error "Не удалось удалить контейнер Agent. Конфигурация сохранена. Проверьте Docker и повторите."
        show_continue_prompt || true
        return 1
    fi

    beszel_ufw_remove_rules_by_comment "BESZEL" "$AGENT_PORT_STORED" || true
    beszel_ufw_remove_rules_by_comment "Beszel Agent" "$AGENT_PORT_STORED" || true

    rm -rf "${DIR_BESZEL_AGENT}"

    [ "$_force" = true ] && return 0

    KEEP_CURSOR_HIDDEN=
    trap - RETURN

    _beszel_post_delete_success_screen "🗑️  Удаление агента Beszel" "✅ Агент Beszel был успешно удалён!"
}
