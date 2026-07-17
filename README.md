# Magento Local Docker Compose

## Directory Path (Important!)
- ~/Sites/ to store multiple Magento2 webshops separated by their respective directory (the directory name will become the domain name followed by .test)
- ~/Docker/general to store the root of this repository
```
For example a project named johndoe situated in ~/Sites/johndoe will be accessible by johndoe.test
```

## Ensure Environment is Ready Checklist
```
~/Docker/general
Chrome Settings DNS Provider to OS Default
Docker Desktop installed (>= 8GB memory for MariaDB buffer pool + OpenSearch)
node/npm installed on the HOST (brew install node) — grunt runs locally, not in a container
```

## Initial Setup (First Time)

### 1. Clone/Get the Repository
```bash
cd ~/Docker
git clone <repository-url> general
# OR if already exists, pull latest changes:
cd ~/Docker/general
git pull
```

### 2. Create Your .env
```bash
cd ~/Docker/general
cp .env.sample .env
```

`.env` is gitignored — without this step `docker compose up` fails with an
invalid image reference (empty `${PHP_VERSION}` etc.).

### 3. Initialize Environment
```bash
cd ~/Docker/general
sudo sh setup-environment.sh
```

**Note:** The script automatically detects if it's run with `sh` and re-executes with `bash` for compatibility.

**Note for WSL Users:**
- The script detects WSL/Linux automatically
- DNSMasq setup differs on WSL (uses system DNS resolution)
- Script works with both `sh setup-environment.sh` and `bash setup-environment.sh`

This will:
- Set up DNSMasq resolver
- Create/update bin wrapper scripts (`/usr/local/bin/php`, `/usr/local/bin/composer`, `/usr/local/bin/mage`, etc.)
- Install the `fixsl` helper (retargets `pub/static` symlinks that point at container paths back to `~/Sites` — needed after grunt/static deploys since grunt runs on the host)
- Install the `fixnode` helper (restores exec bits on `node_modules` binaries after `npm install` — the container's permission pass strips them)
- Configure commands that access `/var/www` to use `app` user (PHP, NodeJS, Nginx) for shared volume compatibility
- Configure database commands (mysql/mysqldump) to use `root` user (mariadb container doesn't have `app` user)

### 4. Start Docker Containers
```bash
cd ~/Docker/general
docker compose up -d
```

The PHP container will automatically fix permissions for `/var/www` on startup.

**Important:** Commands that access `/var/www` (PHP, NodeJS, Nginx) all use `app` user to ensure consistent file ownership. This prevents permission issues when:
- Running Magento grunt tasks (NodeJS) that create files PHP needs to access
- PHP creating files that grunt/npm need to modify
- Nginx CLI commands accessing project files

Database commands (mysql/mysqldump) use `root` since the mariadb container doesn't have `app` user, but they don't write to `/var/www` anyway.

## Updating Existing Setup (After Code Changes)

### Quick Update (Most Common)

If you just need to pull changes and restart containers:

```bash
cd ~/Docker/general
git pull
docker compose down
docker compose up -d
```

This works when:
- `docker-compose.yml` changed
- Entrypoint scripts changed (`php-entrypoint.sh`, etc.)
- Config files changed (`www.conf`, `php.ini`, etc.)

### Full Update (When Bin Scripts Changed)

If `bin/*` scripts or `setup-environment.sh` changed, you also need to update wrapper scripts:

```bash
cd ~/Docker/general
git pull
sudo sh setup-environment.sh  # Updates /usr/local/bin/* scripts
docker compose down
docker compose up -d
```

**When is `setup-environment.sh` needed?**
- When `bin/*` files changed (php, composer, magerun, etc.)
- When `setup-environment.sh` itself changed
- After first-time setup

**Note:** Running `setup-environment.sh` is safe even if nothing changed (idempotent), so you can always run it to be sure.

**Note:** The permission fix runs automatically on every container start, so restarting containers will apply any permission fixes needed.
## To Start and Stop Docker Compose
```
docker compose up -d
docker compose down
```
## To Troubleshoot DNSMasq Conflict Port 53 UDP
disable use kernel networking for UDP in docker network setting
## Change Php Versions / Other Container Versions
```
nano .env # change the containers version accordingly
docker compose up -d
```

## Auto-Updating Containers with Watchtower (Optional)

Watchtower can automatically update containers when new images are available. **For development environments, this is generally NOT recommended** because:

- Containers may restart unexpectedly during work
- Different developers may have different versions
- Breaking changes can disrupt workflow
- Less control over when updates happen

### If You Want to Enable Watchtower:

1. **Uncomment the watchtower service** in `docker-compose.yml`

2. **Configure update schedule** (default: daily at 2 AM):
   ```yaml
   WATCHTOWER_SCHEDULE=0 2 * * *  # Cron format
   ```

3. **Use label-based updates** (recommended):
   Add `com.centurylinklabs.watchtower.enable=true` label to containers you want auto-updated:
   ```yaml
   services:
     php:
       labels:
         - "com.centurylinklabs.watchtower.enable=true"
   ```

4. **Start watchtower**:
   ```bash
   docker compose up -d watchtower
   ```

### Recommended Approach (Manual Updates):

Instead of Watchtower, use manual updates via `.env` file:

```bash
# 1. Update versions in .env file
nano .env

# 2. Pull new images
docker compose pull

# 3. Restart containers
docker compose up -d
```

This gives you:
- Control over when updates happen
- Consistent versions across team
- Ability to test updates before applying

### DNSMasq Local Resolver
```
sudo mkdir -p /etc/resolver
sudo bash -c 'echo "nameserver 127.0.0.1" > /etc/resolver/test'
```
### php (/usr/local/bin/php)
```bash
#!/bin/bash
current_dir=$(basename "$(pwd)")
docker exec -uapp -i -w "/var/www/$current_dir" php php -d memory_limit=-1 "$@"
```
```
sudo chmod +x /usr/local/bin/php
```
### composer (/usr/local/bin/composer)
```bash
#!/bin/bash
current_dir=$(basename "$(pwd)")
docker exec -uapp -i -w "/var/www/$current_dir" php php -d memory_limit=-1 /usr/local/bin/composer "$@"
```
```
sudo chmod +x /usr/local/bin/composer
```
### mysql (/usr/local/bin/mysql)
```
#!/bin/bash
current_dir=$(basename "$(pwd)")
docker exec -i -w "/var/www/$current_dir" mariadb mysql "$@"
```
```
sudo chmod +x /usr/local/bin/mysql
```
### mysqldump (/usr/local/bin/mysqldump)
```
#!/bin/bash
current_dir=$(basename "$(pwd)")
docker exec -i -w "/var/www/$current_dir" mariadb mysqldump "$@"
```
```
sudo chmod +x /usr/local/bin/mysqldump
```