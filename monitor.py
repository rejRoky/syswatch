#!/usr/bin/env python3
"""
Active Traffic Monitor — sd09-stt
Monitors: diarization_service (8080), socket (9395), socket_stt (9394)

Usage:
  python3 monitor.py                  # live terminal dashboard
  python3 monitor.py --log            # live dashboard + save to log file
  python3 monitor.py --log-only       # log to file only (good for background/cron)
  python3 monitor.py --json           # one-shot JSON snapshot and exit
  python3 monitor.py --log --logfile /var/log/stt_monitor.log  # custom log path
"""

import subprocess
import time
import os
import sys
import json
import logging
import re
from datetime import datetime
from pathlib import Path

SERVICES = {
    "diarization-diarization_service-1": {"port": 8080, "label": "Diarization"},
    "socket":                             {"port": 9395, "label": "Socket"},
    "socket_stt":                         {"port": 9394, "label": "Socket STT"},
}

PORTS       = [str(s["port"]) for s in SERVICES.values()]
REFRESH     = 3   # seconds between polls
DEFAULT_LOG = "/var/log/stt_monitor.log"

_last_log_line: dict[str, str] = {}  # dedup container log alerts


# ── argument parsing ─────────────────────────────────────────────────────────

def parse_args():
    args = sys.argv[1:]
    logfile = DEFAULT_LOG
    if "--logfile" in args:
        idx = args.index("--logfile")
        if idx + 1 < len(args):
            logfile = args[idx + 1]
    return {
        "json":     "--json"     in args,
        "log":      "--log"      in args or "--log-only" in args,
        "log_only": "--log-only" in args,
        "logfile":  logfile,
    }


# ── logging setup ────────────────────────────────────────────────────────────

def setup_logger(logfile):
    logger = logging.getLogger("stt_monitor")
    logger.setLevel(logging.DEBUG)

    path = Path(logfile)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fh = logging.FileHandler(logfile)
    except PermissionError:
        fallback = "stt_monitor.log"
        print(f"[warn] Cannot write to {logfile}, using ./{fallback}")
        fh = logging.FileHandler(fallback)
        logfile = fallback

    fh.setLevel(logging.DEBUG)
    fmt = logging.Formatter(
        "%(asctime)s  %(levelname)-7s  %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )
    fh.setFormatter(fmt)
    logger.addHandler(fh)
    return logger, logfile


def strip_ansi(text):
    return re.sub(r"\033\[[0-9;]*m", "", text)


# ── terminal color helpers ────────────────────────────────────────────────────

def color(text, code): return f"\033[{code}m{text}\033[0m"
def green(t):  return color(t, "32")
def yellow(t): return color(t, "33")
def red(t):    return color(t, "31")
def cyan(t):   return color(t, "36")
def bold(t):   return color(t, "1")
def dim(t):    return color(t, "2")


# ── data collection ──────────────────────────────────────────────────────────

def get_connections():
    counts = {p: 0 for p in PORTS}
    try:
        out = subprocess.check_output(
            ["ss", "-tn", "state", "established"],
            stderr=subprocess.DEVNULL
        ).decode()
        for line in out.splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 4:
                for p in PORTS:
                    if parts[3].endswith(f":{p}"):
                        counts[p] += 1
    except Exception:
        pass
    return counts


def get_docker_stats():
    stats = {}
    for name in SERVICES:
        try:
            out = subprocess.check_output(
                ["docker", "stats", "--no-stream", "--format",
                 "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}",
                 name],
                stderr=subprocess.DEVNULL
            ).decode().strip()
            if out:
                parts = out.split("\t")
                if len(parts) >= 6:
                    stats[name] = {
                        "cpu": parts[1], "mem": parts[2],
                        "net": parts[3], "block": parts[4], "pids": parts[5],
                    }
        except Exception:
            pass
    return stats


def get_container_status():
    status = {}
    try:
        out = subprocess.check_output(
            ["docker", "ps", "-a", "--format", "{{.Names}}\t{{.Status}}"],
            stderr=subprocess.DEVNULL
        ).decode()
        for line in out.strip().splitlines():
            parts = line.split("\t", 1)
            if len(parts) == 2:
                status[parts[0]] = parts[1]
    except Exception:
        pass
    return status


def get_recent_logs(container, lines=5):
    try:
        out = subprocess.check_output(
            ["docker", "logs", "--tail", str(lines), container],
            stderr=subprocess.STDOUT
        ).decode(errors="replace")
        return out.strip().splitlines()
    except Exception:
        return []


# ── log writer ───────────────────────────────────────────────────────────────

def write_log_snapshot(logger, connections, docker_stats, statuses, iteration):
    logger.info("─" * 60)
    logger.info(f"Snapshot #{iteration}  |  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    logger.info(f"Total connections: {sum(connections.values())}")

    for name, info in SERVICES.items():
        port   = str(info["port"])
        stat   = docker_stats.get(name, {})
        status = statuses.get(name, "unknown")
        conns  = connections.get(port, 0)
        state  = "UP" if "Up" in status else "DOWN"

        msg = (f"[{info['label']}] port={info['port']}  state={state}"
               f"  connections={conns}")
        if stat:
            msg += (f"  cpu={stat['cpu']}  mem={stat['mem']}"
                    f"  net={stat['net']}  pids={stat['pids']}")

        level = logging.WARNING if state == "DOWN" else logging.INFO
        logger.log(level, msg)

    for name, info in SERVICES.items():
        lines = get_recent_logs(name, lines=10)
        for line in reversed(lines):
            clean = strip_ansi(line).strip()
            if not clean:
                continue
            if "ERROR" in clean or "CRITICAL" in clean or "WARN" in clean:
                if _last_log_line.get(name) == clean:
                    break  # same tail as last snapshot — nothing new
                _last_log_line[name] = clean
                if "ERROR" in clean or "CRITICAL" in clean:
                    logger.error(f"[{info['label']}] {clean[:200]}")
                else:
                    logger.warning(f"[{info['label']}] {clean[:200]}")
                break


# ── terminal display ──────────────────────────────────────────────────────────

def bar(value_str, width=20):
    try:
        val = float(value_str.strip().replace("%", ""))
        filled = min(int((val / 100) * width), width)
        b = "█" * filled + "░" * (width - filled)
        return red(b) if val > 80 else yellow(b) if val > 50 else green(b)
    except Exception:
        return "░" * width


def status_badge(s):
    if "Up"     in s: return green("● UP  ")
    if "Exited" in s: return red("● DOWN")
    return yellow("● ???  ")


def print_header(logfile=None):
    now = datetime.now().strftime("%Y-%m-%d  %H:%M:%S")
    print(bold(cyan("╔══════════════════════════════════════════════════════════════╗")))
    print(bold(cyan("║")) + bold("  sd09-stt — Active Traffic Monitor") +
          dim(f"          {now}  ") + bold(cyan("║")))
    if logfile:
        short = logfile if len(logfile) <= 40 else "…" + logfile[-39:]
        print(bold(cyan("║")) + dim(f"  Logging → {short:<51}") + bold(cyan("║")))
    print(bold(cyan("╚══════════════════════════════════════════════════════════════╝")))
    print()


def print_service_block(name, info, stat, status_str, conns):
    print(f"  {status_badge(status_str)}  {bold(info['label'])}  "
          f"{dim(name)}  {cyan(f':{info[\"port\"]}')}")
    print(f"  {'─'*60}")
    cc = red(str(conns)) if conns > 50 else yellow(str(conns)) if conns > 10 else green(str(conns))
    print(f"  {'Connections':<14} {cc}")
    if stat:
        print(f"  {'CPU':<14} {bar(stat['cpu'])}  {stat['cpu']}")
        print(f"  {'Memory':<14} {stat['mem']}")
        print(f"  {'Net I/O':<14} {stat['net']}")
        print(f"  {'Block I/O':<14} {stat['block']}")
        print(f"  {'PIDs':<14} {stat['pids']}")
    else:
        print(f"  {dim('(docker stats unavailable)')}")
    print()


def print_logs_section(name, label):
    logs = get_recent_logs(name, lines=5)
    if logs:
        print(f"  {dim('─── recent logs: ' + label)}")
        for line in logs:
            if "ERROR" in line or "error" in line:
                print(f"    {red(line[:100])}")
            elif "WARN" in line or "warn" in line:
                print(f"    {yellow(line[:100])}")
            else:
                print(f"    {dim(line[:100])}")
        print()


def print_summary(connections, logfile=None):
    print(bold("  Summary"))
    print(f"  {'─'*60}")
    print(f"  Total active connections : {bold(str(sum(connections.values())))}")
    for name, info in SERVICES.items():
        c = connections.get(str(info["port"]), 0)
        print(f"  {info['label']:<16} port {info['port']}  →  {c} conn")
    print()
    if logfile:
        print(dim(f"  Saving log → {logfile}"))
    print(dim(f"  Refreshing every {REFRESH}s — Ctrl+C to exit"))


# ── main loop ────────────────────────────────────────────────────────────────

def run(opts):
    logger  = None
    logfile = None

    if opts["log"]:
        logger, logfile = setup_logger(opts["logfile"])
        logger.info("=" * 60)
        logger.info("stt_monitor started")
        logger.info(f"Watching: {', '.join(SERVICES.keys())}")
        logger.info("=" * 60)

    if not opts["log_only"]:
        print(bold("\n  Starting monitor… (Ctrl+C to exit)\n"))
        time.sleep(1)

    iteration = 0
    while True:
        try:
            connections  = get_connections()
            docker_stats = get_docker_stats()
            statuses     = get_container_status()

            if not opts["log_only"]:
                os.system("clear")
                print_header(logfile)
                for name, info in SERVICES.items():
                    print_service_block(
                        name, info,
                        docker_stats.get(name, {}),
                        statuses.get(name, "Unknown"),
                        connections.get(str(info["port"]), 0)
                    )
                if iteration % 3 == 0:
                    for name, info in SERVICES.items():
                        print_logs_section(name, info["label"])
                print_summary(connections, logfile)

            if logger:
                write_log_snapshot(logger, connections, docker_stats, statuses, iteration)

            iteration += 1
            time.sleep(REFRESH)

        except KeyboardInterrupt:
            msg = "Monitor stopped by user."
            if not opts["log_only"]:
                print(f"\n\n  {dim(msg)}\n")
            if logger:
                logger.info(msg)
            sys.exit(0)

        except Exception as e:
            if not opts["log_only"]:
                print(f"\n  {red('Error:')} {e}\n")
            if logger:
                logger.error(f"Unhandled exception: {e}")
            time.sleep(REFRESH)


# ── entry point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    opts = parse_args()

    if opts["json"]:
        print(json.dumps({
            "timestamp":   datetime.now().isoformat(),
            "connections": get_connections(),
            "stats":       get_docker_stats(),
            "status":      get_container_status(),
        }, indent=2))
        sys.exit(0)

    run(opts)
