#!/bin/bash

# Ensure script runs with bash (required for some features)
# If executed with 'sh', re-execute with bash
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

# Set DNSMasq Local Resolver (Mac-specific)
# WSL uses systemd-resolved or /etc/resolv.conf, DNSMasq setup differs
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sudo mkdir -p /etc/resolver
    sudo bash -c 'echo "nameserver 127.0.0.1" > /etc/resolver/test'
    echo "DNSMasq resolver configured for macOS"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux/WSL - DNSMasq typically runs on port 53, system handles resolution
    echo "DNSMasq resolver: WSL/Linux uses system DNS resolution"
    echo "Ensure DNSMasq container is running and port 53 is accessible"
else
    echo "Warning: Unknown OS type, skipping DNSMasq resolver setup"
fi

# Docker binary is now automatically managed via docker-compose volumes
# No manual binary creation needed - it's handled by dind-entrypoint.sh
echo "Docker binary is automatically managed by dind container"

# Ensure target directory exists
mkdir -p "$HOME/Docker/general/bin"

# Create PHP wrapper (php, composer, magerun, magerun2, msmtp)
# Tries php-{project} first, falls back to php
create_php_wrapper() {
    local name="$1"
    local command="$2"
    local target1="/usr/local/bin/$name"
    local target2="$HOME/Docker/general/bin/$name"

    cat <<'EOF' | sudo tee "$target1" > /dev/null
#!/bin/bash
project=$(pwd | sed "s|$HOME/Sites/||" | cut -d'/' -f1)

if docker ps --format '{{.Names}}' | grep -q "^php-${project}$"; then
    container="php-$project"
else
    container="php"
fi

EOF
    echo "docker exec -uapp -i -w \"/var/www/\$project\" \"\$container\" $command \"\$@\"" | sudo tee -a "$target1" > /dev/null

    cat <<'EOF' | sudo tee "$target2" > /dev/null
#!/bin/bash
project=$(pwd | sed "s|$HOME/Sites/||" | cut -d'/' -f1)

if docker ps --format '{{.Names}}' | grep -q "^php-${project}$"; then
    container="php-$project"
else
    container="php"
fi

EOF
    echo "docker exec -uapp -i -w \"/var/www/\$project\" \"\$container\" $command \"\$@\"" | sudo tee -a "$target2" > /dev/null

    sudo chmod +rx "$target1" "$target2"
}

# Cleanup old Node wrappers (nodejs container removed - use local npm/node instead)
cleanup_node_wrappers() {
    echo "Cleaning up old Node wrappers (using local npm/node instead)..."
    for name in nodejs npm grunt; do
        # Remove from /usr/local/bin if it's our wrapper (not the real binary)
        if [ -f "/usr/local/bin/$name" ] && grep -q "docker exec" "/usr/local/bin/$name" 2>/dev/null; then
            sudo rm -f "/usr/local/bin/$name"
            echo "  Removed /usr/local/bin/$name (was Docker wrapper)"
        fi
        # Remove from ~/Docker/general/bin
        if [ -f "$HOME/Docker/general/bin/$name" ]; then
            rm -f "$HOME/Docker/general/bin/$name"
            echo "  Removed $HOME/Docker/general/bin/$name"
        fi
    done
}

# Create MySQL wrapper (mysql, mysqldump)
# Tries mariadb-{project}, then postgres-{project}, falls back to mariadb
create_mysql_wrapper() {
    local name="$1"
    local command="$2"
    local pg_command="$3"
    local target1="/usr/local/bin/$name"
    local target2="$HOME/Docker/general/bin/$name"

    cat <<EOF | sudo tee "$target1" > /dev/null
#!/bin/bash
project=\$(pwd | sed "s|\$HOME/Sites/||" | cut -d'/' -f1)

if docker ps --format '{{.Names}}' | grep -q "^mariadb-\${project}\$"; then
    container="mariadb-\$project"
elif docker ps --format '{{.Names}}' | grep -q "^postgres-\${project}\$"; then
    docker exec -i "postgres-\$project" $pg_command -U root "\$@"
    exit \$?
else
    container="mariadb"
fi

docker exec -uroot -i -w "/var/www/\$project" "\$container" $command "\$@"
EOF

    cat <<EOF | sudo tee "$target2" > /dev/null
#!/bin/bash
project=\$(pwd | sed "s|\$HOME/Sites/||" | cut -d'/' -f1)

if docker ps --format '{{.Names}}' | grep -q "^mariadb-\${project}\$"; then
    container="mariadb-\$project"
elif docker ps --format '{{.Names}}' | grep -q "^postgres-\${project}\$"; then
    docker exec -i "postgres-\$project" $pg_command -U root "\$@"
    exit \$?
else
    container="mariadb"
fi

docker exec -uroot -i -w "/var/www/\$project" "\$container" $command "\$@"
EOF

    sudo chmod +rx "$target1" "$target2"
}

# Create Redis wrapper
# Tries redis-{project} first, falls back to redis
create_redis_wrapper() {
    local target1="/usr/local/bin/redis-cli"
    local target2="$HOME/Docker/general/bin/redis-cli"

    cat <<'EOF' | sudo tee "$target1" > /dev/null
#!/bin/bash
project=$(pwd | sed "s|$HOME/Sites/||" | cut -d'/' -f1)

if docker ps --format '{{.Names}}' | grep -q "^redis-${project}$"; then
    container="redis-$project"
else
    container="redis"
fi

docker exec -uroot -i -w "/var/www/$project" "$container" redis-cli "$@"
EOF

    cat <<'EOF' | sudo tee "$target2" > /dev/null
#!/bin/bash
project=$(pwd | sed "s|$HOME/Sites/||" | cut -d'/' -f1)

if docker ps --format '{{.Names}}' | grep -q "^redis-${project}$"; then
    container="redis-$project"
else
    container="redis"
fi

docker exec -uroot -i -w "/var/www/$project" "$container" redis-cli "$@"
EOF

    sudo chmod +rx "$target1" "$target2"
}

# Create Nginx wrapper
# Tries nginx-{project} first, falls back to nginx
create_nginx_wrapper() {
    local target1="/usr/local/bin/nginx"
    local target2="$HOME/Docker/general/bin/nginx"

    cat <<'EOF' | sudo tee "$target1" > /dev/null
#!/bin/bash
project=$(pwd | sed "s|$HOME/Sites/||" | cut -d'/' -f1)

if docker ps --format '{{.Names}}' | grep -q "^nginx-${project}$"; then
    container="nginx-$project"
else
    container="nginx"
fi

docker exec -u root -i "$container" nginx "$@"
EOF

    cat <<'EOF' | sudo tee "$target2" > /dev/null
#!/bin/bash
project=$(pwd | sed "s|$HOME/Sites/||" | cut -d'/' -f1)

if docker ps --format '{{.Names}}' | grep -q "^nginx-${project}$"; then
    container="nginx-$project"
else
    container="nginx"
fi

docker exec -u root -i "$container" nginx "$@"
EOF

    sudo chmod +rx "$target1" "$target2"
}

# Create wrapper scripts
echo "Creating PHP wrappers..."
create_php_wrapper "php" "php -d memory_limit=-1"
create_php_wrapper "composer" "php -d memory_limit=-1 /usr/local/bin/composer"
create_php_wrapper "mage" "php -d memory_limit=-1 bin/magento"
create_php_wrapper "magerun" "magerun"
create_php_wrapper "magerun2" "magerun2"
create_php_wrapper "msmtp" "msmtp"

# Node wrappers removed - use local npm/node instead
cleanup_node_wrappers

echo "Creating MySQL wrappers..."
create_mysql_wrapper "mysql" "mysql" "psql"
create_mysql_wrapper "mysqldump" "mysqldump" "pg_dump"

echo "Creating Redis wrapper..."
create_redis_wrapper

echo "Creating Nginx wrapper..."
create_nginx_wrapper

# Install a standalone helper script to both targets (same pattern as wrappers)
# Content is read from stdin (heredoc)
create_static_script() {
    local name="$1"
    local target1="/usr/local/bin/$name"
    local target2="$HOME/Docker/general/bin/$name"
    local content
    content="$(cat)"

    printf '%s\n' "$content" | sudo tee "$target1" > /dev/null
    printf '%s\n' "$content" | sudo tee "$target2" > /dev/null
    sudo chmod +rx "$target1" "$target2"
}

echo "Creating fixsl helper (retarget container-path symlinks in pub/static)..."
create_static_script "fixsl" <<'EOF'
#!/bin/bash
# Retarget pub/static symlinks that point at container paths (/var/www/...)
# back to the host checkout under ~/Sites. Needed because grunt runs on the
# host while Magento (in the container) creates symlinks using container paths.
if [ ! -d pub/static ]; then
    echo "fixsl: no pub/static here (run from a Magento project root)" >&2
    exit 1
fi
count=0
while IFS= read -r l; do
    t="$(readlink "$l")"
    ln -sfn "$HOME/Sites/${t#/var/www/}" "$l"
    count=$((count+1))
done < <(find pub/static -type l -lname "/var/www/*")
echo "fixsl: retargeted $count symlink(s)"
EOF

echo "Creating fixnode helper (restore exec bits in node_modules)..."
create_static_script "fixnode" <<'EOF'
#!/bin/bash
# Restore exec bits on node_modules binaries (stripped by the php container's
# permission pass over the ~/Sites bind mount). Run after npm install.
dir="${1:-node_modules}"
if [ ! -d "$dir" ]; then
    echo "fixnode: no '$dir' here" >&2
    exit 1
fi
# .bin entries are symlinks; chmod the targets, not the links
for link in "$dir"/.bin/*; do
    [ -e "$link" ] || continue
    target="$(readlink -f "$link" 2>/dev/null)"
    [ -f "$target" ] && chmod u+x "$target"
done
# native binaries that must be spawned (esbuild, etc.) live under */bin/*
find "$dir" -type f -path '*/bin/*' -exec chmod u+x {} + 2>/dev/null
echo "fixnode: exec bits restored in $dir"
EOF

echo "All configurations have been applied successfully."
