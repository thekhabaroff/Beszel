#!/usr/bin/env bash

beszel_ufw_has_allow_tcp() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    command -v ufw >/dev/null 2>&1 || return 1
    _beszel_ufw_is_active || return 1

    if LC_ALL=C ufw status numbered 2>/dev/null | awk -v rule="${port}/tcp" '
        $0 ~ ("^[[:space:]]*\\[[[:space:]]*[0-9]+\\][[:space:]]*" rule "[[:space:]]+ALLOW IN([[:space:]]|$)") { found=1 }
        END { exit !found }
    '; then
        return 0
    fi
    return 1
}

beszel_ufw_allow_tcp() {
    local port="${1:-}" comment="${2:-Beszel}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    command -v ufw >/dev/null 2>&1 || return 0
    _beszel_ufw_is_active || return 0
    beszel_ufw_has_allow_tcp "$port" && return 0
    ufw allow "${port}/tcp" comment "$comment" >/dev/null 2>&1
}

beszel_ufw_allow_tcp_from() {
    local port="${1:-}" source_ip="${2:-}" comment="${3:-BESZEL}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    [ -n "$source_ip" ] || return 1
    command -v ufw >/dev/null 2>&1 || return 2
    _beszel_ufw_is_active || return 2
    ufw insert 1 allow from "$source_ip" to any port "$port" proto tcp comment "$comment" >/dev/null 2>&1
}

beszel_ufw_remove_rules_by_comment() {
    local comment="${1:-}" port="${2:-}" number
    [ -n "$comment" ] || return 1
    if [ -n "$port" ]; then
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    fi
    command -v ufw >/dev/null 2>&1 || return 0
    _beszel_ufw_is_active || return 0

    while IFS= read -r number; do
        [ -n "$number" ] || continue
        printf 'y\n' | ufw delete "$number" >/dev/null 2>&1 || return 1
    done < <(
        LC_ALL=C ufw status numbered 2>/dev/null | awk -v marker="# ${comment}" -v rule="${port:+${port}/tcp}" '
            index($0, marker) && (!rule || index($0, rule)) {
                if (match($0, /^\[[[:space:]]*[0-9]+\]/)) {
                    number=substr($0, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", number)
                    print number
                }
            }
        ' | sort -rn
    )
}

beszel_ufw_remove_open_tcp_rules_by_comment() {
    local comment="${1:-}" port="${2:-}" number
    [ -n "$comment" ] || return 1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    command -v ufw >/dev/null 2>&1 || return 0
    _beszel_ufw_is_active || return 0

    while IFS= read -r number; do
        [ -n "$number" ] || continue
        printf 'y\n' | ufw delete "$number" >/dev/null 2>&1 || return 1
    done < <(
        LC_ALL=C ufw status numbered 2>/dev/null | awk -v marker="# ${comment}" -v port="$port" '
            index($0, marker) {
                line=$0
                sub(/^\[[[:space:]]*[0-9]+\][[:space:]]*/, "", line)
                if (line ~ ("^" port "(/tcp)?([[:space:]]|$)") &&
                    line ~ /ALLOW IN[[:space:]]+Anywhere([[:space:]]|$)/ &&
                    match($0, /^\[[[:space:]]*[0-9]+\]/)) {
                    number=substr($0, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", number)
                    print number
                }
            }
        ' | sort -rn
    )
}

beszel_detect_sshd_port() {
    local config_file="${BESZEL_SSHD_CONFIG:-/etc/ssh/sshd_config}"
    local config_dir="${BESZEL_SSHD_CONFIG_DIR:-/etc/ssh/sshd_config.d}"
    local port=""

    if [ -n "${BESZEL_SSHD_CONFIG:-}" ]; then
        port=$(awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ { print $2; exit }' \
            "$config_file" 2>/dev/null || true)
    elif command -v sshd >/dev/null 2>&1; then
        port=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        port=$(awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ { print $2; exit }' \
            "$config_dir"/*.conf "$config_file" 2>/dev/null || true)
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        port=22
    fi
    printf '%s\n' "$port"
}

ufw_ensure_ssh_allow_with_comment() {
    command -v ufw >/dev/null 2>&1 || return 0
    local sshd_port line
    sshd_port=$(beszel_detect_sshd_port)
    while IFS= read -r line; do
        printf '%s\n' "$line" | grep -Eq "\\][[:space:]]+${sshd_port}(/tcp|[[:space:]]+TCP)([[:space:]]|$)" || continue
        printf '%s\n' "$line" | grep -q 'ALLOW IN' || continue
        return 0
    done < <(LC_ALL=C ufw status numbered 2>/dev/null | grep '^\[' || true)
    ufw insert 1 allow "${sshd_port}/tcp" comment SSH >/dev/null 2>&1 || return 1
    ufw reload >/dev/null 2>&1 || true
}
