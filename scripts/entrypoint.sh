#!/bin/bash
# =============================================================
#  entrypoint.sh — Mail Gateway bootstrap
# =============================================================
set -euo pipefail

LOG=/var/log/mail-gateway/startup.log
mkdir -p /var/log/mail-gateway /config /var/lib/spamassassin/bayes

log() { echo "$(date '+%Y-%m-%d %T') [entrypoint] $*" | tee -a "$LOG"; }

# ── 1. Apply environment variable substitutions ───────────────
log "Applying environment config..."

MYHOSTNAME="${MYHOSTNAME:-mail.example.com}"
MYDOMAIN="${MYDOMAIN:-example.com}"
RELAYHOST="${RELAYHOST:-[127.0.0.1]:10025}"
RELAY_DOMAINS="${RELAY_DOMAINS:-example.com}"
TLS_CERT_FILE="${TLS_CERT_FILE:-/etc/ssl/certs/ssl-cert-snakeoil.pem}"
TLS_KEY_FILE="${TLS_KEY_FILE:-/etc/ssl/private/ssl-cert-snakeoil.key}"

sed -i "s|\${MYHOSTNAME:-mail.example.com}|$MYHOSTNAME|g" /etc/postfix/main.cf
sed -i "s|\${MYDOMAIN:-example.com}|$MYDOMAIN|g"           /etc/postfix/main.cf
sed -i "s|\${RELAYHOST:-\[127.0.0.1\]:10025}|$RELAYHOST|g" /etc/postfix/main.cf
sed -i "s|\${RELAY_DOMAINS:-example.com}|$RELAY_DOMAINS|g" /etc/postfix/main.cf
sed -i "s|\${TLS_CERT_FILE:-.*\.pem}|$TLS_CERT_FILE|g"     /etc/postfix/main.cf
sed -i "s|\${TLS_KEY_FILE:-.*\.key}|$TLS_KEY_FILE|g"       /etc/postfix/main.cf

# ── 2. Build virtual alias hash ───────────────────────────────
if [[ -f /config/virtual ]]; then
    log "Building virtual alias database..."
    postmap /config/virtual
else
    log "WARNING: /config/virtual not found — creating empty placeholder"
    touch /config/virtual
    postmap /config/virtual
fi

# ── 3. Fix Postfix directory permissions ──────────────────────
log "Fixing Postfix ownership..."
for dir in maildrop incoming active deferred bounce defer flush hold \
           corrupt private public saved; do
    mkdir -p "/var/spool/postfix/$dir"
done
chown -R root:root /var/spool/postfix
chown postfix:postfix \
    /var/spool/postfix/maildrop \
    /var/spool/postfix/public

# ── 4. Configure rsyslog → unified log file ───────────────────
log "Configuring rsyslog..."
cat > /etc/rsyslog.d/10-mail-gateway.conf << 'EOF'
# Mail gateway — write everything to a single log file
:programname, startswith, "postfix"   /var/log/mail-gateway/mail.log
:programname, startswith, "spamd"     /var/log/mail-gateway/mail.log
:programname, startswith, "postfix-policyd-spf-perl" /var/log/mail-gateway/mail.log
& stop
EOF

# ── 5. SpamAssassin daemon ────────────────────────────────────
log "Starting SpamAssassin (spamd)..."

# Create spamd user if missing
id spamd &>/dev/null || useradd -r -s /bin/false spamd
mkdir -p /var/lib/spamassassin/bayes
chown -R spamd:spamd /var/lib/spamassassin

SPAMD_BIN="$(command -v spamd || echo /usr/sbin/spamd)"

$SPAMD_BIN \
    --daemonize \
    --pidfile=/var/run/spamd.pid \
    --username=spamd \
    --helper-home-dir=/var/lib/spamassassin \
    --allowed-ips=127.0.0.1 \
    --syslog=yes \
    --max-children=5 \
    --nouser-config \
    --cf="required_score ${SPAM_SCORE_THRESHOLD:-5.0}"

log "spamd started (pid $(cat /var/run/spamd.pid 2>/dev/null || echo '?'))"

# ── 6. Start rsyslog ──────────────────────────────────────────
log "Starting rsyslog..."
rsyslogd

# ── 7. Virtual alias auto-reload watcher (optional) ───────────
if [[ "${AUTO_POSTMAP:-false}" == "true" ]]; then
    log "Starting virtual alias watcher..."
    (
        LAST_HASH=""
        while true; do
            sleep 10
            HASH=$(md5sum /config/virtual 2>/dev/null | cut -d' ' -f1)
            if [[ "$HASH" != "$LAST_HASH" ]]; then
                echo "$(date '+%Y-%m-%d %T') [watcher] virtual changed — reloading" \
                    >> /var/log/mail-gateway/startup.log
                postmap /config/virtual && postfix reload
                LAST_HASH="$HASH"
            fi
        done
    ) &
fi

# ── 8. Start Postfix ──────────────────────────────────────────
log "Starting Postfix ($MYHOSTNAME / relay_domains=$RELAY_DOMAINS)..."
postfix start

log "=== Mail gateway ready ==="
log "  SMTP:       port 25"
log "  Submission: port 587"
log "  Spam action: ${SPAM_ACTION:-tag} (threshold ${SPAM_SCORE_THRESHOLD:-5.0})"
log "  Log:        /var/log/mail-gateway/mail.log"

# ── 9. Tail log to stdout for 'docker logs' ───────────────────
touch /var/log/mail-gateway/mail.log
exec tail -F \
    /var/log/mail-gateway/mail.log \
    /var/log/mail-gateway/spamfilter.log \
    /var/log/mail-gateway/startup.log
