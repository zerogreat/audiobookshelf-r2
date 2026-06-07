#!/bin/sh
set -e

# Configure rclone for Cloudflare R2
mkdir -p /root/.config/rclone
cat > /root/.config/rclone/rclone.conf << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF

mount_r2() {
  # Unmount any stale FUSE mount first
  fusermount3 -u /audiobooks 2>/dev/null || true

  mkdir -p /audiobooks
  mkdir -p /config/rclone-cache
  rclone mount r2:${R2_BUCKET_NAME} /audiobooks \
    --allow-other \
    --vfs-cache-mode full \
    --cache-dir /config/rclone-cache \
    --vfs-cache-max-size 2G \
    --vfs-read-chunk-size 128M \
    --buffer-size 64M \
    --dir-cache-time 72h \
    --poll-interval 30m \
    --low-level-retries 10 \
    --retries 5 \
    --daemon

  # Give rclone a moment to establish the mount
  sleep 5
  echo "R2 bucket '${R2_BUCKET_NAME}' mounted at /audiobooks"
}

# Watchdog: restart rclone if it dies
watchdog() {
  while true; do
    sleep 30
    if ! pidof rclone > /dev/null; then
      echo "WARNING: rclone died, remounting..."
      mount_r2
    fi
  done
}

mount_r2

# Start watchdog in background
watchdog &

exec node index.js
