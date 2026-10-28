# Raspberry Pi 1 / Zero = ARMv6. Only distro packages, no prebuilt binaries.
FROM balenalib/raspberry-pi-debian:bookworm AS build

# gcc for the fbtext renderer; kbd/console-data provide the PSF console font.
RUN install_packages gcc libc6-dev kbd console-data

COPY src/fbtext.c /build/fbtext.c
RUN gcc -O2 -Wall -o /build/fbtext /build/fbtext.c && \
    f=$(ls /usr/share/consolefonts/*16*.psf.gz 2>/dev/null | head -1 || true) && \
    [ -n "$f" ] || f=$(ls /usr/share/consolefonts/*.psf.gz 2>/dev/null | head -1) && \
    echo "using font: $f" && zcat "$f" > /font.psf

FROM balenalib/raspberry-pi-debian:bookworm

# Minimal runtime dependencies: tmux (SSH stream sessions), dropbear (SSH
# server), curl (Loki push). stty comes from coreutils, tr/date/awk from base.
RUN install_packages tmux dropbear curl

COPY --from=build /build/fbtext /usr/src/app/fbtext
COPY --from=build /font.psf /usr/share/fbtext-default.psf
COPY src/entry.sh src/loki-forwarder.sh /usr/src/app/
WORKDIR /usr/src/app
RUN chmod +x entry.sh loki-forwarder.sh fbtext

# Wait for udev to settle so /dev/ttyUSB* exists before we scan.
ENV UDEV=on

CMD ["./entry.sh"]
