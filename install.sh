#!/bin/bash
set -euo pipefail

# ============================================================
#  3x-ui VPN Server — Automated Installer
#  Usage:
#    sudo ./install.sh                   # self-signed cert (IP)
#    sudo ./install.sh nl1.example.com   # Let's Encrypt cert
# ============================================================

DOMAIN="${1:-}"
CERT_DIR="/etc/x-ui/certs"
CRED_FILE="/root/3x-ui-credentials.txt"
DB_PATH="/etc/x-ui/x-ui.db"
LOG_FILE="/tmp/3x_ui_install.log"
WARP_SOCKS_PORT=40000

# ─── Colors ──────────────────────────────────────────────────
R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'
C='\033[0;36m'  B='\033[1m'     N='\033[0m'

info()  { echo -e "${C}[INFO]${N}  $*"; }
ok()    { echo -e "${G}[OK]${N}    $*"; }
warn()  { echo -e "${Y}[WARN]${N}  $*"; }
fail()  { echo -e "${R}[FAIL]${N}  $*"; exit 1; }

# ─── 1. Root check ──────────────────────────────────────────
[[ "$EUID" -eq 0 ]] || fail "Run this script as root: sudo ./install.sh"

# ─── 2. Already installed — show creds & exit ───────────────
if [[ -f /usr/local/x-ui/x-ui && -f "$DB_PATH" ]]; then
    info "3x-ui is already installed. Reading credentials from DB..."

    USER_DB=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='username';" 2>/dev/null || true)
    PASS_DB=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='password';" 2>/dev/null || true)
    PORT_DB=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='port';" 2>/dev/null || true)
    [[ -z "$PORT_DB" || ! "$PORT_DB" =~ ^[0-9]+$ ]] && PORT_DB=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null || true)
    PATH_DB=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null || true)

    IP_ADDR=$(curl -s --max-time 5 ifconfig.me || echo "unknown")
    PATH_CLEAN=$(echo "$PATH_DB" | tr -d '"/')
    PANEL_HOST="${DOMAIN:-$IP_ADDR}"

    echo ""
    echo -e "${B}═══════════════════════════════════════════════════════${N}"
    echo -e "${B}  3x-ui is already installed. Panel credentials:      ${N}"
    echo -e "${B}═══════════════════════════════════════════════════════${N}"
    echo -e "  User:  ${B}${USER_DB}${N}"
    echo -e "  Pass:  ${B}${PASS_DB}${N}"
    echo -e "  Port:  ${Y}${PORT_DB}${N}"
    echo -e "  Path:  /${PATH_CLEAN}/"
    echo -e "  URL:   ${G}https://${PANEL_HOST}:${PORT_DB}/${PATH_CLEAN}/${N}"
    echo -e "${B}═══════════════════════════════════════════════════════${N}"
    echo ""
    exit 0
fi

# ─── 3. Install dependencies ────────────────────────────────
info "Installing dependencies..."
apt-get update -qq
apt-get install -y -qq expect curl sqlite3 openssl fail2ban \
    gnupg lsb-release dnsutils > /dev/null 2>&1
ok "Dependencies installed"

# ─── 4. Swap (if RAM < 1 GB and no swap exists) ─────────────
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
SWAP_TOTAL_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')

if [[ "$TOTAL_RAM_KB" -lt 1048576 && "$SWAP_TOTAL_KB" -lt 524288 ]]; then
    info "Low RAM detected ($(( TOTAL_RAM_KB / 1024 )) MB). Creating 1 GB swap..."
    fallocate -l 1G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Swap created"
else
    ok "RAM/Swap sufficient, skipping swap creation"
fi

# ─── 5. Enable BBR & TCP optimizations ──────────────────────
info "Applying network optimizations (BBR + TCP tuning)..."

SYSCTL_CONF="/etc/sysctl.d/99-vpn-optimize.conf"
cat > "$SYSCTL_CONF" << 'SYSCTL'
# BBR congestion control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# TCP buffer sizes
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 87380 16777216

# Connection handling
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.core.somaxconn=65535
net.core.netdev_max_backlog=65535

# Misc
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_window_scaling=1
SYSCTL

sysctl -p "$SYSCTL_CONF" > /dev/null 2>&1
ok "BBR enabled, TCP stack optimized"

# ─── 6. Fail2ban for SSH ────────────────────────────────────
info "Configuring fail2ban for SSH..."

cat > /etc/fail2ban/jail.d/sshd.conf << 'F2B'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 3600
findtime = 600
F2B

systemctl enable fail2ban > /dev/null 2>&1
systemctl restart fail2ban > /dev/null 2>&1
ok "Fail2ban configured for SSH"

# ─── 7. Install 3x-ui via expect ────────────────────────────
info "Installing 3x-ui (non-interactive)..."
> "$LOG_FILE"

expect <<'EXPECT_SCRIPT' | tee -a "$LOG_FILE"
set timeout 300
spawn bash -c "bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"
expect {
    -re {y/n|Y/N|y\|n} { send "y\r"; exp_continue }
    -re {press Enter|Press ENTER|ENTER} { send "\r"; exp_continue }
    timeout { }
    eof { }
}
EXPECT_SCRIPT

sleep 3

if [[ ! -f /usr/local/x-ui/x-ui ]]; then
    fail "3x-ui installation failed. Check $LOG_FILE"
fi
ok "3x-ui installed"

# ─── 8. Extract credentials ─────────────────────────────────
info "Extracting panel credentials..."

USER_EXT=""
PASS_EXT=""
PORT_EXT=""
PATH_EXT=""

if [[ -f "$DB_PATH" ]]; then
    USER_EXT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='username';" 2>/dev/null || true)
    PASS_EXT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='password';" 2>/dev/null || true)
    PORT_EXT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='port';" 2>/dev/null || true)
    [[ -z "$PORT_EXT" || ! "$PORT_EXT" =~ ^[0-9]+$ ]] && PORT_EXT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null || true)
    PATH_EXT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null || true)
fi

if [[ -z "$USER_EXT" || -z "$PASS_EXT" ]]; then
    USER_EXT=$(grep "Username:" "$LOG_FILE" | tail -1 | awk '{print $NF}' | tr -d '\r')
    PASS_EXT=$(grep "Password:" "$LOG_FILE" | tail -1 | awk '{print $NF}' | tr -d '\r')
fi

if [[ ! "$PORT_EXT" =~ ^[0-9]+$ ]]; then
    PORT_EXT=$(grep -E "Port:[[:space:]]+[0-9]+" "$LOG_FILE" | tail -1 | awk '{print $NF}' | tr -d '\r')
fi

if [[ -z "$PATH_EXT" ]]; then
    PATH_EXT=$(grep "WebBasePath:" "$LOG_FILE" | tail -1 | awk '{print $NF}' | tr -d '\r')
fi

IP_ADDR=$(curl -s --max-time 5 ifconfig.me || echo "unknown")
PATH_CLEAN=$(echo "$PATH_EXT" | tr -d '"/')

rm -f "$LOG_FILE"

# ─── 9. SSL certificate ─────────────────────────────────────
mkdir -p "$CERT_DIR"

if [[ -n "$DOMAIN" ]]; then
    # ── Let's Encrypt via certbot ──
    info "Domain provided: $DOMAIN"
    info "Checking DNS resolution..."

    RESOLVED_IP=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | tail -1)
    if [[ "$RESOLVED_IP" != "$IP_ADDR" ]]; then
        warn "DNS A record for $DOMAIN resolves to '$RESOLVED_IP', server IP is '$IP_ADDR'"
        warn "Waiting up to 120s for DNS propagation..."

        for i in $(seq 1 12); do
            sleep 10
            RESOLVED_IP=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | tail -1)
            if [[ "$RESOLVED_IP" == "$IP_ADDR" ]]; then
                break
            fi
        done

        if [[ "$RESOLVED_IP" != "$IP_ADDR" ]]; then
            warn "DNS not resolved yet. Falling back to self-signed certificate."
            DOMAIN=""
        fi
    fi
fi

if [[ -n "$DOMAIN" ]]; then
    info "Issuing Let's Encrypt certificate for $DOMAIN..."
    apt-get install -y -qq certbot > /dev/null 2>&1

    # Temporarily stop 3x-ui if it occupies port 80
    systemctl stop x-ui 2>/dev/null || true

    if certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email \
        -d "$DOMAIN" 2>/dev/null; then

        CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

        sqlite3 "$DB_PATH" "DELETE FROM settings WHERE key IN ('webCertFile','webKeyFile');"
        sqlite3 "$DB_PATH" "INSERT INTO settings (key, value) VALUES ('webCertFile','$CERT_PATH'), ('webKeyFile','$KEY_PATH');"

        # Auto-renewal cron + restart 3x-ui after renewal
        cat > /etc/letsencrypt/renewal-hooks/deploy/restart-x-ui.sh << 'HOOK'
#!/bin/bash
systemctl restart x-ui
HOOK
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-x-ui.sh

        systemctl start x-ui
        ok "Let's Encrypt certificate issued for $DOMAIN (auto-renewing)"
        SSL_INFO="Let's Encrypt — $DOMAIN (auto-renewal via certbot)"
    else
        warn "Certbot failed. Falling back to self-signed certificate."
        DOMAIN=""
        systemctl start x-ui
    fi
fi

if [[ -z "$DOMAIN" ]]; then
    # ── Self-signed (10 years, ECDSA) ──
    info "Generating self-signed certificate (10 years, ECDSA)..."

    openssl req -x509 -nodes -days 3650 \
        -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$CERT_DIR/private.key" \
        -out "$CERT_DIR/cert.pem" \
        -subj "/CN=${IP_ADDR}" > /dev/null 2>&1

    sqlite3 "$DB_PATH" "DELETE FROM settings WHERE key IN ('webCertFile','webKeyFile');"
    sqlite3 "$DB_PATH" "INSERT INTO settings (key, value) VALUES ('webCertFile','$CERT_DIR/cert.pem'), ('webKeyFile','$CERT_DIR/private.key');"

    ok "Self-signed certificate generated (valid 10 years)"
    SSL_INFO="Self-signed — $CERT_DIR/cert.pem (10 years)"
fi

systemctl restart x-ui
sleep 2

# ─── 10. Cloudflare WARP ────────────────────────────────────
info "Installing Cloudflare WARP..."

WARP_OK=false

if curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg 2>/dev/null \
    | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null; then

    CODENAME=$(lsb_release -cs 2>/dev/null || echo "focal")
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $CODENAME main" \
        > /etc/apt/sources.list.d/cloudflare-client.list

    apt-get update -qq > /dev/null 2>&1

    if apt-get install -y -qq cloudflare-warp > /dev/null 2>&1; then
        # Wait for warp-svc to start
        sleep 2

        if warp-cli registration new 2>/dev/null; then
            warp-cli mode proxy 2>/dev/null || true
            warp-cli proxy port "$WARP_SOCKS_PORT" 2>/dev/null || true
            warp-cli connect 2>/dev/null || true
            sleep 2

            if warp-cli status 2>/dev/null | grep -qi "connected"; then
                WARP_OK=true
                ok "WARP installed — SOCKS5 proxy on 127.0.0.1:${WARP_SOCKS_PORT}"
            else
                warn "WARP installed but failed to connect"
            fi
        else
            warn "WARP registration failed"
        fi
    else
        warn "WARP package install failed (OS may not be supported)"
    fi
else
    warn "Could not fetch WARP GPG key — skipping WARP"
fi

# ─── 11. Build panel URL ────────────────────────────────────
PANEL_HOST="${DOMAIN:-$IP_ADDR}"
PANEL_URL="https://${PANEL_HOST}:${PORT_EXT}/${PATH_CLEAN}/"

# ─── 12. Save credentials ───────────────────────────────────
cat > "$CRED_FILE" << CREDS
# 3x-ui Panel Credentials
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# ──────────────────────────────
Username: ${USER_EXT}
Password: ${PASS_EXT}
Port:     ${PORT_EXT}
Path:     /${PATH_CLEAN}/
URL:      ${PANEL_URL}
SSL:      ${SSL_INFO}
WARP:     $(if $WARP_OK; then echo "Active — SOCKS5 127.0.0.1:${WARP_SOCKS_PORT}"; else echo "Not active"; fi)
Server IP: ${IP_ADDR}
CREDS
chmod 600 "$CRED_FILE"

# ─── 13. Final output ───────────────────────────────────────
echo ""
echo -e "${B}═══════════════════════════════════════════════════════════${N}"
echo -e "${B}        INSTALLATION COMPLETE                             ${N}"
echo -e "${B}═══════════════════════════════════════════════════════════${N}"
echo -e "  User:     ${B}${USER_EXT}${N}"
echo -e "  Password: ${B}${PASS_EXT}${N}"
echo -e "  Port:     ${Y}${PORT_EXT}${N}"
echo -e "  Path:     /${PATH_CLEAN}/"
echo -e "  URL:      ${G}${PANEL_URL}${N}"
echo -e "${B}───────────────────────────────────────────────────────────${N}"
echo -e "  SSL:      ${C}${SSL_INFO}${N}"
if $WARP_OK; then
echo -e "  WARP:     ${G}Active — SOCKS5 127.0.0.1:${WARP_SOCKS_PORT}${N}"
else
echo -e "  WARP:     ${Y}Not active${N}"
fi
echo -e "${B}───────────────────────────────────────────────────────────${N}"
echo -e "  Credentials saved to: ${C}${CRED_FILE}${N}"
echo -e "${B}═══════════════════════════════════════════════════════════${N}"
echo ""

if $WARP_OK; then
    echo -e "${C}[TIP]${N} To route traffic through WARP, add a SOCKS5 outbound"
    echo -e "      in 3x-ui Xray config: 127.0.0.1:${WARP_SOCKS_PORT}"
    echo ""
fi

echo -e "${C}[TIP]${N} When you create inbounds on custom ports, no firewall"
echo -e "      rules are needed — all ports are open by default."
echo ""
