FROM node@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20

ARG OPENCODE_SHA256=5c7d89bc2d5fa5d83cc7768b813ca671368e70b8b9eda9d1ca9e6ec6b66d8ce0
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-venv git build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY opencode /usr/local/bin/opencode
RUN echo "${OPENCODE_SHA256}  /usr/local/bin/opencode" | sha256sum -c - \
    && chmod 755 /usr/local/bin/opencode \
    && mkdir -p /opt/agru \
    && dpkg-query -W > /opt/agru/packages.tsv \
    && /usr/local/bin/opencode --version > /opt/agru/opencode-version.txt
ENV HOME=/tmp/home \
    XDG_CONFIG_HOME=/tmp/config \
    XDG_DATA_HOME=/tmp/data \
    XDG_CACHE_HOME=/tmp/cache
USER 65534:65534
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/opencode"]
