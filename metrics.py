#!/usr/bin/env python3
"""
Worker metrics submitter.

Reads CPU% (averaged across cores) and CPU temperature, POSTs them to the
cluster-manager's metrics-ingest endpoint. Designed to be run from cron once
per minute. Reads its config from `.env` next to this script.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import psutil
import requests

# Repo root, two directories above this script (agents/worker-health/ → agents/ → root).
REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def load_env():
    # Shared per-Pi env file at `agents/.env`, one directory up from this
    # script. See agents/.env.example for the full key reference.
    env = {}
    env_path = Path(__file__).resolve().parent.parent / '.env'
    if not env_path.exists():
        print(f'metrics: missing {env_path}', file=sys.stderr)
        sys.exit(2)
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
    """Return the cluster-manager project version from the repo root
    package.json, or None if it can't be read."""
    pkg = REPO_ROOT / 'package.json'
    try:
        with pkg.open('r', encoding='utf-8') as f:
            data = json.load(f)
        v = data.get('version')
        return v if isinstance(v, str) and v else None
    except (OSError, ValueError):
        return None


def read_agent_commit():
    """Return the short git commit hash (7 chars) of the worktree this
    script lives in, or None if git isn't available / the directory isn't
    a git repo."""
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
    # read fails (no package.json, no git, detached worktree, …), the
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
        sys.exit(0)  # not an error worth alerting on; cron will retry next minute
    if resp.status_code >= 400:
        print(f'metrics: ingest returned HTTP {resp.status_code}: {resp.text}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
