# ═══════════════════════════════════════════════
# ВОССТАНОВЛЕНИЕ ТЕРМИНАЛА И ОБРАБОТКА ПРЕРЫВАНИЙ
# ═══════════════════════════════════════════════

# Сохраняем исходное состояние терминала (до любых изменений)
ORIGINAL_STTY=$(stty -g 2>/dev/null || echo "")

cleanup_terminal() {
    command -v _beszel_bootstrap_spinner_stop >/dev/null 2>&1 && _beszel_bootstrap_spinner_stop || true
    # Закрыть дублирующий fd промпта «Продолжить» (если ui.sh уже загружен)
    command -v beszel_close_continue_prompt_ttyfd >/dev/null 2>&1 && beszel_close_continue_prompt_ttyfd || true
    # Полное восстановление терминала
    tput cnorm 2>/dev/null || true
    tput sgr0 2>/dev/null || true
    printf "\033[0m\033[?25h" 2>/dev/null || true
    if [ -n "$ORIGINAL_STTY" ]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || stty sane 2>/dev/null || true
    else
        stty sane 2>/dev/null || true
    fi
    # Явно восстанавливаем ключевые флаги (echo, icanon) — на случай если
    # read -s или stty -icanon не были корректно сброшены при выходе
    stty echo echoe icanon isig 2>/dev/null || true
}

# These functions intentionally do not remove aliases or files outside this
# standalone package.
cleanup_old_aliases() { :; }
cleanup_uninstalled() { :; }

handle_interrupt() {
    trap '' INT TERM HUP
    command -v _beszel_bootstrap_spinner_stop >/dev/null 2>&1 && _beszel_bootstrap_spinner_stop || true
    command -v beszel_close_continue_prompt_ttyfd >/dev/null 2>&1 && beszel_close_continue_prompt_ttyfd || true
    if [ -n "${ORIGINAL_STTY:-}" ]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || stty sane 2>/dev/null || true
    else
        stty sane 2>/dev/null || true
    fi
    stty echo echoe icanon isig 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    printf "\033[0m" 2>/dev/null || true
    clear
    printf '\033[0;31mСкрипт остановлен пользователем\033[0m\n\n'
    cleanup_uninstalled 2>/dev/null || true
    exit 0
}

# После временного trap INT (установка Beszel, логи docker и т.д.) — вернуть глобальный Ctrl+C
beszel_restore_interrupt_traps() {
    trap handle_interrupt INT TERM HUP
}

trap cleanup_terminal EXIT
trap handle_interrupt INT TERM HUP
