# ═══════════════════════════════════════════════════════════════════════════
# IP geolocation and popular service availability
# ═══════════════════════════════════════════════════════════════════════════

_beszel_network_diagnostics_ensure_dependencies() {
    local -a missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v jq >/dev/null 2>&1 || missing+=(jq)
    [ "${#missing[@]}" -eq 0 ] && return 0
    command -v apt-get >/dev/null 2>&1 || return 1

    local install_log
    install_log=$(mktemp /tmp/beszel-diagnostics-packages.XXXXXX) || return 1
    (
        export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
        apt-get update -qq \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" &&
        apt-get install -y -qq \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            "${missing[@]}"
    ) </dev/null >"$install_log" 2>&1 &

    if ! show_spinner --install-step --pid "$!" \
        "Установка инструментов диагностики" "Инструменты установлены"; then
        show_install_error "Не удалось установить инструменты диагностики" "$install_log" || true
        rm -f "$install_log"
        return 1
    fi
    rm -f "$install_log"

    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1
}

_beszel_network_diagnostics_progress() {
    local pid="$1" progress_file="$2" label="$3" done_message="$4"
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0 service="Определение внешних IP и DNS" rc=0

    tput civis 2>/dev/null || true
    _SPINNER_INTERRUPTED=0
    trap '_SPINNER_INTERRUPTED=1' INT
    _spinner_lock_input

    while kill -0 "$pid" 2>/dev/null && [ "${_SPINNER_INTERRUPTED:-0}" != 1 ]; do
        if [ -s "$progress_file" ]; then
            service=$(tail -n 1 "$progress_file" 2>/dev/null) || service="Определение внешних IP и DNS"
            [ -n "$service" ] || service="Определение внешних IP и DNS"
        fi
        tput civis 2>/dev/null || true
        printf '\r\033[K%b%s%b  %s: %s' "$GREEN" "${spin[$i]}" "$NC" "$label" "$service"
        i=$(( (i + 1) % ${#spin[@]} ))
        sleep 0.08 || true
    done

    if [ "${_SPINNER_INTERRUPTED:-0}" = 1 ]; then
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        printf '\r\033[K'
        _spinner_unlock_input
        beszel_restore_interrupt_traps
        printf '%bОперация прервана (Ctrl+C).%b\n' "$YELLOW" "$NC" >&2
        return 130
    fi

    wait "$pid" 2>/dev/null || rc=$?
    printf '\r\033[K'
    if [ "$rc" -eq 0 ]; then
        print_success "$done_message"
    fi
    _spinner_unlock_input
    beszel_restore_interrupt_traps
    return "$rc"
}

_beszel_network_diagnostics_width() {
    local text="$1" width
    width=$(printf '%s' "$text" | LC_ALL=C tr -d '\200-\277' | wc -c 2>/dev/null | tr -d '[:space:]')
    printf '%s\n' "${width:-${#text}}"
}

_beszel_network_diagnostics_separator() {
    local title="$1" width=38 label label_width left right left_line="" right_line="" i
    label=" [ ${title} ] "
    label_width=$(_beszel_network_diagnostics_width "$label")
    [ "$label_width" -gt $((width - 6)) ] && width=$((label_width + 6))
    left=$(( (width - label_width) / 2 ))
    right=$(( width - label_width - left ))
    for ((i=0; i<left; i++)); do left_line+="─"; done
    for ((i=0; i<right; i++)); do right_line+="─"; done
    printf '%b%s%s%s%b\n' "$BLUE" "$left_line" "$label" "$right_line" "$NC"
}

# Align UTF-8 text in terminal columns; Bash printf widths count bytes.
_beszel_network_diagnostics_pad() {
    local text="$1" width="$2" visible padding
    visible=$(_beszel_network_diagnostics_width "$text")
    padding=$((width - visible))
    [ "$padding" -lt 0 ] && padding=0
    printf '%s%*s' "$text" "$padding" ''
}

_beszel_network_diagnostics_mask_ipv4() {
    local ip="$1" a b c d
    IFS='.' read -r a b c d <<< "$ip"
    if [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]]; then
        printf '%s.%s.*.*\n' "$a" "$b"
    else
        printf '%s\n' "$ip"
    fi
}

_beszel_network_diagnostics_mask_ipv6() {
    awk -v ip="$1" '
        BEGIN {
            ip = tolower(ip)
            if (ip !~ /^[0-9a-f:.]+$/) { print ip; exit }
            parts_count = split(ip, parts, "::")
            if (parts_count > 2) { print ip; exit }
            left_count = 0
            right_count = 0
            if (parts[1] != "") left_count = split(parts[1], left, ":")
            if (parts_count == 2 && parts[2] != "") right_count = split(parts[2], right, ":")
            missing = 8 - left_count - right_count
            idx = 0
            for (i = 1; i <= left_count; i++) groups[++idx] = left[i]
            if (parts_count == 2) for (i = 1; i <= missing; i++) groups[++idx] = "0"
            for (i = 1; i <= right_count; i++) groups[++idx] = right[i]
            if (idx < 4) { print ip; exit }
            for (i = 1; i <= 4; i++) if (groups[i] == "") groups[i] = "0"
            printf "%s:%s:%s:%s:*:*:*:*\n", groups[1], groups[2], groups[3], groups[4]
        }
    '
}

_beszel_network_diagnostics_country_name() {
    local json="$1" code="$2"
    jq -r --arg code "$code" '.country_names[$code] // $code' <<< "$json" 2>/dev/null
}

_beszel_network_diagnostics_geo_table_json() {
    jq '
        .results.geo = ((.results.custom // []) | map(select(.service == "Google" or .service == "YouTube")))
    ' <<< "$1" 2>/dev/null
}

_beszel_network_diagnostics_service_table_json() {
    jq '
        .results.custom = ((.results.custom // []) | map(select(.service != "Google" and .service != "YouTube")))
    ' <<< "$1" 2>/dev/null
}

_beszel_network_diagnostics_emit_addresses() {
    local json="$1" ip ip6 country4 country6 asn asn_name asn_display
    ip=$(jq -r '.ipv4 // empty' <<< "$json" 2>/dev/null)
    ip6=$(jq -r '.ipv6 // empty' <<< "$json" 2>/dev/null)
    [ -z "$ip" ] && [ -z "$ip6" ] && return 0

    echo
    _beszel_network_diagnostics_separator 'Внешние адреса'
    if [ -n "$ip" ]; then
        country4=$(jq -r '.registered_country_ipv4 // empty' <<< "$json" 2>/dev/null)
        if [ -z "$country4" ]; then
            country4=$(jq -r '(.results.primary // [])[] | select(.service == "maxmind.com") | .ipv4 // empty' <<< "$json" 2>/dev/null | head -n 1)
        fi
        if [[ "$country4" =~ ^[A-Z]{2}$ ]]; then
            country4=$(_beszel_network_diagnostics_country_name "$json" "$country4")
        fi
        case "$country4" in ''|—|N/A|null) country4='не определена' ;; esac
        printf '  %bIPv4:%b %s %b(зарегистрирован в %s)%b\n' "$DARKGRAY" "$NC" \
            "$(_beszel_network_diagnostics_mask_ipv4 "$ip")" "$DARKGRAY" "$country4" "$NC"
    fi
    if [ -n "$ip6" ]; then
        country6=$(jq -r '.registered_country_ipv6 // empty' <<< "$json" 2>/dev/null)
        if [ -z "$country6" ]; then
            country6=$(jq -r '(.results.primary // [])[] | select(.service == "maxmind.com") | .ipv6 // empty' <<< "$json" 2>/dev/null | head -n 1)
        fi
        if [[ "$country6" =~ ^[A-Z]{2}$ ]]; then
            country6=$(_beszel_network_diagnostics_country_name "$json" "$country6")
        fi
        case "$country6" in ''|—|N/A|null) country6='не определена' ;; esac
        printf '  %bIPv6:%b %s %b(зарегистрирован в %s)%b\n' "$DARKGRAY" "$NC" \
            "$(_beszel_network_diagnostics_mask_ipv6 "$ip6")" "$DARKGRAY" "$country6" "$NC"
    fi
    asn=$(jq -r '.asn // empty' <<< "$json" 2>/dev/null)
    asn_name=$(jq -r '.asn_name // empty' <<< "$json" 2>/dev/null)
    case "$asn" in
        AS*) asn_display="$asn" ;;
        '') asn_display='' ;;
        *) asn_display="AS${asn}" ;;
    esac
    [ -z "$asn_name" ] || asn_display="${asn_display:+${asn_display} }${asn_name}"
    printf '  %bASN:%b %s\n' "$DARKGRAY" "$NC" "${asn_display:-не определён}"
}

_beszel_network_diagnostics_value() {
    local value="$1" service="$2" group="$3" lower
    lower=$(printf '%s' "$value" | LC_ALL=C.UTF-8 tr '[:upper:]' '[:lower:]')
    if [ "$group" = geo ] && [[ "$service" == 'Google' || "$service" == 'YouTube' ]] && [[ "$value" =~ ^[A-Z]{2}$ ]]; then
        printf '%s\n' "$value"
        return 0
    fi
    if [ "$group" = custom ]; then
        if [ "$service" = 'Google Search Captcha' ]; then
            case "$lower" in
                yes*) printf 'Обнаружена\n' ;;
                no*) printf 'Не обнаружена\n' ;;
                n/a*|null*|'') printf 'Нет данных\n' ;;
                *) printf '%s\n' "$value" ;;
            esac
            return 0
        fi
        case "$lower" in
            yes*|available*|allowed*|ok*) printf 'Доступен\n'; return 0 ;;
            no*|unavailable*|blocked*|failed*) printf 'Недоступен\n'; return 0 ;;
            n/a*|null*|none*|'') printf 'Нет данных\n'; return 0 ;;
        esac
        if [[ "$value" =~ ^[A-Z]{2}$ ]]; then
            printf 'Доступен (%s)\n' "$value"
            return 0
        fi
    fi
    case "$lower" in n/a*|null*|none*|'') printf 'Нет данных\n' ;; *) printf '%s\n' "$value" ;; esac
}

_beszel_network_diagnostics_value_color() {
    local value="$1" service="$2"
    if [ "$service" = 'Google Search Captcha' ] && [[ "$value" == 'Не обнаружена'* || "$value" == 'не обнаружена'* || "$value" == No* || "$value" == no* ]]; then
        printf '%s\n' "$GREEN"
        return 0
    fi
    case "$value" in
        ''|N/A*|n/a*|null*|Null*|none*|None*|undefined*|Нет\ данных*|нет\ данных*|-|—) printf '%s\n' "$DARKGRAY" ;;
        No*|no*|Not*|not*|Недоступен*|недоступен*|Failed*|failed*|Blocked*|blocked*|Unavailable*|unavailable*) printf '%s\n' "$RED" ;;
        Yes*|yes*|Доступен*|доступен*|Доступна*|доступна*|Обнаружена*|обнаружена*|Не\ обнаружена*|не\ обнаружена*|OK*|ok*|Available*|available*|Allowed*|allowed*|[A-Z][A-Z]) printf '%s\n' "$GREEN" ;;
        *) printf '%s\n' "$WHITE" ;;
    esac
}

_beszel_network_diagnostics_emit_table() {
    local json="$1" key="$2" title="$3"
    local rows has_ipv6 service raw4 raw6 value4 value6 color4 color6
    local col_w=0 value4_w=8 value6_w=8 visible
    has_ipv6=$(jq -r '(.ipv6 // "") != ""' <<< "$json" 2>/dev/null)
    rows=$(jq -r --arg k "$key" '
        (.results[$k] // [])[]
        | [.service, (.ipv4 // "N/A" | tostring), (.ipv6 // "N/A" | tostring)]
        | @tsv
    ' <<< "$json" 2>/dev/null)
    [ -n "$rows" ] || return 0

    while IFS=$'\t' read -r service raw4 raw6; do
        [ -n "$service" ] || continue
        visible=$(_beszel_network_diagnostics_width "$service")
        [ "$visible" -gt "$col_w" ] && col_w=$visible
        value4=$(_beszel_network_diagnostics_value "$raw4" "$service" "$key")
        visible=$(_beszel_network_diagnostics_width "$value4")
        [ "$visible" -gt "$value4_w" ] && value4_w=$visible
        if [ "$has_ipv6" = true ]; then
            value6=$(_beszel_network_diagnostics_value "$raw6" "$service" "$key")
            visible=$(_beszel_network_diagnostics_width "$value6")
            [ "$visible" -gt "$value6_w" ] && value6_w=$visible
        fi
    done <<< "$rows"
    col_w=$((col_w + 4))
    [ "$col_w" -lt 27 ] && col_w=27
    value4_w=$((value4_w + 1))
    value6_w=$((value6_w + 1))

    echo
    _beszel_network_diagnostics_separator "$title"
    if [ "$has_ipv6" = true ]; then
        printf ' %b%s%s%s%b\n' "$DARKGRAY" \
            "$(_beszel_network_diagnostics_pad 'Сервис' "$col_w")" \
            "$(_beszel_network_diagnostics_pad 'IPv4' "$value4_w")" 'IPv6' "$NC"
    elif [ "$key" = geo ]; then
        printf ' %b%sСтрана%b\n' "$DARKGRAY" \
            "$(_beszel_network_diagnostics_pad 'Сервис' "$col_w")" "$NC"
    elif [ "$key" != primary ]; then
        printf ' %b%sРезультат%b\n' "$DARKGRAY" \
            "$(_beszel_network_diagnostics_pad 'Сервис' "$col_w")" "$NC"
    else
        printf ' %b%sIPv4%b\n' "$DARKGRAY" \
            "$(_beszel_network_diagnostics_pad 'Сервис' "$col_w")" "$NC"
    fi
    while IFS=$'\t' read -r service raw4 raw6; do
        [ -n "$service" ] || continue
        value4=$(_beszel_network_diagnostics_value "$raw4" "$service" "$key")
        color4=$(_beszel_network_diagnostics_value_color "$value4" "$service")
        if [ "$has_ipv6" = true ]; then
            value6=$(_beszel_network_diagnostics_value "$raw6" "$service" "$key")
            color6=$(_beszel_network_diagnostics_value_color "$value6" "$service")
            printf ' %b%s%b%b%s%b%b%s%b\n' \
                "$DARKGRAY" "$(_beszel_network_diagnostics_pad "$service" "$col_w")" "$NC" \
                "$color4" "$(_beszel_network_diagnostics_pad "$value4" "$value4_w")" "$NC" \
                "$color6" "$value6" "$NC"
        else
            printf ' %b%s%b%b%s%b\n' \
                "$DARKGRAY" "$(_beszel_network_diagnostics_pad "$service" "$col_w")" "$NC" \
                "$color4" "$value4" "$NC"
        fi
    done <<< "$rows"
}

_beszel_network_diagnostics_emit_country_summary() {
    local json="$1" rows code pct4 pct6 country has_ipv6 ipv4 ipv6
    local country_w code_w pct_w=8 visible
    country_w=$(_beszel_network_diagnostics_width 'Страна')
    code_w=$(_beszel_network_diagnostics_width 'Код')
    visible=$(_beszel_network_diagnostics_width '% IPv4')
    [ "$visible" -gt "$pct_w" ] && pct_w=$visible
    visible=$(_beszel_network_diagnostics_width '% IPv6')
    [ "$visible" -gt "$pct_w" ] && pct_w=$visible
    has_ipv6=$(jq -r '(.ipv6 // "") != ""' <<< "$json" 2>/dev/null)
    rows=$(jq -r '
        def codes($field; $names):
            [((.results.primary // []) + (.results.custom // []))[]
             | .[$field] as $code
             | select(($code | type) == "string" and ($code | test("^[A-Z]{2}$")) and ($names[$code] != null))
             | $code];
        (.country_names // {}) as $names
        | codes("ipv4"; $names) as $v4
        | codes("ipv6"; $names) as $v6
        | (($v4 + $v6) | unique) as $all
        | [$all[] as $code | {
            code: $code,
            p4: (if ($v4 | length) == 0 then 0 else (($v4 | map(select(. == $code)) | length) * 100 / ($v4 | length) | round) end),
            p6: (if ($v6 | length) == 0 then 0 else (($v6 | map(select(. == $code)) | length) * 100 / ($v6 | length) | round) end)
        }]
        | sort_by(-.p4, -.p6, .code)[]
        | [.code, (.p4 | tostring), (.p6 | tostring)] | @tsv
    ' <<< "$json" 2>/dev/null)
    [ -n "$rows" ] || return 0

    while IFS=$'\t' read -r code pct4 pct6; do
        [ -n "$code" ] || continue
        country=$(_beszel_network_diagnostics_country_name "$json" "$code")
        visible=$(_beszel_network_diagnostics_width "$country")
        [ "$visible" -gt "$country_w" ] && country_w=$visible
        visible=$(_beszel_network_diagnostics_width "$code")
        [ "$visible" -gt "$code_w" ] && code_w=$visible
    done <<< "$rows"
    country_w=$((country_w + 2))
    code_w=$((code_w + 2))

    echo
    _beszel_network_diagnostics_separator 'Распределение по GeoIP-базам'
    if [ "$has_ipv6" = true ]; then
        printf ' %b%s%s%s%s%b\n' "$DARKGRAY" \
            "$(_beszel_network_diagnostics_pad 'Код' "$code_w")" \
            "$(_beszel_network_diagnostics_pad 'Страна' "$country_w")" \
            "$(_beszel_network_diagnostics_pad '% IPv4' "$pct_w")" \
            "$(_beszel_network_diagnostics_pad '% IPv6' "$pct_w")" "$NC"
    else
        printf ' %b%s%s%s%b\n' "$DARKGRAY" \
            "$(_beszel_network_diagnostics_pad 'Код' "$code_w")" \
            "$(_beszel_network_diagnostics_pad 'Страна' "$country_w")" \
            "$(_beszel_network_diagnostics_pad '% IPv4' "$pct_w")" "$NC"
    fi
    while IFS=$'\t' read -r code pct4 pct6; do
        [ -n "$code" ] || continue
        country=$(_beszel_network_diagnostics_country_name "$json" "$code")
        [ "${pct4:-0}" -gt 0 ] && ipv4="${pct4}%" || ipv4='—'
        [ "${pct6:-0}" -gt 0 ] && ipv6="${pct6}%" || ipv6='—'
        if [ "$has_ipv6" = true ]; then
            printf ' %b%s%b%b%s%b%b%s%s%b\n' \
                "$GREEN" "$(_beszel_network_diagnostics_pad "$code" "$code_w")" "$NC" \
                "$WHITE" "$(_beszel_network_diagnostics_pad "$country" "$country_w")" "$NC" \
                "$GREEN" "$(_beszel_network_diagnostics_pad "$ipv4" "$pct_w")" \
                "$(_beszel_network_diagnostics_pad "$ipv6" "$pct_w")" "$NC"
        else
            printf ' %b%s%b%b%s%b%b%s%b\n' \
                "$GREEN" "$(_beszel_network_diagnostics_pad "$code" "$code_w")" "$NC" \
                "$WHITE" "$(_beszel_network_diagnostics_pad "$country" "$country_w")" "$NC" \
                "$GREEN" "$(_beszel_network_diagnostics_pad "$ipv4" "$pct_w")" "$NC"
        fi
    done <<< "$rows"
}

_beszel_run_network_diagnostics() {
    local group="$1" title="$2" done_message="$3"
    local script tmpdir json_file progress_file error_file rc=0 json table_json service_json has_results
    local show_geoip_results=false
    show_screen_header "$title" "$BLUE"

    if ! _beszel_network_diagnostics_ensure_dependencies; then
        print_error 'Не удалось подготовить инструменты диагностики (curl, jq)'
        show_continue_prompt 'Выход'
        return $?
    fi

    script="${SCRIPT_DIR}/lib/extra/network_diagnostics_cli.sh"
    [ -f "$script" ] || {
        print_error 'Не найден модуль сетевой диагностики'
        show_continue_prompt 'Выход'
        return $?
    }
    tmpdir=$(mktemp -d /tmp/beszel-network-diagnostics.XXXXXX) || {
        print_error 'Не удалось создать временную папку для результатов'
        show_continue_prompt 'Выход'
        return $?
    }
    json_file="$tmpdir/result.json"
    progress_file="$tmpdir/progress"
    error_file="$tmpdir/error.log"
    printf 'Определение внешних IP и DNS\n' > "$progress_file"

    (
        BESZEL_NETWORK_PROGRESS_FILE="$progress_file" \
            bash "$script" -j -g "$group" -t 5 > "$json_file" 2> "$error_file" || exit $?
        if [ "$group" = geo ]; then
            jq -e '((.results.primary // []) | length) + ((.results.custom // []) | length) > 0' \
                "$json_file" >/dev/null 2>&1
        elif [ "$group" = diagnostics ]; then
            jq -e '((.results.primary // []) | length) + ((.results.custom // []) | length) > 0' \
                "$json_file" >/dev/null 2>&1
        else
            jq -e '((.results.custom // []) | length) > 0' "$json_file" >/dev/null 2>&1
        fi
    ) </dev/null &
    local pid=$!
    _beszel_network_diagnostics_progress "$pid" "$progress_file" 'Проверка' "$done_message" || rc=$?

    json=$(cat "$json_file" 2>/dev/null) || json=''
    if [ -n "$json" ] && jq -e 'type == "object"' <<< "$json" >/dev/null 2>&1; then
        if [ "$group" = geo ]; then
            has_results=$(jq -r '((.results.primary // []) | length) + ((.results.custom // []) | length) > 0' <<< "$json" 2>/dev/null)
        elif [ "$group" = diagnostics ]; then
            has_results=$(jq -r '((.results.primary // []) | length) + ((.results.custom // []) | length) > 0' <<< "$json" 2>/dev/null)
        else
            has_results=$(jq -r '((.results.custom // []) | length) > 0' <<< "$json" 2>/dev/null)
        fi
    else
        has_results=false
    fi
    if [ "$rc" -ne 0 ] || [ "$has_results" != true ]; then
        rm -rf "$tmpdir"
        if [ "$rc" -ne 130 ]; then
            print_error 'Не удалось получить результаты диагностики'
            printf '%bПроверьте DNS и доступ сервера к исходящим HTTPS-соединениям.%b\n' "$DARKGRAY" "$NC"
            show_continue_prompt 'Выход'
        fi
        [ "$rc" -ne 0 ] || rc=1
        return "${rc:-1}"
    fi

    _beszel_network_diagnostics_emit_addresses "$json"
    if [ "$group" = geo ] || [ "$group" = diagnostics ]; then
        table_json=$(_beszel_network_diagnostics_geo_table_json "$json") || table_json="$json"
        if [ "$(jq -r '((.results.geo // []) | length)' <<< "$table_json" 2>/dev/null)" -gt 0 ]; then
            _beszel_network_diagnostics_emit_table "$table_json" geo 'Геолокация Google / YouTube'
        fi
        show_geoip_results=true
    fi
    if [ "$group" = custom ] || [ "$group" = diagnostics ]; then
        service_json="$json"
        [ "$group" = diagnostics ] && service_json=$(_beszel_network_diagnostics_service_table_json "$json")
        if [ "$(jq -r '((.results.custom // []) | length)' <<< "$service_json" 2>/dev/null)" -gt 0 ]; then
            _beszel_network_diagnostics_emit_table "$service_json" custom 'Доступность популярных сервисов'
        else
            echo
            _beszel_network_diagnostics_separator 'Доступность популярных сервисов'
            print_error 'Не удалось получить результаты проверки сервисов'
        fi
    fi
    if [ "$show_geoip_results" = true ]; then
        if [ "$(jq -r '((.results.primary // []) | length)' <<< "$table_json" 2>/dev/null)" -gt 0 ]; then
            _beszel_network_diagnostics_emit_table "$table_json" primary 'GeoIP-базы'
        else
            echo
            _beszel_network_diagnostics_separator 'Геолокация IP'
            print_error 'Не удалось получить данные GeoIP-баз'
        fi
        _beszel_network_diagnostics_emit_country_summary "$table_json"
    fi
    rm -rf "$tmpdir"
    echo
    show_continue_prompt 'Выход'
}

run_beszel_geolocation() {
    _beszel_run_network_diagnostics geo '📍  Геолокация IP' 'Проверка геолокации завершена'
}

run_beszel_services_check() {
    _beszel_run_network_diagnostics custom '🌍  Доступность популярных сервисов' 'Проверка сервисов завершена'
}

run_beszel_network_diagnostics() {
    _beszel_run_network_diagnostics diagnostics '🌐  Сетевая диагностика' 'Сбор отчёта завершён'
}
