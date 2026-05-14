# syswatch

Two production-grade monitors for Linux systems and Docker services.

---

## monitor.sh — System Monitor (bash)

Logs per-core CPU, RAM, and GPU metrics every second.

### Features

- Per-core CPU usage via `/proc/stat` diff
- RAM — total, used, available, usage %
- GPU — utilization, VRAM, temperature (NVIDIA via `nvidia-smi`)
- PID file for easy start/stop
- Automatic log rotation at 100 MB
- Graceful shutdown on SIGTERM / SIGINT / SIGHUP

**Requirements:** bash, `nvidia-smi` (optional)

### Start

```bash
nohup bash monitor.sh > /dev/null 2>&1 &
```

### Stop

```bash
kill $(cat /tmp/system_monitor.pid)
```

### Watch live

```bash
tail -f ~/logs/system_monitor.log
```

### Log format

```
2026-05-14 12:00:01 | METRIC | CORES=8 | CPU_TOTAL=4.2% | cpu0=3.0% | ... | RAM_TOTAL=22.9GB | RAM_USED=8.8GB | RAM_AVAIL=14.0GB | RAM_USAGE=38.6% | GPU0_USAGE=12% | GPU0_VRAM_USED=1.2GB | GPU0_VRAM_TOTAL=8.0GB | GPU0_TEMP=43°C
```

### Configuration

Edit the top of `monitor.sh`:

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `~/logs` | Log directory |
| `INTERVAL` | `1` | Seconds between samples |
| `MAX_LOG_MB` | `100` | Log rotation threshold |

---

## monitor.py — Docker Traffic Monitor (Python)

Live terminal dashboard for Docker services on sd09-stt.
Monitors: `diarization_service` (8080), `socket` (9395), `socket_stt` (9394).

- Live terminal dashboard with color-coded status
- Per-service CPU, memory, net I/O, PIDs via `docker stats`
- Active TCP connection counts per port
- Recent container log tail with ERROR/WARN highlighting
- Optional file logging and JSON snapshot mode

**Requirements:** Python 3, Docker

### Usage

```bash
python3 monitor.py                   # live dashboard
python3 monitor.py --log             # dashboard + log file
python3 monitor.py --log-only        # background logging only
python3 monitor.py --json            # one-shot JSON snapshot
python3 monitor.py --log --logfile /var/log/stt_monitor.log
```

### Run in background

```bash
nohup python3 monitor.py --log-only > /dev/null 2>&1 &
```
