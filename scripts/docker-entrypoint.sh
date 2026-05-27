#!/bin/sh
set -e

# Capture runtime UID/GID from environment variables, defaulting to 1000
PUID=${USER_UID:-1000}
PGID=${USER_GID:-1000}

# Adjust the node user's UID/GID if they differ from the runtime request
# and fix volume ownership only when a remap is needed
changed=0

if [ "$(id -u node)" -ne "$PUID" ]; then
    echo "Updating node UID to $PUID"
    usermod -o -u "$PUID" node
    changed=1
fi

if [ "$(id -g node)" -ne "$PGID" ]; then
    echo "Updating node GID to $PGID"
    groupmod -o -g "$PGID" node
    usermod -g "$PGID" node
    changed=1
fi

if [ "$changed" = "1" ]; then
    chown -R node:node /paperclip
fi

# Pre-create config.json with the allowed hostname before the server starts.
# The server requires the hostname to be in the config before it will serve requests,
# but the CLI command to register it requires the config to already exist — so we
# generate a minimal valid config here using Node instead.
if [ -n "$PAPERCLIP_PUBLIC_URL" ]; then
    CONFIG_FILE="${PAPERCLIP_CONFIG:-/paperclip/instances/default/config.json}"
    CONFIG_DIR=$(dirname "$CONFIG_FILE")

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Pre-creating config.json with allowed hostname..."
        mkdir -p "$CONFIG_DIR"
        chown node:node "$CONFIG_DIR"

        gosu node node -e "
const fs = require('fs');
const configFile = process.env.PAPERCLIP_CONFIG || '/paperclip/instances/default/config.json';
const configDir = require('path').dirname(configFile);
const publicUrl = process.env.PAPERCLIP_PUBLIC_URL || '';
const hostname = publicUrl.replace(/^https?:\/\//, '').replace(/:.*/, '').replace(/\/.*/, '');
const config = {
  '\$meta': { version: 1, updatedAt: new Date().toISOString(), source: 'onboard' },
  database: { mode: 'postgres', connectionString: process.env.DATABASE_URL || '' },
  logging: { mode: 'file', logDir: '/paperclip/instances/default/logs' },
  server: {
    deploymentMode: 'authenticated',
    exposure: 'private',
    host: '0.0.0.0',
    port: 3100,
    allowedHostnames: hostname ? [hostname] : [],
    serveUi: true
  },
  auth: { baseUrlMode: 'explicit', publicBaseUrl: publicUrl, disableSignUp: false },
  telemetry: { enabled: true }
};
fs.mkdirSync(configDir, { recursive: true });
fs.writeFileSync(configFile, JSON.stringify(config, null, 2) + '\n', { mode: 0o600 });
console.log('Config created. Allowed hostname:', hostname);
" || echo "Warning: config pre-creation failed, server will initialize it"
    else
        # Config exists from a previous run — ensure the hostname is still registered
        ALLOWED_HOST=$(echo "$PAPERCLIP_PUBLIC_URL" | sed 's|https://||' | sed 's|http://||' | sed 's|:.*||' | sed 's|/.*||')
        echo "Config exists. Ensuring hostname is allowed: $ALLOWED_HOST"
        gosu node sh -c "cd /app && pnpm paperclipai allowed-hostname '$ALLOWED_HOST'" || true
    fi
fi

# After the server starts, generate the first admin invite URL and print it to logs.
# Only runs if no admin exists yet — safe to run on every boot.
(
  sleep 12
  echo "=== Paperclip admin bootstrap ==="
  gosu node sh -c "cd /app && pnpm paperclipai auth bootstrap-ceo" 2>&1 || true
  echo "================================="
) &

exec gosu node "$@"
