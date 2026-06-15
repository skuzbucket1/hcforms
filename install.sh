#!/usr/bin/env bash
#
# hcforms installer — turn a fresh Linux VM into a running hcforms deployment.
#
# Operators run ONE command (no git, no source needed):
#   curl -fsSL https://raw.githubusercontent.com/skuzbucket1/hcforms/main/install.sh | sudo bash
#
# Or with options:
#   curl -fsSL .../install.sh | sudo bash -s -- --domain forms.example.com --email you@example.com --anthropic-key sk-ant-...
#
# It installs Docker, pulls the prebuilt images from ghcr.io, generates secrets
# and TLS, and starts everything as a Docker Compose stack under /opt/hcforms
# (data in /var/hcforms). Idempotent: re-run any time. See --help for options.
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
ROLE="all"                              # all | customer | control-plane
IMAGE_SOURCE="pull"                     # pull (default) | build (from a repo checkout)
DOMAIN=""
EMAIL=""
HOST_OVERRIDE=""
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
OPENAI_BASE_URL=""
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
MODEL_OVERRIDE=""
REGISTRY="ghcr.io/skuzbucket1/hcforms"  # public ghcr namespace
IMAGE_TAG="latest"
REGISTRY_USER=""
REGISTRY_TOKEN=""
CUSTOMER_ID="local"
OPS_URL_FLAG=""                         # control-plane public URL (wires a customer to it)
OPS_SECRET_FLAG=""                      # control-plane-issued per-customer shared secret
OPS_INSECURE=0                          # 1 = trust a self-signed/private-CA control plane
CUSTOMER_API_IMAGE_FLAG=""              # full image ref (overrides REGISTRY/TAG)
CUSTOMER_WEB_IMAGE_FLAG=""              # full image ref (overrides REGISTRY/TAG)
INSTALL_SYSTEMD=1

APP_DIR="/opt/hcforms"
DATA_DIR="/var/hcforms"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /tmp)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || echo /tmp)"

# Globals populated as we go.
HOST=""; LLM_MODE=""; TLS_MODE=""; SERVER_NAME=""; TLS_CERT=""; TLS_KEY=""
CUSTOMER_API_IMAGE=""; CUSTOMER_WEB_IMAGE=""; CONTROL_PLANE_IMAGE=""
OPS_ADMIN_PASSWORD=""; OPS_PW_FRESH=1

# ── Logging ──────────────────────────────────────────────────────────────────
log()  { printf '\033[1;36m[hcforms]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[hcforms] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[hcforms] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,16p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0; }

# ── Argument parsing ─────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --role)            ROLE="$2"; shift 2 ;;
    --domain)          DOMAIN="$2"; shift 2 ;;
    --email)           EMAIL="$2"; shift 2 ;;
    --host)            HOST_OVERRIDE="$2"; shift 2 ;;
    --anthropic-key)   ANTHROPIC_API_KEY="$2"; shift 2 ;;
    --openai-base-url) OPENAI_BASE_URL="$2"; shift 2 ;;
    --openai-key)      OPENAI_API_KEY="$2"; shift 2 ;;
    --model)           MODEL_OVERRIDE="$2"; shift 2 ;;
    --pull)            IMAGE_SOURCE="pull"; shift ;;
    --build)           IMAGE_SOURCE="build"; shift ;;
    --registry)        REGISTRY="$2"; shift 2 ;;
    --tag)             IMAGE_TAG="$2"; shift 2 ;;
    --registry-user)   REGISTRY_USER="$2"; shift 2 ;;
    --registry-token)  REGISTRY_TOKEN="$2"; shift 2 ;;
    --customer-id)     CUSTOMER_ID="$2"; shift 2 ;;
    --ops-url)         OPS_URL_FLAG="$2"; shift 2 ;;
    --ops-secret)      OPS_SECRET_FLAG="$2"; shift 2 ;;
    --ops-insecure)    OPS_INSECURE=1; shift ;;
    --customer-api-image) CUSTOMER_API_IMAGE_FLAG="$2"; shift 2 ;;
    --customer-web-image) CUSTOMER_WEB_IMAGE_FLAG="$2"; shift 2 ;;
    --no-systemd)      INSTALL_SYSTEMD=0; shift ;;
    -h|--help)         usage ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
done

case "$ROLE" in all|customer|control-plane) ;; *) die "--role must be all|customer|control-plane" ;; esac
[ "$(id -u)" -eq 0 ] || die "Please run as root (sudo)."

# ── Helpers ──────────────────────────────────────────────────────────────────
existing_env() { { [ -f "$APP_DIR/.env" ] && sed -n "s/^$1=//p" "$APP_DIR/.env" | head -n1; } || true; }
gen_or_keep()  { local v; v="$(existing_env "$1")"; if [ -n "$v" ]; then printf '%s' "$v"; else openssl rand -hex "$2"; fi; }
have()         { command -v "$1" >/dev/null 2>&1; }

# ── Embedded files (this script is self-contained — no repo needed) ───────────
write_compose() {
  cat > "$APP_DIR/docker-compose.yml" <<'COMPOSE_EOF'
name: hcforms

# Values come from /opt/hcforms/.env. COMPOSE_PROFILES selects which services run.
services:
  postgres:
    image: postgres:16-alpine
    profiles: [customer, control-plane]
    restart: unless-stopped
    environment:
      POSTGRES_DB: hcforms
      POSTGRES_USER: hcforms
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /var/hcforms/pgdata:/var/lib/postgresql/data
      - /opt/hcforms/postgres-init.sql:/docker-entrypoint-initdb.d/10-create-ops-db.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U hcforms"]
      interval: 10s
      timeout: 3s
      retries: 30

  customer-api:
    image: ${CUSTOMER_API_IMAGE}
    profiles: [customer]
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      default:
        aliases: [api]
    environment:
      DATABASE_URL: postgresql://hcforms:${DB_PASSWORD}@postgres:5432/hcforms
      CUSTOMER_ID: ${CUSTOMER_ID}
      FILES_DIR: /var/hcforms/files
      JWT_SECRET: ${CUSTOMER_JWT_SECRET}
      AUTH_MODE: jwt
      LLM_MODE: ${LLM_MODE}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}
      OPENAI_BASE_URL: ${OPENAI_BASE_URL}
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      DEFAULT_LLM_MODEL_ID: ${DEFAULT_LLM_MODEL_ID}
      EXTRACTION_MODEL_ID: ${EXTRACTION_MODEL_ID}
      ALLOWED_ORIGINS: ${CUSTOMER_ALLOWED_ORIGINS}
      OPS_API_URL: ${OPS_API_URL}
      OPS_SHARED_SECRET: ${OPS_SHARED_SECRET}
      OPS_VERIFY_TLS: ${OPS_VERIFY_TLS}
      MONTHLY_TOKEN_CAP: ${MONTHLY_TOKEN_CAP}
    volumes:
      - /var/hcforms/files:/var/hcforms/files
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8080/healthz"]
      interval: 15s
      timeout: 3s
      retries: 10

  customer-worker:
    image: ${CUSTOMER_API_IMAGE}
    profiles: [customer]
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    command: ["python", "-m", "app.worker"]
    healthcheck:
      disable: true
    environment:
      DATABASE_URL: postgresql://hcforms:${DB_PASSWORD}@postgres:5432/hcforms
      CUSTOMER_ID: ${CUSTOMER_ID}
      FILES_DIR: /var/hcforms/files
      LLM_MODE: ${LLM_MODE}
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}
      OPENAI_BASE_URL: ${OPENAI_BASE_URL}
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      DEFAULT_LLM_MODEL_ID: ${DEFAULT_LLM_MODEL_ID}
      EXTRACTION_MODEL_ID: ${EXTRACTION_MODEL_ID}
      OPS_API_URL: ${OPS_API_URL}
      OPS_SHARED_SECRET: ${OPS_SHARED_SECRET}
      OPS_VERIFY_TLS: ${OPS_VERIFY_TLS}
      MONTHLY_TOKEN_CAP: ${MONTHLY_TOKEN_CAP}
    volumes:
      - /var/hcforms/files:/var/hcforms/files

  customer-web:
    image: ${CUSTOMER_WEB_IMAGE}
    profiles: [customer]
    restart: unless-stopped
    depends_on:
      - customer-api
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/"]
      interval: 15s
      timeout: 3s
      retries: 10

  control-plane:
    image: ${CONTROL_PLANE_IMAGE}
    profiles: [control-plane]
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: postgresql://hcforms:${DB_PASSWORD}@postgres:5432/hcforms_ops
      JWT_SECRET: ${OPS_JWT_SECRET}
      ADMIN_EMAIL: ${OPS_ADMIN_EMAIL}
      ADMIN_PASSWORD: ${OPS_ADMIN_PASSWORD}
      ALLOWED_ORIGINS: ${OPS_ALLOWED_ORIGINS}
      SUPPORTED_REGIONS: ${SUPPORTED_REGIONS}
      OPS_API_URL: ${OPS_PUBLIC_URL}
      CUSTOMER_API_IMAGE: ${CUSTOMER_API_IMAGE}
      CUSTOMER_WEB_IMAGE: ${CUSTOMER_WEB_IMAGE}
      DEFAULT_LLM_MODE: ${DEFAULT_LLM_MODE}
      DEFAULT_LLM_MODEL_ID: ${DEFAULT_LLM_MODEL_ID}
      EXTRACTION_MODEL_ID: ${EXTRACTION_MODEL_ID}
      CERTBOT_EMAIL: ${CERTBOT_EMAIL}
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8080/healthz"]
      interval: 15s
      timeout: 3s
      retries: 10

  nginx:
    image: nginx:alpine
    profiles: [customer, control-plane]
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "8443:8443"
    volumes:
      - /opt/hcforms/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /opt/hcforms/tls:/etc/hcforms/tls:ro
      - certbot-etc:/etc/letsencrypt
      - certbot-www:/var/www/certbot

  certbot:
    image: certbot/certbot
    profiles: [letsencrypt]
    restart: unless-stopped
    volumes:
      - certbot-etc:/etc/letsencrypt
      - certbot-www:/var/www/certbot
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait $$!; done;'"

volumes:
  certbot-etc:
  certbot-www:
COMPOSE_EOF
}

write_pg_init() {
  cat > "$APP_DIR/postgres-init.sql" <<'SQL_EOF'
CREATE DATABASE hcforms_ops;
SQL_EOF
}

# ── 1. Preflight ─────────────────────────────────────────────────────────────
preflight() {
  log "Preflight checks..."
  local pkgs="ca-certificates curl openssl"
  if   have apt-get; then { DEBIAN_FRONTEND=noninteractive apt-get update -y -qq && apt-get install -y -qq $pkgs; } >/dev/null 2>&1 || warn "host package install had issues; continuing";
  elif have dnf;     then dnf install -y -q $pkgs >/dev/null 2>&1 || warn "host package install had issues; continuing";
  elif have yum;     then yum install -y -q $pkgs >/dev/null 2>&1 || warn "host package install had issues; continuing";
  else warn "No apt/dnf/yum found — ensure 'curl' and 'openssl' are installed."; fi
  have curl    || die "curl is required but not available."
  have openssl || die "openssl is required but not available."

  if have ss; then
    local ports="80 443"; [ "$ROLE" = all ] && ports="$ports 8443"
    local p
    for p in $ports; do
      if ss -ltn 2>/dev/null | grep -q ":$p "; then warn "Port $p already in use — nginx may fail to bind."; fi
    done
  fi
}

# ── 2. Docker ────────────────────────────────────────────────────────────────
ensure_docker() {
  if have docker; then log "Docker already present."; else
    log "Installing Docker via get.docker.com..."
    curl -fsSL https://get.docker.com | sh
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is not available."
}

# A control-plane-managed customer is redeployed over SSH, so it needs sshd.
# Real VPSes already run it; minimal/container images may not.
ensure_sshd() {
  if systemctl list-unit-files 2>/dev/null | grep -qE '^ssh(d)?\.service'; then
    systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
    return 0
  fi
  log "Installing openssh-server (the control plane manages this box over SSH)..."
  if   have apt-get; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null 2>&1 || warn "sshd install had issues";
  elif have dnf;     then dnf install -y -q openssh-server >/dev/null 2>&1 || warn "sshd install had issues";
  elif have yum;     then yum install -y -q openssh-server >/dev/null 2>&1 || warn "sshd install had issues"; fi
  systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
}

# ── 3. Directories + embedded files ──────────────────────────────────────────
make_dirs() {
  mkdir -p "$APP_DIR" "$APP_DIR/tls" "$DATA_DIR/pgdata" "$DATA_DIR/files"
  chmod 0755 "$DATA_DIR" "$DATA_DIR/files"
  chown -R 10001:10001 "$DATA_DIR/files" 2>/dev/null || true
  write_compose
  write_pg_init
}

# ── 4. Images: pull from ghcr (default) or build from a repo checkout ─────────
resolve_images() {
  if [ "$IMAGE_SOURCE" = build ]; then
    [ -d "$REPO_ROOT/customer-app/api" ] || die "--build needs the source repo on this host; omit it to pull prebuilt images."
    CUSTOMER_API_IMAGE="hcforms/customer-api:local"
    CUSTOMER_WEB_IMAGE="hcforms/customer-web:local"
    CONTROL_PLANE_IMAGE="hcforms/control-plane:local"
    if [ "$ROLE" = all ] || [ "$ROLE" = customer ]; then
      log "Building customer-api image (a few minutes)..."; docker build -t "$CUSTOMER_API_IMAGE" "$REPO_ROOT/customer-app/api"
      log "Building customer-web image..."; docker build -t "$CUSTOMER_WEB_IMAGE" "$REPO_ROOT/customer-app/web"
    fi
    if [ "$ROLE" = all ] || [ "$ROLE" = control-plane ]; then
      log "Building control-plane image..."
      docker build -t "$CONTROL_PLANE_IMAGE" -f "$REPO_ROOT/control-plane/api/Dockerfile" "$REPO_ROOT/control-plane"
    fi
  else
    CUSTOMER_API_IMAGE="${CUSTOMER_API_IMAGE_FLAG:-$REGISTRY/customer-api:$IMAGE_TAG}"
    CUSTOMER_WEB_IMAGE="${CUSTOMER_WEB_IMAGE_FLAG:-$REGISTRY/customer-web:$IMAGE_TAG}"
    CONTROL_PLANE_IMAGE="$REGISTRY/control-plane:$IMAGE_TAG"
    if [ -n "$REGISTRY_TOKEN" ]; then
      log "Logging into ${REGISTRY%%/*}..."
      echo "$REGISTRY_TOKEN" | docker login "${REGISTRY%%/*}" -u "${REGISTRY_USER:-oauth2}" --password-stdin
    fi
  fi
}

# ── 5. Public host for origins + certificate ─────────────────────────────────
resolve_host() {
  HOST="${HOST_OVERRIDE:-${DOMAIN:-}}"
  if [ -z "$HOST" ]; then
    HOST="$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [ -z "$HOST" ]; then
    HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "$HOST" ]; then
    HOST="localhost"
  fi
  return 0
}

# ── 6. TLS ───────────────────────────────────────────────────────────────────
gen_selfsigned() {
  local san
  if printf '%s' "$HOST" | grep -qE '^[0-9.]+$'; then san="IP:$HOST"; else san="DNS:$HOST"; fi
  openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
    -keyout "$APP_DIR/tls/privkey.pem" -out "$APP_DIR/tls/fullchain.pem" \
    -subj "/CN=$HOST" -addext "subjectAltName=$san" >/dev/null 2>&1
  chmod 600 "$APP_DIR/tls/privkey.pem"
}

issue_letsencrypt() {
  docker volume create certbot-etc >/dev/null 2>&1 || true
  docker volume create certbot-www >/dev/null 2>&1 || true
  cat > "$APP_DIR/nginx-init.conf" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 200 'hcforms certbot init'; add_header Content-Type text/plain; }
}
EOF
  docker rm -f hcforms-nginx-init >/dev/null 2>&1 || true
  docker run -d --name hcforms-nginx-init -p 80:80 \
    -v "$APP_DIR/nginx-init.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v certbot-www:/var/www/certbot nginx:alpine >/dev/null
  sleep 4
  local rc=0
  docker run --rm \
    -v certbot-etc:/etc/letsencrypt -v certbot-www:/var/www/certbot \
    certbot/certbot certonly --webroot -w /var/www/certbot \
    --email "$EMAIL" --agree-tos --no-eff-email -d "$DOMAIN" || rc=$?
  docker rm -f hcforms-nginx-init >/dev/null 2>&1 || true
  return $rc
}

setup_tls() {
  if [ -n "$DOMAIN" ] && [ -n "$EMAIL" ]; then
    log "Requesting Let's Encrypt certificate for $DOMAIN..."
    if issue_letsencrypt; then
      TLS_MODE="letsencrypt"; SERVER_NAME="$DOMAIN"
      TLS_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
      TLS_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
      return
    fi
    warn "Let's Encrypt failed (does the DNS A record point at this host?). Falling back to self-signed."
  elif [ -n "$DOMAIN" ]; then
    warn "--domain set without --email; cannot use Let's Encrypt. Using self-signed."
  fi
  log "Generating self-signed certificate for $HOST..."
  TLS_MODE="selfsigned"; SERVER_NAME="_"
  TLS_CERT="/etc/hcforms/tls/fullchain.pem"
  TLS_KEY="/etc/hcforms/tls/privkey.pem"
  gen_selfsigned
}

# ── 7. nginx config (role-aware) ─────────────────────────────────────────────
render_nginx() {
  local f="$APP_DIR/nginx.conf"
  cat > "$f" <<'EOF'
server {
    listen 80;
    server_name @@SERVER_NAME@@;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://$host$request_uri; }
}
EOF
  if [ "$ROLE" = all ] || [ "$ROLE" = customer ]; then
    cat >> "$f" <<'EOF'
server {
    listen 443 ssl;
    server_name @@SERVER_NAME@@;
    ssl_certificate     @@TLS_CERT@@;
    ssl_certificate_key @@TLS_KEY@@;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    client_max_body_size 50m;
    resolver 127.0.0.11 ipv6=off valid=10s;

    location = /healthz {
        set $up_api customer-api:8080;
        proxy_pass http://$up_api/healthz;
    }
    location /api/ {
        set $up_api customer-api:8080;
        proxy_pass http://$up_api;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;
    }
    location / {
        set $up_web customer-web:8080;
        proxy_pass http://$up_web;
        proxy_set_header Host            $host;
        proxy_set_header X-Real-IP       $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
EOF
  fi
  if [ "$ROLE" = all ] || [ "$ROLE" = control-plane ]; then
    cat >> "$f" <<'EOF'
server {
    listen @@CP_PORT@@ ssl;
    server_name @@SERVER_NAME@@;
    ssl_certificate     @@TLS_CERT@@;
    ssl_certificate_key @@TLS_KEY@@;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    client_max_body_size 50m;
    resolver 127.0.0.11 ipv6=off valid=10s;

    location / {
        set $up_cp control-plane:8080;
        proxy_pass http://$up_cp;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 300s;
    }
}
EOF
  fi

  local cp_port="8443"; [ "$ROLE" = control-plane ] && cp_port="443"
  local tmp; tmp="$(mktemp)"
  sed -e "s|@@SERVER_NAME@@|$SERVER_NAME|g" \
      -e "s|@@TLS_CERT@@|$TLS_CERT|g" \
      -e "s|@@TLS_KEY@@|$TLS_KEY|g" \
      -e "s|@@CP_PORT@@|$cp_port|g" "$f" > "$tmp" && mv "$tmp" "$f"
}

# ── 8. Environment file ──────────────────────────────────────────────────────
write_env() {
  local default_model="claude-haiku-4-5-20251001"
  if   [ -n "$OPENAI_BASE_URL" ];    then LLM_MODE="openai"; default_model="qwen3:14b"
  elif [ -n "$ANTHROPIC_API_KEY" ];  then LLM_MODE="anthropic"
  else LLM_MODE="mock"; fi
  if [ -n "$MODEL_OVERRIDE" ]; then default_model="$MODEL_OVERRIDE"; fi

  local cust_origin ops_origin ops_public profiles cust_ops_url
  cust_origin="https://$HOST"
  if [ "$ROLE" = control-plane ]; then ops_origin="https://$HOST"; ops_public="https://$HOST"
  else ops_origin="https://$HOST:8443"; ops_public="https://$HOST:8443"; fi
  # Customer → control-plane wiring. All-in-one talks to the co-located control
  # plane; a standalone customer uses --ops-url when attached to a remote one.
  cust_ops_url=""
  if   [ "$ROLE" = all ];          then cust_ops_url="http://control-plane:8080"
  elif [ -n "$OPS_URL_FLAG" ];     then cust_ops_url="$OPS_URL_FLAG"; fi

  local db_password customer_jwt ops_jwt ops_shared
  db_password="$(gen_or_keep DB_PASSWORD 24)"
  customer_jwt="$(gen_or_keep CUSTOMER_JWT_SECRET 32)"
  ops_jwt="$(gen_or_keep OPS_JWT_SECRET 32)"
  # A control-plane-provisioned customer must use the shared secret the control
  # plane stored for it; otherwise generate (and preserve) a local one.
  if [ -n "$OPS_SECRET_FLAG" ]; then ops_shared="$OPS_SECRET_FLAG"; else ops_shared="$(gen_or_keep OPS_SHARED_SECRET 32)"; fi
  local ops_verify_tls="true"
  if [ "$OPS_INSECURE" = 1 ]; then ops_verify_tls="false"; fi
  OPS_ADMIN_PASSWORD="$(existing_env OPS_ADMIN_PASSWORD)"
  if [ -n "$OPS_ADMIN_PASSWORD" ]; then OPS_PW_FRESH=0; else OPS_ADMIN_PASSWORD="$(openssl rand -hex 12)"; OPS_PW_FRESH=1; fi

  case "$ROLE" in
    all)           profiles="customer,control-plane" ;;
    customer)      profiles="customer" ;;
    control-plane) profiles="control-plane" ;;
  esac
  if [ "$TLS_MODE" = letsencrypt ]; then profiles="$profiles,letsencrypt"; fi

  cat > "$APP_DIR/.env" <<EOF
# Generated by install.sh — secrets are preserved across re-runs. Keep private.
COMPOSE_PROFILES=$profiles

# Images
CUSTOMER_API_IMAGE=$CUSTOMER_API_IMAGE
CUSTOMER_WEB_IMAGE=$CUSTOMER_WEB_IMAGE
CONTROL_PLANE_IMAGE=$CONTROL_PLANE_IMAGE

# Database
DB_PASSWORD=$db_password

# Customer data plane
CUSTOMER_ID=$CUSTOMER_ID
CUSTOMER_JWT_SECRET=$customer_jwt
LLM_MODE=$LLM_MODE
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
OPENAI_BASE_URL=$OPENAI_BASE_URL
OPENAI_API_KEY=$OPENAI_API_KEY
DEFAULT_LLM_MODEL_ID=$default_model
EXTRACTION_MODEL_ID=claude-sonnet-4-6
MONTHLY_TOKEN_CAP=0
CUSTOMER_ALLOWED_ORIGINS=$cust_origin
OPS_API_URL=$cust_ops_url
OPS_SHARED_SECRET=$ops_shared
OPS_VERIFY_TLS=$ops_verify_tls

# Control plane
OPS_JWT_SECRET=$ops_jwt
OPS_ADMIN_EMAIL=admin@ops.local
OPS_ADMIN_PASSWORD=$OPS_ADMIN_PASSWORD
OPS_ALLOWED_ORIGINS=$ops_origin
OPS_PUBLIC_URL=$ops_public
SUPPORTED_REGIONS=local
DEFAULT_LLM_MODE=$LLM_MODE
CERTBOT_EMAIL=$EMAIL
EOF
  chmod 600 "$APP_DIR/.env"
}

# ── 9. Bring up ──────────────────────────────────────────────────────────────
bring_up() {
  cd "$APP_DIR"
  if [ "$IMAGE_SOURCE" = pull ]; then log "Pulling images from $REGISTRY ..."; docker compose pull; fi
  # Start Postgres first and ensure both DBs exist — don't rely on the first-boot
  # init-script mount (it's skipped if pgdata already exists, which stranded
  # hcforms_ops and broke control-plane login on early installs).
  log "Starting Postgres..."
  docker compose up -d postgres
  local i
  for i in $(seq 1 30); do docker compose exec -T postgres pg_isready -U hcforms >/dev/null 2>&1 && break; sleep 2; done
  if ! docker compose exec -T postgres psql -U hcforms -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='hcforms_ops'" 2>/dev/null | grep -q 1; then
    docker compose exec -T postgres psql -U hcforms -d postgres -c "CREATE DATABASE hcforms_ops" >/dev/null 2>&1 || true
  fi
  log "Starting the rest of the stack..."
  docker compose up -d --remove-orphans
}

wait_healthy() {
  log "Waiting for services to become healthy..."
  local cust=0 ops=0 ops_port="8443"
  case "$ROLE" in all|customer) cust=1 ;; esac
  case "$ROLE" in all|control-plane) ops=1 ;; esac
  [ "$ROLE" = control-plane ] && ops_port="443"
  local i ok
  for i in $(seq 1 60); do
    ok=1
    if [ "$cust" = 1 ]; then curl -fsk "https://localhost/healthz"           >/dev/null 2>&1 || ok=0; fi
    if [ "$ops"  = 1 ]; then curl -fsk "https://localhost:$ops_port/healthz" >/dev/null 2>&1 || ok=0; fi
    [ "$ok" = 1 ] && return 0
    sleep 3
  done
  return 1
}

# ── 10. systemd unit ─────────────────────────────────────────────────────────
install_systemd() {
  [ "$INSTALL_SYSTEMD" -eq 1 ] || return 0
  have systemctl || return 0
  cat > /etc/systemd/system/hcforms.service <<'UNIT_EOF'
[Unit]
Description=hcforms application stack (docker compose)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/hcforms
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
UNIT_EOF
  systemctl daemon-reload
  systemctl enable hcforms.service >/dev/null 2>&1 || true
}

# ── Register the local customer with the control plane (all-in-one only) ──────
wire_local_customer() {
  [ "$ROLE" = all ] || return 0
  local secret; secret="$(existing_env OPS_SHARED_SECRET)"
  [ -n "$secret" ] || return 0
  cd "$APP_DIR"
  local i
  for i in $(seq 1 15); do
    if docker compose exec -T postgres psql -U hcforms -d hcforms_ops -c \
      "INSERT INTO customers (customer_id, display_name, region, app_domain, status, ops_shared_secret) VALUES ('${CUSTOMER_ID}','Local install','local','${HOST}','active','${secret}') ON CONFLICT (customer_id) DO UPDATE SET ops_shared_secret=EXCLUDED.ops_shared_secret, status='active';" >/dev/null 2>&1; then
      log "Registered local customer '${CUSTOMER_ID}' with the control plane (usage will report)."
      return 0
    fi
    sleep 2
  done
  warn "Could not auto-register the local customer (control-plane DB not ready); wire it manually later if needed."
  return 0
}

# ── 11. Summary ──────────────────────────────────────────────────────────────
summary() {
  local note="" llm_note="" ops_url="https://$HOST:8443/"
  [ "$TLS_MODE" = selfsigned ] && note=" (self-signed cert — your browser will warn)"
  [ "$LLM_MODE" = mock ] && llm_note="  (offline; pass --anthropic-key for real fills)"
  [ "$ROLE" = control-plane ] && ops_url="https://$HOST/"
  echo
  log "hcforms is installed and running.$note"
  echo "------------------------------------------------------------------"
  if [ "$ROLE" = all ] || [ "$ROLE" = customer ]; then
    echo "  Customer app:    https://$HOST/"
    echo "    admin login:   admin@hcforms.local  /  admin   (change it after first login)"
  fi
  if [ "$ROLE" = all ] || [ "$ROLE" = control-plane ]; then
    echo "  Control plane:   $ops_url"
    if [ "$OPS_PW_FRESH" -eq 1 ]; then
      echo "    admin login:   admin@ops.local  /  $OPS_ADMIN_PASSWORD"
    else
      echo "    admin login:   admin@ops.local  /  (unchanged from a previous install)"
    fi
  fi
  echo "------------------------------------------------------------------"
  echo "  LLM mode:        $LLM_MODE$llm_note"
  echo "  Config:          $APP_DIR/.env          Data/PHI: $DATA_DIR/"
  echo "  Manage:          cd $APP_DIR  &&  docker compose ps | logs -f | restart"
  echo
}

# ── Main ─────────────────────────────────────────────────────────────────────
umask 077
preflight
ensure_docker
if [ "$ROLE" = customer ]; then ensure_sshd; fi
make_dirs
resolve_images
resolve_host
setup_tls
write_env
render_nginx
bring_up
install_systemd
if ! wait_healthy; then
  warn "Services did not report healthy in time. Inspect: cd $APP_DIR && docker compose ps && docker compose logs"
fi
wire_local_customer
summary
