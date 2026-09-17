# WorkBuddy Manager single-container image: Go upstream + Python manager.
FROM golang:1.26-alpine AS upstream-build
WORKDIR /src
COPY workbuddy2api-master/go.mod workbuddy2api-master/go.sum ./
RUN go mod download
COPY workbuddy2api-master/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/wb2api ./cmd/server \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/signin_bin ./cmd/signin \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/login ./cmd/login \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/credit ./cmd/credit \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/trial_bin ./cmd/trial \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/activity_bin ./cmd/activity

FROM node:20-bookworm-slim AS web-build
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build:export

FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH=/app \
    WB_RUN_MODE=docker \
    WB_MANAGER_HOST=0.0.0.0 \
    WB_MANAGER_PORT=7864 \
    WB_INSTALL_DIR=/app \
    WB_DATA_DIR=/app/data \
    WB_STATIC_DIR=/app/web/out \
    WB_UPSTREAM_RUNTIME_DIR=/var/lib/workbuddy2api \
    WB_AUTH_DIR=/var/lib/workbuddy2api/auths \
    WB_UPSTREAM_CONFIG=/var/lib/workbuddy2api/config.json \
    WB_UPSTREAM_DATA_DIR=/var/lib/workbuddy2api/data \
    WB2API_BASE=http://127.0.0.1:7863 \
    WB2API_PID_FILE=/tmp/workbuddy2api.pid \
    WB2API_LOG_FILE=/app/data/workbuddy2api.log

ARG DEBIAN_MIRROR=""
RUN set -eu; \
    set_mirror() { \
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources; do \
            [ -f "$f" ] && sed -i -E "s#(https?://)[^/ ]+#\1$1#g" "$f"; \
        done; \
    }; \
    install_pkgs() { \
        apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15 update \
        && apt-get install -y --no-install-recommends git curl ca-certificates openssh-client bash gosu; \
    }; \
    if [ -n "${DEBIAN_MIRROR}" ]; then set_mirror "${DEBIAN_MIRROR}"; fi; \
    if ! install_pkgs; then \
        rm -rf /var/lib/apt/lists/*; set_mirror mirrors.aliyun.com; install_pkgs; \
    fi; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
ARG PIP_INDEX_URL=""
COPY server/requirements.txt /app/server/requirements.txt
RUN set -eu; \
    pip_install() { pip install --no-cache-dir --retries 5 --timeout 60 --index-url "$1" -r /app/server/requirements.txt; }; \
    if [ -n "${PIP_INDEX_URL}" ]; then pip_install "${PIP_INDEX_URL}"; \
    elif ! pip_install https://pypi.org/simple; then pip_install https://pypi.tuna.tsinghua.edu.cn/simple; fi

COPY server /app/server
COPY --from=web-build /web/out /app/web/out
COPY deploy /app/deploy
COPY CHANGELOG.md README.md /app/
COPY --from=upstream-build /out/ /opt/workbuddy2api/
COPY workbuddy2api-master/login.sh workbuddy2api-master/signin.sh workbuddy2api-master/credit.sh workbuddy2api-master/trial.sh /opt/workbuddy2api/
COPY workbuddy2api-master/scripts /opt/workbuddy2api/scripts
COPY workbuddy2api-master/config.example.json /usr/local/share/workbuddy2api/config.example.json
COPY deploy/container-entrypoint.sh /usr/local/bin/workbuddy-entrypoint

RUN useradd -u 10001 -m -s /bin/bash app \
    && mkdir -p /app/data /var/lib/workbuddy2api/auths /var/lib/workbuddy2api/data \
    && chmod 755 /usr/local/bin/workbuddy-entrypoint /opt/workbuddy2api/*.sh /opt/workbuddy2api/scripts/*.py \
    && chown -R 10001:10001 /app /opt/workbuddy2api /var/lib/workbuddy2api

EXPOSE 7863 7864
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS http://127.0.0.1:7864/api/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/workbuddy-entrypoint"]
