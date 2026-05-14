#!/bin/bash
set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
LOG_DIR="${HOME}/logs"
LOG_FILE="${LOG_DIR}/system_monitor.log"
PID_FILE="/tmp/system_monitor.pid"
INTERVAL=1
MAX_LOG_MB=100
CORES=$(nproc)

# "container-name:port:Label"  (label may contain spaces, not colons)
SERVICES=(
    "diarization-diarization_service-1:8080:Diarization"
    "socket:9395:Socket"
    "socket_stt:9394:Socket STT"
)

# ── Modes  (--log | --log-only | --json) ──────────────────────────────────────
MODE_LOG=0; MODE_LOG_ONLY=0; MODE_JSON=0
for _a in "$@"; do
    case "$_a" in
        --log)      MODE_LOG=1 ;;
        --log-only) MODE_LOG=1; MODE_LOG_ONLY=1 ;;
        --json)     MODE_JSON=1 ;;
    esac
done

# ── Colors ────────────────────────────────────────────────────────────────────
cR=$'\033[31m'; cY=$'\033[33m'; cG=$'\033[32m'; cC=$'\033[36m'
cB=$'\033[1m';  cD=$'\033[2m';  cN=$'\033[0m'

# ── Init ──────────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
declare -A LAST_LOG=()   # dedup: last alerted container log line per service
declare -A CONNS=()      # tcp connection counts  keyed by port
declare -A STATUSES=()   # container status strings keyed by name

svc_name()  { printf '%s' "${1%%:*}"; }
svc_port()  { printf '%s' "${1#*:}" | cut -d: -f1; }
svc_label() { printf '%s' "${1#*:*:}"; }

log() { printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }

cleanup() {
    rm -f "$PID_FILE"
    log "INFO  | Monitor stopped (PID $$)"
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

rotate_log() {
    [[ -f "$LOG_FILE" ]] || return
    local b; b=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if (( b / 1048576 >= MAX_LOG_MB )); then
        mv "$LOG_FILE" "${LOG_FILE%.log}_$(date '+%Y%m%d_%H%M%S').log"
        log "INFO  | Log rotated"
    fi
}

# ── CPU ───────────────────────────────────────────────────────────────────────
snapshot_cpu() { grep "^cpu" /proc/stat; }

cpu_metrics() {
    local prev="$1" curr="$2" out="CORES=${CORES}"
    while IFS= read -r cline; do
        local name; name=$(awk '{print $1}' <<< "$cline")
        local pline; pline=$(grep "^${name} " <<< "$prev" || true)
        [[ -z "$pline" ]] && continue
        local pct
        pct=$(awk -v p="$pline" -v c="$cline" 'BEGIN {
            split(p, a); split(c, b)
            p_idle = a[5]+a[6]; c_idle = b[5]+b[6]
            pt = 0; ct = 0
            for (i=2; i<=9; i++) { pt += a[i]; ct += b[i] }
            dt = ct-pt; di = c_idle-p_idle
            printf "%.1f", (dt > 0) ? (1 - di/dt)*100 : 0
        }')
        if [[ "$name" == "cpu" ]]; then
            out+=" | CPU_TOTAL=${pct}%"
        else
            out+=" | ${name}=${pct}%"
        fi
    done <<< "$curr"
    echo "$out"
}

# ── RAM ───────────────────────────────────────────────────────────────────────
ram_metrics() {
    free -b | awk '/Mem:/ {
        printf "RAM_TOTAL=%.1fGB | RAM_USED=%.1fGB | RAM_AVAIL=%.1fGB | RAM_USAGE=%.1f%%",
            $2/1073741824, $3/1073741824, $7/1073741824, ($3/$2)*100}'
}

# ── GPU ───────────────────────────────────────────────────────────────────────
gpu_metrics() {
    nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null | awk -F', ' '{
        printf "GPU%s_USAGE=%s%% | GPU%s_VRAM=%.1f/%.1fGB | GPU%s_TEMP=%s°C",
            $1, $2, $1, $3/1024, $4/1024, $1, $5}'
}

# ── Docker ────────────────────────────────────────────────────────────────────
collect_docker_stats() {      # runs per-container stats in parallel; returns tmpdir path
    local td; td=$(mktemp -d)
    for svc in "${SERVICES[@]}"; do
        local n; n=$(svc_name "$svc")
        docker stats --no-stream --format \
            "{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}" \
            "$n" > "${td}/${n}" 2>/dev/null &
    done
    wait
    echo "$td"
}

collect_service_data() {      # one docker ps call + ss per port
    local ps_out; ps_out=$(docker ps -a --format "{{.Names}}\t{{.Status}}" 2>/dev/null || true)
    for svc in "${SERVICES[@]}"; do
        local n; n=$(svc_name "$svc")
        local p; p=$(svc_port "$svc")
        STATUSES["$n"]=$(awk -F'\t' -v x="$n" '$1==x{print $2;exit}' <<< "$ps_out")
        CONNS["$p"]=$(ss -tn state established 2>/dev/null | awk -v p=":$p" 'NR>1 && $4~p{c++} END{print c+0}')
    done
}

get_recent_logs() {
    docker logs --tail "${2:-5}" "$1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true
}

# ── Display helpers ───────────────────────────────────────────────────────────
bar() {
    awk -v v="${1//%/}" 'BEGIN {
        w=20; f=int(v/100*w); if(f>w)f=w; if(f<0)f=0
        b=""; for(i=0;i<f;i++) b=b"█"; for(i=f;i<w;i++) b=b"░"
        printf "%s%s\033[0m", (v>80)?"\033[31m":(v>50)?"\033[33m":"\033[32m", b}'
}

badge() {
    case "$1" in
        *Up*)     printf '%s● UP  %s' "$cG" "$cN" ;;
        *Exited*) printf '%s● DOWN%s' "$cR" "$cN" ;;
        *)        printf '%s● ??? %s' "$cY" "$cN" ;;
    esac
}

# ── Terminal dashboard ────────────────────────────────────────────────────────
print_dashboard() {
    local cpu_out="$1" ram_out="$2" gpu_out="$3" td="$4"
    local now; now=$(date '+%Y-%m-%d  %H:%M:%S')

    printf '\033[2J\033[H'
    printf '%s╔══════════════════════════════════════════════════════════════╗%s\n' "$cB$cC" "$cN"
    printf '%s║%s%s  syswatch — System + Traffic Monitor%s    %s  %s║%s\n' \
        "$cB$cC" "$cN" "$cB" "$cN" "$now" "$cB$cC" "$cN"
    printf '%s╚══════════════════════════════════════════════════════════════╝%s\n\n' "$cB$cC" "$cN"

    printf '%s── System ──────────────────────────────────────────────────────%s\n' "$cD" "$cN"
    printf '  %s\n  %s\n' "$cpu_out" "$ram_out"
    if [[ -n "$gpu_out" ]]; then printf '  %s\n' "$gpu_out"; fi
    printf '\n%s── Services ─────────────────────────────────────────────────────%s\n\n' "$cD" "$cN"

    for svc in "${SERVICES[@]}"; do
        local n; n=$(svc_name "$svc")
        local p; p=$(svc_port "$svc")
        local l; l=$(svc_label "$svc")
        local status="${STATUSES[$n]:-}"
        local conns="${CONNS[$p]:-0}"
        local sf="${td}/${n}"

        printf '  '; badge "$status"
        printf '  %s%s%s  %s%s%s  %s:%s%s\n' "$cB" "$l" "$cN" "$cD" "$n" "$cN" "$cC" "$p" "$cN"
        printf '  ──────────────────────────────────────────────────────────────\n'

        local cc
        if   (( conns > 50 )); then cc="${cR}${conns}${cN}"
        elif (( conns > 10 )); then cc="${cY}${conns}${cN}"
        else cc="${cG}${conns}${cN}"; fi
        printf '  %-14s %s\n' "Connections" "$cc"

        if [[ -s "$sf" ]]; then
            IFS=$'\t' read -r cpu mem net block pids < "$sf"
            printf '  %-14s ' "CPU"; bar "$cpu"; printf '  %s\n' "$cpu"
            printf '  %-14s %s\n  %-14s %s\n  %-14s %s\n  %-14s %s\n' \
                "Memory" "$mem" "Net I/O" "$net" "Block I/O" "$block" "PIDs" "$pids"
        else
            printf '  %s(docker stats unavailable)%s\n' "$cD" "$cN"
        fi
        echo
    done

    printf '%s── Summary ──────────────────────────────────────────────────────%s\n' "$cD" "$cN"
    local total=0
    for svc in "${SERVICES[@]}"; do
        local p; p=$(svc_port "$svc")
        local l; l=$(svc_label "$svc")
        local c="${CONNS[$p]:-0}"
        total=$(( total + c ))
        printf '  %-16s port %s  →  %s conn\n' "$l" "$p" "$c"
    done
    printf '\n  Total connections : %s%s%s\n' "$cB" "$total" "$cN"
    if (( MODE_LOG )); then printf '  %sLog → %s%s\n' "$cD" "$LOG_FILE" "$cN"; fi
    printf '  %sRefreshing every %ss — Ctrl+C to exit%s\n\n' "$cD" "$INTERVAL" "$cN"
}

# ── Log snapshot ──────────────────────────────────────────────────────────────
write_log_snapshot() {
    local cpu_out="$1" ram_out="$2" gpu_out="$3" td="$4"

    log "METRIC | ${cpu_out} | ${ram_out}${gpu_out:+ | ${gpu_out}}"

    for svc in "${SERVICES[@]}"; do
        local n; n=$(svc_name "$svc")
        local p; p=$(svc_port "$svc")
        local l; l=$(svc_label "$svc")
        local status="${STATUSES[$n]:-unknown}"
        local conns="${CONNS[$p]:-0}"
        local state; [[ "$status" == *"Up"* ]] && state="UP" || state="DOWN"
        local sf="${td}/${n}"
        local msg="DOCKER | [${l}] port=${p} state=${state} conns=${conns}"

        if [[ -s "$sf" ]]; then
            IFS=$'\t' read -r cpu mem net block pids < "$sf"
            msg+=" cpu=${cpu} mem=${mem} net=${net} pids=${pids}"
        fi

        if [[ "$state" == "DOWN" ]]; then
            printf '%s | WARN  | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_FILE"
        else
            log "$msg"
        fi

        local last_alert=""
        while IFS= read -r line; do
            [[ "$line" =~ ERROR|CRITICAL|WARN ]] && last_alert="$line"
        done < <(get_recent_logs "$n" 10)

        if [[ -n "$last_alert" && "${LAST_LOG[$n]:-}" != "$last_alert" ]]; then
            LAST_LOG["$n"]="$last_alert"
            if [[ "$last_alert" =~ ERROR|CRITICAL ]]; then
                printf '%s | ERROR | [%s] %.200s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$l" "$last_alert" >> "$LOG_FILE"
            else
                printf '%s | WARN  | [%s] %.200s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$l" "$last_alert" >> "$LOG_FILE"
            fi
        fi
    done
}

# ── JSON snapshot ─────────────────────────────────────────────────────────────
json_snapshot() {
    collect_service_data
    printf '{\n  "timestamp": "%s",\n' "$(date -Iseconds)"
    printf '  "system": {"cores": %d, "ram": "%s", "gpu": "%s"},\n' \
        "$CORES" "$(ram_metrics)" "$(gpu_metrics)"
    printf '  "services": {\n'
    local first=1
    for svc in "${SERVICES[@]}"; do
        local n; n=$(svc_name "$svc")
        local p; p=$(svc_port "$svc")
        local l; l=$(svc_label "$svc")
        if (( ! first )); then printf ',\n'; fi; first=0
        printf '    "%s": {"label": "%s", "port": %s, "status": "%s", "connections": %s}' \
            "$n" "$l" "$p" "${STATUSES[$n]:-unknown}" "${CONNS[$p]:-0}"
    done
    printf '\n  }\n}\n'
}

# ── Main ──────────────────────────────────────────────────────────────────────
if (( MODE_JSON )); then
    json_snapshot
    exit 0
fi

echo $$ > "$PID_FILE"
log "INFO  | Monitor started (PID $$) | interval=${INTERVAL}s | cores=${CORES} | log=${LOG_FILE}"
if (( ! MODE_LOG_ONLY )); then
    printf '%s\n  Starting syswatch… (Ctrl+C to exit)\n\n%s' "$cB" "$cN"
fi

prev_snap=$(snapshot_cpu)

while true; do
    td=$(collect_docker_stats)   # ~1s parallel
    curr_snap=$(snapshot_cpu)
    collect_service_data

    cpu_out=$(cpu_metrics "$prev_snap" "$curr_snap")
    ram_out=$(ram_metrics)
    gpu_out=$(gpu_metrics)

    if (( ! MODE_LOG_ONLY )); then
        print_dashboard "$cpu_out" "$ram_out" "$gpu_out" "$td"
    fi
    if (( MODE_LOG )); then
        rotate_log
        write_log_snapshot "$cpu_out" "$ram_out" "$gpu_out" "$td"
    fi

    rm -rf "$td"
    prev_snap="$curr_snap"
    sleep "$INTERVAL"
done
