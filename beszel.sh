#!/usr/bin/env bash

set -o pipefail

BESZEL_VERSION="0.2.165"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DIR_SCRIPT="${SCRIPT_DIR}/"
DIR_BESZEL="${DIR_BESZEL:-/opt/beszel-hub/}"
DIR_BESZEL_AGENT="${DIR_BESZEL_AGENT:-/opt/beszel-agent/}"
DIR_NGINX="${DIR_NGINX:-${BESZEL_PROXY_STANDALONE_DIR:-/opt/beszel-proxy/}}"
DIR_NGINX="${DIR_NGINX%/}/"
BESZEL_PROXY_STANDALONE_DIR="$DIR_NGINX"
BESZEL_PROXY_REMNAWAVE_DIR="${BESZEL_PROXY_REMNAWAVE_DIR:-/opt/remnawave/}"
BESZEL_PROXY_STATE_DIR="${BESZEL_PROXY_STATE_DIR:-/var/lib/beszel/proxy-apps}"

_beszel_lib="${SCRIPT_DIR}/lib"

# Source the Beszel UI and only the helpers used by the Beszel manager.
# These modules are bundled here; the running manager does not load external files.
source "${_beszel_lib}/core/colors.sh"
source "${_beszel_lib}/core/terminal.sh"
source "${_beszel_lib}/core/ui.sh"
source "${_beszel_lib}/extra/firewall.sh"
source "${_beszel_lib}/core/docker_install.sh"
source "${_beszel_lib}/core/nginx.sh"
source "${_beszel_lib}/install/domain.sh"
source "${_beszel_lib}/install/certificates.sh"
source "${_beszel_lib}/install/proxy_environment.sh"
source "${_beszel_lib}/extra/beszel.sh"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "Запустите Beszel Manager от root"
        exit 1
    fi
}

check_os() {
    local os_release_file="${BESZEL_OS_RELEASE_FILE:-/etc/os-release}"
    [ -f "$os_release_file" ] || { print_error "Не удалось определить ОС"; exit 1; }
    . "$os_release_file"
    case "$ID:$VERSION_ID" in
        debian:11|debian:12|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
        *) print_error "Поддерживаются Debian 11/12 и Ubuntu 22.04/24.04/26.04"; exit 1 ;;
    esac
}

# Keep proxy labels consistent in the menu and diagnostics.
beszel_proxy_mode_label() {
    case "${1:-}" in
        caddy) printf 'Caddy Remnawave\n' ;;
        nginx) printf 'Nginx Remnawave\n' ;;
        standalone) printf 'Автономный Nginx Beszel\n' ;;
        *) printf 'не определён\n' ;;
    esac
}

beszel_proxy_install_variant_label() {
    case "${1:-}" in
        caddy) printf 'Caddy Remnawave\n' ;;
        nginx) printf 'Nginx Remnawave\n' ;;
        standalone) printf 'Автономный Nginx Beszel\n' ;;
        *) printf 'Не определён\n' ;;
    esac
}

# Ctrl+C only restores the terminal. It never removes this installation.
cleanup_uninstalled() { :; }
handle_interrupt() {
    trap - INT TERM HUP
    cleanup_terminal
    printf '\nСкрипт остановлен. Файлы Beszel сохранены.\n' >&2
    exit 130
}
trap handle_interrupt INT TERM HUP

_mt_read_input() {
    local variable="${1:?}" prompt="${2:?}" default_value="${3:-}"
    reading_inline "$prompt" "$variable" "$default_value"
    local rc=$?
    [ "$rc" -eq 2 ] && return 1
    return 0
}

_beszel_docker_with_timeout() {
    local seconds="${1:-10}"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after=5s "${seconds}s" docker "$@"
    else
        docker "$@"
    fi
}

_beszel_print_component_status() {
    local name="$1" title="$2" compose="$3" state health url inspect_rc=0
    state=$(_beszel_docker_with_timeout 10 inspect --format '{{.State.Status}}' "$name" 2>/dev/null) || inspect_rc=$?
    if [ "$inspect_rc" -eq 124 ] || [ "$inspect_rc" -eq 137 ]; then
        printf '%s: Docker не ответил за 10 секунд\n' "$title"
        return 0
    fi
    health=$(_beszel_docker_with_timeout 10 inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null || true)
    if [ -z "$state" ]; then
        printf '%s: не запущен\n' "$title"
    else
        [ -n "$health" ] && state="${state}/${health}"
        printf '%s: %s\n' "$title" "$state"
    fi
    if [ -f "$compose" ]; then
        url=$(awk -F '"' '/^[[:space:]]*APP_URL:/ { print $2; exit }' "$compose")
        [ -n "$url" ] && printf '  APP_URL: %s\n' "$url"
    fi
    return 0
}

_beszel_status() {
    case "${1:-all}" in
        hub) _beszel_print_component_status beszel-hub 'Hub Beszel' "${DIR_BESZEL}docker-compose.yml" ;;
        agent) _beszel_print_component_status beszel-agent 'Agent Beszel' "${DIR_BESZEL_AGENT}docker-compose.yml" ;;
        all)
            _beszel_print_component_status beszel-hub 'Hub Beszel' "${DIR_BESZEL}docker-compose.yml"
            _beszel_print_component_status beszel-agent 'Agent Beszel' "${DIR_BESZEL_AGENT}docker-compose.yml"
            ;;
        *) printf 'Неизвестный компонент: %s\n' "$1" >&2; return 2 ;;
    esac
}

_beszel_compose_action() {
    local component="$1" action="$2" directory="" container=""
    case "$component" in
        hub) directory="$DIR_BESZEL"; container=beszel-hub ;;
        agent) directory="$DIR_BESZEL_AGENT"; container=beszel-agent ;;
        *) printf 'Используйте hub или agent.\n' >&2; return 2 ;;
    esac
    case "$action" in
        status) _beszel_status "$component" ;;
        install)
            check_root
            check_os
            if [ "$component" = hub ]; then
                install_beszel
            else
                install_beszel_agent
            fi
            ;;
        update)
            check_root
            if [ "$component" = hub ]; then
                is_beszel_installed || {
                    printf 'Hub не отмечен как установленный Beszel Manager; обновление отменено.\n' >&2
                    return 1
                }
            else
                is_beszel_agent_installed || {
                    printf 'Agent не отмечен как установленный Beszel Manager; обновление отменено.\n' >&2
                    return 1
                }
            fi
            [ -f "${directory}docker-compose.yml" ] || {
                printf '%s ещё не установлен.\n' "$component" >&2
                return 1
            }
            (cd "$directory" && docker compose pull && docker compose up -d --remove-orphans)
            ;;
        logs)
            local logs_rc=0
            _beszel_docker_with_timeout 30 logs --tail 160 "$container" || logs_rc=$?
            if [ "$logs_rc" -eq 124 ] || [ "$logs_rc" -eq 137 ]; then
                printf 'Получение журналов остановлено: Docker не ответил за 30 секунд.\n' >&2
            fi
            return "$logs_rc"
            ;;
        start|stop|restart)
            check_root
            if [ "$component" = hub ]; then
                is_beszel_installed || {
                    printf 'Hub не отмечен как установленный Beszel Manager; действие отменено.\n' >&2
                    return 1
                }
            else
                is_beszel_agent_installed || {
                    printf 'Agent не отмечен как установленный Beszel Manager; действие отменено.\n' >&2
                    return 1
                }
            fi
            [ -f "${directory}docker-compose.yml" ] || {
                printf '%s ещё не установлен.\n' "$component" >&2
                return 1
            }
            (cd "$directory" && docker compose "$action")
            ;;
        remove|uninstall)
            check_root
            if [ "$component" = hub ]; then uninstall_beszel; else uninstall_beszel_agent; fi
            ;;
        *)
            printf 'Действия: status, install, start, stop, restart, update, logs, remove.\n' >&2
            return 2
            ;;
    esac
}

_beszel_help() {
    cat <<'HELP'
Beszel Manager

Использование:
  beszel                         Открыть интерактивное меню
  beszel status                  Показать состояние Hub и Agent
  beszel hub <действие>          Управление Hub
  beszel agent <действие>        Управление Agent

Действия: status, install, start, stop, restart, update, logs, remove
HELP
}

_beszel_main() {
    case "${1:-}" in
        -h|--help|help) _beszel_help ;;
        -v|--version|version) printf 'Beszel Manager %s\n' "$BESZEL_VERSION" ;;
        status) _beszel_status "${2:-all}" ;;
        hub|agent)
            [ "$#" -ge 2 ] || { printf 'Укажите действие для %s.\n' "$1" >&2; return 2; }
            _beszel_compose_action "$1" "$2"
            ;;
        "")
            check_root
            check_os
            manage_beszel
            ;;
        *)
            _beszel_help >&2
            return 2
            ;;
    esac
}

_beszel_main "$@"
