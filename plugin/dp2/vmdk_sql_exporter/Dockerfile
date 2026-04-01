FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       bash coreutils findutils gawk grep gzip procps psmisc sed \
       libc6:i386 libstdc++6:i386 zlib1g:i386 libgcc-s1:i386 libcrypt1:i386 \
    && rm -rf /var/lib/apt/lists/*

COPY export.sh /usr/local/bin/export-vmdk-sql

RUN chmod +x /usr/local/bin/export-vmdk-sql

ENTRYPOINT ["/usr/local/bin/export-vmdk-sql"]
