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

# Register the allowed hostname derived from PAPERCLIP_PUBLIC_URL
if [ -n "$PAPERCLIP_PUBLIC_URL" ]; then
    ALLOWED_HOST=$(echo "$PAPERCLIP_PUBLIC_URL" | sed 's|https\?://||' | sed 's|:.*||' | sed 's|/.*||')
    echo "Registering allowed hostname: $ALLOWED_HOST"
    gosu node sh -c "cd /app && pnpm paperclipai allowed-hostname '$ALLOWED_HOST'" || true
fi

exec gosu node "$@"
