# Single-container Caddy + postgres-mcp image

FROM alpine:3.20

ARG S6_OVERLAY_VERSION=3.1.6.2
ARG POSTGRES_MCP_VERSION=0.3.0

# Base deps
RUN apk add --no-cache \
    caddy \
    curl \
    bash \
    xz \
    python3 \
    py3-pip \
    postgresql-client \
    git

# s6-overlay
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-x86_64.tar.xz /tmp
RUN tar -C / -Jxpf /tmp/s6-overlay-x86_64.tar.xz

# postgres-mcp pinned
RUN pip3 install --break-system-packages "postgres-mcp==${POSTGRES_MCP_VERSION}"

# s6 services
RUN mkdir -p /etc/s6-overlay/s6-rc.d/caddy /etc/s6-overlay/s6-rc.d/postgres-mcp \
    && echo "postgres-mcp" > /etc/s6-overlay/s6-rc.d/caddy/dependencies

# Caddy service
RUN echo "longrun" > /etc/s6-overlay/s6-rc.d/caddy/type \
 && cat > /etc/s6-overlay/s6-rc.d/caddy/run <<'EOF'
#!/command/with-contenv bash
set -euo pipefail
cd /srv
echo "Starting Caddy on port ${PORT:-8080}"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
EOF
RUN chmod +x /etc/s6-overlay/s6-rc.d/caddy/run

# postgres-mcp service
RUN echo "longrun" > /etc/s6-overlay/s6-rc.d/postgres-mcp/type \
 && cat > /etc/s6-overlay/s6-rc.d/postgres-mcp/run <<'EOF'
#!/command/with-contenv bash
set -euo pipefail
if [ -z "${DATABASE_URI:-}" ]; then
  echo "DATABASE_URI is required" >&2
  exit 1
fi
echo "Starting postgres-mcp with ACCESS_MODE=${ACCESS_MODE:-restricted}"
exec postgres-mcp --access-mode=${ACCESS_MODE:-restricted} --transport=sse --sse-port=8000 --sse-host=0.0.0.0 "${DATABASE_URI}"
EOF
RUN chmod +x /etc/s6-overlay/s6-rc.d/postgres-mcp/run

# Finish scripts
RUN echo '#!/command/with-contenv bash' > /etc/s6-overlay/s6-rc.d/postgres-mcp/finish \
 && echo 'echo "postgres-mcp exited with code: $1"' >> /etc/s6-overlay/s6-rc.d/postgres-mcp/finish \
 && echo 's6-svscanctl -t /var/run/s6/services' >> /etc/s6-overlay/s6-rc.d/postgres-mcp/finish \
 && chmod +x /etc/s6-overlay/s6-rc.d/postgres-mcp/finish

RUN echo '#!/command/with-contenv bash' > /etc/s6-overlay/s6-rc.d/caddy/finish \
 && echo 'echo "caddy exited with code: $1"' >> /etc/s6-overlay/s6-rc.d/caddy/finish \
 && chmod +x /etc/s6-overlay/s6-rc.d/caddy/finish

# Register services
RUN touch /etc/s6-overlay/s6-rc.d/user/contents.d/caddy \
 && touch /etc/s6-overlay/s6-rc.d/user/contents.d/postgres-mcp \
 && mkdir -p /etc/s6-overlay/s6-rc.d/caddy/dependencies.d \
 && touch /etc/s6-overlay/s6-rc.d/caddy/dependencies.d/postgres-mcp

# Copy Caddy config
RUN mkdir -p /etc/caddy
COPY Caddyfile /etc/caddy/Caddyfile

# Healthcheck script
RUN echo '#!/bin/bash' > /usr/local/bin/healthcheck \
 && echo 'curl -f -m 10 -H "Authorization: Bearer ${BEARER_TOKEN}" http://localhost:${PORT:-8080}/sse >/dev/null 2>&1' >> /usr/local/bin/healthcheck \
 && chmod +x /usr/local/bin/healthcheck

WORKDIR /srv

# Defaults
ENV S6_SERVICES_GRACETIME=30000 \
    S6_KILL_GRACETIME=10000 \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=30000 \
    UVICORN_LOG_LEVEL=info \
    UVICORN_ACCESS_LOG=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 CMD /usr/local/bin/healthcheck

ENTRYPOINT ["/init"]
