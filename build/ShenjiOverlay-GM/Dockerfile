FROM alpine:3.21

WORKDIR /opt/godofgm

COPY .artifacts/shenji-overlay-gm.tar.gz /tmp/shenji-overlay-gm.tar.gz
COPY build/ShenjiOverlay-GM/entrypoint.sh /usr/local/bin/godofgm-entrypoint

RUN mkdir -p /opt/godofgm /opt/godofgm-init \
    && tar -xzf /tmp/shenji-overlay-gm.tar.gz -C /opt/godofgm-init \
    && cp -a /opt/godofgm-init/. /opt/godofgm/ \
    && chmod +x /usr/local/bin/godofgm-entrypoint /opt/godofgm/godofgm \
    && rm -f /tmp/shenji-overlay-gm.tar.gz

ENTRYPOINT ["/usr/local/bin/godofgm-entrypoint"]
