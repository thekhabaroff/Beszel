# ═══════════════════════════════════════════════════════════
# Установка Docker через официальный скрипт get.docker.com
# Вызывать когда уже есть рабочий curl (или после apt install curl).
# ═══════════════════════════════════════════════════════════

beszel_docker_daemon_ok() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# Скачивает и запускает установщик Docker. Не ставит пакеты через apt.
# Возврат: 0 — docker info отвечает; 1 — ошибка.
beszel_install_docker_engine_official() {
    local installer install_rc
    if beszel_docker_daemon_ok; then
        return 0
    fi
    if command -v docker >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
        print_error "Docker установлен, но демон не отвечает. Запустите: systemctl start docker"
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        print_error "curl не найден — нужен для установки Docker"
        return 1
    fi

    installer=$(mktemp /tmp/beszel-get-docker.XXXXXX) || return 1
    chmod 600 "$installer" || { rm -f "$installer"; return 1; }
    curl -fsSL --connect-timeout 20 --max-time 300 "https://get.docker.com" -o "$installer" || {
        rm -f "$installer"
        return 1
    }
    DEBIAN_FRONTEND=noninteractive sh "$installer" </dev/null >/dev/null 2>&1
    install_rc=$?
    rm -f "$installer"
    [ "$install_rc" -eq 0 ] || return 1
    systemctl start docker >/dev/null 2>&1 || true
    systemctl enable docker >/dev/null 2>&1 || true

    if ! docker info >/dev/null 2>&1; then
        print_error "Docker установлен, но не запустился. Проверьте: systemctl status docker"
        return 1
    fi
    return 0
}
