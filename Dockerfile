FROM debian:bookworm-slim

LABEL maintainer="mail-gateway"
LABEL description="One-container mail gateway: Postfix + SpamAssassin + RBL + SPF"

ENV DEBIAN_FRONTEND=noninteractive

# Install all components
RUN apt-get update && apt-get install -y --no-install-recommends \
    postfix \
    postfix-pcre \
    spamassassin \
    spamc \
    libmail-spf-perl \
    postfix-policyd-spf-perl \
    sa-update \
    rsyslog \
    ca-certificates \
    dnsutils \
    && rm -rf /var/lib/apt/lists/*

# SpamAssassin: update rules at build time
RUN sa-update --no-gpg || true

# Create config directory
RUN mkdir -p /config /var/log/mail-gateway /var/spool/postfix/pid

# Copy config files
COPY config/main.cf          /etc/postfix/main.cf
COPY config/master.cf        /etc/postfix/master.cf
COPY config/header_checks    /etc/postfix/header_checks
COPY config/body_checks      /etc/postfix/body_checks
COPY config/spamassassin.cf  /etc/spamassassin/local.cf
COPY config/virtual          /config/virtual
COPY scripts/entrypoint.sh   /entrypoint.sh
COPY scripts/spamfilter.sh   /usr/local/bin/spamfilter

RUN chmod +x /entrypoint.sh /usr/local/bin/spamfilter

# Postfix needs these dirs
RUN mkdir -p /var/spool/postfix/maildrop \
             /var/spool/postfix/incoming \
             /var/spool/postfix/active \
             /var/spool/postfix/deferred \
             /var/spool/postfix/bounce \
             /var/spool/postfix/defer \
             /var/spool/postfix/flush \
             /var/spool/postfix/hold \
             /var/spool/postfix/corrupt \
             /var/spool/postfix/private \
             /var/spool/postfix/public \
             /var/spool/postfix/saved

EXPOSE 25 587

VOLUME ["/config", "/var/log/mail-gateway"]

ENTRYPOINT ["/entrypoint.sh"]