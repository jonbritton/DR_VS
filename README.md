# DR_VS

### A disaster recovery strategy in 3 acts.
directed by Jon Britton

Automated, encrypted, off-site backup of a VFX studio's **production core** — the small set
of stateful things that kill a facility when lost — paired with an **automated, drillable
restore**. The thesis: *an untested backup is only a hypothesis.* This repo ships the backup,
the restore, the monitoring that proves the backup keeps happening, and the practice of
rehearsing the restore on a schedule with a measured RTO.

The worked example targets a [Thinkbox Deadline](https://www.awsthinkbox.com/deadline) render
farm (MongoDB repository + config trees), but the patterns are domain-agnostic: a stateful
database plus hand-curated configs, backed up immutably with write-only credentials, restored
by one automated code path.

> **Patterns over specifics.** Paths, service names, and the exact contents of the "production
> core" are illustrative and will differ in a real facility. The fixed parts are the *patterns*:
> immutable versioned backups, write-only credentials, checksummed manifests, an automated
> restore, and a drill that produces a timed log. See [`docs/pri/DR-Production-core.md`](docs/pri/DR-Production-core.md)
> for the full design rationale.

---

## What it does

```
on-prem core                    AWS
┌──────────────────┐
│ Deadline Repo    │  backup    ┌─────────────────────────────┐
│  - MongoDB       │ ─timer──▶  │ S3 (versioned, SSE,         │
│  - repo settings │            │ lifecycle → IA → Deep Arch) │
│ pipeline configs │            └──────────┬──────────────────┘
└────────┬─────────┘                       │ restore (Ansible)
         │ metrics                          ▼
         ▼                          scratch VM / container
   Prometheus ──▶ Alertmanager      (quarterly timed drill)
   ("backup stale")
```

1. **Nightly backup** (`dr/core-backup.sh`, run by a systemd timer): `mongodump` of the
   Deadline repository DB + tarball of config trees + a `sha256` manifest, uploaded to a
   timestamped S3 prefix (`core/<UTC-stamp>/`). It also writes a Prometheus text-file metric.
2. **Immutable destination** (`terraform/modules/dr-bup/`): a versioned, encrypted, private S3
   bucket with lifecycle tiering, plus a **write-only** IAM policy so the backup host can put
   and list but never delete — the thing doing backups cannot destroy them.
3. **Automated restore** (`ansible/core-restore.yml`): fetches a chosen snapshot, verifies
   checksums *before touching anything*, restores Mongo and configs, restarts services, and
   validates that the DB came back with data.
4. **Monitoring** (`prometheus/rules/dr.yml`): alerts when a backup is stale (>26h) or
   suspiciously small (<50% of its 7-day average — the silent "a source path got hosed" failure).
5. **CI** (`.github/workflows/core-lint.yaml`): shellcheck + ansible-lint on every PR that
   touches `dr/` or `ansible/`.

---

## Repository layout

```
dr/
  core-backup.sh         # the backup job (bash + Docker)
  core-backup.service    # systemd oneshot unit
  core-backup.timer      # nightly schedule (02:30 UTC + jitter)
ansible/
  core-backup.yml        # deploy the backup to the repo host
  core-restore.yml       # restore / drill playbook
terraform/modules/dr-bup/
  main.tf                # S3 bucket: versioning, SSE, lifecycle, public-access block
  vars.tf                # write-only backup IAM policy
prometheus/rules/dr.yml  # staleness + shrink alerts
.github/workflows/core-lint.yaml
docs/pri/DR-Production-core.md   # full design doc + rationale
```

---

## Prerequisites

**On the backup/restore host (the Deadline repository server):**

- Linux with **systemd** (for the timer-driven backup)
- **Docker** — `mongodump`/`mongorestore`/`mongosh` run from the `mongo:6` image, so no Mongo
  client tooling is installed on the host. Pin the image tag to your server's major version.
- **AWS CLI v2**, configured with credentials that map to the IAM policies below
- **node_exporter** with the [textfile collector](https://github.com/prometheus/node_exporter#textfile-collector)
  enabled, reading `/var/lib/node_exporter/textfile/` (this is where the backup metric lands)
- Network reachability to the Mongo URI (default `mongodb://localhost:27017`) and to S3

**On the control machine (where you run deployments):**

- **Terraform** + an AWS account/credentials able to create S3 buckets and IAM policies
- **Ansible** with an inventory that defines a `deadline_repo` host group
- SSH access (with `become`/sudo) to the target hosts

**AWS-side:**

- An IAM identity for the **backup** host carrying the write-only policy from
  `terraform/modules/dr-bup/vars.tf` (`s3:PutObject` + `s3:ListBucket`, no delete/overwrite).
- A separate **restore** identity with `s3:GetObject` + `s3:ListBucket` — read and write are
  deliberately different credentials. (Production-grade path: IAM Roles Anywhere for short-lived
  credentials with no static keys on disk; the simple path is a scoped IAM user access key.)

---

## How it works

### 1. Provision the destination (Terraform)

The `dr-bup` module creates the backup bucket and the write-only IAM policy:

```bash
cd terraform
# wire the module into a root config, then:
terraform init
terraform apply \
  -var 'name_prefix=render-farm-dev' \
  -var 'account_id=058264204697'
# outputs: bucket = render-farm-dev-dr-058264204697
```

What the module enforces:

- **Versioning** — overwrites/deletes create new versions instead of destroying history
  (ransomware / fat-finger protection).
- **SSE (AES256)** at rest and a full **public-access block**.
- **Lifecycle** — objects → `STANDARD_IA` at 30 days, → `DEEP_ARCHIVE` at 90; noncurrent
  versions expire after 180 days; incomplete multipart uploads abort after 7.

### 2. Deploy the backup job (Ansible)

`ansible/core-backup.yml` installs the script, writes `/etc/core-backup.env`, drops the
systemd units, enables the timer, and fires one backup immediately as a smoke test:

```bash
ansible-playbook ansible/core-backup.yml \
  -e dr_bucket=render-farm-dev-dr-058264204697 \
  -e mongo_uri=mongodb://localhost:27017
```

The timer (`core-backup.timer`) runs nightly at **02:30 UTC** with up to 15 min of jitter and
`Persistent=true`, so a backup missed while the host was down runs at next boot. Unit
success/failure is visible via `systemctl status core-backup.service` and the journal.

**What the backup script does** (`dr/core-backup.sh`), configured via `/etc/core-backup.env`:

| Var | Default | Purpose |
|---|---|---|
| `BUCKET` | *(required)* | Destination S3 bucket |
| `MONGO_URI` | `mongodb://localhost:27017` | Deadline repository DB |
| `CONFIG_PATHS` | `/opt/Thinkbox/DeadlineRepository10/settings /etc/pipeline` | Space-separated config trees to tar |
| `METRICS_FILE` | `/var/lib/node_exporter/textfile/drbackup.prom` | Where the Prometheus metric is written |

Steps per run: (1) `mongodump --gzip --archive` via the `mongo:6` container → (2) `tar -czf`
the config paths (tolerating missing paths) → (3) `sha256sum` manifest → (4) `aws s3 cp` the
whole working dir to `s3://$BUCKET/core/<UTC-stamp>/` → (5) emit `last_success_timestamp` and
`last_size_bytes` gauges for node_exporter.

### 3. Restore (Ansible) — and drill it

`ansible/core-restore.yml` is the RTO machine. It resolves the snapshot (a timestamp prefix,
or `latest`), downloads it, **verifies checksums and aborts on mismatch**, stops the Deadline
launcher, `mongorestore --drop`s the DB, unpacks the config tarball, restarts the service, and
validates that the Jobs DB has collections.

Real restore (defaults to the `deadline_repo` host, latest snapshot):

```bash
ansible-playbook ansible/core-restore.yml \
  -e dr_bucket=render-farm-dev-dr-058264204697 \
  -e backup_id=latest          # or e.g. 20260605T023000Z
```

The **drill** is the same playbook pointed at a throwaway target — one code path, rehearsed
and real:

```bash
ansible-playbook ansible/core-restore.yml \
  -e restore_target=drill_host \
  -e dr_bucket=render-farm-dev-dr-058264204697 \
  -e backup_id=latest
```

Run it quarterly, timed, into a scratch VM/container; record the result (measured RTO, any
issues found) in a dated drill log committed to the repo. That log — a timestamp trail with a
measured RTO — is the project's most credible artifact: *"I don't have backups; I have
restores."*

### 4. Monitoring

The text-file metric is scraped by node_exporter; `prometheus/rules/dr.yml` carries two alerts:

- **`DRBackupStale`** (critical) — no successful backup in >26h.
- **`DRBackupShrunk`** (warning) — latest backup <50% of its 7-day average size, catching the
  "succeeded but produced nothing" failure that staleness alerts miss.

---

## Targets

- **RPO 24h** — one nightly backup is sufficient; run the Mongo dump more often if a day of
  queue state is too much to lose (the design doesn't change).
- **RTO 60 min** — restore is automated, not a manual runbook. The drill log proves the number.

## Cost

Order of magnitude cheaper than the rest of a DR program: roughly **$1–3/month** of S3 for
config-scale nightly backups (~1–2 GB) with 180-day retention; Deep Archive ~$1/TB-month for
the >90-day tier; ~$0.10 per quarterly drill VM. IAM, lifecycle, and alerts are free.

---

## Variant: S3 File Gateway → Glacier Deep Archive

A second egress path lives alongside the direct-to-S3 one. Instead of `aws s3 cp`, the backup
host writes its files to an NFS share exported by an **AWS S3 File Gateway**; the gateway
uploads them to the same DR bucket and the existing lifecycle tiers older snapshots into
**Glacier Deep Archive**. Use it when you want a POSIX file mount on the backup host rather
than an SDK/CLI upload.

- Files: `dr/core-backup-gw.{sh,service,timer}`, `ansible/core-backup-gw.yml`,
  `ansible/core-restore-gw.yml`, `terraform/modules/storage-gateway/`.
- Two trade-offs to know before choosing it: the gateway IAM role can delete objects (so
  immutability shifts from a write-only principal to bucket **Versioning + S3 Object Lock**),
  and a snapshot that has aged into Deep Archive is not readable through the share until it is
  thawed — **up to ~12 h** — so this fits long-tail retention, not fast restore of old
  snapshots. The newest snapshot stays in Standard and restores in minutes.
- Full write-up: [`docs/pri/DR-Storage-Gateway.md`](docs/pri/DR-Storage-Gateway.md).

---

## Known caveat

The backup script emits metrics named `drbackup_last_success_timestamp_seconds` and
`drbackup_last_size_bytes` (`dr/core-backup.sh`), but the alert rules in
`prometheus/rules/dr.yml` query `corebackup_last_success_timestamp_seconds` /
`corebackup_last_size_bytes`. The names must match for the alerts to evaluate — align them
(in one file or the other) before relying on the monitoring.

## Cleanup

The bucket only costs storage. To remove it: empty it **including all versions**
(`aws s3api delete-objects` over the version list, or a temporary expire-everything lifecycle
rule), then `terraform destroy` the module.
