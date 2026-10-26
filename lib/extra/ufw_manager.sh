# ═══════════════════════════════════════════════════
# UFW FIREWALL MANAGER
# ═══════════════════════════════════════════════════

_beszel_ufw_is_active() {
    command -v ufw >/dev/null 2>&1 || return 1
    LC_ALL=C ufw status 2>/dev/null | head -n1 | grep -q '^Status: active'
}

_beszel_ufw_enable_bash_completion() {
    local completion="${BESZEL_UFW_COMPLETION_SOURCE:-/usr/share/bash-completion/completions/ufw}"
    local bash_completion="${BESZEL_BASH_COMPLETION_LOADER:-/usr/share/bash-completion/bash_completion}"
    local completion_dir="${BESZEL_BASH_COMPLETION_DIR:-/etc/bash_completion.d}"
    local system_bashrc="${BESZEL_SYSTEM_BASHRC:-/etc/bash.bashrc}"
    local root_bashrc="${BESZEL_ROOT_BASHRC:-/root/.bashrc}"
    local marker="# Beszel: bash completion"
    local loader rc

    [ -f "$completion" ] && [ -f "$bash_completion" ] || return 1
    mkdir -p "$completion_dir" || return 1
    ln -sf "$completion" "${completion_dir}/ufw" || return 1

    loader="${marker}
if [ -f ${bash_completion} ]; then
    . ${bash_completion}
fi"
    for rc in "$system_bashrc" "$root_bashrc"; do
        mkdir -p "$(dirname "$rc")" || return 1
        touch "$rc" || return 1
        if ! grep -qF "$marker" "$rc" 2>/dev/null; then
            printf '\n%s\n' "$loader" >> "$rc" || return 1
        fi
    done

    source "$bash_completion" 2>/dev/null || true
    source "$completion" 2>/dev/null || true
}

_beszel_ufw_parse_rule_line() {
    local line="${1:-}" rule_body destination action_direction source comment proto_raw is_v6=""

    BESZEL_UFW_RULE_INDEX=""
    BESZEL_UFW_RULE_PORT=""
    BESZEL_UFW_RULE_PROTO=""
    BESZEL_UFW_RULE_ACCESS=""
    BESZEL_UFW_RULE_COMMENT=""
    BESZEL_UFW_RULE_COLOR="${GREEN}"

    [[ "$line" =~ ^\[[[:space:]]*[0-9]+\] ]] || return 1
    BESZEL_UFW_RULE_INDEX=$(printf '%s\n' "$line" | sed -nE 's/^\[[[:space:]]*([0-9]+)\].*/[\1]/p')
    rule_body=$(printf '%s\n' "$line" | sed -E 's/^\[[[:space:]]*[0-9]+\][[:space:]]*//')

    if [[ "$rule_body" == *'#'* ]]; then
        comment=${rule_body#*#}
        rule_body=${rule_body%%#*}
        comment=$(printf '%s\n' "$comment" | xargs)
    else
        comment=""
    fi
    rule_body=$(printf '%s\n' "$rule_body" | sed -E 's/[[:space:]]+$//')

    action_direction=$(printf '%s\n' "$rule_body" \
        | grep -oE '(ALLOW|DENY|REJECT|LIMIT)[[:space:]]+(IN|OUT)' \
        | head -n1 || true)
    [ -n "$action_direction" ] || return 1

    destination=$(printf '%s\n' "$rule_body" \
        | sed -E 's/[[:space:]]+(ALLOW|DENY|REJECT|LIMIT)[[:space:]]+(IN|OUT)[[:space:]]+.*$//')
    source=$(printf '%s\n' "$rule_body" \
        | sed -E 's/^.*[[:space:]]+(ALLOW|DENY|REJECT|LIMIT)[[:space:]]+(IN|OUT)[[:space:]]+//')

    if [[ "$destination" == *"(v6)"* ]] || [[ "$source" == *"(v6)"* ]]; then
        is_v6=" (v6)"
    fi
    destination=$(printf '%s\n' "$destination" | sed -E 's/[[:space:]]*\(v6\)[[:space:]]*$//')
    source=$(printf '%s\n' "$source" | sed -E 's/[[:space:]]*\(v6\)[[:space:]]*$//')

    proto_raw=""
    if [[ "$destination" =~ /([Tt][Cc][Pp]|[Uu][Dd][Pp])$ ]]; then
        proto_raw="${BASH_REMATCH[1],,}"
        destination="${destination%/*}"
    fi
    case "$proto_raw" in
        tcp) BESZEL_UFW_RULE_PROTO="TCP" ;;
        udp) BESZEL_UFW_RULE_PROTO="UDP" ;;
        *)   BESZEL_UFW_RULE_PROTO="ALL" ;;
    esac

    case "${action_direction%% *}" in
        DENY|REJECT)
            BESZEL_UFW_RULE_ACCESS="Запрещён${is_v6}"
            BESZEL_UFW_RULE_COLOR="${RED}"
            ;;
        LIMIT)
            if [ "$source" = "Anywhere" ]; then
                BESZEL_UFW_RULE_ACCESS="Лимит: для всех${is_v6}"
            else
                BESZEL_UFW_RULE_ACCESS="Лимит: ${source}${is_v6}"
            fi
            BESZEL_UFW_RULE_COLOR="${YELLOW}"
            ;;
        *)
            if [ -z "$source" ] || [ "$source" = "Anywhere" ]; then
                BESZEL_UFW_RULE_ACCESS="Для всех${is_v6}"
            else
                BESZEL_UFW_RULE_ACCESS="${source}${is_v6}"
            fi
            ;;
    esac

    BESZEL_UFW_RULE_PORT="$destination"
    BESZEL_UFW_RULE_COMMENT="$comment"
}

_beszel_ufw_fit_cell() {
    local value="${1:-}" width="${2:-1}"
    LC_ALL=C.UTF-8 awk -v text="$value" -v width="$width" 'BEGIN {
        if (width < 1) exit
        if (length(text) > width) {
            if (width == 1) printf "…"
            else printf "%s…", substr(text, 1, width - 1)
        } else {
            printf "%s", text
            for (i = length(text); i < width; i++) printf " "
        }
    }'
}

_beszel_ufw_table_row() {
    printf '%s %s %s %s %s' \
        "$(_beszel_ufw_fit_cell "${1:-}" 4)" \
        "$(_beszel_ufw_fit_cell "${2:-}" 7)" \
        "$(_beszel_ufw_fit_cell "${3:-}" 7)" \
        "$(_beszel_ufw_fit_cell "${4:-}" 16)" \
        "$(_beszel_ufw_fit_cell "${5:-}" 14)"
}

_beszel_ufw_stats_table_row() {
    printf '%s %s %s %s' \
        "$(_beszel_ufw_fit_cell "${1:-}" 7)" \
        "$(_beszel_ufw_fit_cell "${2:-}" 7)" \
        "$(_beszel_ufw_fit_cell "${3:-}" 16)" \
        "$(_beszel_ufw_fit_cell "${4:-}" 14)"
}

_beszel_ufw_port_statistics() {
    local -a menu_items=()
    local line row_separator menu_separator back_idx

    printf -v row_separator '%*s' 47 ''
    row_separator=${row_separator// /─}
    printf -v menu_separator '%*s' 49 ''
    menu_separator=${menu_separator// /─}

    menu_items+=($'\x01'"${DARKGRAY}  $(_beszel_ufw_stats_table_row \
        'Порт' 'Тип' 'Доступ' 'Комментарий')${NC}")
    menu_items+=($'\x02'"  ${row_separator}")

    while IFS= read -r line; do
        _beszel_ufw_parse_rule_line "$line" || continue
        menu_items+=($'\x01'"  $(_beszel_ufw_stats_table_row \
            "$BESZEL_UFW_RULE_PORT" "$BESZEL_UFW_RULE_PROTO" \
            "$BESZEL_UFW_RULE_ACCESS" "$BESZEL_UFW_RULE_COMMENT")")
    done < <(LC_ALL=C ufw status numbered 2>/dev/null | grep '^\[' || true)

    if [ "${#menu_items[@]}" -eq 2 ]; then
        menu_items+=($'\x01'"  ${YELLOW}Правила отсутствуют${NC}")
    fi
    menu_items+=($'\x02'"${menu_separator}")
    back_idx=${#menu_items[@]}
    menu_items+=("⬅️   Назад")

    MENU_WIDTH=49
    MENU_INITIAL_IDX=$back_idx
    MENU_TITLE_COLOR="$GREEN"
    MENU_KEY_HINT="${DARKGRAY}${BLUE}Enter${DARKGRAY}: Назад  ${BLUE}Esc${DARKGRAY}: Назад${NC}"
    MENU_KEY_HINT_ALIGN=center
    show_arrow_menu "📊 Статистика портов" "${menu_items[@]}"
    unset MENU_WIDTH MENU_INITIAL_IDX MENU_TITLE_COLOR MENU_KEY_HINT MENU_KEY_HINT_ALIGN
}

_beszel_ufw_delete_rule_menu() {
    while true; do
        local -a rule_numbers=() rule_labels=()
        local line rule_number row_separator menu_separator back_idx

        while IFS= read -r line; do
            _beszel_ufw_parse_rule_line "$line" || continue
            rule_number="${BESZEL_UFW_RULE_INDEX//[^0-9]/}"
            [ -n "$rule_number" ] || continue
            rule_numbers+=("$rule_number")
            rule_labels+=("$(_beszel_ufw_table_row \
                "$BESZEL_UFW_RULE_INDEX" "$BESZEL_UFW_RULE_PORT" "$BESZEL_UFW_RULE_PROTO" \
                "$BESZEL_UFW_RULE_ACCESS" "$BESZEL_UFW_RULE_COMMENT")")
        done < <(LC_ALL=C ufw status numbered 2>/dev/null | grep '^\[' || true)

        if [ "${#rule_numbers[@]}" -eq 0 ]; then
            show_screen_header "➖ Удалить правило" "$GREEN"
            print_warning "Правила отсутствуют"
            show_continue_prompt || true
            return 0
        fi

        local -a menu_items=()
        printf -v row_separator '%*s' 52 ''
        row_separator=${row_separator// /─}
        printf -v menu_separator '%*s' 54 ''
        menu_separator=${menu_separator// /─}
        menu_items+=($'\x01'"${DARKGRAY}  $(_beszel_ufw_table_row '№' 'Порт' 'Тип' 'Доступ' 'Комментарий')${NC}")
        menu_items+=($'\x02'"  ${row_separator}")
        menu_items+=("${rule_labels[@]}")
        menu_items+=($'\x02'"${menu_separator}")
        back_idx=${#menu_items[@]}
        menu_items+=("⬅️   Назад")

        MENU_WIDTH=54
        MENU_TITLE_COLOR="$GREEN"
        MENU_KEY_HINT="${DARKGRAY}${BLUE}↑↓${DARKGRAY}: Навигация  ${BLUE}Enter${DARKGRAY}: Удалить  ${BLUE}Esc${DARKGRAY}: Назад${NC}"
        MENU_KEY_HINT_ALIGN=center
        show_arrow_menu "➖ Удалить правило" "${menu_items[@]}"
        local choice=$?
        unset MENU_WIDTH MENU_TITLE_COLOR MENU_KEY_HINT MENU_KEY_HINT_ALIGN
        { [ "$choice" -eq 255 ] || [ "$choice" -eq "$back_idx" ]; } && return 0
        [ "$choice" -ge 2 ] || continue

        local rule_idx=$((choice - 2))
        [ "$rule_idx" -lt "${#rule_numbers[@]}" ] || continue
        confirm_nav --delete "➖ Удалить правило UFW" || continue
        if printf 'y\n' | ufw delete "${rule_numbers[$rule_idx]}" >/dev/null 2>&1; then
            print_success "Правило удалено"
        else
            print_error "Не удалось удалить правило UFW"
            show_continue_prompt || return 1
        fi
    done
}

_beszel_ufw_add_rule() {
    local port="" proto="" comment="" source_ip="" rc=0
    local -a command_args=(ufw allow)

    show_screen_header "➕ Открытие порта" "$BLUE"
    reading_inline "Порт (обязательно):" port || rc=$?
    [ "$rc" -eq 2 ] && return 0
    [ "$rc" -eq 0 ] || return 1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        print_error "Порт не указан или некорректен"
        show_continue_prompt || return 1
        return 0
    fi

    rc=0
    reading_inline "Протокол (tcp/udp/пусто для любого):" proto || rc=$?
    [ "$rc" -eq 2 ] && return 0
    [ "$rc" -eq 0 ] || return 1
    proto="${proto,,}"
    if [ -n "$proto" ] && [ "$proto" != tcp ] && [ "$proto" != udp ]; then
        print_error "Поддерживаются только протоколы tcp и udp"
        show_continue_prompt || return 1
        return 0
    fi

    rc=0
    reading_inline "Комментарий (Enter для пропуска):" comment || rc=$?
    [ "$rc" -eq 2 ] && return 0
    [ "$rc" -eq 0 ] || return 1
    rc=0
    reading_inline "IP-адрес (Enter для всех):" source_ip || rc=$?
    [ "$rc" -eq 2 ] && return 0
    [ "$rc" -eq 0 ] || return 1

    if [ -n "$source_ip" ]; then
        command_args+=(from "$source_ip")
    fi
    command_args+=(to any port "$port")
    [ -z "$proto" ] || command_args+=(proto "$proto")
    [ -z "$comment" ] || command_args+=(comment "$comment")

    if "${command_args[@]}" >/dev/null 2>&1 </dev/null; then
        print_success "Правило для порта ${port} добавлено"
    else
        print_error "UFW отклонил правило. Проверьте порт, протокол и IP-адрес"
    fi
    show_continue_prompt || return 1
}

_beszel_ufw_delete_all_rules_except_ssh() {
    command -v ufw >/dev/null 2>&1 || return 0
    local ssh_port line number i
    local -a numbers=()
    ssh_port=$(beszel_detect_sshd_port)

    while IFS= read -r line; do
        if printf '%s\n' "$line" | grep -Eq "\\][[:space:]]+${ssh_port}(/tcp|[[:space:]]+TCP)([[:space:]]|$)" && \
           printf '%s\n' "$line" | grep -q 'ALLOW IN'; then
            continue
        fi
        number=$(printf '%s\n' "$line" | sed -nE 's/^\[[[:space:]]*([0-9]+)\].*/\1/p')
        [ -n "$number" ] && numbers+=("$number")
    done < <(LC_ALL=C ufw status numbered 2>/dev/null | grep '^\[' || true)

    for ((i=${#numbers[@]}-1; i>=0; i--)); do
        printf 'y\n' | ufw delete "${numbers[$i]}" >/dev/null 2>&1 || return 1
    done
    ufw_ensure_ssh_allow_with_comment || return 1
    ufw reload >/dev/null 2>&1 || return 1
}

_beszel_ufw_install() {
    command -v apt-get >/dev/null 2>&1 || {
        print_error "Автоматическая установка UFW доступна только в Debian и Ubuntu"
        show_continue_prompt || true
        return 1
    }

    local log_file
    log_file=$(mktemp /tmp/beszel-ufw-install.XXXXXX) || return 1
    (DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw bash-completion >"$log_file" 2>&1) </dev/null &
    if ! show_spinner --install-step "Установка UFW"; then
        show_install_error "Не удалось установить UFW" "$log_file" || true
        rm -f "$log_file"
        return 1
    fi
    if ! command -v ufw >/dev/null 2>&1; then
        show_install_error "Установка завершилась, но команда ufw не найдена" "$log_file" || true
        rm -f "$log_file"
        return 1
    fi
    _beszel_ufw_enable_bash_completion >/dev/null 2>&1 || true
    rm -f "$log_file"
    print_success "UFW успешно установлен"
    show_continue_prompt || true
}

manage_beszel_ufw() {
    while true; do
        if ! command -v ufw >/dev/null 2>&1; then
            show_arrow_menu "🔥 UFW - Firewall" \
                "🛡️   Установить Firewall (UFW)" \
                "──────────────────────────────────────" \
                "⬅️   Назад"
            local choice=$?
            [ "$choice" -eq 255 ] && return 0
            if [ "$choice" -eq 0 ]; then
                _beszel_ufw_install || true
                continue
            fi
            return 0
        fi

        local toggle_label
        if _beszel_ufw_is_active; then
            toggle_label="⏹️   Отключить Firewall"
        else
            toggle_label="▶️   Включить Firewall"
        fi
        show_arrow_menu "🔥 UFW - Firewall" \
            "➕  Открыть порт" \
            "📊  Статистика портов" \
            "➖  Удалить правило" \
            "🧹  Очистить правила (SSH сохранить)" \
            "$toggle_label" \
            "──────────────────────────────────────" \
            "⬅️   Назад"
        local choice=$?
        [ "$choice" -eq 255 ] && return 0

        case "$choice" in
            0) _beszel_ufw_add_rule || return 1 ;;
            1) _beszel_ufw_port_statistics ;;
            2) _beszel_ufw_delete_rule_menu || return 1 ;;
            3)
                local rule_count
                rule_count=$(LC_ALL=C ufw status numbered 2>/dev/null | grep -c '^\[' || true)
                if [ "$rule_count" -eq 0 ]; then
                    show_screen_header "🧹 Очистить правила UFW" "$BLUE"
                    print_warning "Правила для удаления отсутствуют"
                    show_continue_prompt || return 1
                    continue
                fi
                confirm_nav --delete "🧹 Очистить правила UFW (SSH сохранить)" || continue
                show_screen_header "🧹 Очистить правила UFW" "$BLUE"
                if _beszel_ufw_delete_all_rules_except_ssh; then
                    print_success "Правила очищены, доступ к SSH сохранён"
                else
                    print_error "Не удалось очистить правила UFW"
                fi
                show_continue_prompt || return 1
                ;;
            4)
                if _beszel_ufw_is_active; then
                    if ufw --force disable >/dev/null 2>&1; then
                        print_success "Firewall выключен, правила сохранены"
                    else
                        print_error "Не удалось выключить Firewall"
                    fi
                else
                    ufw default deny incoming >/dev/null 2>&1 || true
                    ufw default allow outgoing >/dev/null 2>&1 || true
                    ufw_ensure_ssh_allow_with_comment || true
                    if ufw --force enable >/dev/null 2>&1; then
                        print_success "Firewall включён, доступ к SSH сохранён"
                    else
                        print_error "Не удалось включить Firewall"
                    fi
                fi
                show_continue_prompt || return 1
                ;;
            5) continue ;;
            6) return 0 ;;
        esac
    done
}
