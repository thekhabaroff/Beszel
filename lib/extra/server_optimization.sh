# ═══════════════════════════════════════════════════
# ОПТИМИЗАЦИЯ СЕРВЕРА
# ═══════════════════════════════════════════════════

_beszel_swap_file() { printf '%s\n' "${BESZEL_SWAP_FILE:-/swapfile.beszel}"; }
_beszel_swap_sysctl_file() { printf '%s\n' "${BESZEL_SWAP_SYSCTL_FILE:-/etc/sysctl.d/99-beszel-swap.conf}"; }
_beszel_fstab_file() { printf '%s\n' "${BESZEL_FSTAB_FILE:-/etc/fstab}"; }

_beszel_optimization_pad() {
    local text="$1" width="$2" visible padding
    visible=$(printf '%s' "$text" | LC_ALL=C tr -d '\200-\277' | wc -c 2>/dev/null | tr -d '[:space:]')
    [[ "$visible" =~ ^[0-9]+$ ]] || visible=${#text}
    padding=$((width - visible))
    [ "$padding" -lt 0 ] && padding=0
    printf '%s%*s' "$text" "$padding" ''
}

_beszel_swap_recommended_size_gb() {
    local ram_mb="${1:-0}"
    [[ "$ram_mb" =~ ^[0-9]+$ ]] || ram_mb=0
    if [ "$ram_mb" -le 2048 ]; then printf '2\n'; else printf '4\n'; fi
}

_beszel_swapfile_is_active() {
    local swap_file="${1:-$(_beszel_swap_file)}"
    swapon --show=NAME --noheadings 2>/dev/null \
        | awk -v path="$swap_file" '$1 == path { found=1 } END { exit !found }'
}

_beszel_swap_total_size_gb() {
    local swaps_file="${BESZEL_PROC_SWAPS_FILE:-/proc/swaps}" total_kb=0
    if [ -r "$swaps_file" ]; then
        total_kb=$(awk 'NR > 1 && $3 ~ /^[0-9]+$/ { total += $3 } END { print total + 0 }' \
            "$swaps_file" 2>/dev/null || printf '0')
    fi
    [[ "$total_kb" =~ ^[0-9]+$ ]] || total_kb=0
    if [ "$total_kb" -gt 0 ]; then
        printf '%d\n' $(((total_kb + 1048575) / 1048576))
    else
        printf '0\n'
    fi
}

_beszel_swap_file_size_gb() {
    local swap_file="${1:-$(_beszel_swap_file)}" size_bytes=0
    size_bytes=$(stat -c '%s' -- "$swap_file" 2>/dev/null || printf '0')
    [[ "$size_bytes" =~ ^[0-9]+$ ]] || size_bytes=0
    if [ "$size_bytes" -gt 0 ]; then
        printf '%d\n' $(((size_bytes + 1073741823) / 1073741824))
    else
        printf '0\n'
    fi
}

_beszel_swap_path_is_safe_file() {
    local swap_file="${1:-}"
    [[ "$swap_file" == /* && "$swap_file" != / && "$swap_file" != /dev/* ]] || return 1
    if [ -e "$swap_file" ] || [ -L "$swap_file" ]; then
        [ -f "$swap_file" ] && [ ! -L "$swap_file" ] || return 1
    fi
    return 0
}

_beszel_swap_fstab_remove() {
    local swap_file="$1" fstab_file
    fstab_file=$(_beszel_fstab_file)
    [ -f "$fstab_file" ] || return 0
    [ ! -L "$fstab_file" ] || return 1
    local tmp_file
    tmp_file=$(mktemp "$(dirname "$fstab_file")/.beszel-fstab.XXXXXX") || return 1
    awk -v path="$swap_file" '$1 != path { print }' "$fstab_file" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    chmod --reference="$fstab_file" "$tmp_file" 2>/dev/null || chmod 644 "$tmp_file"
    mv "$tmp_file" "$fstab_file"
}

_beszel_swap_fstab_add() {
    local swap_file="$1" fstab_file
    fstab_file=$(_beszel_fstab_file)
    mkdir -p "$(dirname "$fstab_file")" || return 1
    [ ! -L "$fstab_file" ] || return 1
    touch "$fstab_file" || return 1
    awk -v path="$swap_file" '$1 == path { found=1 } END { exit !found }' "$fstab_file" 2>/dev/null || \
        printf '%s none swap sw 0 0\n' "$swap_file" >> "$fstab_file"
}

_beszel_swap_has_staging_space() {
    local size_gb="$1" free_space_kb needed_kb reserve_kb
    free_space_kb=$(df "${BESZEL_SWAP_DISK_PATH:-/}" --output=avail 2>/dev/null | tail -n1 | tr -d ' ')
    [[ "$free_space_kb" =~ ^[0-9]+$ ]] || free_space_kb=0
    needed_kb=$((size_gb * 1024 * 1024))
    reserve_kb=$((1024 * 1024))
    [ "$free_space_kb" -ge $((needed_kb + reserve_kb)) ]
}

_beszel_swap_write_policy() {
    local sysctl_file="$(_beszel_swap_sysctl_file)"
    mkdir -p "$(dirname "$sysctl_file")" || return 1
    [ ! -L "$sysctl_file" ] || return 1
    cat > "$sysctl_file" <<'SYSCTL'
# Managed by Beszel Manager. SWAP is emergency memory, not a RAM replacement.
vm.swappiness=10
SYSCTL
    chmod 644 "$sysctl_file"
}

_beszel_swap_create_file() {
    local size_gb="$1" swap_file="$2" sysctl_file
    sysctl_file=$(_beszel_swap_sysctl_file)
    _beszel_swap_path_is_safe_file "$swap_file" || return 1
    [ ! -e "$swap_file" ] && [ ! -L "$swap_file" ] || return 1

    if ! fallocate -l "${size_gb}G" "$swap_file" 2>/dev/null; then
        if ! dd if=/dev/zero of="$swap_file" bs=1M count=$((size_gb * 1024)) status=none 2>/dev/null; then
            rm -f "$swap_file" 2>/dev/null || true
            return 1
        fi
    fi
    chmod 600 "$swap_file" || { rm -f "$swap_file"; return 1; }
    mkswap "$swap_file" >/dev/null 2>&1 || { rm -f "$swap_file"; return 1; }
    swapon "$swap_file" >/dev/null 2>&1 || { rm -f "$swap_file"; return 1; }
    if ! _beszel_swap_fstab_add "$swap_file"; then
        swapoff "$swap_file" >/dev/null 2>&1 || true
        rm -f "$swap_file" 2>/dev/null || true
        return 1
    fi
    if ! _beszel_swap_write_policy; then
        swapoff "$swap_file" >/dev/null 2>&1 || true
        _beszel_swap_fstab_remove "$swap_file" || true
        rm -f "$swap_file" 2>/dev/null || true
        return 1
    fi
    sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
    return 0
}

_beszel_swap_remove_file() {
    local swap_file="$1" was_active=0 sysctl_file
    sysctl_file=$(_beszel_swap_sysctl_file)
    _beszel_swap_path_is_safe_file "$swap_file" || return 1
    [ "$swap_file" = "$(_beszel_swap_file)" ] || return 1

    if _beszel_swapfile_is_active "$swap_file"; then
        was_active=1
        swapoff "$swap_file" >/dev/null 2>&1 || return 1
    fi
    if ! _beszel_swap_fstab_remove "$swap_file"; then
        [ "$was_active" -eq 0 ] || swapon "$swap_file" >/dev/null 2>&1 || true
        return 1
    fi
    if ! rm -f "$swap_file" 2>/dev/null; then
        _beszel_swap_fstab_add "$swap_file" || true
        [ "$was_active" -eq 0 ] || swapon "$swap_file" >/dev/null 2>&1 || true
        return 1
    fi
    rm -f "$sysctl_file" 2>/dev/null || return 1
    sysctl --system >/dev/null 2>&1 || true
    return 0
}

_beszel_swap_resize_file() {
    local swap_file="$1" size_gb="$2" backup_file="${1}.beszel-backup.$$"
    _beszel_swap_path_is_safe_file "$swap_file" || return 1
    [ "$swap_file" = "$(_beszel_swap_file)" ] && [ -f "$swap_file" ] || return 1
    _beszel_swapfile_is_active "$swap_file" || return 1
    [ ! -e "$backup_file" ] || return 1

    swapoff "$swap_file" >/dev/null 2>&1 || return 1
    if ! mv "$swap_file" "$backup_file"; then
        swapon "$swap_file" >/dev/null 2>&1 || true
        return 1
    fi
    if _beszel_swap_create_file "$size_gb" "$swap_file"; then
        rm -f "$backup_file"
        return 0
    fi

    swapoff "$swap_file" >/dev/null 2>&1 || true
    rm -f "$swap_file" 2>/dev/null || true
    mv "$backup_file" "$swap_file" 2>/dev/null || return 1
    swapon "$swap_file" >/dev/null 2>&1 || return 1
    _beszel_swap_fstab_add "$swap_file" || true
    _beszel_swap_write_policy || true
    sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
    return 1
}

_beszel_swap_select_size() {
    local recommended_size_gb="$1" choice
    MENU_TITLE_COLOR="$BLUE"
    MENU_INITIAL_IDX=0
    show_arrow_menu "💾 Размер SWAP" \
        "Рекомендуемый размер (${recommended_size_gb} ГБ)" \
        "Выделить 1 ГБ" \
        "Выделить 2 ГБ" \
        "Выделить 4 ГБ" \
        "Выделить 8 ГБ" \
        "──────────────────────────────────────" \
        "⬅️   Назад"
    choice=$?
    [ "$choice" -ne 255 ] || return 1
    case "$choice" in
        0) BESZEL_SWAP_SELECTED_SIZE="$recommended_size_gb" ;;
        1) BESZEL_SWAP_SELECTED_SIZE=1 ;;
        2) BESZEL_SWAP_SELECTED_SIZE=2 ;;
        3) BESZEL_SWAP_SELECTED_SIZE=4 ;;
        4) BESZEL_SWAP_SELECTED_SIZE=8 ;;
        *) return 1 ;;
    esac
}

manage_beszel_swap() {
    local swap_file ram_kb ram_mb recommended_size choice current_swap selected_size action
    swap_file=$(_beszel_swap_file)
    ram_kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null)
    [[ "$ram_kb" =~ ^[0-9]+$ ]] || ram_kb=0
    ram_mb=$((ram_kb / 1024))
    recommended_size=$(_beszel_swap_recommended_size_gb "$ram_mb")

    while true; do
        current_swap=$(swapon --show --noheadings 2>/dev/null || true)
        if _beszel_swapfile_is_active "$swap_file"; then
            local total_swap
            total_swap=$(_beszel_swap_total_size_gb)
            show_arrow_menu "💾 Управление SWAP" \
                $'\x01'"${GREEN}✅${NC} ${WHITE}SWAP Beszel активен${NC}" \
                $'\x01'"${DARKGRAY}Общий объём SWAP: ${total_swap} ГБ${NC}" \
                $'\x01' \
                "Изменить размер" \
                "Удалить SWAP Beszel" \
                "──────────────────────────────────────" \
                "⬅️   Назад"
            choice=$?
            [ "$choice" -ne 255 ] || return 0
            case "$choice" in
                3)
                    _beszel_swap_select_size "$recommended_size" || continue
                    selected_size="$BESZEL_SWAP_SELECTED_SIZE"
                    action=resize
                    ;;
                4)
                    confirm_nav --delete "🗑️ Удалить SWAP Beszel" || continue
                    show_screen_header "💾 Удаление SWAP" "$BLUE"
                    _beszel_swap_remove_file "$swap_file" </dev/null &
                    if show_spinner "Удаление SWAP"; then
                        print_success "SWAP Beszel удалён"
                    else
                        print_error "Не удалось удалить SWAP Beszel; проверьте свободную память и файл /etc/fstab"
                    fi
                    show_continue_prompt "Назад" || return 1
                    continue
                    ;;
                *) continue ;;
            esac
        else
            if [ -e "$swap_file" ] || [ -L "$swap_file" ]; then
                show_arrow_menu "💾 Управление SWAP" \
                    $'\x01'"${YELLOW}⚠${NC} ${WHITE}Файл $swap_file существует, но не активен${NC}" \
                    $'\x01'"${DARKGRAY}Beszel не будет перезаписывать неизвестный файл.${NC}" \
                    "⬅️   Назад"
                return 0
            fi
            if [ -n "$current_swap" ]; then
                show_arrow_menu "💾 Управление SWAP" \
                    $'\x01'"${GREEN}✅${NC} ${WHITE}Системный SWAP уже активен${NC}" \
                    $'\x01'"${DARKGRAY}Другие разделы и файлы SWAP Beszel не изменяет.${NC}" \
                    $'\x01' \
                    "Добавить SWAP Beszel" \
                    "──────────────────────────────────────" \
                    "⬅️   Назад"
                choice=$?
                [ "$choice" -ne 255 ] || return 0
                [ "$choice" -eq 3 ] || continue
            else
                show_arrow_menu "💾 Управление SWAP" \
                    $'\x01'"${YELLOW}⚠${NC} ${WHITE}SWAP не настроен${NC}" \
                    $'\x01' \
                    "Создать SWAP Beszel" \
                    "──────────────────────────────────────" \
                    "⬅️   Назад"
                choice=$?
                [ "$choice" -ne 255 ] || return 0
                [ "$choice" -eq 2 ] || continue
            fi
            _beszel_swap_select_size "$recommended_size" || continue
            selected_size="$BESZEL_SWAP_SELECTED_SIZE"
            action=create
        fi

        show_screen_header "💾 Настройка SWAP" "$BLUE"
        if ! _beszel_swap_has_staging_space "$selected_size"; then
            print_error "Недостаточно свободного места для безопасной настройки SWAP"
            echo -e "${DARKGRAY}Нужно ${selected_size} ГБ и ещё 1 ГБ свободного места.${NC}"
        else
            if [ "$action" = resize ]; then
                _beszel_swap_resize_file "$swap_file" "$selected_size" </dev/null &
                if show_spinner "Изменение размера SWAP"; then
                    print_success "SWAP Beszel изменён: ${selected_size} ГБ"
                else
                    print_error "Не удалось изменить SWAP; прежний файл восстановлен"
                fi
            else
                _beszel_swap_create_file "$selected_size" "$swap_file" </dev/null &
                if show_spinner "Создание SWAP"; then
                    print_success "SWAP Beszel создан: ${selected_size} ГБ"
                else
                    print_error "Не удалось создать SWAP Beszel"
                fi
            fi
        fi
        show_continue_prompt "Назад" || return 1
    done
}

_beszel_logrotate_policy_file() { printf '%s\n' "${BESZEL_LOGROTATE_POLICY_FILE:-/etc/logrotate.d/beszel-manager}"; }
_beszel_journald_policy_file() { printf '%s\n' "${BESZEL_JOURNALD_POLICY_FILE:-/etc/systemd/journald.conf.d/90-beszel-limits.conf}"; }

_beszel_logrotate_write_policy() {
    local policy_file journal_file
    policy_file=$(_beszel_logrotate_policy_file)
    journal_file=$(_beszel_journald_policy_file)
    mkdir -p "$(dirname "$policy_file")" "$(dirname "$journal_file")" || return 1
    [ ! -L "$policy_file" ] && [ ! -L "$journal_file" ] || return 1
    cat > "$policy_file" <<'LOGROTATE'
# Managed by Beszel Manager; Docker container logs keep their own policies.
/var/log/beszel*.log /var/log/beszel/*.log {
    daily
    maxsize 20M
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su root root
}
LOGROTATE
    cat > "$journal_file" <<'JOURNALD'
# Managed by Beszel Manager.
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
MaxRetentionSec=14day
Compress=yes
JOURNALD
    chmod 644 "$policy_file" "$journal_file"
}

_beszel_logrotate_validate() {
    command -v logrotate >/dev/null 2>&1 || return 1
    logrotate --debug "${BESZEL_LOGROTATE_CONFIG_FILE:-/etc/logrotate.conf}" >/dev/null 2>&1
}

_beszel_logrotate_is_configured() {
    local policy_file journal_file
    policy_file=$(_beszel_logrotate_policy_file)
    journal_file=$(_beszel_journald_policy_file)
    command -v logrotate >/dev/null 2>&1 || return 1
    grep -qF '/var/log/beszel*.log /var/log/beszel/*.log' "$policy_file" 2>/dev/null || return 1
    grep -qF 'maxsize 20M' "$policy_file" 2>/dev/null || return 1
    grep -qF 'SystemMaxUse=100M' "$journal_file" 2>/dev/null || return 1
    grep -qF 'MaxRetentionSec=14day' "$journal_file" 2>/dev/null || return 1
}

_beszel_logrotate_timer_exists() {
    systemctl list-unit-files --type=timer --no-legend 2>/dev/null \
        | awk '$1 == "logrotate.timer" { found=1 } END { exit !found }'
}

_beszel_logrotate_apply() {
    local policy_file journal_file backup_dir had_policy=0 had_journal=0
    policy_file=$(_beszel_logrotate_policy_file)
    journal_file=$(_beszel_journald_policy_file)
    [ ! -L "$policy_file" ] && [ ! -L "$journal_file" ] || return 1
    if ! command -v logrotate >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1 || return 1
        apt-get install -y -qq logrotate >/dev/null 2>&1 || return 1
    fi
    backup_dir=$(mktemp -d /tmp/beszel-logrotate-backup.XXXXXX) || return 1
    if [ -f "$policy_file" ]; then cp -p "$policy_file" "$backup_dir/policy" || { rm -rf "$backup_dir"; return 1; }; had_policy=1; fi
    if [ -f "$journal_file" ]; then cp -p "$journal_file" "$backup_dir/journal" || { rm -rf "$backup_dir"; return 1; }; had_journal=1; fi

    if ! _beszel_logrotate_write_policy || ! _beszel_logrotate_validate; then
        if [ "$had_policy" -eq 1 ]; then cp -p "$backup_dir/policy" "$policy_file"; else rm -f "$policy_file"; fi
        if [ "$had_journal" -eq 1 ]; then cp -p "$backup_dir/journal" "$journal_file"; else rm -f "$journal_file"; fi
        rm -rf "$backup_dir"
        return 1
    fi
    rm -rf "$backup_dir"
    if _beszel_logrotate_timer_exists; then
        systemctl enable --now logrotate.timer >/dev/null 2>&1 || return 1
    elif systemctl list-unit-files cron.service >/dev/null 2>&1; then
        systemctl enable --now cron.service >/dev/null 2>&1 || return 1
    fi
    systemctl try-restart systemd-journald.service >/dev/null 2>&1 || true
    return 0
}

_beszel_logrotate_cleanup_journal() {
    command -v journalctl >/dev/null 2>&1 || return 1
    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time=14d --vacuum-size=100M >/dev/null 2>&1 || return 1
}

manage_beszel_logrotate() {
    while true; do
        show_arrow_menu "📝 Ротация журналов" \
            "✅  Применить рекомендуемые настройки" \
            "🧹  Очистить накопившиеся системные журналы" \
            "🔎  Проверить конфигурацию logrotate" \
            "──────────────────────────────────────" \
            "⬅️   Назад"
        local choice=$?
        [ "$choice" -ne 255 ] || return 0
        case "$choice" in
            0)
                _beszel_logrotate_apply </dev/null &
                if show_spinner "Настройка ротации журналов"; then
                    print_success "Настройки logrotate и journald применены"
                else
                    print_error "Не удалось применить настройки; конфигурация logrotate не прошла проверку"
                fi
                show_continue_prompt "Назад" || return 1
                ;;
            1)
                confirm_nav --delete "🧹 Очистить системные журналы" || continue
                (_beszel_logrotate_apply && _beszel_logrotate_cleanup_journal) </dev/null &
                if show_spinner "Ограничение и очистка системных журналов"; then
                    print_success "Системные журналы ограничены и очищены по сроку хранения"
                else
                    print_error "Не удалось очистить системные журналы"
                fi
                show_continue_prompt "Назад" || return 1
                ;;
            2)
                if _beszel_logrotate_validate; then
                    print_success "Ошибок конфигурации logrotate не найдено"
                else
                    print_error "Конфигурация logrotate не прошла проверку"
                    echo -e "${DARKGRAY}Проверьте: logrotate --debug ${BESZEL_LOGROTATE_CONFIG_FILE:-/etc/logrotate.conf}${NC}"
                fi
                show_continue_prompt "Назад" || return 1
                ;;
            4) return 0 ;;
        esac
    done
}

manage_beszel_server_optimization() {
    while true; do
        local swap_file swap_size swap_status logrotate_status choice status_col=21
        swap_file=$(_beszel_swap_file)
        if _beszel_swapfile_is_active "$swap_file"; then
            swap_size=$(_beszel_swap_file_size_gb "$swap_file")
            swap_status="${GREEN}(${swap_size} ГБ)${NC}"
        elif [ -n "$(swapon --show --noheadings 2>/dev/null || true)" ]; then
            swap_status="${DARKGRAY}(системный активен)${NC}"
        else
            swap_status="${DARKGRAY}(не настроен)${NC}"
        fi
        if _beszel_logrotate_is_configured; then logrotate_status="${GREEN}(настроена)${NC}"; else logrotate_status="${DARKGRAY}(не настроена)${NC}"; fi

        show_arrow_menu "⚙️  Оптимизация сервера" \
            "💾  $(_beszel_optimization_pad 'SWAP' "$status_col") ${swap_status}" \
            "📝  $(_beszel_optimization_pad 'Ротация журналов' "$status_col") ${logrotate_status}" \
            "──────────────────────────────────────" \
            "⬅️   Назад"
        choice=$?
        [ "$choice" -ne 255 ] || return 0
        case "$choice" in
            0) manage_beszel_swap || return 1 ;;
            1) manage_beszel_logrotate || return 1 ;;
            3) return 0 ;;
        esac
    done
}
