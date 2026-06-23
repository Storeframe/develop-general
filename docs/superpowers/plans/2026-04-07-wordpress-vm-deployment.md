# WordPress VM Deployment (techflexwp.storeframe.store) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a production WordPress stack on a pre-provisioned Hetzner VM using the StoreFrame OpenResty security gateway (PoW, ACME SSL, CrowdSec, rate limiting, bot detection).

**Architecture:** OpenResty catch-all reverse proxy handles SSL termination and security pipeline, proxy_passes to an internal nginx container that handles WordPress-specific routing (permalinks, static assets, fastcgi). PHP-FPM runs in a separate container. WordPress files are bind-mounted from the host (`application/`) for SFTP-based management. All containers on a single flat Docker network.

**Tech Stack:** OpenResty (storeframe/nginx:mainline), PHP 8.3 FPM Alpine, nginx Alpine (internal), MariaDB 11.4, Redis 7 Alpine, CrowdSec, lua-resty-acme (ZeroSSL), SHA256 Proof-of-Work.

---

## Target VM

- **Host:** techflexwp.storeframe.store (78.46.192.104)
- **SSH:** `app@techflexwp.storeframe.store -p2409`
- **OS:** Ubuntu 24.04.4 LTS, 16GB RAM, 150GB disk
- **Docker:** 29.4.0 + Compose v5.1.1
- **Network:** `techflexwp.storeframe.store` (172.18.0.0/16) pre-created by Ansible
- **UFW:** port 2409 (SSH), 443/udp (QUIC) allowed; port 22 denied; ufw-docker manages container ports

## Directory Structure

```
/var/www/techflexwp.storeframe.store/
├── docker-compose.yml
├── .env
├── .docker/
│   ├── nginx/                          # OpenResty security gateway
│   │   └── etc/nginx/
│   │       ├── nginx.conf
│   │       ├── conf.d/
│   │       │   ├── proof-of-work.conf
│   │       │   ├── block-allow.conf
│   │       │   ├── crowdsec.conf
│   │       │   ├── log-json-analytics.conf
│   │       │   └── module-brotli.conf
│   │       ├── lua/
│   │       │   ├── loader.lua
│   │       │   ├── init.d/10-acme.lua
│   │       │   ├── init-worker.d/10-router.lua
│   │       │   ├── init-worker.d/30-acme.lua
│   │       │   ├── module/router.lua
│   │       │   ├── module/bot-detector.lua
│   │       │   ├── handler/proof-of-work.lua
│   │       │   ├── config/sites.d/techflexwp.storeframe.store.lua
│   │       │   └── data/
│   │       │       ├── h2-fingerprints.lua
│   │       │       └── ja4-fingerprints.lua
│   │       └── sites-enabled/
│   │           └── catch-all.conf
│   ├── wordpress/                      # Internal nginx for WP routing
│   │   └── nginx.conf
│   ├── crowdsec/                       # CrowdSec runtime
│   │   ├── etc/crowdsec/
│   │   │   └── bouncers/
│   │   │       └── crowdsec-openresty-bouncer.conf
│   │   └── var/lib/crowdsec/
│   └── certbot/                        # ACME + fallback cert
│       └── etc/letsencrypt/
│           ├── acme/                   # ZeroSSL account key (auto-created)
│           └── default/
│               ├── fullchain.pem       # Self-signed fallback
│               └── privkey.pem
└── application/                        # WordPress root (SFTP target)
    └── (wp-admin/, wp-content/, wp-includes/, wp-config.php, ...)
```

## Source Files

OpenResty configs are adapted from: `/Users/laurnts/Sites/storeframe/.docker/nginx/`

Files copied **as-is** (no changes):
- `nginx.conf` (main OpenResty config)
- `conf.d/proof-of-work.conf` (shared memory zones)
- `conf.d/block-allow.conf` (IP whitelist/blacklist)
- `conf.d/crowdsec.conf` (CrowdSec bouncer rewrite phase)
- `conf.d/module-brotli.conf` (Brotli compression)
- `lua/loader.lua` (plugin discovery)
- `lua/init.d/10-acme.lua` (ACME autossl init)
- `lua/init-worker.d/10-router.lua` (router worker init)
- `lua/init-worker.d/30-acme.lua` (ACME renewal timers)
- `lua/module/router.lua` (dynamic Lua router)
- `lua/module/bot-detector.lua` (bot classification)
- `lua/handler/proof-of-work.lua` (full 14k-line security pipeline)
- `lua/data/h2-fingerprints.lua` (future)
- `lua/data/ja4-fingerprints.lua` (future)

Files **adapted** for WordPress:
- `conf.d/log-json-analytics.conf` — remove GeoIP variables (no GeoIP DB on this VM)
- `sites-enabled/catch-all.conf` — remove StoreFrame-specific locations, change default backend

Files **new**:
- `sites.d/techflexwp.storeframe.store.lua` — site routing config
- `.docker/wordpress/nginx.conf` — internal nginx for WordPress routing
- `docker-compose.yml`
- `.env`

---

### Task 1: Create directory structure and runtime directories

**Target:** VM via SSH

- [ ] **Step 1: Create all directories**

```bash
ssh app@techflexwp.storeframe.store -p2409 'bash -s' << 'SCRIPT'
cd /var/www/techflexwp.storeframe.store

# OpenResty config directories
mkdir -p .docker/nginx/etc/nginx/conf.d
mkdir -p .docker/nginx/etc/nginx/sites-enabled
mkdir -p .docker/nginx/etc/nginx/lua/init.d
mkdir -p .docker/nginx/etc/nginx/lua/init-worker.d
mkdir -p .docker/nginx/etc/nginx/lua/module
mkdir -p .docker/nginx/etc/nginx/lua/handler
mkdir -p .docker/nginx/etc/nginx/lua/config/sites.d
mkdir -p .docker/nginx/etc/nginx/lua/data

# WordPress internal nginx
mkdir -p .docker/wordpress

# CrowdSec runtime
mkdir -p .docker/crowdsec/etc/crowdsec/bouncers
mkdir -p .docker/crowdsec/etc/crowdsec/acquis.d
mkdir -p .docker/crowdsec/var/lib/crowdsec

# ACME / Certbot
mkdir -p .docker/certbot/etc/letsencrypt/acme
mkdir -p .docker/certbot/etc/letsencrypt/default

echo "Directories created"
find .docker -type d | sort
SCRIPT
```

- [ ] **Step 2: Verify directory structure**

```bash
ssh app@techflexwp.storeframe.store -p2409 \
  "find /var/www/techflexwp.storeframe.store/.docker -type d | sort"
```

Expected: All directories from the structure above listed.

---

### Task 2: Generate self-signed fallback certificate

**Target:** VM via SSH

The fallback cert is used during ACME bootstrap (before ZeroSSL issues the real cert). Without it, OpenResty refuses to start because `ssl_certificate` points to a non-existent file.

- [ ] **Step 1: Generate self-signed cert**

```bash
ssh app@techflexwp.storeframe.store -p2409 'bash -s' << 'SCRIPT'
cd /var/www/techflexwp.storeframe.store/.docker/certbot/etc/letsencrypt/default

openssl req -x509 -nodes -days 3650 \
  -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout privkey.pem \
  -out fullchain.pem \
  -subj "/CN=techflexwp.storeframe.store/O=StoreFrame/C=NL"

echo "Fallback cert generated:"
openssl x509 -in fullchain.pem -noout -subject -dates
SCRIPT
```

Expected: Certificate created with 10-year expiry. This is only used as fallback until lua-resty-acme issues the real ZeroSSL cert.

- [ ] **Step 2: Verify files exist**

```bash
ssh app@techflexwp.storeframe.store -p2409 \
  "ls -la /var/www/techflexwp.storeframe.store/.docker/certbot/etc/letsencrypt/default/"
```

Expected: `fullchain.pem` and `privkey.pem` present.

---

### Task 3: Deploy OpenResty configs (copy as-is from StoreFrame)

**Source:** `/Users/laurnts/Sites/storeframe/.docker/nginx/`
**Target:** VM `/var/www/techflexwp.storeframe.store/.docker/nginx/`

These files are copied verbatim — no modifications needed.

- [ ] **Step 1: Copy nginx.conf**

```bash
scp -P 2409 \
  /Users/laurnts/Sites/storeframe/.docker/nginx/etc/nginx/nginx.conf \
  app@techflexwp.storeframe.store:/var/www/techflexwp.storeframe.store/.docker/nginx/etc/nginx/nginx.conf
```

- [ ] **Step 2: Copy conf.d files (as-is)**

```bash
for f in proof-of-work.conf block-allow.conf crowdsec.conf module-brotli.conf; do
  scp -P 2409 \
    "/Users/laurnts/Sites/storeframe/.docker/nginx/etc/nginx/conf.d/$f" \
    "app@techflexwp.storeframe.store:/var/www/techflexwp.storeframe.store/.docker/nginx/etc/nginx/conf.d/$f"
done
```

- [ ] **Step 3: Copy all Lua files (as-is)**

```bash
# loader.lua
scp -P 2409 \
  /Users/laurnts/Sites/storeframe/.docker/nginx/etc/nginx/lua/loader.lua \
  app@techflexwp.storeframe.store:/var/www/techflexwp.storeframe.store/.docker/nginx/etc/nginx/lua/loader.lua

# init.d/
scp -P 2409 \
  /Users/laurnts/Sites/storeframe/.docker/nginx/etc/nginx/lua/init.d/10-acme.lua \
  app@techflexwp.storeframe.store:/var/www/techflexwp.storeframe.store/.docker/nginx/etc/nginx/lua/init.d/10-acme.lua

# init-worker.d/
for f in 10-router.lua 30-acme.lua; do
  scp -P 2409 \
    "/Users/laurnts/Sites/storeframe/.docker/nginx/etc/nginx/lua/init-worker.d/$f" \
    "app@techflexwp.storeframe.store:/var/www/techflexwp.storeframe.store/.docker/nginx/etc/nginx/lua/init-worker.d/$f"
done

# module/
for f in router.lua bot-detector.lua; do
  scp -P 2409 \
    "/Users/laurnts/Sites/storeframe/.docker/nginx/etc/nginx/lua/module/$f" \
    "app@techflexwp.storeframe.store:/var/www/techflexwp.storeframe.store/.docker/nginx/etc/nginx/lua/module/$f"
done

# handler/ (proof-of-work.lua — 14k lines)
scp -P 2409 \
  /Users/laurnts/Sites/storeframe/.docker/nginx/etc/nginx/lua/handler/proof-of-work.lua \
  app@techflexwp.storeframe.store:/var/www/techflexwp.storeframe.store/.docker/nginx/etc/nginx/lua/handler/proof-of-work.lua

# data/
for f in h2-fingerprints.lua ja4-fingerprints.lua; do
  scp -P 2409 \
    "/Users/laurnts/Sites/storeframe/.docker/nginx/etc/nginx/lua/data/$f" \
    "app@techflexwp.storeframe.store:/var/www/techflexwp.storeframe.store/.docker/nginx/etc/nginx/lua/data/$f"
done
```

- [ ] **Step 4: Verify all files landed**

```bash
ssh app@techflexwp.storeframe.store -p2409 \
  "find /var/www/techflexwp.storeframe.store/.docker/nginx -type f | sort"
```

Expected: All files listed matching the directory structure.

---

### Task 4: Deploy adapted OpenResty configs

These files are modified from StoreFrame originals.

- [ ] **Step 1: Create log-json-analytics.conf (without GeoIP variables)**

Write to VM at `.docker/nginx/etc/nginx/conf.d/log-json-analytics.conf`:

```nginx
# Security variables set by proof-of-work.lua / header_filter

log_format json_analytics escape=json '{'
    '"connection_requests": "$connection_requests", '
    '"request_length": "$request_length", '
    '"remote_addr": "$remote_addr", '
    '"request_uri": "$request_uri", '
    '"args": "$args", '
    '"status": "$status", '
    '"bytes_sent": "$bytes_sent", '
    '"http_referer": "$http_referer", '
    '"http_user_agent": "$http_user_agent", '
    '"host": "$host", '
    '"http_host": "$http_host", '
    '"request_time": "$request_time", '
    '"scheme": "$scheme", '
    '"request_method": "$request_method", '
    '"server_protocol": "$server_protocol", '
    '"security_event": "$sent_http_x_security_event", '
    '"security_flags": "$security_flags", '
    '"security_action": "$security_action", '
    '"security_detail": "$security_detail", '
    '"bot_score": "$bot_score"'
'}';

access_log /proc/self/fd/1 json_analytics;
```

Changes from StoreFrame: Removed `$geoip2_data_*` variables (no GeoIP DB on this VM).

- [ ] **Step 2: Create catch-all.conf (adapted for WordPress)**

Write to VM at `.docker/nginx/etc/nginx/sites-enabled/catch-all.conf`:

```nginx
# WordPress catch-all: single server block, routing via lua/config/sites.d/*.lua
# Adapted from StoreFrame HUB catch-all

# -------------------------------------------------------------------------------------------------------------------- #
# HTTP redirect to HTTPS

server {
    listen 80;
    listen [::]:80;
    server_name _;

    location /.well-known/acme-challenge/ {
        content_by_lua_block {
            local ok, err = pcall(function()
                require("resty.acme.autossl").serve_http_challenge()
            end)
            if not ok then
                ngx.status = 404
                ngx.say("Not found")
                return
            end
        }
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# -------------------------------------------------------------------------------------------------------------------- #
# HTTPS catch-all

server {
    listen 443 quic reuseport;
    listen [::]:443 quic reuseport;
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    http3 on;
    server_name _;

    # Dynamic SSL (lua-resty-acme); fallback cert when autossl not yet issued
    ssl_certificate_by_lua_block {
        local router = require("router")
        router.ssl_certificate()
    }
    ssl_certificate     /etc/letsencrypt/default/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/default/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Alt-Svc 'h3=":$server_port"; ma=86400' always;
    quic_retry on;

    # Default backend (WordPress internal nginx)
    set $backend "wordpress-web:8080";

    # ACME HTTP-01 (HTTPS)
    location /.well-known/acme-challenge/ {
        access_by_lua_block { return }
        content_by_lua_block {
            local ok, err = pcall(function()
                require("resty.acme.autossl").serve_http_challenge()
            end)
            if not ok then
                ngx.status = 404
                ngx.say("Not found")
                return
            end
        }
    }

    # Route by Host (sets ngx.ctx.route and ngx.var.backend)
    rewrite_by_lua_block {
        local router = require("router")
        router.rewrite()
    }

    # Security pipeline (PoW, rate limit, bot detection)
    access_by_lua_file /usr/local/openresty/nginx/conf/lua/handler/proof-of-work.lua;

    # Copy security ctx to log vars; connection limiter leaving()
    log_by_lua_block {
        if ngx.var.security_flags == "" and ngx.ctx.security_flags then
            ngx.var.security_flags = ngx.ctx.security_flags
            ngx.var.security_action = ngx.ctx.security_action or ""
            ngx.var.security_detail = ngx.ctx.security_detail or ""
            ngx.var.bot_score = ngx.ctx.bot_score or ""
        end
        if ngx.ctx.conn_limiter then
            local lim = ngx.ctx.conn_limiter
            local key = ngx.ctx.conn_limit_key
            local req_time = tonumber(ngx.var.request_time) or 0
            pcall(function() lim:leaving(key, req_time) end)
        end
    }

    # PoW challenge endpoint
    location = /.pow {
        default_type text/html;
        content_by_lua_file /usr/local/openresty/nginx/conf/lua/handler/proof-of-work.lua;
    }

    # Proxy to backend (WebSocket upgrade supported)
    location / {
        proxy_pass http://$backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 86400;
    }
}
```

Changes from StoreFrame: Removed `/api/inngest` bypass, removed `/api/broadcast` block, changed default backend to `wordpress-web:8080`.

- [ ] **Step 3: Create site config**

Write to VM at `.docker/nginx/etc/nginx/lua/config/sites.d/techflexwp.storeframe.store.lua`:

```lua
-- techflexwp.storeframe.store (WordPress)
return {
    hosts = { "techflexwp.storeframe.store" },
    canonical_host = "techflexwp.storeframe.store",
    backend = "wordpress-web:8080",
}
```

Note: When the customer's real domain is ready, add it to `hosts` and update `canonical_host`. ACME will auto-issue a cert for any host listed here.

---

### Task 5: Create WordPress internal nginx config

This nginx runs inside the `wordpress-web` container and handles WordPress-specific routing (permalinks, PHP-FPM fastcgi, static assets, security blocks). OpenResty proxy_passes to this.

- [ ] **Step 1: Create internal nginx config**

Write to VM at `.docker/wordpress/nginx.conf`:

```nginx
server {
    listen 8080;
    server_name _;
    root /var/www/html;
    index index.php;

    client_max_body_size 128m;

    # Pretty permalinks
    location / {
        try_files $uri $uri/ /index.php$is_args$args;
    }

    # PHP-FPM (fastcgi to wordpress container)
    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_pass wordpress:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_read_timeout 300s;
    }

    # Block xmlrpc.php (brute force vector #1 for WordPress)
    location = /xmlrpc.php {
        deny all;
    }

    # Deny access to sensitive files
    location ~ /\.ht {
        deny all;
    }
    location ~ wp-config\.php {
        deny all;
    }
    location ~ readme\.html {
        deny all;
    }
    location ~ /wp-includes/.*\.php$ {
        deny all;
    }

    # Deny PHP execution in uploads (malware prevention)
    location ~* /wp-content/uploads/.*\.php$ {
        deny all;
    }

    # Static asset caching
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|svgz|webp|avif|woff2?|ttf|eot|otf)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
}
```

---

### Task 6: Create CrowdSec bouncer config

- [ ] **Step 1: Create bouncer config**

Write to VM at `.docker/crowdsec/etc/crowdsec/bouncers/crowdsec-openresty-bouncer.conf`:

```
ENABLED=true
API_URL=http://crowdsec:8080
MODE=stream
BOUNCING_ON_TYPE=all
FALLBACK_REMEDIATION=ban
UPDATE_FREQUENCY=10
```

---

### Task 7: Create docker-compose.yml

- [ ] **Step 1: Create docker-compose.yml**

Write to VM at `/var/www/techflexwp.storeframe.store/docker-compose.yml`:

```yaml
services:
  nginx:
    container_name: nginx
    image: storeframe/nginx:mainline
    hostname: techflexwp.storeframe.store
    restart: unless-stopped
    user: root
    env_file:
      - .env
    ports:
      - "80:80"
      - "443:443/tcp"
      - "443:443/udp"
    volumes:
      - ./.docker/nginx/etc/nginx/nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf:ro
      - ./.docker/nginx/etc/nginx/conf.d:/usr/local/openresty/nginx/conf/conf.d:ro
      - ./.docker/nginx/etc/nginx/lua:/usr/local/openresty/nginx/conf/lua:ro
      - ./.docker/nginx/etc/nginx/sites-enabled:/usr/local/openresty/nginx/conf/sites-enabled:ro
      - ./.docker/certbot/etc/letsencrypt:/etc/letsencrypt:ro
      - ./.docker/crowdsec/etc/crowdsec/bouncers/crowdsec-openresty-bouncer.conf:/etc/crowdsec/bouncers/crowdsec-openresty-bouncer.conf:ro
    entrypoint: >
      /bin/sh -c 'echo "[AutoReload] Starting at $$(date)" >&2;
      (while true; do sleep 3600; echo "[AutoReload] Reloading nginx at $$(date)" >&2; nginx -s reload 2>&1; done) &
      exec openresty -g "daemon off;"'
    depends_on:
      - crowdsec
      - wordpress-web
    networks:
      default:

  wordpress:
    container_name: wordpress
    image: wordpress:php8.3-fpm-alpine
    restart: unless-stopped
    volumes:
      - ./application:/var/www/html
    environment:
      WORDPRESS_DB_HOST: mariadb
      WORDPRESS_DB_NAME: ${WP_DB_NAME}
      WORDPRESS_DB_USER: ${WP_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WP_DB_PASSWORD}
      WORDPRESS_CONFIG_EXTRA: |
        define('DISABLE_WP_CRON', true);
        define('WP_REDIS_HOST', 'redis');
        define('WP_REDIS_PORT', 6379);
    depends_on:
      - mariadb
      - redis
    networks:
      default:

  wordpress-web:
    container_name: wordpress-web
    image: nginx:1.27-alpine
    restart: unless-stopped
    volumes:
      - ./application:/var/www/html:ro
      - ./.docker/wordpress/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - wordpress
    networks:
      default:

  mariadb:
    container_name: mariadb
    image: mariadb:11.4
    restart: unless-stopped
    volumes:
      - ./.docker/mariadb/data:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${WP_DB_NAME}
      MYSQL_USER: ${WP_DB_USER}
      MYSQL_PASSWORD: ${WP_DB_PASSWORD}
    networks:
      default:

  redis:
    container_name: redis
    image: redis:7-alpine
    restart: unless-stopped
    networks:
      default:

  crowdsec:
    container_name: crowdsec
    image: crowdsecurity/crowdsec
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "127.0.0.1:8080:8080"
      - "127.0.0.1:6060:6060"
    volumes:
      - ./.docker/crowdsec/etc/crowdsec:/etc/crowdsec
      - ./.docker/crowdsec/etc/crowdsec/acquis.d:/etc/crowdsec/acquis.d
      - ./.docker/crowdsec/var/lib/crowdsec:/var/lib/crowdsec
      - /var/log/syslog:/var/log/syslog:ro
      - /var/log/auth.log:/var/log/auth.log:ro
      - /var/log/kern.log:/var/log/kern.log:ro
      - /var/log/ufw.log:/var/log/ufw.log:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      default:

networks:
  default:
    external: true
    name: techflexwp.storeframe.store
```

Notes:
- Uses the pre-existing `techflexwp.storeframe.store` Docker network created by Ansible.
- `wordpress` container: official WordPress FPM Alpine image handles wp-config.php generation from env vars on first boot.
- `wordpress-web`: read-only mount of `application/` (only serves static files + fastcgi proxy, never writes).
- `wordpress`: read-write mount of `application/` (WordPress writes to `wp-content/uploads/`, generates wp-config.php on first run).

---

### Task 8: Create .env file

- [ ] **Step 1: Create .env**

Write to VM at `/var/www/techflexwp.storeframe.store/.env`:

```bash
# WordPress Database
WP_DB_NAME=wordpress
WP_DB_USER=wordpress
WP_DB_PASSWORD=<generate-secure-password>
MYSQL_ROOT_PASSWORD=<generate-secure-password>

# OpenResty Security
POW_ENABLED=yes
POW_SECRET=<generate-64-char-random-string>
POW_DIFFICULTY=4
POW_SESSION_EXPIRE=86400
POW_BOT_SCORE_ENABLED=no
RATELIMIT_ENABLED=yes
RATELIMIT_RPS=10
RATELIMIT_BURST=50
BLOCKLIST_ENABLED=yes
CONNLIMIT_MAX=50
CONNLIMIT_BURST=10

# ACME SSL (ZeroSSL)
ACME_EMAIL=ssl@storeframe.io

# CrowdSec
CUSTOM_HOSTNAME=techflexwp.storeframe.store
COLLECTIONS=crowdsecurity/base-http-scenarios crowdsecurity/linux crowdsecurity/sshd crowdsecurity/whitelist-good-actors crowdsecurity/http-cve crowdsecurity/http-dos crowdsecurity/nginx
ENROLL_KEY=
ENROLL_INSTANCE_NAME=techflexwp.storeframe.store
ENROLL_TAGS=wordpress
```

- [ ] **Step 2: Generate passwords**

```bash
ssh app@techflexwp.storeframe.store -p2409 'bash -s' << 'SCRIPT'
cd /var/www/techflexwp.storeframe.store

WP_DB_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
MYSQL_ROOT_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
POW_SECRET=$(openssl rand -hex 32)

sed -i "s|<generate-secure-password>|${WP_DB_PASS}|" .env
sed -i "0,/<generate-secure-password>/s|<generate-secure-password>|${MYSQL_ROOT_PASS}|" .env
sed -i "s|<generate-64-char-random-string>|${POW_SECRET}|" .env

echo "Passwords generated. Verify (redacted):"
grep -E "^(WP_DB_PASSWORD|MYSQL_ROOT_PASSWORD|POW_SECRET)" .env | sed 's/=.*/=***REDACTED***/'
SCRIPT
```

Note: The sed for two different `<generate-secure-password>` values needs to be handled carefully. The first sed replaces the first occurrence (WP_DB_PASSWORD), then the second occurrence becomes MYSQL_ROOT_PASSWORD. If this doesn't work cleanly, write the .env directly with the generated values via a heredoc instead.

---

### Task 9: Configure UFW for Docker container ports

- [ ] **Step 1: Allow HTTP/HTTPS through ufw-docker**

The VM has `ufw-docker` installed (from `docker_install.yml`). The nginx container exposes ports 80 and 443. `ufw-docker` manages the iptables rules to allow traffic to Docker-published ports.

```bash
ssh app@techflexwp.storeframe.store -p2409 'bash -s' << 'SCRIPT'
# ufw-docker will auto-allow published container ports once containers start
# Verify current rules
sudo ufw status verbose
# Port 443/udp (QUIC) is already allowed from Ansible
# Port 80 and 443/tcp will be handled by ufw-docker when nginx container starts
SCRIPT
```

Note: Check after `docker compose up` whether port 80 and 443/tcp are reachable. If not, run:
```bash
sudo ufw-docker allow nginx 80/tcp
sudo ufw-docker allow nginx 443/tcp
```

---

### Task 10: Start the stack and verify

- [ ] **Step 1: Pull images**

```bash
ssh app@techflexwp.storeframe.store -p2409 \
  "cd /var/www/techflexwp.storeframe.store && docker compose pull"
```

- [ ] **Step 2: Start the stack**

```bash
ssh app@techflexwp.storeframe.store -p2409 \
  "cd /var/www/techflexwp.storeframe.store && docker compose up -d"
```

- [ ] **Step 3: Verify all containers are running**

```bash
ssh app@techflexwp.storeframe.store -p2409 "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
```

Expected: 6 containers running (nginx, wordpress, wordpress-web, mariadb, redis, crowdsec).

- [ ] **Step 4: Check nginx logs for startup errors**

```bash
ssh app@techflexwp.storeframe.store -p2409 "docker logs nginx 2>&1 | head -30"
```

Expected: No Lua errors. Should see `[ACME] Initialised autossl with 1 whitelisted host(s)` and `router: loaded 1 site(s)`.

- [ ] **Step 5: Check CrowdSec logs**

```bash
ssh app@techflexwp.storeframe.store -p2409 "docker logs crowdsec 2>&1 | tail -20"
```

Expected: CrowdSec started, collections loaded.

- [ ] **Step 6: Test HTTP → HTTPS redirect**

```bash
curl -I http://techflexwp.storeframe.store 2>/dev/null | head -5
```

Expected: `301 Moved Permanently` → `https://techflexwp.storeframe.store`

- [ ] **Step 7: Test HTTPS (will use self-signed cert initially)**

```bash
curl -kI https://techflexwp.storeframe.store 2>/dev/null | head -10
```

Expected: `200 OK` or WordPress installation page. The `-k` flag skips cert verification (self-signed until ACME issues real cert).

- [ ] **Step 8: Verify ACME certificate issuance**

Wait 1-2 minutes after first HTTPS request, then:

```bash
echo | openssl s_client -connect techflexwp.storeframe.store:443 -servername techflexwp.storeframe.store 2>/dev/null | openssl x509 -noout -issuer -subject -dates
```

Expected: Issuer should show ZeroSSL (not the self-signed CN). If still self-signed, check nginx error logs for ACME errors.

- [ ] **Step 9: Test PoW challenge**

```bash
curl -kI https://techflexwp.storeframe.store 2>/dev/null | grep -i "x-security"
```

Expected: Security headers present, or a PoW challenge page returned (since curl sends `Accept: */*` which includes `text/html`).

---

### Task 11: Set up WordPress cron via system cron

WordPress's built-in wp-cron fires on page visits, which is unreliable and wasteful. Disable it (already done via `WORDPRESS_CONFIG_EXTRA` in docker-compose) and use a real cron job.

- [ ] **Step 1: Add cron job**

```bash
ssh app@techflexwp.storeframe.store -p2409 'bash -s' << 'SCRIPT'
# Run WordPress cron every 5 minutes
(crontab -l 2>/dev/null; echo "*/5 * * * * docker exec -u www-data wordpress wp cron event run --due-now --path=/var/www/html 2>&1 | logger -t wp-cron") | crontab -

echo "Cron installed:"
crontab -l
SCRIPT
```

- [ ] **Step 2: Verify WP-CLI is available in container**

```bash
ssh app@techflexwp.storeframe.store -p2409 \
  "docker exec wordpress wp --info 2>/dev/null || echo 'WP-CLI not in official image - install it'"
```

Note: The official `wordpress:php8.3-fpm-alpine` image does NOT include WP-CLI. If not present, install it:

```bash
ssh app@techflexwp.storeframe.store -p2409 'bash -s' << 'SCRIPT'
docker exec wordpress sh -c '
  curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar &&
  chmod +x wp-cli.phar &&
  mv wp-cli.phar /usr/local/bin/wp
'
docker exec -u www-data wordpress wp --info
SCRIPT
```

If WP-CLI is not persistent across container restarts, consider building a custom Dockerfile that bakes it in.

---

### Task 12: Register CrowdSec bouncer API key

CrowdSec bouncer needs an API key to communicate with the CrowdSec LAPI.

- [ ] **Step 1: Register bouncer**

```bash
ssh app@techflexwp.storeframe.store -p2409 'bash -s' << 'SCRIPT'
# Generate bouncer API key
BOUNCER_KEY=$(docker exec crowdsec cscli bouncers add openresty-bouncer -o raw 2>/dev/null)
echo "Bouncer API key: $BOUNCER_KEY"

# Add to bouncer config
cd /var/www/techflexwp.storeframe.store
echo "API_KEY=$BOUNCER_KEY" >> .docker/crowdsec/etc/crowdsec/bouncers/crowdsec-openresty-bouncer.conf

echo "Updated bouncer config:"
cat .docker/crowdsec/etc/crowdsec/bouncers/crowdsec-openresty-bouncer.conf
SCRIPT
```

- [ ] **Step 2: Restart nginx to pick up bouncer key**

```bash
ssh app@techflexwp.storeframe.store -p2409 \
  "cd /var/www/techflexwp.storeframe.store && docker compose restart nginx"
```

- [ ] **Step 3: Verify CrowdSec bouncer connection**

```bash
ssh app@techflexwp.storeframe.store -p2409 \
  "docker exec crowdsec cscli bouncers list"
```

Expected: `openresty-bouncer` listed with `validated` status.

---

### Task 13: Final verification and smoke test

- [ ] **Step 1: Full stack health check**

```bash
ssh app@techflexwp.storeframe.store -p2409 'bash -s' << 'SCRIPT'
echo "=== Container Status ==="
docker ps --format 'table {{.Names}}\t{{.Status}}'

echo ""
echo "=== Disk Usage ==="
df -h /

echo ""
echo "=== Memory Usage ==="
free -h

echo ""
echo "=== Docker Network ==="
docker network inspect techflexwp.storeframe.store --format '{{range .Containers}}{{.Name}} → {{.IPv4Address}}{{"\n"}}{{end}}'

echo ""
echo "=== WordPress DB Connection ==="
docker exec wordpress wp db check --path=/var/www/html 2>/dev/null && echo "DB OK" || echo "DB check failed (WP-CLI may need install, or WordPress not yet installed)"

echo ""
echo "=== CrowdSec Status ==="
docker exec crowdsec cscli metrics 2>/dev/null | head -10
SCRIPT
```

- [ ] **Step 2: Test from outside**

```bash
# HTTPS with real cert (after ACME)
curl -sI https://techflexwp.storeframe.store | head -10

# Check SSL cert
echo | openssl s_client -connect techflexwp.storeframe.store:443 -servername techflexwp.storeframe.store 2>/dev/null | openssl x509 -noout -issuer -subject

# Check HTTP/3 support
curl --http3 -sI https://techflexwp.storeframe.store 2>/dev/null | head -5 || echo "HTTP/3 test requires curl with HTTP/3 support"
```

- [ ] **Step 3: Verify WordPress installation page**

Open `https://techflexwp.storeframe.store` in a browser. You should see:
1. First: PoW challenge page (solve the SHA256 puzzle)
2. After solving: WordPress installation wizard (language selection → site setup)

---

## Post-Deployment Notes

**Customer domain:** When the customer's real domain (e.g., `www.techflex.nl`) is ready:
1. Point DNS A record to `78.46.192.104`
2. Add to `.docker/nginx/etc/nginx/lua/config/sites.d/techflexwp.storeframe.store.lua`:
   ```lua
   return {
       hosts = { "techflexwp.storeframe.store", "www.techflex.nl", "techflex.nl" },
       canonical_host = "www.techflex.nl",
       backend = "wordpress-web:8080",
   }
   ```
3. Reload nginx: `docker exec nginx nginx -s reload`
4. ACME will auto-issue certs for the new domains within minutes.

**Redis object cache:** After WordPress is installed, install the Redis Object Cache plugin and activate it. The `WP_REDIS_HOST` and `WP_REDIS_PORT` constants are already set in wp-config.php via `WORDPRESS_CONFIG_EXTRA`.

**Backups:** Not covered in this plan. Consider adding Restic backup for `application/` and MariaDB dumps (same pattern as Magento VMs).

**WP-CLI persistence:** The official WordPress Docker image doesn't include WP-CLI. For persistence across container restarts, either:
- Build a custom Dockerfile extending `wordpress:php8.3-fpm-alpine` with WP-CLI baked in
- Or bind-mount wp-cli.phar from the host
