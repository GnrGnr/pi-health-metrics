# pi-health-metrics

A small Python script that submits CPU% and CPU temperature from a Pi to **cluster-frontend**'s metrics endpoint once per minute. Cluster-frontend renders the data as per-card sparklines on the dashboard.

Standalone repo — install it on any Pi you want to appear in the dashboard's health charts, regardless of role:

- Workers running [pi-cluster-worker](https://github.com/GnrGnr/pi-cluster-worker)
- The cluster controller (same repo)
- Scanners running [pi-presence-scanner](https://github.com/GnrGnr/pi-presence-scanner)
- Anything else with a network path to cluster-frontend (HomeAssistant Pi, dev box, etc.)

## Install

```sh
cd ~
git clone https://github.com/GnrGnr/pi-health-metrics.git
cd pi-health-metrics

# Seed .env before first run:
cp .env.example .env
# …edit .env, set NODE_NAME, INGEST_URL, WORKER_SECRET.
chmod 600 .env

sudo bash install.sh                 # interactive
sudo bash install.sh --yes           # no prompts
```

The installer:
- Removes any predecessor `~/cluster-manager/agents/worker-health/metrics.py` cron line.
- Removes the legacy `worker-health.{service,timer}` from the scanner repo if present (this repo replaces them).
- Installs `python3-psutil` + `python3-requests` if missing.
- Substitutes the actual user + repo path into the systemd unit (so it works regardless of whether the Pi runs as `admin`, `pi`, or something else).
- Installs + enables + starts `pi-health-metrics.timer`.
- Triggers one immediate run so the dashboard updates without waiting for the first scheduled tick.

Idempotent — re-run after `git pull` to update.

## What gets sent

Each tick POSTs:

```json
{
  "name": "pi-1",
  "cpu": 17.3,
  "temp": 47.1,
  "agent_version": "1.0.0",
  "agent_commit": "a3f5c91"
}
```

| Field | Source |
|---|---|
| `name` | `NODE_NAME` from `.env`, matched against `cluster_pi.name` (case-insensitive) |
| `cpu` | `psutil.cpu_percent(interval=1)` — cores-averaged over a 1-second sample |
| `temp` | `psutil.sensors_temperatures()['cpu_thermal']` (or `coretemp` / `cpu-thermal` as fallbacks). Omitted if no thermal sensor is exposed. |
| `agent_version` | Plain-text contents of the repo's `VERSION` file (semver). Omitted if missing. |
| `agent_commit` | Short git SHA of this worktree (`git rev-parse --short HEAD`). Omitted if not in a git repo. |

If the Pi name isn't registered yet on cluster-frontend, the ingest returns 404 — the script exits 0 (not an alertable error) and the next minute's run retries.

## Environment variables

| Var | Description |
|---|---|
| `INGEST_URL` | Full URL of cluster-frontend's metrics endpoint, typically `https://<domain>/api/metrics-ingest`. |
| `WORKER_SECRET` | Shared secret. Must match `WORKER_SECRET` in cluster-frontend's root `.env` on Uberspace. |
| `NODE_NAME` | This Pi's name as it appears in `cluster_pi.name`. Different per Pi. |

## Versioning

This repo carries its own version in the `VERSION` file at the repo root. Bump it when you ship a change worth flagging on the dashboard. The script reads it on every run and includes it in each POST as `agent_version`, so cluster-frontend can tell which Pi is on which version without an active SSH session.

## Server-side retention

Cluster-frontend keeps the last 24 hours of metrics. Each successful ingest opportunistically prunes:

```sql
DELETE FROM cluster_pi_metric WHERE measured_at < NOW() - INTERVAL 24 HOUR;
```

So data is pruned by *any* Pi's submission. If every Pi goes silent, no pruning happens — the existing rows simply stop ageing out.

## Why systemd timer instead of cron

Cluster-manager's original health-metrics setup used a crontab line; the scanner repo used a systemd timer. This repo standardises on the **systemd timer**:

- Journal-based logging (`journalctl -u pi-health-metrics`) rather than ad-hoc log files.
- `OnBootSec=45s` delay so the cpu_percent(interval=1) sample doesn't compete with OS boot warmup.
- `Persistent=false` so we don't catch up missed runs after a power-off (the metrics only make sense in real-time).
- One configuration mechanism across all Pi-side daemons.

## Migrating from the old setup

If this Pi previously ran `~/cluster-manager/agents/worker-health/metrics.py` via crontab, or the scanner repo's `worker-health.service`/`.timer`, the installer detects both and offers to remove them before installing the new timer. Confirm when prompted.
