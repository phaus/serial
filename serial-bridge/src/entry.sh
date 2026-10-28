#!/bin/sh
# serial-bridge entrypoint.
#
# Fan-out for one or two USB serial adapters:
#   device -> cat -> tee -> [ HDMI (fb0 via fbtext), tmux session (SSH), Loki forwarder ]
#
# A small supervisor loop rescans for devices every SCAN_INTERVAL seconds, so
# adapters can be hot-plugged and unplugged without restarting the container.
set -u

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN="${SERIAL_RUNTIME_DIR:-/run/serial-bridge}"
HDMI_TTY="${HDMI_TTY:-/dev/tty1}"
HDMI_FONT="${HDMI_FONT:-/usr/share/fbtext-default.psf}"
BAUD="${SERIAL_BAUDRATE:-115200}"
SCAN_INTERVAL="${SCAN_INTERVAL:-10}"
mkdir -p "$RUN"

log() { echo "[serial-bridge] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

container_name() {
  echo "${CONTAINER_NAME:-${BALENA_SERVICE_NAME:-$(hostname)}}"
}

# ---------------------------------------------------------------------------
# SSH (dropbear). Host keys are generated on first connect via -R.
# Access: ssh -p $SSH_PORT root@<device-ip>
# ---------------------------------------------------------------------------
start_ssh() {
  [ "${SSH_ENABLE:-true}" = "true" ] || return 0
  mkdir -p /etc/dropbear /root/.ssh
  chmod 700 /root/.ssh
  if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    printf '%s\n' "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
  fi
  if [ -n "${SSH_PASSWORD:-}" ]; then
    echo "root:${SSH_PASSWORD}" | chpasswd
  fi
  if [ ! -f /etc/dropbear/dropbear_rsa_host_key ] && command -v dropbearkey >/dev/null 2>&1; then
    dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key >/dev/null
  fi
  if [ ! -n "${SSH_PUBLIC_KEY:-}" ] && [ ! -n "${SSH_PASSWORD:-}" ]; then
    log "WARNING: no SSH_PUBLIC_KEY and no SSH_PASSWORD set; logins will be impossible"
  fi
  # -j/-k: disable port forwarding; -R: generate host keys on demand.
  dropbear -R -j -k -p "0.0.0.0:${SSH_PORT:-2222}"
  cat > /etc/motd <<'EOF'

Serial stream console
  tmux ls                     list active streams
  tmux attach -t ttyUSB0      follow /dev/ttyUSB0   (detach: Ctrl-b d)
  tmux attach -t ttyUSB1      follow /dev/ttyUSB1
EOF
  log "SSH ready on port ${SSH_PORT:-2222}"
}

# ---------------------------------------------------------------------------
# Sinks. Every sink runs in a reopen loop: if it dies or its FIFO has no
# reader, the producer's tee() gets SIGPIPE / blocks, the reader loop restarts
# and everything re-connects. This is what keeps the pipeline self-healing.
# ---------------------------------------------------------------------------
drain() { # discard a FIFO's contents (sink disabled); exits when the stream dir is removed
  d=$1
  f=$2
  while [ -d "$d" ]; do
    if [ -p "$d/$f" ]; then
      cat < "$d/$f" > /dev/null
    else
      sleep 1
    fi
  done
}

sanitize() { # strip non-printable bytes (for the raw tty fallback path)
  if [ "${HDMI_SANITIZE:-true}" = "true" ]; then
    tr -cd '\011\012\015\040-\176'
  else
    cat
  fi
}

# Global HDMI sink: fbtext renders the merged stream of all adapters directly
# on /dev/fb0. balenaOS boots with console=null and its VT layer does not
# render post-boot writes, so /dev/tty1 is only used as a last-resort fallback.
hdmi_sink_all() {
  while :; do
    if [ -x "$APP_DIR/fbtext" ] && [ -r "$HDMI_FONT" ] && [ -c /dev/fb0 ]; then
      "$APP_DIR/fbtext" --fb /dev/fb0 --font "$HDMI_FONT" < "$RUN/hdmi-all"
    elif [ -c "$HDMI_TTY" ] && [ -w "$HDMI_TTY" ]; then
      sanitize < "$RUN/hdmi-all" > "$HDMI_TTY"
    else
      cat < "$RUN/hdmi-all" > /dev/null
    fi
    sleep 2
  done
}

# ---------------------------------------------------------------------------
# One stream per device. Per-device FIFOs: $d/loki, $d/ssh. All devices share
# $RUN/hdmi-all for the HDMI sink (exactly ONE reader per FIFO, ever).
# ---------------------------------------------------------------------------
start_stream() {
  port=$1
  name=$(basename "$port")
  d="$RUN/$name"
  [ -f "$d/active" ] && return 0
  mkdir -p "$d"
  touch "$d/active"
  rm -f "$d/loki" "$d/ssh"
  mkfifo "$d/loki" "$d/ssh"

  # Loki sink
  : > "$d/helpers"
  if [ -n "${LOKI_URL:-}" ]; then
    "$APP_DIR/loki-forwarder.sh" "$d" "$port" &
  else
    drain "$d" loki &
  fi
  echo $! >> "$d/helpers"

  printf 'set -g history-limit 10000\nset -g remain-on-exit on\n' > /root/.tmux.conf
  tmux kill-session -t "$name" 2>/dev/null || true
  tmux new-session -d -s "$name" "cat $d/ssh" 2>/dev/null || true
  (
    while [ -d "$d" ]; do
      tmux has-session -t "$name" 2>/dev/null ||
        tmux new-session -d -s "$name" "cat $d/ssh"
      sleep 5
    done
  ) &
  echo $! >> "$d/helpers"

  (
    while [ -f "$d/active" ]; do
      if [ -c "$port" ]; then
        stty -F "$port" "$BAUD" raw -echo 2>/dev/null ||
          log "stty failed for $port (continuing with device defaults)"
        cat "$port" 2>/dev/null | tee "$d/loki" "$d/ssh" "$RUN/hdmi-all" > /dev/null
        log "reader for $port exited; retrying in 5s"
      fi
      sleep 5
    done
  ) &
  echo $! > "$d/pid"
  log "stream started: $port -> hdmi/ssh(tmux:$name)${LOKI_URL:+/loki}"
}

stop_stream() {
  port=$1
  name=$(basename "$port")
  d="$RUN/$name"
  log "stopping stream $port"
  for pidfile in "$d/pid" "$d/helpers"; do
    if [ -f "$pidfile" ]; then
      while read -r p; do
        kill "$p" 2>/dev/null || true
      done < "$pidfile"
    fi
  done
  tmux kill-session -t "$name" 2>/dev/null || true
  rm -rf "$d"
}

list_ports() {
  case "${SERIAL_PORTS:-auto}" in
    auto) ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true ;;
    *) printf '%s\n' "$SERIAL_PORTS" | tr ',' '\n' | sed 's/[[:space:]]//g' ;;
  esac
}

# ---------------------------------------------------------------------------
# Supervisor loop: hotplug handling.
# ---------------------------------------------------------------------------
log "serial-bridge starting (ports=${SERIAL_PORTS:-auto} baud=$BAUD)"
start_ssh

rm -f "$RUN/hdmi-all"
mkfifo "$RUN/hdmi-all"
if [ "${HDMI_ENABLE:-true}" = "true" ]; then
  hdmi_sink_all &
else
  drain "$RUN/hdmi-all" &
fi

while :; do
  for port in $(list_ports); do
    [ -c "$port" ] || continue
    start_stream "$port"
  done
  for d in "$RUN"/*; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    case $name in ttyUSB* | ttyACM*) ;; *) continue ;; esac
    [ -c "/dev/$name" ] || stop_stream "/dev/$name"
  done
  sleep "$SCAN_INTERVAL"
done
