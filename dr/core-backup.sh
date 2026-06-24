#!/usr/bin/env bash
# Backup the production core: Mongo dump + config tarballs + checksum manifest

set -euo pipefail

# ---- configuration (override via /etc/core-backup.env) ----
BUCKET="${BUCKET:?set BUCKET}"                       # S3 Bucket  e.g. render-farm-dev-dr-############
MONGO_URI="${MONGO_URI:-mongodb://localhost:27017}"  # Deadline Repository DB
CONFIG_PATHS="${CONFIG_PATHS:-/opt/Thinkbox/DeadlineRepository10/settings /etc/pipeline}"  
WORK="$(mktemp -d /tmp/corebackup.XXXXXX)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PREFIX="core/${STAMP}"
METRICS_FILE="${METRICS_FILE:-/var/lib/node_exporter/textfile/corebackup.prom}"

trap 'rm -rf "$WORK"' EXIT

#=---- 1. Mongo dump (gzip archive)
# Runs mongodump from a container so the host needs no Mongo tooling installed;
# pin the image tag to match the server's major version.
docker run --rm --network host \
  -v "$WORK:/dump" \
  mongo:6 \
  mongodump --uri "$MONGO_URI" --gzip --archive=/dump/deadline-mongo.archive.gz


#=---- 2. tarball(s) up!
tar -czf "$WORK/configs.tar.gz" $CONFIG_PATHS 2>/dev/null || {
  echo "WARN: some config paths missing; archiving what exists" >&2
  tar -czf "$WORK/configs.tar.gz" --ignore-failed-read $CONFIG_PATHS
}


#=---- 3. Checksum manifest
( cd "$WORK" && sha256sum ./*.gz ./*.archive.gz 2>/dev/null | tee manifest.sha256 )

#=---- 4. Upload ----
aws s3 cp "$WORK/" "s3://${BUCKET}/${PREFIX}/" --recursive --only-show-errors

#=---- 5. Emit Prometheus metrics (node_exporter textfile collector)
SIZE_BYTES=$(du -sb "$WORK" | cut -f1)
cat > "$METRICS_FILE" <<EOF
# HELP corebackup_last_success_timestamp_seconds Unix time of last successful core backup.
# TYPE corebackup_last_success_timestamp_seconds gauge
corebackup_last_success_timestamp_seconds $(date +%s)
# HELP corebackup_last_size_bytes Size of last core backup payload.
# TYPE corebackup_last_size_bytes gauge
corebackup_last_size_bytes ${SIZE_BYTES}
EOF

echo "OK: ${PREFIX} (${SIZE_BYTES} bytes)"
