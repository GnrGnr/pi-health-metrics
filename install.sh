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

# Pre-check: detect corrupt git state from a previous OOM/crash during
# fetch. On 1 GB Pis under memory pressure, `git fetch` can write zero-byte
# object files; subsequent operations look fine but actually run against
# stale code (last successful checkout). Detect and refuse — the recovery
# is to nuke and reclone, which the installer can't safely do for the
# user (.env would be lost without an explicit save).
FSCK_OUT=$(sudo -u "$RUN_USER" git -C "$REPO_ROOT" fsck --no-progress 2>&1 || true)
if printf '%s' "$FSCK_OUT" | grep -qE 'empty|missing|corrupt|broken'; then
	err "git repository is corrupt at $REPO_ROOT:"
	printf '%s\n' "$FSCK_OUT" | head -10 | sed 's/^/    /' >&2
	err "Most likely cause: OOM during git fetch on a 1 GB Pi under load."
	err "Recover by reclone (preserves .env):"
	dim "  sudo cp $REPO_ROOT/.env /tmp/phm-env"
	dim "  cd ~ && rm -rf pi-health-metrics"
	dim "  git clone https://github.com/GnrGnr/pi-health-metrics.git"
	dim "  sudo cp /tmp/phm-env pi-health-metrics/.env"
	dim "  sudo chown $RUN_USER:$RUN_USER pi-health-metrics/.env"
	dim "  sudo chmod 600 pi-health-metrics/.env"
	dim "  rm -f /tmp/phm-env"
	dim "  cd pi-health-metrics && sudo bash install.sh"
	exit 1
fi

# Clean up any zero-byte ORIG_HEAD left by a previous interrupted fetch.
# Harmless (it's just a "what was HEAD before the last reset?" marker)
# but it makes every subsequent git operation print a confusing error.
if [ -f "$REPO_ROOT/.git/ORIG_HEAD" ] && [ ! -s "$REPO_ROOT/.git/ORIG_HEAD" ]; then
	rm -f "$REPO_ROOT/.git/ORIG_HEAD"
	dim "removed empty .git/ORIG_HEAD from a previous interrupted git op"
fi

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

# ─── 2c. enable persistent systemd journal ────────────────────────────────────
# Pi OS Lite defaults to volatile journal (tmpfs only). After a reboot,
# previous-boot logs are gone — which makes post-mortem of any crash
# (OOM kill, kernel hang, SD I/O error, …) basically impossible.
# Pi-health-metrics installs on every Pi in the fleet, so it's the right
# place to flip persistent journal on universally.
#
# Idempotent: if the per-machine subdirectory already exists with
# content, journald is already persistent — skip. Otherwise create
# /var/log/journal with the canonical layout and restart journald,
# which will create the per-machine subdir on first start.
say "→ Enable persistent systemd journal"
MACHINE_ID=$(cat /etc/machine-id 2>/dev/null || true)
if [ -n "$MACHINE_ID" ] && [ -d "/var/log/journal/$MACHINE_ID" ] \
		&& [ -n "$(ls -A "/var/log/journal/$MACHINE_ID" 2>/dev/null)" ]; then
	dim "already persistent — /var/log/journal/$MACHINE_ID exists"
else
	# Pi OS Lite ships a drop-in at /usr/lib/systemd/journald.conf.d/
	# 40-rpi-volatile-storage.conf that forces Storage=volatile to
	# reduce SD card wear. Drop-ins in /usr/lib/ are processed before
	# drop-ins in /etc/, so we override there with the highest-priority
	# numeric prefix (99-) so any future drop-ins still lose to ours.
	#
	# Editing /etc/systemd/journald.conf alone doesn't work — the Pi OS
	# drop-in still wins. Editing the Pi OS drop-in in /usr/lib would
	# get overwritten by package updates. /etc/ drop-ins are the
	# canonical Linux mechanism for local overrides.
	install -d -m 755 /etc/systemd/journald.conf.d
	cat > /etc/systemd/journald.conf.d/99-pi-health-metrics-persistent.conf <<'JOURNALD_CONF'
# Installed by pi-health-metrics/install.sh. Overrides Pi OS Lite's
# default 40-rpi-volatile-storage.conf to give us post-mortem-able
# logs across reboots. ~25 MB on disk; cheap.
[Journal]
Storage=persistent
SystemMaxUse=200M
SystemKeepFree=500M
JOURNALD_CONF

	# Restart journald so it re-reads the merged config. The dir tree
	# under /var/log/journal/ needs to exist with the right perms or
	# journald will silently fall back to volatile; recreate it cleanly.
	systemctl stop systemd-journald 2>/dev/null || true
	rm -rf /var/log/journal
	install -d -o root -g systemd-journal -m 2755 /var/log/journal
	systemctl start systemd-journald
	# Poll for the per-machine subdir up to 10s. journald creates it
	# asynchronously after restart; on a busy Pi 3B+ this can take
	# a few seconds. If it still hasn't shown up after the poll, force
	# the flush from runtime → persistent.
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		[ -n "$MACHINE_ID" ] && [ -d "/var/log/journal/$MACHINE_ID" ] && break
		sleep 1
	done
	if [ -z "$MACHINE_ID" ] || [ ! -d "/var/log/journal/$MACHINE_ID" ]; then
		systemctl kill --signal=SIGUSR1 systemd-journald 2>/dev/null || true
		sleep 2
	fi
	if [ -n "$MACHINE_ID" ] && [ -d "/var/log/journal/$MACHINE_ID" ]; then
		ok "persistent journal enabled at /var/log/journal/$MACHINE_ID"
	else
		warn "persistent journal directory not populated after restart + flush"
		warn "  check: systemd-analyze cat-config systemd/journald.conf"
		warn "  this is non-fatal — pi-health-metrics will still work"
	fi
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

# ─── 3b. diagnostic tools (passive, no daemon) ────────────────────────────────
# smartmontools is installed but smartd is intentionally NOT enabled.
# We want `sudo smartctl -a /dev/mmcblk0` available when a Pi acts up,
# without paying for a background polling daemon. SD cards rarely
# expose meaningful SMART anyway; the real signal lives in dmesg +
# the now-persistent journal. This is a "have it when you need it" tool.
if ! command -v smartctl >/dev/null 2>&1; then
	say "→ Install diagnostic tools"
	apt install -y smartmontools >/dev/null 2>&1
	# Don't enable the smartd daemon — passive use only.
	systemctl disable --now smartd 2>/dev/null || true
	systemctl disable --now smartmontools 2>/dev/null || true
	if command -v smartctl >/dev/null 2>&1; then
		ok "smartmontools installed (smartd not enabled — passive only)"
	else
		warn "smartmontools install failed — non-fatal, continuing"
	fi
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

# Sanity-check that we actually produced a real unit file. If /tmp is
# tmpfs and the system is under memory pressure (chronic on 1 GB Pis),
# the redirect above can succeed with an empty result. Installing an
# empty file to /etc/systemd/system/ effectively masks the unit — the
# timer becomes inert and the user gets no clue why. Refuse early.
if [ ! -s "$TMP_SERVICE" ]; then
	err "generated unit file is empty — refusing to install."
	err "  source: $SERVICE_SRC ($(stat -c%s "$SERVICE_SRC" 2>/dev/null || echo '?') bytes)"
	err "  temp:   $TMP_SERVICE ($(stat -c%s "$TMP_SERVICE" 2>/dev/null || echo '?') bytes)"
	err "  /tmp space:"
	df -h /tmp 2>&1 | sed 's/^/    /' >&2
	exit 1
fi
if [ ! -s "$TIMER_SRC" ]; then
	err "timer source file is empty — refusing to install: $TIMER_SRC"
	exit 1
fi

# If the destination is currently masked (symlink to /dev/null, or a
# zero-byte file left by a previous broken run), unmask it first. The
# install below would otherwise either fail (real mask) or look like a
# success but produce a still-masked-equivalent state.
for dest in "$SERVICE_DEST" "$TIMER_DEST"; do
	if [ -L "$dest" ] && [ "$(readlink "$dest")" = "/dev/null" ]; then
		warn "$dest is masked (symlink to /dev/null) — unmasking"
		rm -f "$dest"
	elif [ -e "$dest" ] && [ ! -s "$dest" ]; then
		warn "$dest is zero-byte (broken previous install) — removing"
		rm -f "$dest"
	fi
done

NEED_RELOAD=0
if cmp -s "$TMP_SERVICE" "$SERVICE_DEST" 2>/dev/null; then
	dim "$SERVICE_DEST unchanged"
else
	install -m 644 "$TMP_SERVICE" "$SERVICE_DEST"
	ok "installed $SERVICE_DEST ($(stat -c%s "$SERVICE_DEST") bytes)"
	NEED_RELOAD=1
fi

if cmp -s "$TIMER_SRC" "$TIMER_DEST" 2>/dev/null; then
	dim "$TIMER_DEST unchanged"
else
	install -m 644 "$TIMER_SRC" "$TIMER_DEST"
	ok "installed $TIMER_DEST ($(stat -c%s "$TIMER_DEST") bytes)"
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

# ─── 7. NODE_NAME sanity check ────────────────────────────────────────────────
# Bites people during fleet rollouts: the .env gets copied from another Pi
# (preserving secrets) but NODE_NAME accidentally stays the source Pi's
# name, so metrics submit under the wrong identity. Dashboard shows
# "Boot error" on the affected Pi (no metric arriving for *that* Pi) and
# the source Pi happily gets double-coverage. Hard to spot without this
# check.
#
# Best-effort: hostname stripped of common prefixes (Worker-, etc.)
# usually matches cluster_pi.name. Where it doesn't (custom hostname,
# unusual naming), we just warn — can't fail-hard since we can't enforce
# the naming convention.
say "→ NODE_NAME sanity check"
EXPECTED_NAME=$(hostname | sed 's/^Worker-//')
HEALTH_NN=$(grep '^NODE_NAME=' "$REPO_ROOT/.env" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"'"'")
WORKER_ENV="$RUN_HOME/pi-cluster-worker/agents/.env"
WORKER_NN=""
if [ -f "$WORKER_ENV" ]; then
	WORKER_NN=$(sudo -u "$RUN_USER" grep '^NODE_NAME=' "$WORKER_ENV" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"'"'")
fi

MISMATCH=0
if [ "$HEALTH_NN" != "$EXPECTED_NAME" ]; then
	warn "pi-health-metrics/.env NODE_NAME='$HEALTH_NN' differs from hostname-derived '$EXPECTED_NAME'"
	MISMATCH=1
fi
if [ -n "$WORKER_NN" ] && [ "$WORKER_NN" != "$EXPECTED_NAME" ]; then
	warn "pi-cluster-worker/agents/.env NODE_NAME='$WORKER_NN' differs from hostname-derived '$EXPECTED_NAME'"
	MISMATCH=1
fi
if [ -n "$WORKER_NN" ] && [ "$HEALTH_NN" != "$WORKER_NN" ]; then
	warn "the two .env files disagree: health='$HEALTH_NN' worker='$WORKER_NN'"
	MISMATCH=1
fi
if [ "$MISMATCH" -eq 1 ]; then
	warn "if this Pi's cluster_pi.name really is '$EXPECTED_NAME', fix with:"
	dim "  sudo sed -i 's/^NODE_NAME=.*/NODE_NAME=$EXPECTED_NAME/' $REPO_ROOT/.env"
	if [ -f "$WORKER_ENV" ]; then
		dim "  sudo sed -i 's/^NODE_NAME=.*/NODE_NAME=$EXPECTED_NAME/' $WORKER_ENV"
		dim "  sudo systemctl restart pi-health-metrics.service cluster-worker.service"
	else
		dim "  sudo systemctl restart pi-health-metrics.service"
	fi
	warn "(this is non-fatal — install completed, metrics will submit under the current NODE_NAME)"
else
	ok "NODE_NAME='$EXPECTED_NAME' matches hostname"
fi

# ─── done ──────────────────────────────────────────────────────────────────────
VERSION=$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo unknown)
say "✓ install complete on $(hostname) — version=$VERSION, commit=$(git rev-parse --short HEAD)"
dim ""
dim "Watch the first metric land:"
dim "  journalctl -u pi-health-metrics.service -f"
dim ""
dim "Next scheduled run:"
dim "  systemctl list-timers pi-health-metrics.timer"
