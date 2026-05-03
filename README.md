# worker-health (metrics submitter)

A small Python script that runs on each worker Pi via cron, reads CPU% and CPU temperature, and POSTs them to the cluster-manager. The cluster-manager renders the data as a per-card sparkline on `/home`.

> Renamed from `agents/worker/` — see "Migrating from the old `agents/worker/` setup" at the bottom of this file.

## Install

On each worker Pi:

```sh
sudo apt update
sudo apt install -y python3-psutil python3-requests

cd ~
# clone if not already (matches the controller's clone path)
git clone git@github.com:GnrGnr/cluster-manager.git
cd cluster-manager/agents/worker-health

cp .env.example .env
# edit .env:
#   INGEST_URL  -> https://<your-domain>/api/metrics-ingest
#   WORKER_SECRET -> the shared secret from the cluster-manager's .env
#   NODE_NAME   -> this Pi's name as registered in the `cluster_pi` table
chmod 600 .env

# sanity check: run once manually
./metrics.py && echo "ok"
```

If the manual run prints nothing and exits 0, the metric was accepted. Open `/home` in a browser — within a minute the chart for that Pi should pick up its first sample.

## Schedule with cron

```sh
crontab -e
```

Add (one line):

```
* * * * * /home/admin/cluster-manager/agents/worker-health/metrics.py >> /home/admin/cluster-manager/agents/worker-health/metrics.log 2>&1
```

The script blocks for 1 second on `psutil.cpu_percent(interval=1)`, so each invocation takes ~1.5s wall time. Once-per-minute cron is plenty.

`metrics.log` will contain stderr from any failures (network timeouts, 404 if the Pi name isn't registered yet, etc.). It's gitignored. Rotate manually if it ever grows large — typical noise is one line per failure, near-zero on a healthy network.

## Environment variables

| Var | Description |
|---|---|
| `INGEST_URL` | Full URL of the cluster-manager metrics endpoint, typically `https://<domain>/api/metrics-ingest`. |
| `WORKER_SECRET` | Shared secret. Must match `WORKER_SECRET` on the cluster-manager. |
| `NODE_NAME` | This Pi's name as it appears in `cluster_pi.name`. Case-insensitive. If the name isn't registered yet, the ingest returns 404 — the script exits 0 (not an alertable error), and the next minute's cron retries. |

## What gets sent

Each cron tick POSTs:

```json
{
  "name": "pi-1",
  "cpu": 17.3,
  "temp": 47.1
}
```

`cpu` is the cores-averaged CPU% over a 1-second sample. `temp` is the CPU temperature in °C from `psutil.sensors_temperatures()['cpu_thermal']` (or `coretemp` / `cpu-thermal` as fallbacks). If no thermal sensor is exposed, the field is omitted.

## Server-side bounded ring

The cluster-manager keeps the last 24 hours of metrics. Every successful ingest also runs:

```sql
DELETE FROM cluster_pi_metric WHERE measured_at < NOW() - INTERVAL 24 HOUR;
```

So data is pruned by *any* worker's submission, regardless of which Pi it came from. If all workers go silent, no pruning happens — the existing rows simply stop ageing out.

## Migrating from the old `agents/worker/` setup

If you previously had `metrics.py` running from `agents/worker/`, the directory has moved to `agents/worker-health/`. After `git pull` on the worker Pi:

```sh
# Edit your existing crontab and update the path
crontab -e
```

Replace the old line:

```
* * * * * /home/admin/cluster-manager/agents/worker/metrics.py >> /home/admin/cluster-manager/agents/worker/metrics.log 2>&1
```

with:

```
* * * * * /home/admin/cluster-manager/agents/worker-health/metrics.py >> /home/admin/cluster-manager/agents/worker-health/metrics.log 2>&1
```

Save and exit. Cron picks up the change on the next minute boundary — no reload needed.

If you had any `.env` or untracked log files in the old `agents/worker/` directory, git will not have moved them (only tracked files follow the rename). Move them manually:

```sh
mv ~/cluster-manager/agents/worker/.env ~/cluster-manager/agents/worker-health/.env 2>/dev/null
mv ~/cluster-manager/agents/worker/metrics.log ~/cluster-manager/agents/worker-health/metrics.log 2>/dev/null
rmdir ~/cluster-manager/agents/worker 2>/dev/null
```
