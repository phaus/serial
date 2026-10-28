#!/bin/sh
# Forwards one serial stream to Loki's HTTP push API.
#
# usage: loki-forwarder.sh <stream-dir> <device-path>
#
# Design: a spooler appends lines from the FIFO to a spool file; a flusher
# pushes batches of LOKI_BATCH_LINES lines, or whatever accumulated after
# LOKI_BATCH_INTERVAL seconds, whichever comes first. Failed pushes are
# requeued, so short Loki outages don't lose data.
#
# Labels: LOKI_EXTERNAL_LABELS is "key=value,key=value" (same format as the
# Docker Loki log driver). "{{.Name}}" is replaced with the container name.
# A "serial_port" label with the device path is always added.
set -u

D=$1
DEV=$2
URL=${LOKI_URL:?LOKI_URL not set}
SPOOL=$D/loki.spool
TMP=$D/loki.push
BATCH=${LOKI_BATCH_LINES:-100}
INTERVAL=${LOKI_BATCH_INTERVAL:-2}

log() { echo "[loki-forwarder $DEV] $*" >&2; }

esc_json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

cname=${CONTAINER_NAME:-${BALENA_SERVICE_NAME:-$(hostname)}}

labels="{\"serial_port\":\"$(esc_json "$DEV")\""
if [ -n "${LOKI_EXTERNAL_LABELS:-}" ]; then
  rest=$(printf '%s' "$LOKI_EXTERNAL_LABELS" | tr ',' '\n' | while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    case $kv in *=*) ;; *) continue ;; esac
    k=${kv%%=*}
    v=${kv#*=}
    case $v in '{{.Name}}') v=$cname ;; esac
    printf ',"%s":"%s"' "$(esc_json "$k")" "$(esc_json "$v")"
  done)
  labels="$labels$rest"
fi
labels="$labels}"

# Spooler: FIFO -> spool file. CR is normalised to LF so lines terminated
# with \r or \r\n both flush; empty lines are dropped.
(
  tr '\r' '\n' < "$D/loki" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" >> "$SPOOL"
  done
) &

# Flusher.
last=$(date +%s)
while :; do
  [ -d "$D" ] || exit 0 # stream dir removed (adapter unplugged)
  sleep 1
  n=$(wc -l < "$SPOOL" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ "$n" -ge "$BATCH" ] || { [ "$n" -gt 0 ] && [ $((now - last)) -ge "$INTERVAL" ]; }; then
    mv "$SPOOL" "$TMP"
    touch "$SPOOL"
    if awk -v labels="$labels" -v ts="$(date +%s%N)" '
        BEGIN { printf "{\"streams\":[{\"stream\":%s,\"values\":[", labels }
        { gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "%s[\"%s\",\"%s\"]", (NR > 1 ? "," : ""), ts, $0 }
        END { print "]}]" }' "$TMP" > "$TMP.json" &&
      curl -sf --max-time 10 -X POST "$URL" -H 'Content-Type: application/json' --data-binary @"$TMP.json" >/dev/null; then
      rm -f "$TMP" "$TMP.json"
    else
      log "push failed; requeueing $n lines"
      cat "$TMP" >> "$SPOOL"
      rm -f "$TMP.json"
    fi
    last=$now
  fi
done
