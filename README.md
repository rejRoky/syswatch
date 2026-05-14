# syswatch

Production-grade Linux system + Docker traffic monitor in a single bash script.

Tracks per-core CPU, RAM, GPU, and Docker service health every second.

---

## Features

- Per-core CPU usage via `/proc/stat` diff
- RAM — total, used, available, usage %
- GPU — utilization, VRAM, temperature (NVIDIA via `nvidia-smi`)
- Docker services — status, TCP connections, CPU/mem/net/block I/O, PIDs
- Live color terminal dashboard
- File logging with structured output and auto-rotation at 100 MB
- Container log scanning — deduped ERROR/WARN alerts in log file
- PID file for easy stop
- Graceful shutdown on SIGTERM / SIGINT / SIGHUP

**Requirements:** bash, docker, `nvidia-smi` (optional)

---

## Usage

### Live dashboard

```bash
bash monitor.sh
```

### Live dashboard + log file

```bash
bash monitor.sh --log
```

### Background logging only

```bash
nohup bash monitor.sh --log-only > /dev/null 2>&1 &
```

### One-shot JSON snapshot

```bash
bash monitor.sh --json
```

---

## Start / Stop

```bash
# Start in background
nohup bash monitor.sh --log-only > /dev/null 2>&1 &

# Stop
kill $(cat /tmp/system_monitor.pid)

# Watch live log
tail -f ~/logs/system_monitor.log
```

---

## Log format

```text
2026-05-14 12:00:01 | METRIC | CORES=8 | CPU_TOTAL=4.2% | cpu0=3.0% | ... | RAM_TOTAL=22.9GB | RAM_USED=8.8GB | RAM_AVAIL=14.0GB | RAM_USAGE=38.6% | GPU0_USAGE=12% | GPU0_VRAM=1.2/8.0GB | GPU0_TEMP=43°C
2026-05-14 12:00:01 | DOCKER | [Diarization] port=8080 state=UP conns=3 cpu=1.2% mem=512MiB / 8GiB ...
2026-05-14 12:00:01 | WARN   | [Socket STT] port=9394 state=DOWN conns=0
```

---

## Configuration

Edit the top of `monitor.sh`:

| Variable | Default | Description |
| --- | --- | --- |
| `LOG_DIR` | `~/logs` | Log directory |
| `INTERVAL` | `1` | Seconds between samples |
| `MAX_LOG_MB` | `100` | Log rotation threshold |
| `SERVICES` | 3 docker services | `"name:port:Label"` array |
