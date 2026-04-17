#!/bin/bash
# =============================================================
#  spamfilter — Postfix content_filter pipe script
#
#  Called by Postfix as:
#    spamfilter <sender> <recipient> [<recipient> ...]
#
#  Flow:
#    stdin  → spamc (SpamAssassin client)  → re-inject via sendmail
# =============================================================

set -euo pipefail

SENDMAIL=/usr/sbin/sendmail
SPAMC=/usr/bin/spamc
LOGFILE=/var/log/mail-gateway/spamfilter.log
SPAM_SCORE_THRESHOLD=${SPAM_SCORE_THRESHOLD:-5}
SPAM_ACTION=${SPAM_ACTION:-tag}   # "tag" | "drop" | "quarantine"
QUARANTINE_DIR=/var/log/mail-gateway/quarantine

SENDER="$1"
shift
RECIPIENTS=("$@")

log() {
    echo "$(date '+%Y-%m-%d %T') [spamfilter] $*" >> "$LOGFILE"
}

# Read stdin into temp file (spamc needs it twice on some paths)
TMPFILE=$(mktemp /tmp/spamfilter.XXXXXX)
trap 'rm -f "$TMPFILE"' EXIT

cat > "$TMPFILE"

# ── Run SpamAssassin ──────────────────────────────────────────
SCANNED=$(mktemp /tmp/spamfilter-scanned.XXXXXX)
trap 'rm -f "$TMPFILE" "$SCANNED"' EXIT

$SPAMC -f < "$TMPFILE" > "$SCANNED"
SA_EXIT=$?

# Parse spam flag and score from headers
IS_SPAM=$(grep -m1 '^X-Spam-Flag:' "$SCANNED" | grep -qi 'YES' && echo yes || echo no)
SCORE=$(grep -m1 '^X-Spam-Status:' "$SCANNED" | grep -oP 'score=\K[0-9.]+' || echo "0")

log "sender=<$SENDER> recipients=<${RECIPIENTS[*]}> spam=$IS_SPAM score=$SCORE"

# ── Act on spam ───────────────────────────────────────────────
if [[ "$IS_SPAM" == "yes" ]]; then
    case "$SPAM_ACTION" in
        drop)
            log "ACTION=drop score=$SCORE"
            # Exit 0 = Postfix considers it delivered (silent drop)
            exit 0
            ;;
        quarantine)
            mkdir -p "$QUARANTINE_DIR"
            QFILE="$QUARANTINE_DIR/$(date +%Y%m%d-%H%M%S)-$$"
            cp "$SCANNED" "$QFILE"
            log "ACTION=quarantine file=$QFILE score=$SCORE"
            exit 0
            ;;
        tag|*)
            log "ACTION=tag (deliver with headers) score=$SCORE"
            ;;
    esac
fi

# ── Re-inject into Postfix on port 10025 ──────────────────────
$SENDMAIL -i \
    -f "$SENDER" \
    "${RECIPIENTS[@]}" \
    < "$SCANNED"

INJECT_EXIT=$?
if [[ $INJECT_EXIT -ne 0 ]]; then
    log "ERROR sendmail exit=$INJECT_EXIT"
    exit 75   # EX_TEMPFAIL — Postfix will retry
fi

exit 0
