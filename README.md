# serial-bridge — balenaOS on Raspberry Pi 1

Balena deployment that turns a Raspberry Pi 1 into a serial stream terminal:

- **HDMI**: streams from one or two USB serial adapters are mirrored to the HDMI console.
- **SSH**: attach to any stream from an SSH session (tmux per port).
- **Loki**: forward streams to a Loki endpoint (e.g. Grafana Loki) with configurable external labels.

One or two adapters (`/dev/ttyUSB*`, `/dev/ttyACM*`) are supported. Adapters can be hot-plugged; the container rescans every 10 seconds.

## Architecture

```
                         ┌─────────────────── container: serial-bridge (privileged) ───────────────────────┐
 /dev/ttyUSB0 ──▶ stty ─▶ cat ─▶ tee ──┬─▶ hdmi-all ─▶ fbtext ─▶ /dev/fb0   HDMI, sanitised text        │
 /dev/ttyUSB1 ──▶ stty ─▶ cat ─▶ tee ──┼─▶ tmux session ─▶ ssh -p 2222 root@<device-ip>                  │
   (raw, 8N1)                          └─▶ loki-forwarder ─▶ LOKI_URL (batched push + retry)            │
                         └──────────────────────────────────────────────────────────────────────────────────┘
```

Each device gets a `tee` fan-out over named FIFOs in `/run/serial-bridge/<dev>/`. All devices share one `hdmi-all` FIFO feeding the HDMI renderer — a FIFO with multiple readers would split the stream, so every FIFO has exactly one reader. Every sink runs in a reopen loop, so a crashed consumer, a detached terminal or an unplugged adapter only stalls its own branch — the supervisor restarts it. A single privileged container is deliberate: the Pi 1 (ARMv6, 512 MB) has no RAM to spare for a multi-container stack.

**Why `fbtext`?** balenaOS boots with `console=null` and its VT layer does not render post-boot writes — text written to `/dev/tty1` silently goes nowhere (verified on balenaOS 9.0.3/rpi). The container therefore ships `src/fbtext.c`, a ~200-line PSF-font text renderer that mmaps `/dev/fb0` and draws the stream like a dumb terminal (scroll on newline, ANSI escapes stripped). It is compiled at image build time from the distro `gcc` — no prebuilt binaries.

## The setup in pictures

Hardware (Raspberry Pi 1 as console bridge, USB serial adapters):

![serial-bridge hardware](images/serial-bridge-hardware.jpeg)

Serial console of the attached device, as shown in the repo documentation:

![serial console](images/serial-bridge-console.jpeg)

## Repository layout

| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | balena service definition + default environment |
| `serial-bridge/Dockerfile` | `balenalib/raspberry-pi-debian:bookworm` (ARMv6), only distro packages: `tmux`, `dropbear`, `curl` |
| `serial-bridge/src/entry.sh` | Supervisor: SSH, per-device tee fan-out, HDMI sink, hotplug rescan |
| `serial-bridge/src/loki-forwarder.sh` | FIFO → spool → batched Loki push with retry |

## Requirements

- Raspberry Pi 1 (A/B/B+), Pi Zero also works — device type `raspberrypi`
- balenaOS 2.x flashed for that device type
- 1–2 USB serial adapters (cp210x, ftdi, pl2303, ch341 — all in the kernel)
- balena CLI (`npm i -g balena-cli`)

## Quickstart

```sh
balena login
balena fleet create serial-bridge --type raspberrypi   # once

# configure (fleet-wide, survives reboots/redeploys) — placeholders, see env.example
balena env set LOKI_URL "http://loki.example.com:3100/loki/api/v1/push" -f serial-bridge
balena env set LOKI_EXTERNAL_LABELS "host=my-node,location=homelab,application=serial,container_name={{.Name}}" -f serial-bridge
balena env set SSH_PASSWORD "s3cret" -f serial-bridge

balena push serial-bridge   # builds ARMv6 in the balena cloud, then deploys
```

The Pi 1 never builds anything itself — `balena push` compiles in balena's builders.

## Configuration

Set via balena dashboard (Fleet → Configuration → Variables) or `balena env set`.

For local runs and tooling, copy `env.example` to `env.local` and fill in your real values — `env.local` is git-ignored and never committed. This repository contains placeholders only.

| Variable | Default | Description |
| --- | --- | --- |
| `SERIAL_PORTS` | `auto` | `auto` scans for `ttyUSB*`/`ttyACM*`; or explicit: `/dev/ttyUSB0,/dev/ttyUSB1` |
| `SERIAL_BAUDRATE` | `115200` | Line settings applied via `stty` (raw, 8N1) |
| `SCAN_INTERVAL` | `10` | Hotplug rescan interval in seconds |
| `HDMI_ENABLE` | `true` | Mirror streams to the HDMI framebuffer |
| `HDMI_TTY` | `/dev/tty1` | Fallback TTY if `/dev/fb0` is unavailable (rarely useful on balenaOS) |
| `HDMI_FONT` | `/usr/share/fbtext-default.psf` | PSF font for the fbtext renderer |
| `HDMI_SANITIZE` | `true` | Strip non-printable bytes on the `$HDMI_TTY` fallback path (fbtext strips ANSI + control bytes itself) |
| `SSH_ENABLE` | `true` | Start dropbear inside the container |
| `SSH_PORT` | `2222` | SSH listen port (host network) |
| `SSH_PASSWORD` | – | Root password; empty = pubkey only |
| `SSH_PUBLIC_KEY` | – | OpenSSH public key added to `/root/.ssh/authorized_keys` |
| `LOKI_URL` | – | Loki push endpoint; **empty disables forwarding** |
| `LOKI_EXTERNAL_LABELS` | – | `key=value,key=value` pairs, promtail/docker-driver style |
| `LOKI_BATCH_LINES` | `100` | Flush after this many lines |
| `LOKI_BATCH_INTERVAL` | `2` | Flush partial batches after this many seconds |
| `CONTAINER_NAME` | auto | Override for the `{{.Name}}` label template |

## Watching the streams

### HDMI

The merged stream of all adapters is rendered directly on the framebuffer (`/dev/fb0`) by the bundled `fbtext` tool: black screen, white 8×16 text, scroll on newline, ANSI escapes stripped. The balena logo is overwritten on first line. Two adapters appear interleaved on HDMI; use SSH/tmux for per-stream views.

Fallback chain: `fbtext` on `/dev/fb0` → sanitised text on `$HDMI_TTY` (in case a custom OS image has a working console) → `/dev/null`.

### SSH

```sh
# from your LAN
ssh -p 2222 root@<device-ip>
# or through the balena VPN (works even behind NAT)
balena ssh <device-uuid> serial-bridge
```

Inside:

```
tmux ls                      # active streams
tmux attach -t ttyUSB0       # follow /dev/ttyUSB0
Ctrl-b d                     # detach
```

Each stream is a tmux session with 10,000 lines of scrollback (`Ctrl-b [` to browse). balenaOS's own SSH on port 22222 / `balena ssh <uuid>` (no service name) still reaches the host.

## Loki forwarding

Example configuration — the same `loki-external-labels` format the Docker Loki driver uses:

```
loki-url: "http://loki.example.com:3100/loki/api/v1/push"
loki-external-labels: "host=my-node,location=homelab,application=serial,container_name={{.Name}}"
```

As balena env vars:

```sh
balena env set LOKI_URL "http://loki.example.com:3100/loki/api/v1/push" -f serial-bridge
balena env set LOKI_EXTERNAL_LABELS "host=my-node,location=homelab,application=serial,container_name={{.Name}}" -f serial-bridge
```

Label handling:

- `{{.Name}}` is replaced with the container name (service name `serial-bridge`, or `CONTAINER_NAME` if set).
- A `serial_port` label (`/dev/ttyUSB0`, …) is added automatically so two adapters stay distinguishable.
- Lines are pushed in batches (`LOKI_BATCH_LINES` / `LOKI_BATCH_INTERVAL`). Failed pushes are requeued, so short Loki outages lose nothing.
- Timestamps are assigned at push time, not at capture time (a deliberate trade-off — per-line timestamps would need one `date` fork per line, too heavy for a 700 MHz ARMv6 core).

Resulting payload per batch:

```json
{"streams":[{"stream":{"serial_port":"/dev/ttyUSB0","host":"my-node","location":"homelab","application":"serial","container_name":"serial-bridge"},"values":[["1730000000000000000","some serial line"]]}]}
```

In Grafana, query e.g. `{serial_port="/dev/ttyUSB0"}`.

## Local development

```sh
# cross-build check (needs docker buildx + qemu binfmt)
docker buildx build --platform linux/arm/v6 -t serial-bridge:armv6 serial-bridge

# lint
shellcheck serial-bridge/src/*.sh

# run outside balena (no display → fbtext exits, HDMI sink reopens in a loop)
docker run --rm -it --privileged -p 2222:2222 \
  -e LOKI_URL="http://loki.example.com:3100/loki/api/v1/push" \
  -e LOKI_EXTERNAL_LABELS="host=test,location=homelab" \
  serial-bridge:armv6
```

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Adapter missing | `balena ssh <uuid>` → `dmesg \| grep -i tty` on the host; driver built in? |
| No HDMI output | Screen stays on balena logo with `HDMI_ENABLE=true`? Check `balena ssh <uuid> serial-bridge` → `ls -l /dev/fb0` (must exist) and logs for fbtext errors. A silent serial device produces a blank screen by design. |
| HDMI garbled/wrong colors | `HDMI_SANITIZE=false` if control characters matter; fbtext maps non-Latin-1 to `?`. |
| SSH refused | `SSH_PASSWORD` or `SSH_PUBLIC_KEY` set? `balena device logs <uuid>` for the "no credentials" warning. |
| Loki 400/422 | Label values containing `,` are not supported (comma is the pair separator); check device logs. |
| Push retries in a loop | Verify `LOKI_URL` from the device: `balena ssh <uuid> serial-bridge` → `curl -s $LOKI_URL/ready`. |

### balenaOS HDMI/console specifics (why fbtext exists)

balenaOS for `raspberrypi` boots with `console=null` (see `/proc/cmdline`). Text written to `/dev/tty1` is accepted (`write()` returns 0) but never rendered — the VT layer binds a dummy console and does not draw post-boot, even with `console=tty1` set on the boot partition (tested). Do **not** rely on `/dev/tty1`; the container renders on `/dev/fb0` directly.

## Known limitations

- HDMI shows a linear text dump — no curses-style full-screen terminal emulation (that would need `screen`/`minicom` bound to the framebuffer).
- Loki lines are text-only; CR is normalised to LF, empty lines dropped.
- `tee` fan-out means the slowest sink can back-pressure the others; the HDMI sink drains fast, so in practice this only matters with a stalled console device.
