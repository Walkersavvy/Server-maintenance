#!/usr/bin/env bash
#
# server-maintenance.sh
#
# Routine server maintenance automation:
#   - System package updates (security or full)
#   - Disk cleanup (apt cache, old kernels, tmp files)
#   - Log rotation trigger + old log pruning
#   - Disk space / memory threshold checks with alerting
#   - Failed systemd service check
#   - Optional backup of specified directories
#
# Usage:
#   sudo ./server-maintenance.sh [--dry-run] [--security-only] [--no-backup]
#
# Schedule via cron, e.g.:
#   0 3 * * * /path/to/server-maintenance.sh >> /var/log/server-maintenance.log 2>&1

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these for your environment
# ---------------------------------------------------------------------------
LOG_FILE="/var/log/server-maintenance.log"
BACKUP_SRC_DIRS=("/etc" "/home")          # dirs to back up
BACKUP_DEST_DIR="/var/backups/server-maintenance"
BACKUP_RETENTION_DAYS=14
DISK_WARN_THRESHOLD=85                    # percent used
MEM_WARN_THRESHOLD=90                     # percent used
OLD_LOG_DAYS=30                           # delete logs older than this in /var/log
ALERT_EMAIL="zebulon4g@gmail.com"                            # set to enable mail alerts (requires mailutils/ssmtp)

DRY_RUN=false
SECURITY_ONLY=false
DO_BACKUP=true

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --security-only) SECURITY_ONLY=true ;;
    --no-backup) DO_BACKUP=false ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--security-only] [--no-backup]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

run() {
  # Runs a command unless in dry-run mode
  if $DRY_RUN; then
    log "[DRY-RUN] $*"
  else
    log "RUN: $*"
    eval "$@" >> "$LOG_FILE" 2>&1
  fi
}

alert() {
  local subject="$1"
  local body="$2"
  log "ALERT: $subject — $body"
  if [[ -n "$ALERT_EMAIL" ]]; then
    echo "$body" | mail -s "$subject" "$ALERT_EMAIL" 2>/dev/null || \
      log "WARN: failed to send alert email (mail command not available/configured)"
  fi
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Tasks
# ---------------------------------------------------------------------------

task_update_packages() {
  log "=== Package update check ==="
  run "apt-get update -qq"

  if $SECURITY_ONLY; then
    if command -v unattended-upgrade >/dev/null 2>&1; then
      run "unattended-upgrade -d"
    else
      log "WARN: unattended-upgrades not installed; skipping security-only update. Install with: apt-get install unattended-upgrades"
    fi
  else
    run "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq"
  fi
}

task_cleanup_disk() {
  log "=== Disk cleanup ==="
  run "apt-get autoremove -y -qq"
  run "apt-get autoclean -y -qq"
  run "find /tmp -type f -atime +7 -delete"
  run "find /var/log -type f -name '*.gz' -mtime +${OLD_LOG_DAYS} -delete"
  run "find /var/log -type f -name '*.log.*' -mtime +${OLD_LOG_DAYS} -delete"
}

task_log_rotation() {
  log "=== Log rotation ==="
  if command -v logrotate >/dev/null 2>&1; then
    run "logrotate -f /etc/logrotate.conf"
  else
    log "WARN: logrotate not installed; skipping"
  fi
}

task_check_disk_space() {
  log "=== Disk space check ==="
  # Mounts to skip: WSL's own driver mount and the host Windows drive(s) it
  # exposes under /mnt/*, since their usage reflects the Windows host, not
  # this Linux environment. On a real (non-WSL) server this exclusion is a
  # no-op since those mounts won't exist.
  df -P -x tmpfs -x devtmpfs | tail -n +2 | while read -r fs blocks used avail pcent mnt; do
    case "$mnt" in
      /usr/lib/wsl/drivers*|/mnt/c|/mnt/[a-z]) continue ;;
    esac
    pct="${pcent%\%}"
    if [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= DISK_WARN_THRESHOLD )); then
      alert "Disk space warning on $(hostname)" "Mount $mnt is at ${pct}% (threshold ${DISK_WARN_THRESHOLD}%)"
    fi
  done
}

task_check_memory() {
  log "=== Memory check ==="
  local mem_pct
  mem_pct=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}')
  log "Memory usage: ${mem_pct}%"
  if (( mem_pct >= MEM_WARN_THRESHOLD )); then
    alert "Memory warning on $(hostname)" "Memory usage is at ${mem_pct}% (threshold ${MEM_WARN_THRESHOLD}%)"
  fi
}

task_check_services() {
  log "=== Failed systemd services check ==="
  if command -v systemctl >/dev/null 2>&1; then
    local failed
    failed=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}')
    if [[ -n "$failed" ]]; then
      alert "Failed services on $(hostname)" "Failed units: $failed"
    else
      log "No failed services."
    fi
  else
    log "WARN: systemctl not available; skipping service check (expected under WSL)"
  fi
}

task_backup() {
  if ! $DO_BACKUP; then
    log "=== Backup skipped (--no-backup) ==="
    return
  fi
  log "=== Backup ==="
  local ts
  ts=$(date '+%Y%m%d-%H%M%S')
  local dest="${BACKUP_DEST_DIR}/backup-${ts}.tar.gz"

  run "mkdir -p ${BACKUP_DEST_DIR}"
  run "tar -czf ${dest} ${BACKUP_SRC_DIRS[*]} 2>/dev/null"
  run "find ${BACKUP_DEST_DIR} -type f -name 'backup-*.tar.gz' -mtime +${BACKUP_RETENTION_DAYS} -delete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  require_root
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  log "########## Maintenance run started (dry_run=$DRY_RUN, security_only=$SECURITY_ONLY) ##########"

  task_update_packages
  task_cleanup_disk
  task_log_rotation
  task_check_disk_space
  task_check_memory
  task_check_services
  task_backup

  log "########## Maintenance run finished ##########"
}

main