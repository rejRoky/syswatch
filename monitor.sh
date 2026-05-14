#!/bin/bash
set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
LOG_DIR="${HOME}/logs"
LOG_FILE="${LOG_DIR}/system_monitor.log"
PID_FILE="/tmp/system_monitor.pid"
INTERVAL=1
MAX_LOG_MB=100
CORES=$(nproc)

# ── Init ──────────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"

log() {
    printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

cleanup() {
    rm -f "$PID_FILE"
    log "INFO  | Monitor stopped (PID $$)"
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

rotate_log() {
    [[ -f "$LOG_FILE" ]] || return
    local bytes; bytes=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if (( bytes / 1048576 >= MAX_LOG_MB )); then
        mv "$LOG_FILE" "${LOG_FILE%.log}_$(date '+%Y%m%d_%H%M%S').log"
        log "INFO  | Log rotated"
    fi
}

# ── CPU (diff two /proc/stat snapshots over INTERVAL) ─────────────────────────
snapshot_cpu() {
    grep "^cpu" /proc/stat
}

cpu_metrics() {
    local prev="$1" curr="$2"
    local out="CORES=${CORES}"

    while IFS= read -r cline; do
        local name; name=$(awk '{print $1}' <<< "$cline")
        local pline; pline=$(grep "^${name} " <<< "$prev" || true)
        [[ -z "$pline" ]] && continue

        # Pass both lines directly into awk; use only fields 2-9 (excludes
        # guest/guest_nice which are already counted inside user/nice)
        local pct
        pct=$(awk -v p="$pline" -v c="$cline" 'BEGIN {
            split(p, a); split(c, b)
            p_idle = a[5] + a[6]; c_idle = b[5] + b[6]
            p_tot = 0; c_tot = 0
            for (i = 2; i <= 9; i++) { p_tot += a[i]; c_tot += b[i] }
            dt = c_tot - p_tot; di = c_idle - p_idle
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

# ── GPU (nvidia-smi) ──────────────────────────────────────────────────────────
gpu_metrics() {
    nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu \
               --format=csv,noheader,nounits 2>/dev/null | \
    awk -F', ' '{
        used_gb  = $3 / 1024
        total_gb = $4 / 1024
        printf "GPU%s_USAGE=%s%% | GPU%s_VRAM_USED=%.1fGB | GPU%s_VRAM_TOTAL=%.1fGB | GPU%s_TEMP=%s°C",
            $1, $2, $1, used_gb, $1, total_gb, $1, $5
    }'
}

# ── RAM ───────────────────────────────────────────────────────────────────────
ram_metrics() {
    free -b | awk '/Mem:/ {
        total=$2; used=$3; avail=$7
        printf "RAM_TOTAL=%.1fGB | RAM_USED=%.1fGB | RAM_AVAIL=%.1fGB | RAM_USAGE=%.1f%%",
            total/1073741824, used/1073741824, avail/1073741824, (used/total)*100
    }'
}

# ── Main loop ─────────────────────────────────────────────────────────────────
echo $$ > "$PID_FILE"
log "INFO  | Monitor started (PID $$) | interval=${INTERVAL}s | cores=${CORES} | log=${LOG_FILE}"
echo "Monitor started. PID=$$ | Log: $LOG_FILE | Stop: kill \$(cat $PID_FILE)"

prev_snap=$(snapshot_cpu)

while true; do
    sleep "$INTERVAL"
    rotate_log

    curr_snap=$(snapshot_cpu)
    log "METRIC | $(cpu_metrics "$prev_snap" "$curr_snap") | $(ram_metrics) | $(gpu_metrics)"
    prev_snap="$curr_snap"
done
