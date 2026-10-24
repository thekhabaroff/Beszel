# ═══════════════════════════════════════════════
# РАБОТА С ДОМЕНАМИ
# ═══════════════════════════════════════════════

extract_domain() {
    local full_domain="$1"
    local parts
    parts=$(echo "$full_domain" | tr '.' '\n' | wc -l)
    if [ "$parts" -gt 2 ]; then
        echo "$full_domain" | cut -d'.' -f2-
    else
        echo "$full_domain"
    fi
}

get_server_ip() {
    local ip=""
    
    # Пробуем несколько сервисов для получения IP адреса
    ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null)
    if [ -n "$ip" ] && [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$ip"
        return 0
    fi
    
    ip=$(curl -s4 --max-time 5 icanhazip.com 2>/dev/null)
    if [ -n "$ip" ] && [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$ip"
        return 0
    fi
    
    ip=$(curl -s4 --max-time 5 ident.me 2>/dev/null)
    if [ -n "$ip" ] && [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$ip"
        return 0
    fi
    
    # Фоллбек на локальный IP если нет доступа в интернет
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -n "$ip" ] && [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$ip"
        return 0
    fi
    
    echo "unknown"
}

resolve_domain_ip() {
    local domain="$1"
    local ip=""

    # 1. dig через публичные DNS (обходим локальный кэш)
    if command -v dig &>/dev/null; then
        ip=$(dig @8.8.8.8 +short +time=3 +tries=1 "$domain" A 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1)
        [ -n "$ip" ] && echo "$ip" && return 0
        ip=$(dig @1.1.1.1 +short +time=3 +tries=1 "$domain" A 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1)
        [ -n "$ip" ] && echo "$ip" && return 0
    fi

    # 2. nslookup через публичный DNS
    if command -v nslookup &>/dev/null; then
        ip=$(timeout 3 nslookup "$domain" 8.8.8.8 2>/dev/null | awk '/^Address:/{print $2}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1)
        [ -n "$ip" ] && echo "$ip" && return 0
    fi

    # 3. host через публичный DNS
    if command -v host &>/dev/null; then
        ip=$(timeout 3 host -t A "$domain" 8.8.8.8 2>/dev/null | awk '/has address/{print $NF}' | head -1)
        [ -n "$ip" ] && echo "$ip" && return 0
    fi

    # 4. getent (локальный резолвер, последний резерв)
    if command -v getent &>/dev/null; then
        ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1)
        [ -n "$ip" ] && echo "$ip" && return 0
    fi

    echo ""
}

_beszel_print_domain_missing_error() {
    local domain="$1"
    print_error "Домена ${YELLOW}${domain}${RED} не существует"
    echo -e "${RED}Проверьте запись домена или пропустите проверку.${NC}"
}

_beszel_print_domain_mismatch_error() {
    local domain="$1"
    local domain_ip="$2"
    local server_ip="$3"
    print_error "Домен ${YELLOW}${domain}${RED} указывает на ${YELLOW}${domain_ip}${RED}, а не на IP сервера ${YELLOW}${server_ip}${RED}"
    echo -e "${RED}Проверьте запись домена или пропустите проверку.${NC}"
}

check_domain() {
    local domain="$1"
    local check_ip="${2:-true}"
    
    # Получаем IP домена
    local domain_ip
    domain_ip=$(resolve_domain_ip "$domain")

    # Получаем IP сервера для сообщений об ошибках
    local server_ip
    server_ip=$(get_server_ip)

    if [ -z "$domain_ip" ]; then
        _beszel_print_domain_missing_error "$domain"
        return 1
    fi

    if [ "$check_ip" = false ]; then
        return 0
    fi

    # ═══════════════════════════════════════════════════════════
    # УЛУЧШЕННАЯ ПРОВЕРКА IP С ПОДДЕРЖКОЙ NAT/DOCKER/ПРОКСИ
    # ═══════════════════════════════════════════════════════════
    
    local ip_match=false
    
    # 1. Проверяем прямое совпадение с внешним IP
    if [ "$domain_ip" = "$server_ip" ]; then
        ip_match=true
    else
        # 2. Проверяем локальные IP интерфейсов (для Docker/NAT)
        local local_ips
        local_ips=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1')
        
        if [ -n "$local_ips" ]; then
            while IFS= read -r local_ip; do
                if [ "$domain_ip" = "$local_ip" ]; then
                    ip_match=true
                    break
                fi
            done <<< "$local_ips"
        fi
    fi
    
    # 3. HTTP fallback проверка (если IP не совпал)
    if [ "$ip_match" = false ]; then
        # Создаём временный токен для проверки
        local test_token
        test_token=$(openssl rand -hex 16)
        mkdir -p /var/www/html
        echo "$test_token" > "/var/www/html/.test_${test_token}.txt" 2>/dev/null
        
        # Пытаемся получить файл через домен
        local test_response
        test_response=$(curl -s -m 5 "http://${domain}/.test_${test_token}.txt" 2>/dev/null || echo "")
        
        # Удаляем тестовый файл
        rm -f "/var/www/html/.test_${test_token}.txt" 2>/dev/null
        
        # Если получили правильный ответ - домен указывает на этот сервер
        if [ "$test_response" = "$test_token" ]; then
            ip_match=true
        fi
    fi
    
    # ═══════════════════════════════════════════════════════════
    # ФИНАЛЬНАЯ ПРОВЕРКА
    # ═══════════════════════════════════════════════════════════
    
    if [ "$ip_match" = false ]; then
        _beszel_print_domain_mismatch_error "$domain" "$domain_ip" "$server_ip"
        return 1
    fi
    
    return 0
}

# Возврат: 0 — ок; 1 — отмена (Esc) / выход к вызывающему меню; 2 — Esc «шаг назад» (только с --back-on-esc при вводе, не в меню ошибки DNS)
prompt_domain_with_retry() {
    local _esc_back=false
    if [[ "${1:-}" == "--back-on-esc" ]]; then
        _esc_back=true
        shift
    fi
    local prompt_text="$1"
    local var_name="$2"
    local use_inline="${3:-false}" # сохранён для совместимости вызовов; ввод всегда inline --no-eol + спиннер на строке ввода (как Beszel)
    local skip_ip_check="${4:-false}"
    local forbid_ipv4="${5:-false}"
    local allow_ipv4="${6:-false}"

    while true; do
        reading_inline --no-eol "$prompt_text" "$var_name"
        local _rc=$?
        if [ $_rc -ne 0 ]; then
            if [ $_rc -eq 2 ] && [ "$_esc_back" = true ]; then
                return 2
            fi
            return 1
        fi

        if [ "$forbid_ipv4" = true ] && [[ "${!var_name}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo
            print_error "Укажите доменное имя (например monitor.example.com), а не IP-адрес."
            echo -e "${DARKGRAY}   Нужна DNS-запись на этот сервер и сертификат на имя хоста.${NC}"
            echo
            continue
        fi

        if [ "$allow_ipv4" = true ] && [[ "${!var_name}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo
            return 0
        fi

        local check_ip_flag=true
        [ "$skip_ip_check" = true ] && check_ip_flag=false

        # Проверка домена — спиннер на той же строке, что и ввод (как install_beszel)
        local _check_out _check_rc
        local _check_out_file _check_rc_file
        _check_out_file=$(mktemp)
        _check_rc_file=$(mktemp)
        (
            set +e
            check_domain "${!var_name}" "$check_ip_flag" > "$_check_out_file" 2>&1
            local _domain_check_rc=$?
            printf '%s\n' "$_domain_check_rc" > "$_check_rc_file"
            exit 0
        ) </dev/null &
        local _check_pid=$!
        beszel_domain_check_wait_inline "$_check_pid"
        _check_rc=$(cat "$_check_rc_file" 2>/dev/null)
        [[ "$_check_rc" =~ ^[0-9]+$ ]] || _check_rc=1
        _check_out=$(cat "$_check_out_file" 2>/dev/null)
        rm -f "$_check_out_file" "$_check_rc_file"

        # Выводим сообщение об ошибке (если есть) после очистки строки спиннера
        local _out_lines=0
        if [ -n "$_check_out" ]; then
            echo
            printf "%s\n" "$_check_out"
            _out_lines=$(echo "$_check_out" | wc -l)
        fi

        if [ "$_check_rc" = "0" ]; then
            echo
            return 0
        fi

        echo
        echo -e "${BLUE}══════════════════════════════════════${NC}"
        echo -e "${BLUE}Enter${DARKGRAY}: Повторить   ${BLUE}S${DARKGRAY}: Пропустить   ${BLUE}Esc${DARKGRAY}: Назад${NC}"

        # error_line + error_lines + empty + separator + action_prompt
        local _total_lines=$((_out_lines + 4))

        tput civis 2>/dev/null || true
        local key
        while true; do
            read -s -n 1 key
            if [[ "$key" == $'\x1b' ]]; then
                if _beszel_after_esc_is_bare; then
                    tput civis 2>/dev/null || true
                    echo
                    [ "$_esc_back" = true ] && return 2
                    return 1
                fi
                continue
            elif [[ "$key" == "s" || "$key" == "S" ]]; then
                tput civis 2>/dev/null || true
                echo
                local skip_lines=$((_total_lines + 1))
                for ((l=0; l<skip_lines; l++)); do
                    tput cuu1 2>/dev/null
                    tput el 2>/dev/null
                done
                return 0
            elif [[ "$key" == "" ]]; then
                tput civis 2>/dev/null || true
                local lines_up=$_total_lines
                for ((l=0; l<lines_up; l++)); do
                    tput cuu1 2>/dev/null
                    tput el 2>/dev/null
                done
                break
            fi
        done
    done
}

