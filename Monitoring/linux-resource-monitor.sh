#!/usr/bin/env bash
# Debian/Ubuntu/CentOS resource monitor. Edit all settings below.
set -u

# ============================== CONFIGURATION ==============================
TELEGRAM_BOT_TOKEN=''
TELEGRAM_CHAT_ID=''
TELEGRAM_MESSAGE_THREAD_ID=''
CPU_THRESHOLD=90
MEMORY_THRESHOLD=90
DISK_THRESHOLD=90
LOAD_THRESHOLD=90       # 1-minute load as % of logical CPU capacity
DISK_PATHS=("/")
CRON_SCHEDULE="*/5 * * * *"
CRON_LOG="/var/log/linux-resource-monitor.log"
ALERT_COOLDOWN=900
STATE_DIR="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/linux-resource-monitor"
# ===========================================================================

SCRIPT_NAME="linux-resource-monitor"
CRON_MARKER="# ${SCRIPT_NAME}-managed"
log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$SCRIPT_NAME" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

detect_os() {
    [[ -r /etc/os-release ]] || die "Cannot detect OS: /etc/os-release is missing"
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"; OS_NAME="${PRETTY_NAME:-$OS_ID}"; OS_LIKE="${ID_LIKE:-}"
    case "$OS_ID" in
        debian|ubuntu|centos|rhel|rocky|almalinux) ;;
        *) case " $OS_LIKE " in
               *" debian "*|*" rhel "*|*" centos "*) ;;
               *) die "Unsupported OS: $OS_NAME" ;;
           esac ;;
    esac
}

validate_config() {
    local value
    for value in "$CPU_THRESHOLD" "$MEMORY_THRESHOLD" "$DISK_THRESHOLD" "$LOAD_THRESHOLD"; do
        [[ "$value" =~ ^[0-9]+$ ]] || die "Resource thresholds must be integers"
    done
    [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]] || die "Set Telegram token and chat ID at the top"
    command -v curl >/dev/null 2>&1 || die "curl is required"
}

install_cron_once() {
    command -v crontab >/dev/null 2>&1 || { log "WARNING: install cron/cronie to enable scheduling"; return; }
    local script_path current cron_line
    script_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf %s "$0")"
    current="$(crontab -l 2>/dev/null || true)"
    printf '%s\n' "$current" | grep -Fq "$CRON_MARKER" && return
    printf -v cron_line '%s %q >> %q 2>&1 %s' "$CRON_SCHEDULE" "$script_path" "$CRON_LOG" "$CRON_MARKER"
    { printf '%s\n' "$current"; printf '%s\n' "$cron_line"; } | sed '/^[[:space:]]*$/d' | crontab -
    log "Installed cron schedule: $CRON_SCHEDULE"
}

cpu_usage() {
    local cpu user nice system idle iowait irq softirq steal guest guest_nice ia ta ib tb
    read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    ia=$((idle+iowait)); ta=$((user+nice+system+idle+iowait+irq+softirq+steal)); sleep 1
    read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    ib=$((idle+iowait)); tb=$((user+nice+system+idle+iowait+irq+softirq+steal))
    awk -v i="$((ib-ia))" -v t="$((tb-ta))" 'BEGIN{if(t<=0)print 0;else printf "%.0f",100*(t-i)/t}'
}
memory_usage() { awk '/MemTotal:/{t=$2}/MemAvailable:/{a=$2}END{if(t<=0)print 0;else printf "%.0f",100*(t-a)/t}' /proc/meminfo; }
load_usage() {
    local load cores
    load="$(awk '{print $1}' /proc/loadavg)"; cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || printf 1)"
    awk -v l="$load" -v c="$cores" 'BEGIN{printf "%.0f",100*l/c}'
}

primary_ip() {
    local address
    address="$(hostname -I 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\./) {print $i; exit}}')"
    if [[ -z "$address" ]] && command -v ip >/dev/null 2>&1; then
        address="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
    fi
    printf '%s' "${address:-unknown}"
}

send_telegram() {
    local response chat_id="$TELEGRAM_CHAT_ID" thread_id="$TELEGRAM_MESSAGE_THREAD_ID"
    local -a request_args

    # Backward-compatible shorthand for forum topics: -1001234567890:42
    if [[ -z "$thread_id" && "$chat_id" =~ ^(-?[0-9]+):([0-9]+)$ ]]; then
        chat_id="${BASH_REMATCH[1]}"
        thread_id="${BASH_REMATCH[2]}"
    fi

    request_args=(
        -sS --max-time 15 -X POST
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
        --data-urlencode "chat_id=${chat_id}"
        --data-urlencode "text=$1"
    )
    [[ -n "$thread_id" ]] && request_args+=(--data-urlencode "message_thread_id=${thread_id}")

    response="$(curl "${request_args[@]}" 2>&1)" || {
        log "Telegram request failed: $response" >&2
        return 1
    }
    if ! printf '%s' "$response" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true'; then
        log "Telegram API rejected the message: $response" >&2
        return 1
    fi
}
alert_if_due() {
    local key="$1" message="$2" now last=0 state_file active_file
    now="$(date +%s)"; state_file="$STATE_DIR/${key}.last"; active_file="$STATE_DIR/${key}.active"
    : > "$active_file"
    [[ -r "$state_file" ]] && read -r last < "$state_file"; [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if ((now-last>=ALERT_COOLDOWN)); then
        if send_telegram "$message"; then printf '%s\n' "$now" > "$state_file"; log "Alert sent: $key"; fi
    else log "Alert suppressed by cooldown: $key"; fi
}

recover_if_needed() {
    local key="$1" resource="$2" value="$3" active_file="$STATE_DIR/${1}.active"
    local message
    [[ -e "$active_file" ]] || return 0
    printf -v message '✅ RECOVERED: %s\nHost: %s\nIP: %s\nCurrent: %s\nOS: %s\nTime: %s' \
        "$resource" "$HOST_NAME" "$HOST_IP" "$value" "$OS_NAME" "$NOW"
    if send_telegram "$message"; then
        rm -f "$active_file" "$STATE_DIR/${key}.last"
        log "Recovery sent: $key"
    fi
}

send_test_alert() {
    local message path disk disk_report=""
    for path in "${DISK_PATHS[@]}"; do
        if [[ -e "$path" ]]; then
            disk="$(df -P "$path" | awk 'NR==2{gsub(/%/,"",$5);print $5}')"
            printf -v disk_report '%s\nDisk %s: %s%% used' "$disk_report" "$path" "$disk"
        else
            printf -v disk_report '%s\nDisk %s: path not found' "$disk_report" "$path"
        fi
    done
    printf -v message '🧪 TEST ALERT (thresholds bypassed)\nHost: %s\nIP: %s\nOS: %s\nCPU: %s%%\nRAM: %s%%\nLoad: %s%% capacity%s\nTime: %s' \
        "$HOST_NAME" "$HOST_IP" "$OS_NAME" "$CPU_USAGE" "$MEMORY_USAGE" "$LOAD_USAGE" "$disk_report" "$NOW"
    send_telegram "$message" && log "Test alert sent"
}

usage() {
    printf 'Usage: %s [--test]\n  --test, -t  Send a real Telegram test alert and bypass thresholds\n' "$0"
}

main() {
    local mode="monitor"
    case "${1:-}" in
        --test|-t) mode="test" ;;
        --help|-h) usage; return 0 ;;
        "") ;;
        *) usage >&2; die "Unknown argument: $1" ;;
    esac
    detect_os                 # OS check always runs first.
    validate_config
    install_cron_once         # Adds exactly one marked job on first valid run.
    mkdir -p "$STATE_DIR" || die "Cannot create state directory: $STATE_DIR"
    local disk path message key alerts=0
    HOST_NAME="$(hostname -f 2>/dev/null || hostname)"; HOST_IP="$(primary_ip)"; NOW="$(date '+%F %T %Z')"
    CPU_USAGE="$(cpu_usage)"; MEMORY_USAGE="$(memory_usage)"; LOAD_USAGE="$(load_usage)"
    if [[ "$mode" == "test" ]]; then send_test_alert; return $?; fi
    if ((CPU_USAGE>=CPU_THRESHOLD)); then printf -v message '⚠️ %s: CPU %s%% (limit %s%%)\nIP: %s\nOS: %s\nTime: %s' "$HOST_NAME" "$CPU_USAGE" "$CPU_THRESHOLD" "$HOST_IP" "$OS_NAME" "$NOW"; alert_if_due cpu "$message"; alerts=$((alerts+1)); else recover_if_needed cpu CPU "${CPU_USAGE}%"; fi
    if ((MEMORY_USAGE>=MEMORY_THRESHOLD)); then printf -v message '⚠️ %s: RAM %s%% (limit %s%%)\nIP: %s\nOS: %s\nTime: %s' "$HOST_NAME" "$MEMORY_USAGE" "$MEMORY_THRESHOLD" "$HOST_IP" "$OS_NAME" "$NOW"; alert_if_due memory "$message"; alerts=$((alerts+1)); else recover_if_needed memory RAM "${MEMORY_USAGE}%"; fi
    if ((LOAD_USAGE>=LOAD_THRESHOLD)); then printf -v message '⚠️ %s: Load %s%% capacity (limit %s%%)\nIP: %s\nOS: %s\nTime: %s' "$HOST_NAME" "$LOAD_USAGE" "$LOAD_THRESHOLD" "$HOST_IP" "$OS_NAME" "$NOW"; alert_if_due load "$message"; alerts=$((alerts+1)); else recover_if_needed load Load "${LOAD_USAGE}% capacity"; fi
    for path in "${DISK_PATHS[@]}"; do
        [[ -e "$path" ]] || { log "WARNING: disk path missing: $path"; continue; }
        disk="$(df -P "$path" | awk 'NR==2{gsub(/%/,"",$5);print $5}')"
        key="disk-$(printf %s "$path" | tr '/ ' '__')"
        if [[ "$disk" =~ ^[0-9]+$ ]] && ((disk>=DISK_THRESHOLD)); then
            printf -v message '⚠️ %s: Disk %s is %s%% full (limit %s%%)\nIP: %s\nOS: %s\nTime: %s' "$HOST_NAME" "$path" "$disk" "$DISK_THRESHOLD" "$HOST_IP" "$OS_NAME" "$NOW"
            alert_if_due "$key" "$message"; alerts=$((alerts+1))
        else recover_if_needed "$key" "Disk $path" "${disk}% used"; fi
    done
    ((alerts==0)) && log "OK: IP=$HOST_IP CPU=$CPU_USAGE% RAM=$MEMORY_USAGE% Load=$LOAD_USAGE%"
}
main "$@"
