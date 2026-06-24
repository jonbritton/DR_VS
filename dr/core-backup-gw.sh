#!/usr/bin/env bash
# Back up the production core THROUGH an S3 File Gateway:
#   Mongo dump + config tarballs + checksum manifest, written to the gateway's
#   NFS file share instead of `aws s3 cp`. The gateway uploads each closed file
#   to S3 under core/<stamp>/; bucket lifecycle then tiers older snapshots down
#   to Glacier Deep Archive (see terraform/modules/dr-bup).

set -euo pipefail

# ---- configuration (override via /etc/core-backup-gw.env) ----
GW_MOUNT="${GW_MOUNT:?set GW_MOUNT}"                   # NFS mount of the File Gateway share
FILE_SHARE_ARN="${FILE_SHARE_ARN:?set FILE_SHARE_ARN}" # Request an upload-complete notification
MONGO_URI="${MONGO_URI:-mongodb://localhost:27017}"    # Deadline Repo
CONFIG_PATHS="${CONFIG_PATHS:-/opt/Thinkbox/DeadlineRepository10/settings /etc/pipeline}"
METRICS_FILE="${METRICS_FILE:-/var/lib/node_exporter/textfile/corebackup.prom}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${GW_MOUNT}/core/${STAMP}"

# Check that the mount is the live gateway share
mountpoint -q "$GW_MOUNT" || { echo "FATAL: $GW_MOUNT is not mounted" >&2; exit 1; }
mkdir -p "$DEST"

#=---- 1. Mongo dump straight onto the share
# Runs mongodump from a container so the host needs no Mongo tooling installed;
# pin the image tag to match the server's major version.
docker run --rm --network host \
  -v "$DEST:/dump" \
  mongo:6 \
  mongodump --uri "$MONGO_URI" --gzip --archive=/dump/deadline-mongo.archive.gz

#=---- 2. tarball(s) up!
tar -czf "$DEST/configs.tar.gz" $CONFIG_PATHS 2>/dev/null || {
  echo "WARN: some config paths missing; archiving what exists" >&2
  tar -czf "$DEST/configs.tar.gz" --ignore-failed-read $CONFIG_PATHS
}

#=---- 3. Checksum 
( cd "$DEST" && sha256sum ./*.gz ./*.archive.gz 2>/dev/null | tee manifest.sha256 )

#=---- 4. Flush to the gateway and request an upload-complete notification
# File Gateway uploads asynchronously after each file is closed. `sync` pushes
# the writes; notify-when-uploaded returns a handle that fires a CloudWatch
# event once every file written to the share has reached S3 — that event, not
# this script returning, is the durability guarantee.
sync
NOTIFY_ID="$(aws storagegateway notify-when-uploaded \
  --file-share-arn "$FILE_SHARE_ARN" \
  --query NotificationId --output text)"
echo "upload notification queued: ${NOTIFY_ID} (completes on CloudWatch event)"

#=---- 5. Emit Prometheus metrics (node_exporter textfile collector)
SIZE_BYTES=$(du -sb "$DEST" | cut -f1)
cat > "$METRICS_FILE" <<EOF
# HELP corebackup_last_success_timestamp_seconds Unix time of last successful core backup.
# TYPE corebackup_last_success_timestamp_seconds gauge
corebackup_last_success_timestamp_seconds $(date +%s)
# HELP corebackup_last_size_bytes Size of last core backup payload.
# TYPE corebackup_last_size_bytes gauge
corebackup_last_size_bytes ${SIZE_BYTES}
EOF

echo "OK: core/${STAMP} (${SIZE_BYTES} bytes) staged to gateway"
