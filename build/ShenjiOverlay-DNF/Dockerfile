ARG BASE_IMAGE=llnut/dnf:debian13-qf1031-latest
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="DNF Shenji Overlay"
LABEL org.opencontainers.image.description="Qingfeng qf1031 base image with Shenji overlay assets baked into the image"

COPY .artifacts/shenji-overlay-dnf.tar.gz /tmp/shenji-overlay-dnf.tar.gz

RUN tar -xzf /tmp/shenji-overlay-dnf.tar.gz -C / \
    && rm -f /tmp/shenji-overlay-dnf.tar.gz
