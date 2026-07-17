#!/usr/bin/env bash
# Backup the production core: Mongo dump + config tarballs + checksum manifest

set -euo pipefail

# ---- configuration (override via /etc/core-backup.env) ----
BUCKET="${BUCKET:?set BUCKET}"                       # S3 Bucket  e.g. render-farm-dev-dr-############
MONGO_URI="${MONGO_URI:-mongodb://localhost:27017}"  # Deadline Repository DB
CONFIG_PATHS="${CONFIG_PATHS:-/opt/Thinkbox/DeadlineRepository10/settings /etc/pipeline}"
WORK_ROOT="${WORK_ROOT:-/var/tmp}"                   # parent of the working dir — real disk, NOT tmpfs (/tmp often is)
MIN_FREE_MB="${MIN_FREE_MB:-2048}"                   # refuse to start below this much free space; size to ~2x a backup
MAX_BANDWIDTH="${MAX_BANDWIDTH:-}"                   # e.g. 6MB/s — cap the upload so it can't saturate the uplink; empty = unthrottled
METRICS_FILE="${METRICS_FILE:-/var/lib/node_exporter/textfile/corebackup.prom}"

#=---- 0. Preflight: room for the dump to land ----
AVAIL_MB="$(df -Pm "$WORK_ROOT" | awk 'NR==2 {print $4}')"
if (( AVAIL_MB < MIN_FREE_MB )); then
  echo "FATAL: ${AVAIL_MB} MB free under ${WORK_ROOT}, need at least ${MIN_FREE_MB} (MIN_FREE_MB)" >&2
  exit 1
fi

WORK="$(mktemp -d "${WORK_ROOT}/corebackup.XXXXXX")"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
PREFIX="core/${STAMP}"

trap 'rm -rf "$WORK" "${WORK}.awscfg"' EXIT

#=---- 1. Mongo dump (gzip archive)
# Runs mongodump from a container so the host needs no Mongo tooling installed;
# pin the image tag to match the server's major version.
docker run --rm --network host \
  -v "$WORK:/dump" \
  mongo:6 \
  mongodump --uri "$MONGO_URI" --gzip --archive=/dump/deadline-mongo.archive.gz


#=---- 2. tarball(s) up!
# shellcheck disable=SC2086  # CONFIG_PATHS is a space-separated list, deliberately word-split
tar -czf "$WORK/configs.tar.gz" $CONFIG_PATHS 2>/dev/null || {
  echo "WARN: some config paths missing; archiving what exists" >&2
  # shellcheck disable=SC2086
  tar -czf "$WORK/configs.tar.gz" --ignore-failed-read $CONFIG_PATHS
}


#=---- 3. Checksum manifest
( cd "$WORK" && sha256sum ./*.gz ./*.archive.gz 2>/dev/null | tee manifest.sha256 )

#=---- 4. Upload ----
# The throttle rides in via a generated aws-cli config (there is no CLI flag or
# env var for s3.max_bandwidth), so it needs no persistent state on the host.
# The generated file replaces ~/.aws/config for this one command — region must
# come from the environment (AWS_DEFAULT_REGION, provisioned by the playbook).
if [[ -n "$MAX_BANDWIDTH" ]]; then
  printf '[default]\ns3 =\n  max_bandwidth = %s\n' "$MAX_BANDWIDTH" > "${WORK}.awscfg"
  AWS_CONFIG_FILE="${WORK}.awscfg" aws s3 cp "$WORK/" "s3://${BUCKET}/${PREFIX}/" --recursive --only-show-errors
else
  aws s3 cp "$WORK/" "s3://${BUCKET}/${PREFIX}/" --recursive --only-show-errors
fi

#=---- 5. Emit Prometheus metrics (node_exporter textfile collector)
# The variant label and per-variant file keep this script and the gateway one
# from clobbering each other if both ever run on a host; write-then-rename so
# the collector never scrapes a half-written file.
SIZE_BYTES=$(du -sb "$WORK" | cut -f1)
cat > "${METRICS_FILE}.tmp" <<EOF
# HELP corebackup_last_success_timestamp_seconds Unix time of last successful core backup.
# TYPE corebackup_last_success_timestamp_seconds gauge
corebackup_last_success_timestamp_seconds{variant="direct"} $(date +%s)
# HELP corebackup_last_size_bytes Size of last core backup payload.
# TYPE corebackup_last_size_bytes gauge
corebackup_last_size_bytes{variant="direct"} ${SIZE_BYTES}
EOF
mv "${METRICS_FILE}.tmp" "$METRICS_FILE"

echo "OK: ${PREFIX} (${SIZE_BYTES} bytes)"
