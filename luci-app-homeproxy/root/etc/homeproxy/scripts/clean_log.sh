#!/bin/sh

NAME="homeproxy"

log_max_size="50"
main_log_file="/var/run/$NAME/$NAME.log"
singc_log_file="/var/run/$NAME/sing-box-c.log"
sings_log_file="/var/run/$NAME/sing-box-s.log"

while true; do
	sleep 180
	for i in "$main_log_file" "$singc_log_file" "$sings_log_file"; do
		[ -s "$i" ] || continue
		size="$(stat -c %s "$i" 2>"/dev/null")" || continue
		[ -n "$size" ] || continue
		[ "$((size / 1024))" -ge "$log_max_size" ] && : > "$i"
	done
done
