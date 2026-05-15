#!/usr/bin/env python3
"""
Pi health metrics submitter.

Reads CPU% (averaged across cores) and CPU temperature, POSTs them to
cluster-frontend's /api/metrics-ingest endpoint. Designed to be run by a
systemd timer (every minute). Reads its config from .env next to this
script.

This repo is standalone — install it on any Pi you want to appear in the
dashboard's health charts, regardless of whether the Pi is also a cluster
worker, the cluster controller, a presence scanner, or something else
entirely (HomeAssistant, etc.).
"""
import os
import subprocess
import sys
from pathlib import Path

import psutil
import requests

# Repo root = directory this script lives in. metrics.py is the entry
# point at the top of the repo; VERSION and .env sit next to it.
REPO_ROOT = Path(__file__).resolve().parent


def load_env():
    env_path = REPO_ROOT / '.env'
    if not env_path.exists():
        print(f'metrics: missing {env_path}', file=sys.stderr)
        sys.exit(2)
    env = {}
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        k, v = line.split('=', 1)
        # strip optional surrounding single/double quotes
        v = v.strip()
        if (v.startswith("'") and v.endswith("'")) or (v.startswith('"') and v.endswith('"')):
            v = v[1:-1]
        env[k.strip()] = v
    return env


def read_temp():
    """Return CPU temperature in Celsius, or None if not exposed."""
    try:
        temps = psutil.sensors_temperatures()
    except (AttributeError, OSError):
        return None
    for key in ('cpu_thermal', 'coretemp', 'cpu-thermal'):
        if key in temps and temps[key]:
            return temps[key][0].current
    return None


def read_agent_version():
    """Return the pi-health-metrics version from the repo's VERSION file,
    or None if it can't be read. Plain-text semver, one line."""
    vfile = REPO_ROOT / 'VERSION'
    try:
        v = vfile.read_text(encoding='utf-8').strip()
        return v or None
    except OSError:
        return None


def read_agent_commit():
    """Return the short git commit hash (7 chars) of this worktree, or
    None if git isn't available / the directory isn't a git repo."""
    try:
        out = subprocess.run(
            ['git', 'rev-parse', '--short', 'HEAD'],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            timeout=3
        )
        if out.returncode != 0:
            return None
        sha = out.stdout.strip()
        # `--short` typically produces 7 chars but git may extend on collisions;
        # cap to 16 to match the DB column width.
        return sha[:16] if sha else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def main():
    env = load_env()
    for required in ('INGEST_URL', 'WORKER_SECRET', 'NODE_NAME'):
        if not env.get(required):
            print(f'metrics: missing {required} in .env', file=sys.stderr)
            sys.exit(2)

    cpu = psutil.cpu_percent(interval=1)  # blocks for 1s, returns averaged %
    temp = read_temp()

    payload = {'name': env['NODE_NAME'], 'cpu': cpu}
    if temp is not None:
        payload['temp'] = temp

    # Best-effort version reporting. Both fields are optional; if either
    # read fails (no VERSION file, no git, detached worktree, …), the
    # endpoint will skip updating that column. Sending null on every tick
    # would wipe the existing row's value, so we omit instead.
    agent_version = read_agent_version()
    if agent_version:
        payload['agent_version'] = agent_version
    agent_commit = read_agent_commit()
    if agent_commit:
        payload['agent_commit'] = agent_commit

    try:
        resp = requests.post(
            env['INGEST_URL'],
            headers={'X-Device-Secret': env['WORKER_SECRET']},
            json=payload,
            timeout=10
        )
    except requests.RequestException as e:
        print(f'metrics: request failed: {e}', file=sys.stderr)
        sys.exit(1)

    if resp.status_code == 404:
        print(f'metrics: pi name "{env["NODE_NAME"]}" not registered yet', file=sys.stderr)
        sys.exit(0)  # not an error worth alerting on; the timer will retry next minute
    if resp.status_code >= 400:
        print(f'metrics: ingest returned HTTP {resp.status_code}: {resp.text}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
