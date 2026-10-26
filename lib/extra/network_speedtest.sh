# ═══════════════════════════════════════════════════
# NETWORK SPEED TEST
# ═══════════════════════════════════════════════════

_beszel_speedtest_ensure_dependencies() {
    local -a missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v jq >/dev/null 2>&1 || missing+=(jq)
    command -v tar >/dev/null 2>&1 || missing+=(tar)
    [ "${#missing[@]}" -eq 0 ] && return 0
    command -v apt-get >/dev/null 2>&1 || return 1

    local install_log
    install_log=$(mktemp /tmp/beszel-speedtest-packages.XXXXXX) || return 1
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

    if ! show_spinner --step --chain "Установка инструментов диагностики" "Инструменты установлены"; then
        show_install_error "Не удалось установить инструменты диагностики" "$install_log" || true
        rm -f "$install_log"
        return 1
    fi
    rm -f "$install_log"

    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v tar >/dev/null 2>&1
}

_beszel_speedtest_json_valid() {
    local json="$1"
    printf '%s' "$json" | jq -e '
        ((.server.name // "") != "")
        and (.ping.latency != null)
        and (.download.bandwidth != null)
        and (.upload.bandwidth != null)
    ' >/dev/null 2>&1
}

_beszel_speedtest_number() {
    local value="${1:-}" multiplier="${2:-1}" unit="${3:-}"
    if [[ ! "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        printf '—\n'
        return 0
    fi
    LC_ALL=C awk -v value="$value" -v multiplier="$multiplier" -v unit="$unit" \
        'BEGIN { printf "%.2f%s%s\n", value * multiplier, (unit == "" ? "" : " "), unit }'
}

_beszel_speedtest_pad() {
    local value="$1" width="$2" chars bytes padded_width
    chars=${#value}
    bytes=$(printf '%s' "$value" | wc -c)
    padded_width=$((width + bytes - chars))
    printf "%-${padded_width}s" "$value"
}

_beszel_speedtest_separator() {
    local title="$1" width=38 label left right left_line="" right_line=""
    label=" [ ${title} ] "
    [ "${#label}" -lt "$width" ] || {
        printf '%b%s%b\n' "$BLUE" "$label" "$NC"
        return 0
    }
    left=$(( (width - ${#label}) / 2 ))
    right=$(( width - ${#label} - left ))
    while [ "${#left_line}" -lt "$left" ]; do left_line="${left_line}─"; done
    while [ "${#right_line}" -lt "$right" ]; do right_line="${right_line}─"; done
    printf '%b%s%s%s%b\n' "$BLUE" "$left_line" "$label" "$right_line" "$NC"
}

_beszel_speedtest_result_line() {
    local label="$(_beszel_speedtest_pad "${1}:" 21)" value="$2" color="${3:-$WHITE}"
    printf '%b%s%b %b%s%b\n' "$DARKGRAY" "$label" "$NC" "$color" "$value" "$NC"
}

_beszel_speedtest_emit_result() {
    local json="$1"
    local server location country isp latency jitter download upload download_latency upload_latency loss
    local loss_color="$GREEN"

    server=$(printf '%s' "$json" | jq -r '.server.name // empty')
    location=$(printf '%s' "$json" | jq -r '.server.location // empty')
    country=$(printf '%s' "$json" | jq -r '.server.country // empty')
    isp=$(printf '%s' "$json" | jq -r '.isp // empty')
    latency=$(_beszel_speedtest_number "$(printf '%s' "$json" | jq -r '.ping.latency // empty')" 1 'мс')
    jitter=$(_beszel_speedtest_number "$(printf '%s' "$json" | jq -r '.ping.jitter // empty')" 1 'мс')
    download=$(_beszel_speedtest_number "$(printf '%s' "$json" | jq -r '.download.bandwidth // empty')" 0.000008 'Мбит/с')
    upload=$(_beszel_speedtest_number "$(printf '%s' "$json" | jq -r '.upload.bandwidth // empty')" 0.000008 'Мбит/с')
    download_latency=$(_beszel_speedtest_number "$(printf '%s' "$json" | jq -r '.download.latency.iqm // empty')" 1 'мс')
    upload_latency=$(_beszel_speedtest_number "$(printf '%s' "$json" | jq -r '.upload.latency.iqm // empty')" 1 'мс')
    loss=$(_beszel_speedtest_number "$(printf '%s' "$json" | jq -r '.packetLoss // empty')" 1 '%')

    if [[ "$loss" != '—' ]]; then
        local loss_value
        loss_value=$(printf '%s' "$json" | jq -r '.packetLoss // 0')
        if awk -v value="$loss_value" 'BEGIN { exit !(value >= 5) }'; then
            loss_color="$RED"
        elif awk -v value="$loss_value" 'BEGIN { exit !(value > 0) }'; then
            loss_color="$YELLOW"
        fi
    fi

    _beszel_speedtest_separator 'Сервер'
    _beszel_speedtest_result_line 'Сервер' "$server"
    if [ -n "$location" ] || [ -n "$country" ]; then
        local place="$location"
        [ -z "$location" ] || [ -z "$country" ] || place+=", "
        place+="$country"
        _beszel_speedtest_result_line 'Расположение' "$place"
    fi
    [ -z "$isp" ] || _beszel_speedtest_result_line 'Провайдер' "$isp"

    echo
    _beszel_speedtest_separator 'Результат'
    _beszel_speedtest_result_line 'Задержка' "$latency" "$YELLOW"
    _beszel_speedtest_result_line 'Джиттер' "$jitter" "$YELLOW"
    _beszel_speedtest_result_line 'Загрузка' "$download" "$GREEN"
    [ "$download_latency" = '—' ] || _beszel_speedtest_result_line 'Задержка загрузки' "$download_latency"
    _beszel_speedtest_result_line 'Отправка' "$upload" "$GREEN"
    [ "$upload_latency" = '—' ] || _beszel_speedtest_result_line 'Задержка отправки' "$upload_latency"
    _beszel_speedtest_result_line 'Потеря пакетов' "$loss" "$loss_color"
}

run_beszel_speed_test() {
    show_screen_header '⚡  Тест скорости сети' "$BLUE"

    if ! _beszel_speedtest_ensure_dependencies; then
        print_error 'Не удалось подготовить инструменты диагностики'
        show_continue_prompt 'Выход'
        return $?
    fi

    local arch package tmpdir output_file error_file output
    arch=$(uname -m)
    case "$arch" in
        x86_64) package='ookla-speedtest-1.2.0-linux-x86_64.tgz' ;;
        aarch64|arm64) package='ookla-speedtest-1.2.0-linux-aarch64.tgz' ;;
        *)
            print_error "Тест Speedtest поддерживает только x86_64 и aarch64"
            echo -e "${DARKGRAY}Текущая архитектура: ${arch}${NC}"
            show_continue_prompt 'Выход'
            return $?
            ;;
    esac

    tmpdir=$(mktemp -d /tmp/beszel-speedtest.XXXXXX) || {
        print_error 'Не удалось создать временную папку для Speedtest'
        show_continue_prompt 'Выход'
        return $?
    }
    output_file="${tmpdir}/result.json"
    error_file="${tmpdir}/error.log"

    (
        set -e
        cd "$tmpdir"
        curl -fsSL --connect-timeout 15 --max-time 180 \
            "https://install.speedtest.net/app/cli/${package}" -o speedtest.tgz
        tar -xzf speedtest.tgz
        [ -x "${tmpdir}/speedtest" ]
    ) </dev/null >"${tmpdir}/prepare.log" 2>&1 &
    if ! show_spinner --step --chain 'Подготовка Speedtest'; then
        rm -rf "$tmpdir"
        echo
        print_error 'Не удалось подготовить Speedtest'
        echo -e "${DARKGRAY}Проверьте DNS и доступ сервера к исходящим HTTPS-соединениям.${NC}"
        show_continue_prompt 'Выход'
        return $?
    fi

    (
        "${tmpdir}/speedtest" --accept-license --accept-gdpr --format=json \
            >"$output_file" 2>"$error_file"
    ) </dev/null &
    if ! show_spinner --step 'Тестирование скорости'; then
        rm -rf "$tmpdir"
        echo
        print_error 'Не удалось выполнить тест скорости'
        echo -e "${DARKGRAY}Сервис Speedtest не ответил или недоступен из этой сети.${NC}"
        show_continue_prompt 'Выход'
        return $?
    fi

    output=$(cat "$output_file" 2>/dev/null) || true
    rm -rf "$tmpdir"
    if [ -z "$output" ] || ! _beszel_speedtest_json_valid "$output"; then
        echo
        print_error 'Speedtest вернул неполный результат'
        echo -e "${DARKGRAY}Повторите проверку позже или проверьте исходящие соединения сервера.${NC}"
        show_continue_prompt 'Выход'
        return $?
    fi

    echo -e "${GREEN}✅ Тест скорости соединения завершён${NC}"
    echo
    _beszel_speedtest_emit_result "$output"
    show_continue_prompt 'Выход'
}
