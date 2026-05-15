#!/bin/sh
# Pi-side installer for pi-health-metrics.
#
# Pi-health-metrics submits this Pi's CPU% + temperature to cluster-frontend
# once per minute. It's a single Python script driven by a systemd timer.
#
# This installer:
#   1. Force-syncs the working tree to origin/master.
#   2. Removes any predecessor health-metrics daemons:
#        - the legacy crontab line that pointed at
#          ~/cluster-manager/agents/worker-health/metrics.py
#        - scanner's worker-health.service + worker-health.timer (the
#          scanner project used to ship its own copy of this submitter)
#   3. Verifies python3-psutil + python3-requests are installed.
#   4. Substitutes the actual user + repo path into the systemd .service
#      file (because the canonical file ships with /home/admin/ baked in
#      and not every Pi runs as admin).
#   5. Installs pi-health-metrics.service + pi-health-metrics.timer into
#      /etc/systemd/system/, enables + starts the timer.
#   6. Prints a one-line status.
#
# Idempotent: safe to re-run after `git pull`.
#
# Usage:
#   cd ~/pi-health-metrics
#   sudo bash install.sh                  # interactive
#   sudo bash install.sh --yes            # no prompts
#
# Requirements: git, python3, systemd, sudo.

set -eu

# ─── arg parsing ───────────────────────────────────────────────────────────────
ASSUME_YES=0
for arg in "$@"; do
	case "$arg" in
		--yes|-y) ASSUME_YES=1 ;;
		--help|-h)
			grep '^#' "$0" | sed -e 's/^# \{0,1\}//' -e 's/^!.*//'
			exit 0
			;;
		*)
			echo "unknown argument: $arg" >&2
			exit 2
			;;
	esac
done

# ─── pretty logging ────────────────────────────────────────────────────────────
GREEN=""; YELLOW=""; RED=""; DIM=""; BOLD=""; RESET=""
if [ -t 1 ]; then
	GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); RED=$(printf '\033[31m')
	DIM=$(printf '\033[2m'); BOLD=$(printf '\033[1m'); RESET=$(printf '\033[0m')
fi
say() { printf '%s%s%s\n' "$BOLD" "$*" "$RESET"; }
ok()  { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn(){ printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
err() { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*" >&2; }
dim() { printf '  %s%s%s\n' "$DIM" "$*" "$RESET"; }
confirm() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	printf '  %s?%s %s [y/N] ' "$YELLOW" "$RESET" "$1"
	read -r answer
	case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ─── locate repo root ──────────────────────────────────────────────────────────
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT="$SCRIPT_DIR"
cd "$REPO_ROOT"

if [ ! -d .git ]; then
	err "Not inside a git repo: $REPO_ROOT"
	exit 1
fi

say "→ Installer running from $REPO_ROOT"

# Resolve the invoking user.
RUN_USER="${SUDO_USER:-$USER}"
RUN_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6 || true)
[ -n "$RUN_HOME" ] || RUN_HOME=$(eval echo "~$RUN_USER")
ok "user=$RUN_USER home=$RUN_HOME"

# ─── 1. force-sync working tree ────────────────────────────────────────────────
say "→ Sync working tree"
sudo -u "$RUN_USER" git fetch --quiet origin
DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || echo master)
sudo -u "$RUN_USER" git reset --hard "origin/$DEFAULT_BRANCH"
ok "synced to origin/$DEFAULT_BRANCH @ $(git rev-parse --short HEAD)"

# ─── 2. cleanup of predecessor health-metrics daemons ─────────────────────────
say "→ Clean up predecessor health-metrics daemons"

# 2a. Legacy crontab line that ran ~/cluster-manager/agents/worker-health/metrics.py.
STALE_CRON_LINES=$(crontab -u "$RUN_USER" -l 2>/dev/null \
	| awk '/cluster-manager\/agents\/worker-health/ { print }' || true)
if [ -n "$STALE_CRON_LINES" ]; then
	warn "Found legacy cron lines:"
	printf '%s\n' "$STALE_CRON_LINES" | sed 's/^/    /'
	if confirm "Remove these (this daemon replaces them)?"; then
		crontab -u "$RUN_USER" -l 2>/dev/null \
			| awk '!/cluster-manager\/agents\/worker-health/ { print }' \
			| crontab -u "$RUN_USER" -
		ok "removed"
	else
		dim "skipped"
	fi
else
	dim "no legacy cron lines"
fi

# 2b. Scanner's worker-health.service + .timer (an older copy of this
# submitter, shipped with the scanner repo before this code was split out).
LEGACY_SCANNER_UNITS=""
for u in worker-health.service worker-health.timer; do
	[ -f "/etc/systemd/system/$u" ] && LEGACY_SCANNER_UNITS="$LEGACY_SCANNER_UNITS $u"
done
if [ -n "$LEGACY_SCANNER_UNITS" ]; then
	warn "Found legacy scanner units:$LEGACY_SCANNER_UNITS"
	if confirm "Disable + remove these (pi-health-metrics replaces them)?"; then
		for u in $LEGACY_SCANNER_UNITS; do
			systemctl disable --now "$u" 2>/dev/null || true
			rm -f "/etc/systemd/system/$u"
			ok "removed $u"
		done
	else
		dim "skipped — pi-health-metrics will install alongside (both will fire!)"
	fi
else
	dim "no legacy scanner units"
fi

# ─── 3. python deps ────────────────────────────────────────────────────────────
say "→ Verify Python deps"
if ! sudo -u "$RUN_USER" python3 -c "import psutil, requests" 2>/dev/null; then
	warn "missing python3-psutil and/or python3-requests"
	if confirm "Install via apt?"; then
		apt update >/dev/null
		apt install -y python3-psutil python3-requests
		ok "installed"
	else
		err "skipped — the timer will fail until these are installed"
		exit 1
	fi
else
	ok "python3-psutil + python3-requests present"
fi

# ─── 4. substitute path + user into .service ──────────────────────────────────
say "→ Prepare systemd unit"
SERVICE_SRC="$REPO_ROOT/pi-health-metrics.service"
SERVICE_DEST="/etc/systemd/system/pi-health-metrics.service"
TIMER_SRC="$REPO_ROOT/pi-health-metrics.timer"
TIMER_DEST="/etc/systemd/system/pi-health-metrics.timer"

# The .service file ships with /home/admin/ baked in. Substitute the
# actual user + repo path so it works regardless of how the Pi is set up.
TMP_SERVICE=$(mktemp)
trap 'rm -f "$TMP_SERVICE"' EXIT
sed \
	-e "s|^User=.*$|User=$RUN_USER|" \
	-e "s|^WorkingDirectory=.*$|WorkingDirectory=$REPO_ROOT|" \
	-e "s|^ExecStart=.*$|ExecStart=/usr/bin/python3 $REPO_ROOT/metrics.py|" \
	"$SERVICE_SRC" > "$TMP_SERVICE"

NEED_RELOAD=0
if cmp -s "$TMP_SERVICE" "$SERVICE_DEST" 2>/dev/null; then
	dim "$SERVICE_DEST unchanged"
else
	install -m 644 "$TMP_SERVICE" "$SERVICE_DEST"
	ok "installed $SERVICE_DEST"
	NEED_RELOAD=1
fi

if cmp -s "$TIMER_SRC" "$TIMER_DEST" 2>/dev/null; then
	dim "$TIMER_DEST unchanged"
else
	install -m 644 "$TIMER_SRC" "$TIMER_DEST"
	ok "installed $TIMER_DEST"
	NEED_RELOAD=1
fi

if [ "$NEED_RELOAD" -eq 1 ]; then
	systemctl daemon-reload
	ok "systemd daemon-reload"
fi

# ─── 5. .env check ────────────────────────────────────────────────────────────
say "→ Check .env"
if [ ! -f "$REPO_ROOT/.env" ]; then
	warn "$REPO_ROOT/.env not found"
	if [ -f "$REPO_ROOT/.env.example" ]; then
		cp "$REPO_ROOT/.env.example" "$REPO_ROOT/.env"
		chown "$RUN_USER:$RUN_USER" "$REPO_ROOT/.env"
		chmod 600 "$REPO_ROOT/.env"
		warn "seeded .env from .env.example — EDIT IT before the first run:"
		dim "  - NODE_NAME (this Pi's cluster_pi.name)"
		dim "  - INGEST_URL (https://<your-domain>/api/metrics-ingest)"
		dim "  - WORKER_SECRET (must match cluster-frontend's root .env)"
		err "exiting — re-run after editing .env"
		exit 1
	else
		err "no .env.example to seed from — set up .env manually then re-run"
		exit 1
	fi
else
	ok ".env present"
fi

# ─── 6. enable + start timer ───────────────────────────────────────────────────
say "→ Enable + start timer"
systemctl enable pi-health-metrics.timer >/dev/null 2>&1 || true
systemctl restart pi-health-metrics.timer
sleep 1
state=$(systemctl is-active pi-health-metrics.timer 2>/dev/null || true)
case "$state" in
	active) ok "pi-health-metrics.timer: $state" ;;
	*) warn "pi-health-metrics.timer: $state" ;;
esac

# Trigger one immediate run so the dashboard updates without waiting up
# to a minute for the next scheduled tick.
systemctl start pi-health-metrics.service || true

# ─── done ──────────────────────────────────────────────────────────────────────
VERSION=$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo unknown)
say "✓ install complete on $(hostname) — version=$VERSION, commit=$(git rev-parse --short HEAD)"
dim ""
dim "Watch the first metric land:"
dim "  journalctl -u pi-health-metrics.service -f"
dim ""
dim "Next scheduled run:"
dim "  systemctl list-timers pi-health-metrics.timer"
