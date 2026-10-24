# ═══════════════════════════════════════════════
# СЕРТИФИКАТЫ
# ═══════════════════════════════════════════════

# Парсинг ошибки certbot в человекочитаемое сообщение
_parse_cert_error() {
    local log_file="$1"
    local domain="${2:-}"
    local raw
    raw=$(cat "$log_file" 2>/dev/null)

    if echo "$raw" | grep -qiE "dns.*problem|NXDOMAIN|no valid A|Incorrect TXT|DNS problem"; then
        echo "DNS-запись не настроена или не указывает на этот сервер"
    elif echo "$raw" | grep -qiE "Could not bind TCP port 80|Address already in use|Порт 80 занят"; then
        echo "Порт 80 занят другим процессом — остановите сторонний веб-сервер и повторите"
    elif echo "$raw" | grep -qiE "connection refused|Could not connect|Timeout|timed out|port 80"; then
        local domain_ip="" server_ip=""
        if [ -n "$domain" ] && declare -F resolve_domain_ip >/dev/null 2>&1; then
            domain_ip=$(resolve_domain_ip "$domain" 2>/dev/null || true)
        fi
        if declare -F get_server_ip >/dev/null 2>&1; then
            server_ip=$(get_server_ip 2>/dev/null || true)
        fi
        if [ -n "$domain" ] && [ -z "$domain_ip" ]; then
            echo "DNS-запись домена ${domain} ещё не появилась — дождитесь её распространения"
        elif [ -n "$domain_ip" ] && [ -n "$server_ip" ] && [ "$server_ip" != "unknown" ] && \
             [ "$domain_ip" != "$server_ip" ]; then
            echo "Домен ${domain} всё ещё указывает на ${domain_ip}, а IP этого сервера — ${server_ip}; дождитесь обновления DNS"
        else
            echo "Let's Encrypt не смог подключиться к порту 80 — проверьте внешний firewall, NAT и правила провайдера"
        fi
    elif echo "$raw" | grep -qiE "too many requests|rate.limit|rate limit"; then
        echo "Превышен лимит запросов Let's Encrypt — повторите через час"
    elif echo "$raw" | grep -qiE "unauthorized|403|invalid response"; then
        echo "Домен не прошёл проверку — убедитесь что DNS указывает на этот сервер"
    elif echo "$raw" | grep -qiE "invalid domain|not a FQDN|malformed"; then
        echo "Некорректное доменное имя"
    elif echo "$raw" | grep -qiE "cloudflare.*error|API Token|dns_cloudflare"; then
        echo "Ошибка Cloudflare API — проверьте токен и права доступа"
    elif echo "$raw" | grep -qiE "gcore.*error|dns_gcore|apitoken.*gcore"; then
        echo "Ошибка Gcore API — проверьте токен"
    else
        local detail
        detail=$(grep -iE "Detail:|Error:|FAILED|Problem|certbot: error" "$log_file" 2>/dev/null \
            | grep -v "^-\|Saving debug\|^$" | head -2 \
            | sed 's/.*Detail: *//;s/.*Error: *//;s/.*certbot: error: *//')
        if [ -n "$detail" ]; then
            echo "$detail"
        else
            # Последний шанс: любые непустые строки из хвоста лога
            local _tail
            _tail=$(grep -vE '^[[:space:]]*$|^-{5}|Saving debug log|^Cert is due|^IMPORTANT' \
                "$log_file" 2>/dev/null | tail -4 | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//')
            if [ -n "$_tail" ]; then
                echo "$_tail"
            else
                echo "Не удалось определить причину — проверьте DNS и сетевые настройки"
            fi
        fi
    fi
}

# Реальное имя подкаталога в /etc/letsencrypt/live/ (регистр, линия -0001 не ищем).
le_live_basename() {
    local d="$1"
    local low cand
    low=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')
    for cand in "$d" "$low"; do
        if [ -f "/etc/letsencrypt/live/${cand}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${cand}/privkey.pem" ]; then
            printf '%s' "$cand"
            return 0
        fi
    done
    if [ -d /etc/letsencrypt/live ]; then
        for dir in /etc/letsencrypt/live/*/; do
            [ -d "$dir" ] || continue
            cand=$(basename "$dir")
            if [ "$(printf '%s' "$cand" | tr '[:upper:]' '[:lower:]')" = "$low" ]; then
                if [ -f "${dir}fullchain.pem" ] && [ -f "${dir}privkey.pem" ]; then
                    printf '%s' "$cand"
                    return 0
                fi
            fi
        done
    fi
    return 1
}

handle_certificates() {
    local -n domains_ref=$1
    local cert_method="$2"
    local email="$3"

    for domain in "${!domains_ref[@]}"; do
        local base_domain
        base_domain=$(extract_domain "$domain")

        # Проверяем наличие сертификата
        if [ -d "/etc/letsencrypt/live/$domain" ] || [ -d "/etc/letsencrypt/live/$base_domain" ]; then
            print_cert_exists "$domain"
            continue
        fi

        case "$cert_method" in
            1)
                # Cloudflare DNS-01 (wildcard)
                get_cert_cloudflare "$base_domain" "$email" || return 1
                ;;
            2)
                # ACME HTTP-01
                get_cert_acme "$domain" "$email" || return 1
                ;;
            3)
                # Gcore DNS-01 (wildcard)
                get_cert_gcore "$base_domain" "$email" || return 1
                ;;
            *)
                print_error "Неизвестный метод сертификации"
                return 1
                ;;
        esac
    done

    # Не добавляем лишние пустые строки — следующий шаг должен идти сразу.
}

detect_cert_method() {
    local domain="$1"
    local base_domain
    base_domain=$(extract_domain "$domain")

    if [ -d "/etc/letsencrypt/live/$domain" ]; then
        echo "2"
    elif [ -d "/etc/letsencrypt/live/$base_domain" ] && [ -f "/etc/letsencrypt/live/$base_domain/fullchain.pem" ]; then
        echo "1"
    else
        echo "2"
    fi
}

check_if_certificates_needed() {
    local -n domains_ref=$1

    for domain in "${!domains_ref[@]}"; do
        local base_domain
        base_domain=$(extract_domain "$domain")

        if [ ! -d "/etc/letsencrypt/live/$domain" ] && [ ! -d "/etc/letsencrypt/live/$base_domain" ]; then
            return 0
        fi
    done

    return 1
}

# Устанавливает certbot и docker если не установлены
_ensure_system_deps() {
    local _need_certbot=false _need_docker=false _need_cron=false
    command -v certbot >/dev/null 2>&1 || _need_certbot=true
    { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; } || _need_docker=true
    command -v crontab >/dev/null 2>&1 || _need_cron=true

    [ "$_need_certbot" = false ] && [ "$_need_docker" = false ] && [ "$_need_cron" = false ] && return 0

    (
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
        if [ "$_need_certbot" = true ]; then
            apt-get install -y -qq $DPKG_OPTS certbot python3-certbot-dns-cloudflare >/dev/null 2>&1
        fi
        if [ "$_need_cron" = true ]; then
            apt-get install -y -qq $DPKG_OPTS cron >/dev/null 2>&1
        fi
        if [ "$_need_docker" = true ]; then
            apt-get install -y -qq $DPKG_OPTS ca-certificates curl >/dev/null 2>&1
            beszel_install_docker_engine_official >/dev/null 2>&1 || true
        fi
        systemctl start cron 2>/dev/null || true
        systemctl enable cron 2>/dev/null || true
     ) </dev/null &    show_spinner --step "Обновление пакетов системы"

    if [ "$_need_certbot" = true ] && ! command -v certbot >/dev/null 2>&1; then
        print_error "certbot не удалось установить. Установите вручную: apt install certbot"
        return 1
    fi
    if [ "$_need_docker" = true ] && { ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; }; then
        print_error "Docker не удалось установить. Установите вручную: curl -fsSL https://get.docker.com | sh"
        return 1
    fi
    if [ "$_need_cron" = true ] && ! command -v crontab >/dev/null 2>&1; then
        print_error "cron не удалось установить. Установите вручную: apt install cron"
        return 1
    fi
}

# Для обратной совместимости: вызывает _ensure_system_deps
_ensure_certbot() { _ensure_system_deps; }

beszel_certbot_install_http01_hook() {
    local hook_dst="${BESZEL_CERTBOT_HTTP01_HOOK_DST:-/usr/local/sbin/beszel-certbot-http01-hook}"
    local hook_src="${DIR_SCRIPT%/}/lib/extra/beszel_certbot_http01_hook.sh"
    [ -f "$hook_src" ] || return 1
    mkdir -p "$(dirname "$hook_dst")"
    cp -f "$hook_src" "$hook_dst" || return 1
    chmod 755 "$hook_dst"
    printf '%s' "$hook_dst"
}

beszel_certbot_install_deploy_hook() {
    local hook_dst="${BESZEL_CERTBOT_DEPLOY_HOOK_DST:-/usr/local/sbin/beszel-certbot-deploy-hook}"
    local hook_src="${DIR_SCRIPT%/}/lib/extra/beszel_certbot_deploy_hook.sh"
    [ -f "$hook_src" ] || return 1
    mkdir -p "$(dirname "$hook_dst")"
    cp -f "$hook_src" "$hook_dst" || return 1
    chmod 755 "$hook_dst"
    printf '%s' "$hook_dst"
}

# Installs native Certbot renewal hooks. They are picked up by both the
# distro systemd timer and manual `certbot renew`, so the Beszel proxy's
# certificate copies are refreshed regardless of how renewal was started.
beszel_certbot_install_renew_cron() {
    local _cert_method="${1:-2}"
    local http_hook deploy_hook
    local _le_dir="${BESZEL_LETSENCRYPT_DIR:-/etc/letsencrypt}"
    local _cron_file="${BESZEL_CERTBOT_CRON_FILE:-/etc/cron.d/beszel-certbot-renew}"
    http_hook=$(beszel_certbot_install_http01_hook) || return 1
    deploy_hook=$(beszel_certbot_install_deploy_hook) || return 1

    mkdir -p "$_le_dir/renewal-hooks/pre" \
        "$_le_dir/renewal-hooks/post" \
        "$_le_dir/renewal-hooks/deploy"

    cat > "$_le_dir/renewal-hooks/pre/beszel-http01-prepare" <<EOF
#!/bin/sh
exec "${http_hook}" pre
EOF
    cat > "$_le_dir/renewal-hooks/post/beszel-http01-restore" <<EOF
#!/bin/sh
exec "${http_hook}" post
EOF
    cat > "$_le_dir/renewal-hooks/deploy/beszel-sync-nginx" <<EOF
#!/bin/sh
exec "${deploy_hook}"
EOF
    chmod 755 \
        "$_le_dir/renewal-hooks/pre/beszel-http01-prepare" \
        "$_le_dir/renewal-hooks/post/beszel-http01-restore" \
        "$_le_dir/renewal-hooks/deploy/beszel-sync-nginx"

    # Prefer the distribution timer. Keep a cron fallback for minimal images
    # where certbot.timer is unavailable.
    if command -v systemctl >/dev/null 2>&1 && \
       systemctl list-unit-files certbot.timer --no-legend 2>/dev/null | grep -q '^certbot.timer'; then
        rm -f "$_cron_file"
        systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    elif command -v crontab >/dev/null 2>&1; then
        mkdir -p "$(dirname "$_cron_file")"
        cat > "$_cron_file" <<'EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3,15 * * * root certbot renew --quiet >/dev/null 2>&1
EOF
        chmod 644 "$_cron_file"
        systemctl start cron 2>/dev/null || true
        systemctl enable cron 2>/dev/null || true
    fi

    : "$_cert_method"
}

# Устанавливает плагин certbot-dns-gcore через pip3 если ещё не установлен
_ensure_gcore_plugin() {
    if python3 -c "import certbot_dns_gcore" >/dev/null 2>&1; then
        return 0
    fi
    (
        export DEBIAN_FRONTEND=noninteractive
        local DPKG_OPTS='-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'
        # Устанавливаем pip3 если отсутствует
        if ! command -v pip3 >/dev/null 2>&1; then
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq $DPKG_OPTS python3-pip >/dev/null 2>&1
        fi
        pip3 install --quiet certbot-dns-gcore >/dev/null 2>&1
     ) </dev/null &    show_spinner --step "Установка плагина Gcore DNS"
    if ! python3 -c "import certbot_dns_gcore" >/dev/null 2>&1; then
        print_error "Не удалось установить certbot-dns-gcore. Установите вручную: pip3 install certbot-dns-gcore"
        return 1
    fi
}

get_cert_cloudflare() {
    local domain="$1"
    local email="$2"
    local dnorm
    dnorm=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')

    _ensure_certbot || return 1

    if [ ! -f "/etc/letsencrypt/cloudflare.ini" ]; then
        print_error "Файл /etc/letsencrypt/cloudflare.ini не найден"
        return 1
    fi

    local _tmp_log _exit_file
    _tmp_log=$(mktemp)
    _exit_file="${_tmp_log}.exit"

    (
        set +e
        certbot certonly --dns-cloudflare \
            --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
            --dns-cloudflare-propagation-seconds 60 \
            -d "$dnorm" -d "*.$dnorm" \
            --email "$email" --agree-tos --non-interactive \
            --key-type ecdsa > "$_tmp_log" 2>&1
        _ec=$?
        if [ "$_ec" -ne 0 ] && [ -f "$_tmp_log" ] && le_live_basename "$dnorm" >/dev/null 2>&1; then
            if grep -qiE 'Certificate not yet due for renewal|not yet due for renewal; no action taken' "$_tmp_log" 2>/dev/null; then
                _ec=0
            fi
        fi
        echo "$_ec" > "$_exit_file"
     ) </dev/null &    show_spinner --step "Получение wildcard сертификата для *.$dnorm"
    echo

    local _exit_code
    _exit_code=$(cat "$_exit_file" 2>/dev/null || echo 1)
    local _lebn
    _lebn=$(le_live_basename "$dnorm" 2>/dev/null) || _lebn=""
    if [ "$_exit_code" -ne 0 ] && [ -n "$_lebn" ] && [ -f "$_tmp_log" ] && \
        grep -qiE 'Certificate not yet due for renewal|not yet due for renewal; no action taken' "$_tmp_log" 2>/dev/null; then
        _exit_code=0
    fi
    if [ "$_exit_code" -ne 0 ] || [ -z "$_lebn" ]; then
        local _cert_reason _raw_log
        _cert_reason=$(_parse_cert_error "$_tmp_log")
        _raw_log=$(grep -vE '^[[:space:]]*$' "$_tmp_log" 2>/dev/null | tail -35)
        rm -f "$_tmp_log" "$_exit_file"
        echo
        print_error "Не удалось получить сертификат для $dnorm"
        echo -e "   ${DARKGRAY}Причина: ${_cert_reason}${NC}"
        # Показываем развёрнутый лог только если он содержит больше одной новой строки (=не дублирует Причину)
        local _raw_lines
        _raw_lines=$(echo "$_raw_log" | wc -l)
        if [ -n "$_raw_log" ] && [ "$_raw_lines" -gt 1 ]; then
            echo
            echo -e "${DARKGRAY}── Вывод certbot ───────────────────────${NC}"
            echo "$_raw_log"
            echo -e "${DARKGRAY}────────────────────────────────────────${NC}"
        fi
        return 1
    fi

    rm -f "$_tmp_log" "$_exit_file"

    beszel_certbot_install_renew_cron 1 || true
}

get_cert_acme() {
    local domain="$1"
    local email="$2"
    # Let's Encrypt и каталог live/ — в нижнем регистре; иначе дубликат и «не найдено».
    local dnorm
    dnorm=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')

    _ensure_certbot || return 1

    local _tmp_log _exit_file _phase_file _http_hook _spinner_rc=0
    _tmp_log=$(mktemp)
    _exit_file="${_tmp_log}.exit"
    _phase_file="${_tmp_log}.phase"

    _http_hook=$(beszel_certbot_install_http01_hook 2>/dev/null) || _http_hook=""
    (
        set +e
        printf 'prepare\n' > "$_phase_file"
        : > "$_tmp_log"
        if [ -z "$_http_hook" ] || ! BESZEL_HTTP01_FORCE_STOP=1 "$_http_hook" pre >"$_tmp_log" 2>&1; then
            echo 90 > "$_exit_file"
            exit 0
        fi

        printf 'certbot\n' > "$_phase_file"
        : > "$_tmp_log"
        certbot certonly --standalone \
            -d "$dnorm" \
            --email "$email" --agree-tos --non-interactive \
            --http-01-port 80 \
            --key-type ecdsa > "$_tmp_log" 2>&1
        _ec=$?
        if [ "$_ec" -ne 0 ] && [ -f "$_tmp_log" ] && le_live_basename "$dnorm" >/dev/null 2>&1; then
            if grep -qiE 'Certificate not yet due for renewal|not yet due for renewal; no action taken' "$_tmp_log" 2>/dev/null; then
                _ec=0
            fi
        fi
        echo "$_ec" > "$_exit_file"
     ) </dev/null &
    show_spinner --step "Получение сертификата для $dnorm" || _spinner_rc=$?

    # Restore Nginx and remove only the firewall rules created by pre, even
    # when Certbot failed or the spinner was interrupted.
    [ -z "$_http_hook" ] || "$_http_hook" post >/dev/null 2>&1 || true

    local _exit_code
    _exit_code=$(cat "$_exit_file" 2>/dev/null || echo 1)
    [ "$_spinner_rc" -eq 0 ] || _exit_code="$_spinner_rc"
    local _lebn
    _lebn=$(le_live_basename "$dnorm" 2>/dev/null) || _lebn=""
    if [ "$_exit_code" -ne 0 ] && [ -n "$_lebn" ] && [ -f "$_tmp_log" ] && \
        grep -qiE 'Certificate not yet due for renewal|not yet due for renewal; no action taken' "$_tmp_log" 2>/dev/null; then
        _exit_code=0
    fi
    if [ "$_exit_code" -ne 0 ] || [ -z "$_lebn" ]; then
        local _cert_reason _raw_log
        _cert_reason=$(_parse_cert_error "$_tmp_log" "$dnorm")
        _raw_log=$(grep -vE '^[[:space:]]*$' "$_tmp_log" 2>/dev/null | tail -35)
        local _failed_phase
        _failed_phase=$(cat "$_phase_file" 2>/dev/null || printf 'certbot')
        rm -f "$_tmp_log" "$_exit_file" "$_phase_file"
        echo
        if [ "$_failed_phase" = "prepare" ]; then
            print_error "Не удалось подготовить порт 80 для $dnorm"
        else
            print_error "Не удалось получить сертификат для $dnorm"
        fi
        echo -e "   ${DARKGRAY}Причина: ${_cert_reason}${NC}"
        local _raw_lines
        _raw_lines=$(echo "$_raw_log" | wc -l)
        if [ -n "$_raw_log" ] && [ "$_raw_lines" -gt 1 ]; then
            echo
            echo -e "${DARKGRAY}── Вывод certbot ────────────────────────────${NC}"
            echo "$_raw_log"
            echo -e "${DARKGRAY}────────────────────────────────────────────────${NC}"
        fi
        return 1
    fi

    rm -f "$_tmp_log" "$_exit_file" "$_phase_file"

    beszel_certbot_install_renew_cron 2 || true
}

setup_cloudflare_credentials() {
    reading "Введите Cloudflare API Token:" CF_TOKEN || return 1

    # Определяем тип токена:
    # Новый API Token (содержит буквы верхнего регистра — cfut_, cf_, etc.)
    # Старый Global API Key (только hex, строчные буквы и цифры)
    local _is_api_token=false
    if [[ "$CF_TOKEN" =~ [A-Z] ]] || [[ "$CF_TOKEN" =~ _ ]]; then
        _is_api_token=true
    fi

    local _cf_email=""
    if [ "$_is_api_token" = false ]; then
        reading "Введите Cloudflare Email (для Global API Key):" _cf_email || return 1
    fi

    # Шаг 1: проверяем что токен валиден и не отозван
    local _auth_header
    if [ "$_is_api_token" = true ]; then
        _auth_header="Authorization: Bearer $CF_TOKEN"
    else
        _auth_header="X-Auth-Key: $CF_TOKEN"
    fi

    local check
    if [ "$_is_api_token" = true ]; then
        check=$(curl -sS --connect-timeout 10 --max-time 45 -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
            -H "$_auth_header" | jq -r '.success' 2>/dev/null)
        if [ "$check" != "true" ]; then
            print_error "Cloudflare API Token невалиден или отозван"
            show_continue_prompt
            return 1
        fi
    fi

    # Шаг 2: проверяем доступ к зонам (Zone:Read)
    local zones_resp zones_ok zone_id
    if [ "$_is_api_token" = true ]; then
        zones_resp=$(curl -sS --connect-timeout 10 --max-time 45 -X GET "https://api.cloudflare.com/client/v4/zones?per_page=1" \
            -H "$_auth_header" -H "Content-Type: application/json" 2>/dev/null)
    else
        zones_resp=$(curl -sS --connect-timeout 10 --max-time 45 -X GET "https://api.cloudflare.com/client/v4/zones?per_page=1" \
            -H "X-Auth-Email: $_cf_email" -H "$_auth_header" -H "Content-Type: application/json" 2>/dev/null)
    fi
    zones_ok=$(echo "$zones_resp" | jq -r '.success' 2>/dev/null)
    zone_id=$(echo "$zones_resp" | jq -r '.result[0].id // empty' 2>/dev/null)

    if [ "$zones_ok" != "true" ]; then
        local _zones_err
        _zones_err=$(echo "$zones_resp" | jq -r '.errors[0].code // empty' 2>/dev/null)
        print_error "Токен не имеет доступа к зонам (код ошибки: ${_zones_err:-10000})"
        echo -e "   ${DARKGRAY}Убедитесь что токен имеет разрешение: Zone → Read${NC}"
        show_continue_prompt
        return 1
    fi

    # Шаг 3: проверяем Zone:DNS:Edit — пробуем создать тестовую TXT-запись и сразу удалить
    # GET /dns_records проверяет только Read, а certbot нужен Edit (POST)
    if [ -n "$zone_id" ]; then
        local create_resp create_ok record_id _dns_write_err
        if [ "$_is_api_token" = true ]; then
            create_resp=$(curl -sS --connect-timeout 10 --max-time 45 -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
                -H "$_auth_header" -H "Content-Type: application/json" \
                --data '{"type":"TXT","name":"_beszel-acme-test","content":"beszel-write-test","ttl":60}' 2>/dev/null)
        else
            create_resp=$(curl -sS --connect-timeout 10 --max-time 45 -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
                -H "X-Auth-Email: $_cf_email" -H "$_auth_header" -H "Content-Type: application/json" \
                --data '{"type":"TXT","name":"_beszel-acme-test","content":"beszel-write-test","ttl":60}' 2>/dev/null)
        fi
        create_ok=$(echo "$create_resp" | jq -r '.success' 2>/dev/null)

        if [ "$create_ok" = "true" ]; then
            # Удаляем тестовую запись
            record_id=$(echo "$create_resp" | jq -r '.result.id // empty' 2>/dev/null)
            if [ -n "$record_id" ]; then
                if [ "$_is_api_token" = true ]; then
                    curl -sS --connect-timeout 10 --max-time 45 -X DELETE "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
                        -H "$_auth_header" >/dev/null 2>&1
                else
                    curl -sS --connect-timeout 10 --max-time 45 -X DELETE "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
                        -H "X-Auth-Email: $_cf_email" -H "$_auth_header" >/dev/null 2>&1
                fi
            fi
        else
            _dns_write_err=$(echo "$create_resp" | jq -r '.errors[0].code // empty' 2>/dev/null)
            print_error "Токен не имеет прав на создание DNS-записей (код: ${_dns_write_err:-10000})"
            echo -e "   ${DARKGRAY}Токен имеет Zone:Read, но НЕТ Zone:DNS:Edit — именно оно нужно certbot${NC}"
            echo -e "   ${DARKGRAY}Создайте новый токен: dash.cloudflare.com/profile/api-tokens${NC}"
            echo -e "   ${DARKGRAY}Шаблон: Edit zone DNS → выберите нужную зону${NC}"
            show_continue_prompt
            return 1
        fi
    fi

    print_success "Cloudflare API Token подтверждён"

    mkdir -p /etc/letsencrypt
    if [ "$_is_api_token" = true ]; then
        cat > /etc/letsencrypt/cloudflare.ini <<EOF
dns_cloudflare_api_token = $CF_TOKEN
EOF
    else
        cat > /etc/letsencrypt/cloudflare.ini <<EOF
dns_cloudflare_email = $_cf_email
dns_cloudflare_api_key = $CF_TOKEN
EOF
    fi
    chmod 600 /etc/letsencrypt/cloudflare.ini
}

setup_gcore_credentials() {
    reading "Введите Gcore API Token:" GC_TOKEN || return 1

    # Проверяем что токен валиден через Gcore API
    local check_resp check_ok
    check_resp=$(curl -sS --connect-timeout 10 --max-time 30 \
        -X GET "https://api.gcore.com/dns/v2/zones?limit=1" \
        -H "Authorization: APIKey $GC_TOKEN" \
        -H "Content-Type: application/json" 2>/dev/null)
    check_ok=$(echo "$check_resp" | grep -c '"id"' 2>/dev/null || true)

    # Gcore возвращает JSON со списком зон — успех если нет "error"
    if echo "$check_resp" | grep -qiE '"error"|"status":4[0-9]{2}|Unauthorized|Forbidden'; then
        print_error "Gcore API Token невалиден или нет прав доступа к DNS зонам"
        echo -e "   ${DARKGRAY}Убедитесь что токен имеет доступ к DNS в личном кабинете Gcore${NC}"
        show_continue_prompt
        return 1
    fi

    print_success "Gcore API Token подтверждён"

    mkdir -p /etc/letsencrypt
    cat > /etc/letsencrypt/gcore.ini <<EOF
dns_gcore_apitoken = $GC_TOKEN
EOF
    chmod 600 /etc/letsencrypt/gcore.ini
}

get_cert_gcore() {
    local domain="$1"
    local email="$2"
    local dnorm
    dnorm=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')

    _ensure_certbot || return 1
    _ensure_gcore_plugin || return 1

    if [ ! -f "/etc/letsencrypt/gcore.ini" ]; then
        print_error "Файл /etc/letsencrypt/gcore.ini не найден"
        return 1
    fi

    local _tmp_log _exit_file
    _tmp_log=$(mktemp)
    _exit_file="${_tmp_log}.exit"

    (
        set +e
        certbot certonly --authenticator dns-gcore \
            --dns-gcore-credentials /etc/letsencrypt/gcore.ini \
            --dns-gcore-propagation-seconds 80 \
            -d "$dnorm" -d "*.$dnorm" \
            --email "$email" --agree-tos --non-interactive \
            --key-type ecdsa > "$_tmp_log" 2>&1
        _ec=$?
        if [ "$_ec" -ne 0 ] && [ -f "$_tmp_log" ] && le_live_basename "$dnorm" >/dev/null 2>&1; then
            if grep -qiE 'Certificate not yet due for renewal|not yet due for renewal; no action taken' "$_tmp_log" 2>/dev/null; then
                _ec=0
            fi
        fi
        echo "$_ec" > "$_exit_file"
     ) </dev/null &    show_spinner --step "Получение wildcard сертификата для *.$dnorm (Gcore)"
    echo

    local _exit_code
    _exit_code=$(cat "$_exit_file" 2>/dev/null || echo 1)
    local _lebn
    _lebn=$(le_live_basename "$dnorm" 2>/dev/null) || _lebn=""
    if [ "$_exit_code" -ne 0 ] && [ -n "$_lebn" ] && [ -f "$_tmp_log" ] && \
        grep -qiE 'Certificate not yet due for renewal|not yet due for renewal; no action taken' "$_tmp_log" 2>/dev/null; then
        _exit_code=0
    fi
    if [ "$_exit_code" -ne 0 ] || [ -z "$_lebn" ]; then
        local _cert_reason _raw_log
        _cert_reason=$(_parse_cert_error "$_tmp_log")
        _raw_log=$(grep -vE '^[[:space:]]*$' "$_tmp_log" 2>/dev/null | tail -35)
        rm -f "$_tmp_log" "$_exit_file"
        echo
        print_error "Не удалось получить сертификат для $dnorm"
        echo -e "   ${DARKGRAY}Причина: ${_cert_reason}${NC}"
        local _raw_lines
        _raw_lines=$(echo "$_raw_log" | wc -l)
        if [ -n "$_raw_log" ] && [ "$_raw_lines" -gt 1 ]; then
            echo
            echo -e "${DARKGRAY}── Вывод certbot ───────────────────────${NC}"
            echo "$_raw_log"
            echo -e "${DARKGRAY}────────────────────────────────────────${NC}"
        fi
        return 1
    fi

    rm -f "$_tmp_log" "$_exit_file"

    beszel_certbot_install_renew_cron 3 || true
}
