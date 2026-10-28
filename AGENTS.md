# AGENTS.md

Guidance for AI agents (and humans) working in this repository.

## What this is

A single-service balena deployment for the **Raspberry Pi 1** (device type `raspberrypi`, ARMv6). The `serial-bridge` container reads one or two USB serial adapters and fans each stream out to three sinks:

1. **HDMI** — writes the stream to `/dev/tty1` (balenaOS framebuffer console), control characters stripped unless `HDMI_SANITIZE=false`.
2. **SSH** — dropbear on port 2222 (host network); each stream is a tmux session named after the device (`ttyUSB0`, …), 10k lines scrollback.
3. **Loki** — `serial-bridge/src/loki-forwarder.sh` spools lines and pushes batches to `LOKI_URL` in Loki HTTP push format; `LOKI_EXTERNAL_LABELS` supports the docker-driver style `key=value,key=value` list, and `{{.Name}}` is substituted with the container name. A `serial_port` label is always added.

## Repository layout

| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | Service definition; all runtime config via environment |
| `serial-bridge/Dockerfile` | Two-stage: `gcc` build stage compiles `fbtext` from source (plus PSF font from `kbd`/`console-data`), runtime image is `balenalib/raspberry-pi-debian:bookworm` + `tmux dropbear curl` |
| `serial-bridge/src/entry.sh` | Supervisor loop, SSH setup, per-device tee fan-out over FIFOs, HDMI sink |
| `serial-bridge/src/loki-forwarder.sh` | Per-stream spool + batched push with requeue-on-failure |
| `serial-bridge/src/fbtext.c` | ~200-line PSF-font text renderer for `/dev/fb0` (see "Why fbtext" in README) |

## Hard constraints

- **ARMv6 (rpi) target.** Only distro packages from the balenalib ARMv6 base image. No prebuilt binaries, no Node/Python runtimes, no musl-only or armv7-only artifacts. Anything new must exist in Debian bookworm for `armhf/armv6`.
- **512 MB RAM.** Keep it one container, shell-only. `cat`, `tee`, `awk`, `sed`, `tr`, `date`, `curl` are the toolbox.
- **POSIX sh.** Scripts run with `/bin/sh` and `set -u` (no `set -e` — the supervisor must survive individual failures). Run `shellcheck serial-bridge/src/*.sh` before committing; it must stay clean.

## Design invariants — do not break these

- **FIFO fan-out:** A FIFO with multiple *readers* splits the stream (each byte goes to exactly one reader). All sinks must be fed by the single `tee` in `entry.sh`; per-device FIFOs are `$RUN/<dev>/{loki,ssh}`, and all devices share exactly one `$RUN/hdmi-all` FIFO feeding the HDMI renderer.
- **Sinks start before the producer.** `tee` blocks on `open()` of a FIFO until a reader appears. Sink loops must reopen (the `while :; do … sleep` pattern) so a dead sink only stalls its own branch and the reader loop restarts it.
- **HDMI goes through fbtext on /dev/fb0, never /dev/tty1.** balenaOS boots `console=null`; its VT layer accepts writes to tty1 but never renders them (verified on balenaOS 9.0.3/rpi, with and without `console=tty1` on the boot partition). If you need different HDMI behaviour, extend `fbtext.c` — do not reintroduce tty1 writes except as last-resort fallback.
- **Spool-then-push.** Loki pushes go through a spool file (`loki.spool` → moved to `loki.push` → pushed → requeued on failure). Never push per line; a fork per line saturates the 700 MHz core at line rates. Timestamps are batch-level (documented trade-off).
- **Hotplug tolerance.** `entry.sh` rescans every `SCAN_INTERVAL`s; streams for vanished devices are stopped and cleaned up. Any new sink must handle the device/FIFO disappearing mid-write.
- **fbtext is built, never vendored.** The binary is compiled from `src/fbtext.c` in the Dockerfile's build stage (distro `gcc`). Keep the final image free of compilers and of any checked-in binaries.

## Configuration surface

All runtime configuration is environment-only (see the table in `README.md`). When adding a variable:

1. Add it with a sane default in `docker-compose.yml`.
2. Document it in the README table.
3. Read it defensively in shell (`${VAR:-default}`), because balena users may set it fleet-wide or per-device.

**Secrets policy:** this is a public repository. Real endpoints, hostnames, tokens and credentials never go into tracked files — placeholders only (see `env.example`). Real values live in `env.local` (git-ignored) and in balena fleet env vars (cloud-side). Before every push, grep the tree for private infrastructure names/IPs.

## Verification

```sh
shellcheck serial-bridge/src/*.sh
docker buildx build --platform linux/arm/v6 -t serial-bridge:armv6 serial-bridge   # needs qemu binfmt
docker run --rm -it --privileged -p 2222:2222 serial-bridge:armv6                 # smoke test
```

On-device: `balena push <fleet>`, then `balena logs <uuid>`, `balena ssh <uuid> serial-bridge`, `tmux ls`. Loki endpoint reachability: `curl -s $LOKI_URL/ready` from inside the container.

## Gotchas

- `dropbear -R` generates host keys lazily; `dropbearkey` may not exist in the image — don't hard-require it.
- balenaOS's VT layer accepts writes to `/dev/tty1` but never renders them (`console=null`, dummy console binding). Screen verification must check `/dev/fb0` content (e.g. `md5sum /dev/fb0` before/while/after) or human eyes — not tty1.
- `SERIAL_PORTS` explicit lists must be comma-separated with optional spaces; `auto` globs `/dev/ttyUSB* /dev/ttyACM*`.
- Loki label values must not contain commas (pair separator); document this if users hit HTTP 4xx.
- The Pi 1 builds nothing — rely on `balena push` (cloud builders) or the `linux/arm/v6` buildx command above. A full image download takes the Pi ~25 min; source-only deltas apply much faster, so keep changes inside `src/` when possible.
