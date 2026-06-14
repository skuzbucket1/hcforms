#!/usr/bin/env bash
# hcforms uninstaller. Stops the stack; preserves data unless --purge is given.
#
#   sudo ./uninstall.sh           # stop + remove containers, keep PHI/data
#   sudo ./uninstall.sh --purge   # also delete /opt/hcforms and /var/hcforms
set -euo pipefail

APP_DIR=/opt/hcforms
DATA_DIR=/var/hcforms
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

[ "$(id -u)" -eq 0 ] || { echo "Please run as root (sudo)." >&2; exit 1; }

if [ -f "$APP_DIR/docker-compose.yml" ]; then
  ( cd "$APP_DIR" \
    && docker compose --profile customer --profile control-plane --profile letsencrypt \
         down --remove-orphans $( [ "$PURGE" -eq 1 ] && echo -v ) ) || true
fi

systemctl disable --now hcforms.service 2>/dev/null || true
rm -f /etc/systemd/system/hcforms.service
systemctl daemon-reload 2>/dev/null || true

if [ "$PURGE" -eq 1 ]; then
  rm -rf "$APP_DIR" "$DATA_DIR"
  echo "Purged $APP_DIR and $DATA_DIR — all data and PHI removed."
else
  echo "Stopped hcforms. Data preserved in $DATA_DIR."
  echo "Re-run install.sh to start again, or ./uninstall.sh --purge to wipe everything."
fi
