#!/usr/bin/env ash
# shellcheck shell=dash

set -euo pipefail

pkg_manager() {
    local OP="$1" PM=apk
    shift
    if [ -f /etc/gentoo-release ]; then
        PM=emerge
        case "$OP" in
        add)
            OP='-v'
            ;;
        del)
            OP='-C'
            ;;
        esac
    fi
    if [ $# -eq 0 ]; then
        echo "$PM $OP"
    else
        $PM "$OP" "$@"
    fi
}

check_distro() {
    if [ -z "$(command -v rc-service)" ]; then
        echo "No OpenRC init-system detected."
        return 1
    fi
    if [ -f /etc/alpine-release ] || [ -f /etc/gentoo-release ]; then
        return 0
    else
        return 1
    fi
}

check_if_running_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    else
        echo "error: You must run this script as root!"
        return 1
    fi
}

identify_architecture() {
    if [ "$(uname)" != 'Linux' ]; then
        echo "error: This operating system is not supported."
        return 1
    fi
    case "$(uname -m)" in
    'amd64' | 'x86_64')
        BINARY_DIR='binary_amd64'
        ;;
    'armv8' | 'aarch64')
        BINARY_DIR='binary_arm64'
        ;;
    *)
        echo "error: The architecture is not supported. Only x86_64 and aarch64 are supported."
        return 1
        ;;
    esac
    if [ ! -f '/etc/os-release' ]; then
        echo "error: Don't use outdated Linux distributions."
        return 1
    fi
}

install_dependencies() {

    local NEED_PACKAGES=""
    if [ -z "$(command -v curl)" ]; then
        NEED_PACKAGES="$NEED_PACKAGES curl"
    fi

    if [ -n "$NEED_PACKAGES" ]; then
        if [ "$(command -v apk)" ]; then
            # shellcheck disable=SC2086
            set -- $NEED_PACKAGES
            echo "Installing required dependencies:$NEED_PACKAGES..."
            pkg_manager add "$@"
        else
            echo "error: The script does not support the package manager in this operating system."
            exit 1
        fi
    fi
}

has_downloaded_payload() {
    [ -s "${TMP_DIRECTORY}xray" ] && [ -s "${TMP_DIRECTORY}geoip.dat" ] && [ -s "${TMP_DIRECTORY}geosite.dat" ]
}

prepare_xray_payload() {
    if has_downloaded_payload; then
        echo "Using cached payload files, skipping download."
        return 0
    fi

    echo "Downloading Xray files from repo path: ${BINARY_DIR}"
    local base_url="https://raw.githubusercontent.com/livingfree2023/Xray-install/refs/heads/main/${BINARY_DIR}"

    if ! curl -f -L -H 'Cache-Control: no-cache' -o "${TMP_DIRECTORY}xray" "${base_url}/xray" -#; then
        echo 'error: Failed to download xray binary.'
        exit 1
    fi
    if ! curl -f -L -H 'Cache-Control: no-cache' -o "${TMP_DIRECTORY}geoip.dat" "${base_url}/geoip.dat" -#; then
        echo 'error: Failed to download geoip.dat.'
        exit 1
    fi
    if ! curl -f -L -H 'Cache-Control: no-cache' -o "${TMP_DIRECTORY}geosite.dat" "${base_url}/geosite.dat" -#; then
        echo 'error: Failed to download geosite.dat.'
        exit 1
    fi
}

is_it_running() {
    XRAY_RUNNING='0'
    if [ -n "$(pgrep xray)" ]; then
        rc-service xray stop
        XRAY_RUNNING='1'
    fi
}

install_xray() {
    echo "Deploying Xray execution binaries and data assets..."
    mkdir -p /usr/local/bin/
    mkdir -p /usr/local/share/xray/

    # Using cp + chmod instead of install to avoid high memory buffering
    cp "${TMP_DIRECTORY}xray" "/usr/local/bin/xray"
    chmod 755 /usr/local/bin/xray

    cp "${TMP_DIRECTORY}geoip.dat" "/usr/local/share/xray/geoip.dat"
    cp "${TMP_DIRECTORY}geosite.dat" "/usr/local/share/xray/geosite.dat"
    chmod 644 /usr/local/share/xray/*.dat
}

install_confdir() {
    CONFDIR='0'
    if [ ! -d '/usr/local/etc/xray/' ]; then
        install -d /usr/local/etc/xray/
        for BASE in 00_log 01_api 02_dns 03_routing 04_policy 05_inbounds 06_outbounds 07_transport 08_stats 09_reverse; do
            echo '{}' >"/usr/local/etc/xray/$BASE.json"
        done
        CONFDIR='1'
    fi
}

install_log() {
    local log_user="nobody"
    local log_group="nobody"
    if ! getent group "$log_group" >/dev/null 2>&1; then
        if getent group "nogroup" >/dev/null 2>&1; then
            log_group="nogroup"
        else
            # Fallback for minimal systems lacking both groups
            log_user="root"
            log_group="root"
        fi
    fi

    LOG='0'
    if [ ! -d '/var/log/xray/' ]; then
        install -d -m 755 -o 0 -g 0 /var/log/xray/
        install -m 600 -o "$log_user" -g "$log_group" /dev/null /var/log/xray/access.log
        install -m 600 -o "$log_user" -g "$log_group" /dev/null /var/log/xray/error.log
        LOG='1'
    else
        chown 0:0 /var/log/xray/
        chmod 755 /var/log/xray/
        chown "$log_user:$log_group" /var/log/xray/*.log
        chmod 600 /var/log/xray/*.log
    fi
}

install_startup_service_file() {
    OPENRC='0'
    if [ ! -f '/etc/init.d/xray' ]; then
        mkdir "${TMP_DIRECTORY}init.d/"
        if ! curl -f -L -o "${TMP_DIRECTORY}init.d/xray" https://github.com/XTLS/Xray-install/raw/main/alpinelinux/init.d/xray -sS; then
            echo 'error: Failed to start service file download! Please check your network or try again.'
            exit 1
        fi
        install -m 755 "${TMP_DIRECTORY}init.d/xray" /etc/init.d/xray
        OPENRC='1'
    fi
}

information() {
    echo 'installed: /usr/local/bin/xray'
    echo 'installed: /usr/local/share/xray/geoip.dat'
    echo 'installed: /usr/local/share/xray/geosite.dat'
    if [ "$CONFDIR" -eq '1' ]; then
        echo 'installed: /usr/local/etc/xray/00_log.json'
        echo 'installed: /usr/local/etc/xray/01_api.json'
        echo 'installed: /usr/local/etc/xray/02_dns.json'
        echo 'installed: /usr/local/etc/xray/03_routing.json'
        echo 'installed: /usr/local/etc/xray/04_policy.json'
        echo 'installed: /usr/local/etc/xray/05_inbounds.json'
        echo 'installed: /usr/local/etc/xray/06_outbounds.json'
        echo 'installed: /usr/local/etc/xray/07_transport.json'
        echo 'installed: /usr/local/etc/xray/08_stats.json'
        echo 'installed: /usr/local/etc/xray/09_reverse.json'
    fi
    if [ "$LOG" -eq '1' ]; then
        echo 'installed: /var/log/xray/'
    fi
    if [ "$OPENRC" -eq '1' ]; then
        echo 'installed: /etc/init.d/xray'
    fi
    rm -r "$TMP_DIRECTORY"
    echo "removed: $TMP_DIRECTORY"
    echo "You may need to execute a command to remove dependent software: $(pkg_manager del) curl"
    if [ "$XRAY_RUNNING" -eq '1' ]; then
        rc-service xray start
    else
        echo 'Please execute the command: rc-update add xray; rc-service xray start'
    fi
    echo "info: Xray is installed."
}

main() {
    check_distro || return 1
    check_if_running_as_root || return 1
    identify_architecture || return 1
    install_dependencies

    TMP_DIRECTORY="${HOME}/xray_tmp/"
    mkdir -p "$TMP_DIRECTORY"
    
    prepare_xray_payload
    is_it_running
    install_xray
    install_confdir
    install_log
    install_startup_service_file || return 1
    information
}

main
