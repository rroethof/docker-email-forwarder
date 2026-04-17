# 📬 Mail Gateway — one-container

Een productie-klare mail gateway in één Docker-container.

| Component | Functie |
|---|---|
| **Postfix** | SMTP ontvangst (25) + Submission (587) + forwarding |
| **SpamAssassin** | Score-based spam filtering (spamd + spamc) |
| **RBL** | Spamhaus ZEN, SpamCop, Barracuda — afgewezen op SMTP-niveau |
| **SPF** | `postfix-policyd-spf-perl` — policy check vóór DATA |
| **Virtual aliases** | Bestandsgebaseerd via `/config/virtual` |
| **Logging** | Alles naar `/var/log/mail-gateway/mail.log` + docker logs |

---

## Mailflow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        INKOMENDE MAIL                               │
└─────────────────────────────────────────────────────────────────────┘

  Internet
     │
     ▼  TCP :25 (SMTP) of :587 (Submission)
  ┌──────────────────────────────────────────┐
  │  Postfix smtpd — verbindingsfase         │
  │                                          │
  │  1. HELO/EHLO validatie                  │
  │     → reject_invalid_helo_hostname       │
  │     → reject_non_fqdn_helo_hostname      │
  │                                          │
  │  2. MAIL FROM validatie                  │
  │     → reject_non_fqdn_sender             │
  │     → reject_unknown_sender_domain       │
  │                                          │
  │  3. RCPT TO — RBL checks  ◄──────────────┼─── zen.spamhaus.org
  │     → reject_rbl_client        (IP-check)│    bl.spamcop.net
  │                                          │    b.barracudacentral.org
  │  4. RCPT TO — SPF policy check           │
  │     → postfix-policyd-spf-perl           │
  │        FAIL    → 550 rejected            │
  │        SOFTFAIL → header toegevoegd      │
  │        PASS    → doorgaan                │
  │                                          │
  │  5. DATA — header/body PCRE checks       │
  │     → reject_unauth_pipelining           │
  │     → header_checks (exe-bijlagen, etc.) │
  │     → body_checks   (binary payloads)    │
  └─────────────────┬────────────────────────┘
                    │ mail geaccepteerd
                    ▼
  ┌──────────────────────────────────────────┐
  │  content_filter: spamfilter pipe         │
  │                                          │
  │  spamfilter.sh → spamc → spamd           │
  │                                          │
  │  SpamAssassin beoordeelt:                │
  │  • Bayes classifier                      │
  │  • Header-analyse                        │
  │  • URI-blacklists (DBL, URIBL)           │
  │  • Score opgebouwd uit tientallen tests  │
  │                                          │
  │  Score < threshold (5.0)?                │
  │     → X-Spam-Status: No  (schoon)        │
  │  Score ≥ threshold?                      │
  │     → X-Spam-Flag: YES                   │
  │        SPAM_ACTION=tag        ──────────►│ bezorgen met [SPAM] header
  │        SPAM_ACTION=drop       ──────────►│ stilletjes weggooien
  │        SPAM_ACTION=quarantine ──────────►│ opslaan in /quarantine/
  └─────────────────┬────────────────────────┘
                    │ schone mail (of getagde spam bij 'tag')
                    ▼
  ┌──────────────────────────────────────────┐
  │  Re-injectie op poort 10025              │
  │  (content_filter omzeild, alleen relay)  │
  │                                          │
  │  virtual alias lookup                    │
  │    /config/virtual (hash-tabel)          │
  │    info@example.com → helpdesk@intern    │
  └─────────────────┬────────────────────────┘
                    │
                    ▼
            RELAYHOST (jouw interne MTA / IMAP-server)
```

### Waar wordt wat geblokkeerd?

| Fase | Check | Geblokkeerd wegens |
|---|---|---|
| Verbinding | RBL (Spamhaus/SpamCop) | Bekend spam-IP |
| RCPT TO | SPF FAIL | Afzenderdomein niet geautoriseerd |
| DATA | header_checks PCRE | Executable bijlage, verdacht header |
| DATA | body_checks PCRE | Binary payload in body |
| Content filter | SpamAssassin score | Score ≥ threshold |

---

## Snel starten

```bash
# 1. Clone / kopieer de bestanden
git clone <repo> mail-gateway && cd mail-gateway

# 2. Pas aan
cp config/virtual config/virtual.local
#   edit config/virtual, docker-compose.yml (MYHOSTNAME, MYDOMAIN, RELAYHOST)

# 3. Bouwen + starten
docker compose up -d --build

# 4. Logs bekijken
docker compose logs -f
```

---

## Structuur

```
mail-gateway/
├── Dockerfile
├── docker-compose.yml
├── config/
│   ├── main.cf              # Postfix hoofdconfig
│   ├── master.cf            # Postfix services
│   ├── header_checks        # PCRE header filters
│   ├── body_checks          # PCRE body filters
│   ├── spamassassin.cf      # SA local.cf
│   └── virtual              # ← HIER aliassen bewerken
└── scripts/
    ├── entrypoint.sh        # Container bootstrap
    └── spamfilter.sh        # SA pipe wrapper
```

---

## Aliassen beheren (`/config/virtual`)

```
# Formaat: <bron>   <bestemming>
info@example.com        helpdesk@intern.example.com
abuse@example.com       security@intern.example.com
@example.com            catchall@intern.example.com   # catch-all
noreply@example.com     /dev/null                     # weggooien
```

### Wijzigingen toepassen

**Automatisch** (standaard): stel `AUTO_POSTMAP=true` in; de container
detecteert wijzigingen elke 10 seconden.

**Handmatig**:
```bash
docker exec mail-gateway postmap /config/virtual
docker exec mail-gateway postfix reload
```

---

## Environment variabelen

| Variabele | Standaard | Beschrijving |
|---|---|---|
| `MYHOSTNAME` | `mail.example.com` | FQDN van de gateway |
| `MYDOMAIN` | `example.com` | Maildomein |
| `RELAY_DOMAINS` | `example.com` | Domeinen waarvoor we mail accepteren |
| `RELAYHOST` | `[127.0.0.1]:10025` | Upstream MTA voor aflevering |
| `SPAM_SCORE_THRESHOLD` | `5.0` | SpamAssassin grens |
| `SPAM_ACTION` | `tag` | `tag` / `drop` / `quarantine` |
| `AUTO_POSTMAP` | `false` | Automatisch virtual herladen |
| `TLS_CERT_FILE` | snakeoil | Pad naar TLS certificaat |
| `TLS_KEY_FILE` | snakeoil | Pad naar TLS privésleutel |

---

## Spam-acties

| Actie | Gedrag |
|---|---|
| `tag` | Bezorgen met `X-Spam-*` headers + `[SPAM]` in onderwerp |
| `drop` | Stilletjes verwijderen (exit 0 → Postfix denkt: bezorgd) |
| `quarantine` | Opslaan in `/var/log/mail-gateway/quarantine/` |

---

## RBL-lijsten (poort-25 niveau)

Mails van IP's op deze lijsten worden **geweigerd vóór DATA**:

- `zen.spamhaus.org` — combineert SBL + XBL + PBL
- `bl.spamcop.net` — SpamCop meldingssysteem  
- `b.barracudacentral.org` — Barracuda Reputation Block List

Extra lijsten toevoegen in `config/main.cf` onder `smtpd_recipient_restrictions`:
```
reject_rbl_client lijst.example.com,
```

---

## SPF

Postfix roept `postfix-policyd-spf-perl` aan als policy service.
Mails die SPF FAIL retourneren worden geweigerd. SPF SOFTFAIL levert
een waarschuwingsheader.

Eigen SPF-gedrag aanpassen in `/etc/postfix-policyd-spf-perl.conf`
(mount als volume indien gewenst).

---

## TLS / Let's Encrypt

```yaml
# docker-compose.yml
environment:
  TLS_CERT_FILE: /etc/ssl/mail/cert.pem
  TLS_KEY_FILE:  /etc/ssl/mail/key.pem
volumes:
  - /etc/letsencrypt/live/mail.example.com/fullchain.pem:/etc/ssl/mail/cert.pem:ro
  - /etc/letsencrypt/live/mail.example.com/privkey.pem:/etc/ssl/mail/key.pem:ro
```

---

## Nuttige commando's

```bash
# Live mailwachtrij bekijken
docker exec mail-gateway mailq

# Wachtrij geforceerd afleveren
docker exec mail-gateway postfix flush

# SpamAssassin regels updaten
docker exec mail-gateway sa-update

# Mail testen
echo "Test mail body" | docker exec -i mail-gateway \
  sendmail -v test@example.com

# Postfix status
docker exec mail-gateway postfix status
```

---

## Productie checklist

- [ ] Stel een echte `MYHOSTNAME` in met werkende PTR-record (rDNS)
- [ ] Monteer een geldig TLS-certificaat (Let's Encrypt)
- [ ] Stel de juiste `RELAY_DOMAINS` in
- [ ] Stel `RELAYHOST` in naar uw interne MTA / IMAP-server
- [ ] Voeg SPF-record toe aan DNS: `v=spf1 mx ~all`
- [ ] Voeg DKIM toe (bijv. via `opendkim` als sidecar)
- [ ] Test met mail-tester.com of MXToolbox
- [ ] Monitor `/var/log/mail-gateway/mail.log`
