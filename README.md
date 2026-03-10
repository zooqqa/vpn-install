# 3x-ui VPN Server — Automated Installer

Fully automated script to deploy a **3x-ui** panel with SSL, network optimizations, and Cloudflare WARP.

## Features

- **Zero interaction** — runs start to finish without prompts
- **SSL certificate** — Let's Encrypt (with domain) or self-signed 10-year ECDSA (without domain)
- **TCP BBR** — Google's congestion control for better throughput
- **TCP tuning** — optimized buffer sizes, Fast Open, connection reuse
- **Fail2ban** — SSH brute-force protection
- **Cloudflare WARP** — SOCKS5 proxy for geo-unblocking (ChatGPT, Netflix, etc.)
- **Swap** — auto-created on low-RAM servers (< 1 GB)
- **Credentials saved** to `/root/3x-ui-credentials.txt`

## Requirements

- Ubuntu 20.04+ / Debian 11+
- Root access
- (Optional) Domain with A record pointing to server IP

## Usage

### With domain (Let's Encrypt)

Create an A record first: `nl1.example.com → server IP`, then:

```bash
sudo bash install.sh nl1.example.com
```

### Without domain (self-signed)

```bash
sudo bash install.sh
```

## Quick install (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/zooqqa/vpn-install/main/install.sh -o install.sh && sudo bash install.sh YOUR_DOMAIN
```

## WARP integration

After install, WARP runs as a SOCKS5 proxy on `127.0.0.1:40000`. To route specific traffic through WARP, add an outbound in the 3x-ui Xray config:

```json
{
  "tag": "warp",
  "protocol": "socks",
  "settings": {
    "servers": [{ "address": "127.0.0.1", "port": 40000 }]
  }
}
```

Then add routing rules for desired domains (e.g., `geosite:openai`, `geosite:netflix`).

## What it does (step by step)

1. Checks root permissions
2. Installs dependencies (openssl, curl, sqlite3, expect, certbot, fail2ban)
3. Creates swap if RAM < 1 GB
4. Enables BBR and applies TCP optimizations
5. Configures fail2ban for SSH
6. Installs 3x-ui non-interactively
7. Issues SSL certificate (Let's Encrypt or self-signed)
8. Writes certificate paths into 3x-ui database
9. Installs and configures Cloudflare WARP
10. Displays and saves panel credentials
