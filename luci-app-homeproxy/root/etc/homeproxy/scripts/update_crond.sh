#!/bin/sh

SCRIPTS_DIR="/etc/homeproxy/scripts"
RUN_DIR="/var/run/homeproxy"
mkdir -p "$RUN_DIR"
exec 200>"$RUN_DIR/update_crond.lock"
flock -n 200 || exit 0

"$SCRIPTS_DIR"/update_subscriptions.uc
