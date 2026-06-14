# hcforms installer

One command turns a fresh Linux VM into a fully running hcforms deployment —
control plane + customer app + PostgreSQL + nginx/TLS. **No git, no source:** the
script pulls prebuilt images from ghcr.io and starts everything.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/skuzbucket1/hcforms/main/install.sh | sudo bash
```

With options (real TLS + real LLM):

```bash
curl -fsSL https://raw.githubusercontent.com/skuzbucket1/hcforms/main/install.sh \
  | sudo bash -s -- --domain forms.example.com --email you@example.com --anthropic-key sk-ant-...
```

Self-hosted model (Ollama / Qwen3 — keeps inference on your own box):

```bash
curl -fsSL https://raw.githubusercontent.com/skuzbucket1/hcforms/main/install.sh \
  | sudo bash -s -- --openai-base-url https://ollama.zipprofile.com/v1 --openai-key <KEY> --model qwen3:14b
```

When it finishes it prints your URLs and the generated control-plane admin
password. The default run uses **self-signed TLS + offline `mock` LLM**, so it
works on a bare IP with zero external dependencies.

LLM precedence: `--openai-base-url` → `openai`, else `--anthropic-key` →
`anthropic`, else `mock`.

## What it installs

A Docker Compose stack under `/opt/hcforms`, with data under `/var/hcforms`
(`pgdata/` + `files/` — the latter holds PHI):

| Service | Role |
|---|---|
| postgres (16) | one instance, two DBs: customer app + control plane |
| customer-api / customer-worker / customer-web | the end-user form app |
| control-plane | super-admin / ops UI + API |
| nginx | TLS termination + reverse proxy |
| certbot | Let's Encrypt renewal (only with `--domain`) |

Routing (role `all`): customer app at `https://<host>/`, control plane at
`https://<host>:8443/`.

## Options

| Flag | Default | Meaning |
|---|---|---|
| `--role all\|customer\|control-plane` | `all` | which planes to install |
| `--domain <fqdn>` / `--email <addr>` | — | enable Let's Encrypt TLS |
| `--host <ip-or-name>` | auto | host used for origins + self-signed cert |
| `--anthropic-key <key>` | — | use Anthropic for fills |
| `--openai-base-url <url>` | — | OpenAI-compatible endpoint (e.g. Ollama `https://host/v1`) → `openai` mode |
| `--openai-key <key>` | — | API key for the OpenAI-compatible endpoint |
| `--model <id>` | per-mode default | model id to use (e.g. `qwen3:14b`) |
| `--tag <tag>` | `latest` | image tag to pull |
| `--registry <ref>` | `ghcr.io/skuzbucket1/hcforms` | image namespace |
| `--registry-user` / `--registry-token` | — | auth for private images |
| `--customer-id <id>` | `local` | id stamped on the customer app |
| `--no-systemd` | | skip the boot-time service unit |
| `--build` | | build images from a source checkout instead of pulling |

## Requirements

- A fresh Debian/Ubuntu VM (apt/dnf), run as root, with outbound internet.
- Inbound `80`, `443`, and (role `all`) `8443` open at your cloud firewall.
- For `--domain`, point the DNS A record at the VM first (Let's Encrypt validates
  over HTTP); issuance falls back to self-signed if it can't reach the host.

## Day-2 operations

```bash
cd /opt/hcforms
docker compose ps                              # status
docker compose logs -f                         # logs
docker compose pull && docker compose up -d    # update to newer images
```

Re-running the installer is safe and idempotent (secrets and data preserved).

## Uninstall

```bash
sudo bash uninstall.sh           # stop, keep data
sudo bash uninstall.sh --purge   # stop and delete all data + PHI
```

---

*Maintainers:* images are built from the private source repo by GitHub Actions and
published to `ghcr.io/skuzbucket1/hcforms/*`. This repo holds only the installer.
