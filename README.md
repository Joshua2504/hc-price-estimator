# Hetzner Cloud Price & Snapshot Tools

Small, dependency-light Bash tools for Hetzner Cloud projects:

- `hc-cost-estimator.sh` — estimates your monthly Hetzner Cloud costs using live pricing and your current resources.
- `hc-snapshot-all.sh` — triggers snapshots for every server in your project (with optional wait/force/dry-run).


## Prerequisites

- Bash 4+
- `curl`
- `jq`

Install `jq` quickly:

- macOS: `brew install jq`
- Ubuntu/Debian: `sudo apt-get update && sudo apt-get install -y jq`


## Authentication

Both scripts use the Hetzner Cloud API and require a personal access token with access to your project.

You can provide the token via either:

- Environment variable at runtime: `HCLOUD_TOKEN=... ./hc-cost-estimator.sh`
- A dotenv file placed next to the scripts: create `.env` containing `HCLOUD_TOKEN=...`

There is an example at `.env.example`.

Advanced: You can point scripts to a specific env file by setting `HC_PRICE_ENV_FILE` to a path. Example: `HC_PRICE_ENV_FILE=~/secrets/hcloud.env ./hc-cost-estimator.sh`.


## Cost Estimator

Script: `./hc-cost-estimator.sh`

What it does

- Fetches live pricing from Hetzner Cloud `/pricing`.
- Sums up your current project resources.
- Prints a total and a per-resource breakdown.
- Supports net (default) and gross (incl. VAT) pricing.

Included in the estimate

- Servers (by server type and location)
- Optional server backups (+20% of the server’s monthly price when backups are enabled)
- Volumes (per-GB per month)
- Load balancers (by type and location)
- Primary IPs (IPv4 and IPv6)
- Snapshots (per-GB per month)

Not included

- Traffic overages
- Object Storage (not currently queried)

Usage

- Net pricing (default): `HCLOUD_TOKEN=... ./hc-cost-estimator.sh`
- Gross pricing (incl. VAT): `HCLOUD_TOKEN=... ./hc-cost-estimator.sh --gross`

Example output (format)

```
Hetzner Cloud Monthly Cost Estimate (NET (excl. VAT))
===========================================
Servers:                   12.34 €
  Backups (20%):            2.47 €
Volumes:                    4.00 €  (Total size: 200 GB @ 0.02/GB)
Load Balancers:             5.00 €
Primary IPs:                1.20 €  (2 IPv4, 3 IPv6)
Snapshots:                  0.80 €  (Total size: 40 GB @ 0.02/GB)
-------------------------------------------
TOTAL:                     25.81 €

Per-Resource Costs
------------------
Servers (2):
  - app-1:     5.50 € (backup +1.10 €)
  - db-1:      6.84 €

Volumes (3):
  - data-1 (50 GB):  1.00 €
  - data-2 (100 GB): 2.00 €
  - logs (50 GB):    1.00 €

Load Balancers (1):
  - lb-app:    5.00 €

Primary IPs (5):
  - 203.0.113.10 (ipv4): 0.60 €
  - 2001:db8::1 (ipv6):  0.00 €

Snapshots (2):
  - snapshot-2025-09-24-app (20 GB): 0.40 €
  - snapshot-2025-09-24-db (20 GB):  0.40 €
```

Notes

- If a location-specific price is unavailable, the script falls back to the first listed price for the type.
- Currency is displayed as reported by the Hetzner API (typically Euros).


## Snapshot All Servers

Script: `./hc-snapshot-all.sh`

What it does

- Iterates over all servers in your project and triggers a snapshot action for each.
- Can optionally wait for each snapshot to complete.
- Supports a description prefix to make snapshots easy to find.
- Supports a dry-run mode to preview actions without calling the API.

Usage

```
HCLOUD_TOKEN=... ./hc-snapshot-all.sh [--wait] [--force] [--prefix PREFIX] [--dry-run]
```

Options

- `--wait` — wait for each snapshot action to finish (polls the action until `success` or `error`).
- `--force` — pass `force: true` to the snapshot action (use with care).
- `--prefix PREFIX` — set the snapshot description prefix (default: `snapshot-YYYY-MM-DD-`).
- `--dry-run` — print intended actions without calling the API.
- `-h`, `--help` — show inline help.

Examples

- Preview without executing: `HCLOUD_TOKEN=... ./hc-snapshot-all.sh --dry-run`
- Snapshot now and wait: `HCLOUD_TOKEN=... ./hc-snapshot-all.sh --wait`
- Custom prefix: `HCLOUD_TOKEN=... ./hc-snapshot-all.sh --prefix nightly-`

Permissions

- If you receive `403` errors, ensure your token has write permissions for the project.


## Environment & Secrets

- Do not commit real tokens. The repo’s `.gitignore` already ignores `.env`.
- Use `.env.example` as a template and keep your actual `.env` private.
- You can also export `HCLOUD_TOKEN` in your shell profile if you prefer.


## Troubleshooting

- `command not found: jq` — install `jq` (see prerequisites).
- `Error: Please export HCLOUD_TOKEN first` — set `HCLOUD_TOKEN` in your environment or `.env`.
- `403` on snapshot actions — your token likely lacks write permissions or project scope.
- Empty results — check that your token targets the correct project; consider project-level tokens.
- Rate limits/transient API errors — rerun later; the scripts use straightforward API calls via `curl`.


## Development Notes

- Both scripts are POSIX-friendly Bash with `set -euo pipefail` and lean on `jq` for JSON parsing.
- No external CLI (e.g., `hcloud`) is required; everything goes through the REST API.

