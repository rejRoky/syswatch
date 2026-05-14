# syswatch

Production-grade system monitor for Linux. Logs per-core CPU, RAM, and GPU metrics every second.

## Features

- Per-core CPU usage (via `/proc/stat` diff)
- RAM — total, used, available, usage %
- GPU — utilization, VRAM, temperature (NVIDIA via `nvidia-smi`)
- PID file for easy start/stop
- Automatic log rotation at 100 MB
- Graceful shutdown on SIGTERM / SIGINT / SIGHUP

## Requirements

- bash
- `nvidia-smi` (optional, for GPU metrics)

## Usage

**Start**
```bash
nohup bash monitor.sh > /dev/null 2>&1 &
```

**Stop**
```bash
kill $(cat /tmp/system_monitor.pid)
```

**Watch live**
```bash
tail -f ~/logs/system_monitor.log
```

## Log format

```
2026-05-14 12:00:01 | METRIC | CORES=8 | CPU_TOTAL=4.2% | cpu0=3.0% | ... | RAM_TOTAL=22.9GB | RAM_USED=8.8GB | RAM_AVAIL=14.0GB | RAM_USAGE=38.6% | GPU0_USAGE=12% | GPU0_VRAM_USED=1.2GB | GPU0_VRAM_TOTAL=8.0GB | GPU0_TEMP=43°C
```

## Configuration

Edit the top of `monitor.sh`:

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `~/logs` | Log directory |
| `INTERVAL` | `1` | Seconds between samples |
| `MAX_LOG_MB` | `100` | Log rotation threshold |
