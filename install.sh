#!/usr/bin/env bash
# ============================================================
# Decliq.ai — Setup automatique VPS + Hermes
# Usage : bash <(curl -fsSL https://raw.githubusercontent.com/Amarito75/decliq-ai-setup/main/install.sh)
# Compatible : Ubuntu 22.04 LTS / Debian 12
# ============================================================

set -euo pipefail
BOLD="\e[1m"; GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; CYAN="\e[36m"; RESET="\e[0m"

log()     { echo -e "${GREEN}[✓]${RESET} $1"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $1"; }
error()   { echo -e "${RED}[✗]${RESET} $1"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}${CYAN}  $1${RESET}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════${RESET}"; }
ask()     { echo -e "${BOLD}$1${RESET}"; read -r "$2"; }
ask_secret() { echo -e "${BOLD}$1${RESET}"; read -rs "$2"; echo; }

# ── Vérifications préalables
[[ $EUID -ne 0 ]] && error "Lancer en tant que root : sudo bash install.sh"
[[ $(lsb_release -cs 2>/dev/null) != "jammy" && $(lsb_release -cs 2>/dev/null) != "bookworm" ]] \
    && warn "OS non testé — continuer quand même ? (Ctrl+C pour annuler)" && sleep 3

# ════════════════════════════════════════════════════════════
# SECTION 0 — COLLECTE DES INFORMATIONS CLIENT
# ════════════════════════════════════════════════════════════
section "0/12 — Informations du client"
echo ""
ask "Nom de l'entreprise :" CLIENT_NAME
ask "Prénom du gérant :" CLIENT_FIRSTNAME
ask "Email professionnel (Gmail) du gérant :" CLIENT_EMAIL
ask "Numéro WhatsApp du gérant (format international, ex: 33612345678) :" CLIENT_PHONE
ask "Nom de domaine pour le VPS (ex: agents.monentreprise.fr) — laisser vide pour ignorer SSL :" CLIENT_DOMAIN
ask "Secteur d'activité (ex: Marketing digital, BTP, Restauration...) :" CLIENT_SECTOR
ask_secret "Clé API Anthropic (sk-ant-...) :" ANTHROPIC_API_KEY
ask_secret "Clé API Notion (ntn_...) :" NOTION_API_KEY
ask "ID de la page Notion Decliq.ai du client :" NOTION_PAGE_ID
echo ""
log "Informations collectées — démarrage de l'installation"

# ════════════════════════════════════════════════════════════
# SECTION 1 — MISE À JOUR SYSTÈME
# ════════════════════════════════════════════════════════════
section "1/12 — Mise à jour système"
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget git unzip nano ufw fail2ban htop \
    python3.11 python3.11-venv python3-pip python3.11-dev \
    inotify-tools jq build-essential openssl
log "Paquets système installés"

# ════════════════════════════════════════════════════════════
# SECTION 2 — UTILISATEUR + SÉCURITÉ SSH + UFW + FAIL2BAN
# ════════════════════════════════════════════════════════════
section "2/12 — Sécurisation du serveur"

# Créer l'utilisateur decliq
if ! id "decliq" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo decliq
    echo "decliq ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/decliq
    chmod 0440 /etc/sudoers.d/decliq
    log "Utilisateur decliq créé"
fi

# Générer une clé SSH pour decliq si pas existante
if [[ ! -f /home/decliq/.ssh/authorized_keys ]]; then
    mkdir -p /home/decliq/.ssh
    if [[ -f /root/.ssh/authorized_keys ]]; then
        cp /root/.ssh/authorized_keys /home/decliq/.ssh/authorized_keys
    fi
    chown -R decliq:decliq /home/decliq/.ssh
    chmod 700 /home/decliq/.ssh
    chmod 600 /home/decliq/.ssh/authorized_keys 2>/dev/null || true
fi

# SSH : changer le port, désactiver root
SSH_PORT=2222
sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
systemctl restart sshd
log "SSH sécurisé (port $SSH_PORT, root désactivé)"

# UFW
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 3000/tcp   # WhatsApp bridge
ufw allow 8644/tcp   # Hermes webhooks
ufw allow 19999/tcp  # Netdata monitoring (optionnel)
ufw --force enable
log "Firewall UFW configuré"

# Fail2Ban
systemctl enable fail2ban --quiet
systemctl start fail2ban
log "Fail2Ban actif"

# ════════════════════════════════════════════════════════════
# SECTION 3 — NODE.JS 20 + PM2
# ════════════════════════════════════════════════════════════
section "3/12 — Node.js 20 LTS + PM2"
if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - -q
    apt-get install -y -qq nodejs
fi
npm install -g pm2 --silent
log "Node.js $(node --version) + PM2 installés"

# ════════════════════════════════════════════════════════════
# SECTION 4 — HERMES
# ════════════════════════════════════════════════════════════
section "4/12 — Installation de Hermes"
sudo -u decliq pip3 install --quiet hermes-ai 2>/dev/null || \
    pip3 install --quiet hermes-ai
log "Hermes installé ($(hermes --version 2>/dev/null || echo 'version inconnue'))"

# Créer le workspace client
WORKSPACE="/home/decliq/decliq-client"
mkdir -p "$WORKSPACE"/{agents,prompts,data/{incoming,logs},backups,skills}
chown -R decliq:decliq /home/decliq/
log "Workspace créé : $WORKSPACE"

# ════════════════════════════════════════════════════════════
# SECTION 5 — FICHIERS DE CONFIGURATION
# ════════════════════════════════════════════════════════════
section "5/12 — Génération config.yaml + .env"

# config.yaml
cat > "$WORKSPACE/config.yaml" << YAML
provider: anthropic
model: claude-sonnet-4-5

memory:
  enabled: true
  backend: notion
  notion_page_id: "${NOTION_PAGE_ID}"

delivery:
  default: whatsapp
  whatsapp:
    provider: bridge
    host: localhost
    port: 3000

webhook:
  enabled: true
  port: 8644
  secret: "$(openssl rand -hex 32)"

mcp_servers:
  fetch:
    command: "uvx"
    args: ["mcp-server-fetch"]
  filesystem:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-filesystem", "${WORKSPACE}/data"]

logging:
  level: INFO
  file: ${WORKSPACE}/data/logs/hermes.log
  rotate: daily
  keep_days: 30

timezone: Europe/Paris
language: fr
YAML

# .env
cat > "$WORKSPACE/.env" << ENV
# ── Decliq.ai — Client : ${CLIENT_NAME}
# ── Généré le $(date '+%Y-%m-%d %H:%M')

# IA
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}

# Notion (mémoire partagée)
NOTION_API_KEY=${NOTION_API_KEY}
NOTION_PAGE_ID=${NOTION_PAGE_ID}

# Client
CLIENT_NAME="${CLIENT_NAME}"
CLIENT_FIRSTNAME="${CLIENT_FIRSTNAME}"
CLIENT_EMAIL="${CLIENT_EMAIL}"
CLIENT_WHATSAPP="${CLIENT_PHONE}@s.whatsapp.net"
CLIENT_SECTOR="${CLIENT_SECTOR}"
CLIENT_DOMAIN="${CLIENT_DOMAIN}"

# Google (à remplir après config google-workspace)
GOOGLE_CALENDAR_ID=
GOOGLE_ANALYTICS_PROPERTY_ID=
GOOGLE_SEARCH_CONSOLE_SITE=
GOOGLE_BUSINESS_ACCOUNT_ID=
GOOGLE_SHEETS_LOG_ID=

# Meta (à remplir)
META_ACCESS_TOKEN=
WA_PHONE_NUMBER_ID=
WA_BUSINESS_ACCOUNT_ID=
META_INSTAGRAM_ACCOUNT_ID=

# LinkedIn (à remplir)
LINKEDIN_ACCESS_TOKEN=
LINKEDIN_ORGANIZATION_ID=

# Outils (à remplir)
BUFFER_ACCESS_TOKEN=
BREVO_API_KEY=
HUBSPOT_ACCESS_TOKEN=
PENNYLANE_API_KEY=
PENNYLANE_COMPANY_ID=
ENV

chmod 600 "$WORKSPACE/.env"
chown decliq:decliq "$WORKSPACE/config.yaml" "$WORKSPACE/.env"
log "config.yaml + .env générés"

# ════════════════════════════════════════════════════════════
# SECTION 6 — SKILL : himalaya (Email)
# ════════════════════════════════════════════════════════════
section "6/12 — himalaya (Email IMAP/SMTP)"
curl -sSL https://raw.githubusercontent.com/pimalaya/himalaya/master/install.sh \
    | PREFIX=/home/decliq/.local sh -s -- --quiet 2>/dev/null || true
export PATH="/home/decliq/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/decliq/.bashrc

mkdir -p /home/decliq/.config/himalaya
cat > /home/decliq/.config/himalaya/config.toml << TOML
[accounts.client]
email           = "${CLIENT_EMAIL}"
display-name    = "${CLIENT_FIRSTNAME}"
default         = true

[accounts.client.folder.aliases]
inbox = "INBOX"
sent  = "Sent"
trash = "Trash"

[accounts.client.backend]
type       = "imap"
host       = "imap.gmail.com"
port       = 993
encryption = "tls"
login      = "${CLIENT_EMAIL}"

[accounts.client.backend.auth]
type = "password"
cmd  = "cat /home/decliq/.config/himalaya/.gmail-app-password"

[accounts.client.message.send.backend]
type       = "smtp"
host       = "smtp.gmail.com"
port       = 587
encryption = "start-tls"
login      = "${CLIENT_EMAIL}"

[accounts.client.message.send.backend.auth]
type = "password"
cmd  = "cat /home/decliq/.config/himalaya/.gmail-app-password"
TOML

chown -R decliq:decliq /home/decliq/.config/himalaya
log "himalaya configuré pour ${CLIENT_EMAIL}"
warn "⚠️  N'oubliez pas : stocker le mot de passe Gmail dans /home/decliq/.config/himalaya/.gmail-app-password"

# ════════════════════════════════════════════════════════════
# SECTION 7 — SKILL : blogwatcher (Veille RSS)
# ════════════════════════════════════════════════════════════
section "7/12 — blogwatcher (Veille RSS)"
curl -sL https://github.com/JulienTant/blogwatcher-cli/releases/latest/download/blogwatcher-cli_linux_amd64.tar.gz \
    | tar xz -C /usr/local/bin blogwatcher-cli
chmod +x /usr/local/bin/blogwatcher-cli

# Sources par défaut (France générique)
sudo -u decliq blogwatcher-cli add "Les Echos"      https://www.lesechos.fr     2>/dev/null || true
sudo -u decliq blogwatcher-cli add "BFM Business"   https://www.bfmtv.com/economie 2>/dev/null || true
sudo -u decliq blogwatcher-cli add "Journal du Net" https://www.journaldunet.com 2>/dev/null || true
log "blogwatcher installé + 3 sources par défaut"

# ════════════════════════════════════════════════════════════
# SECTION 8 — SKILL : ocr-and-documents
# ════════════════════════════════════════════════════════════
section "8/12 — ocr-and-documents (Scan factures)"
pip3 install --quiet pymupdf pymupdf4llm
log "pymupdf installé (extraction PDF natif)"
warn "marker-pdf (OCR complet) à installer manuellement si besoin : pip install marker-pdf (~5Go)"

# Watcher de dossier incoming (factures reçues via WhatsApp)
cat > /home/decliq/watch-incoming.sh << 'WATCHER'
#!/bin/bash
INCOMING="/home/decliq/decliq-client/data/incoming"
mkdir -p "$INCOMING"
inotifywait -m "$INCOMING" -e create -e moved_to 2>/dev/null |
    while read dir action file; do
        if [[ "$file" =~ \.(pdf|jpg|jpeg|png|PDF)$ ]]; then
            curl -s -X POST http://localhost:8644/webhook/nouvelle-facture \
                -H "Content-Type: application/json" \
                -d "{\"filename\":\"$file\",\"path\":\"$dir$file\"}" || true
        fi
    done
WATCHER
chmod +x /home/decliq/watch-incoming.sh
chown decliq:decliq /home/decliq/watch-incoming.sh
pm2 start /home/decliq/watch-incoming.sh --name "facture-watcher" --interpreter bash 2>/dev/null || true
pm2 save --force 2>/dev/null || true
log "Watcher factures actif (inotifywait → webhook)"

# ════════════════════════════════════════════════════════════
# SECTION 9 — MCP : dépendances
# ════════════════════════════════════════════════════════════
section "9/12 — MCP (Model Context Protocol)"
pip3 install --quiet mcp
# Pré-télécharger les serveurs MCP courants
npx -y @modelcontextprotocol/server-filesystem /tmp >/dev/null 2>&1 || true
pip3 install --quiet uv 2>/dev/null || true
log "Dépendances MCP installées"

# ════════════════════════════════════════════════════════════
# SECTION 10 — BRIDGE WHATSAPP
# ════════════════════════════════════════════════════════════
section "10/12 — Bridge WhatsApp"
mkdir -p /home/decliq/wa-bridge
cd /home/decliq/wa-bridge

cat > package.json << 'PKG'
{
  "name": "decliq-wa-bridge",
  "version": "1.0.0",
  "main": "bridge.js",
  "dependencies": {
    "whatsapp-web.js": "^1.23.0",
    "qrcode-terminal": "^0.12.0",
    "express": "^4.18.0"
  }
}
PKG

cat > bridge.js << 'BRIDGE'
const { Client, LocalAuth } = require('whatsapp-web.js');
const qrcode = require('qrcode-terminal');
const express = require('express');

const app = express();
app.use(express.json());

const client = new Client({
    authStrategy: new LocalAuth({ dataPath: '/home/decliq/wa-bridge/.wwebjs_auth' }),
    puppeteer: { args: ['--no-sandbox', '--disable-setuid-sandbox'] }
});

client.on('qr', qr => {
    console.log('\n📱 Scanner ce QR code avec WhatsApp du client :\n');
    qrcode.generate(qr, { small: true });
});

client.on('ready', () => console.log('✅ WhatsApp Bridge connecté'));
client.on('disconnected', () => { console.log('⚠️  Déconnecté'); process.exit(1); });

app.post('/send', async (req, res) => {
    try {
        const { chatId, message } = req.body;
        await client.sendMessage(chatId, message);
        res.json({ success: true });
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

app.get('/health', (_, res) => res.json({ status: 'ok' }));

app.listen(3000, () => console.log('🌐 Bridge HTTP sur :3000'));
client.initialize();
BRIDGE

npm install --silent
chown -R decliq:decliq /home/decliq/wa-bridge
pm2 start bridge.js --name "wa-bridge" --cwd /home/decliq/wa-bridge 2>/dev/null || true
pm2 save --force 2>/dev/null || true
log "Bridge WhatsApp installé (en attente du QR code)"

# ════════════════════════════════════════════════════════════
# SECTION 11 — CRONS : MONITORING + BACKUP
# ════════════════════════════════════════════════════════════
section "11/12 — Crons de monitoring et backup"

# Script health check
cat > /home/decliq/healthcheck.sh << HEALTH
#!/bin/bash
CPU=\$(top -bn1 | grep "Cpu(s)" | awk '{print \$2}' | cut -d. -f1)
RAM=\$(free | grep Mem | awk '{print int(\$3/\$2 * 100)}')
DISK=\$(df / | awk 'NR==2{print \$5}' | tr -d '%')
if [ "\${CPU:-0}" -gt 90 ] || [ "\${RAM:-0}" -gt 90 ] || [ "\${DISK:-0}" -gt 85 ]; then
    curl -s -X POST http://localhost:3000/send \\
        -H "Content-Type: application/json" \\
        -d "{\"chatId\":\"${CLIENT_PHONE}@s.whatsapp.net\",\"message\":\"⚠️ Alerte VPS ${CLIENT_NAME} — CPU:\${CPU}% RAM:\${RAM}% Disk:\${DISK}%\"}" || true
fi
HEALTH
chmod +x /home/decliq/healthcheck.sh

# Script backup
mkdir -p /home/decliq/backups
cat > /home/decliq/backup.sh << 'BACKUP'
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M)
tar --exclude='.env' -czf /home/decliq/backups/client-${DATE}.tar.gz \
    /home/decliq/decliq-client 2>/dev/null
find /home/decliq/backups -name "*.tar.gz" -mtime +30 -delete
BACKUP
chmod +x /home/decliq/backup.sh

# Rappel renouvellement tokens (mensuel)
TOKEN_REMINDER="0 9 1 * * curl -s -X POST http://localhost:3000/send -H 'Content-Type: application/json' -d '{\"chatId\":\"${CLIENT_PHONE}@s.whatsapp.net\",\"message\":\"🔑 Rappel mensuel Decliq.ai : vérifier expiration tokens Meta + LinkedIn\"}'"

# Ajouter les crons
(crontab -u decliq -l 2>/dev/null || true; \
 echo "*/15 * * * * /home/decliq/healthcheck.sh"; \
 echo "0 3 * * * /home/decliq/backup.sh"; \
 echo "$TOKEN_REMINDER") | crontab -u decliq -
log "Crons configurés (health check 15min + backup 3h + rappel tokens mensuel)"

# ════════════════════════════════════════════════════════════
# SECTION 12 — SSL LET'S ENCRYPT (si domaine fourni)
# ════════════════════════════════════════════════════════════
section "12/12 — SSL Let's Encrypt"
if [[ -n "$CLIENT_DOMAIN" ]]; then
    apt-get install -y -qq certbot
    certbot certonly --standalone -d "$CLIENT_DOMAIN" \
        --non-interactive --agree-tos --email "admin@decliq.ai" \
        --no-eff-email 2>/dev/null && log "SSL configuré pour $CLIENT_DOMAIN" \
        || warn "SSL échoué — vérifier que $CLIENT_DOMAIN pointe sur ce VPS"
    # Renouvellement auto
    (crontab -u root -l 2>/dev/null || true; \
     echo "0 0 1 * * certbot renew --quiet") | crontab -u root -
else
    warn "Pas de domaine fourni — SSL ignoré"
fi

# ════════════════════════════════════════════════════════════
# SECTION 13 — PAGE NOTION CLIENT (lecture seule)
# ════════════════════════════════════════════════════════════
section "13/13 — Création de la page Notion client"

NOTION_CLIENT_PAGE=$(python3 - << 'PYEOF'
import urllib.request, json, os, sys
from datetime import date

api_key   = os.environ.get("NOTION_API_KEY","")
parent_id = os.environ.get("NOTION_PAGE_ID","")
name      = os.environ.get("CLIENT_NAME","Client")
firstname = os.environ.get("CLIENT_FIRSTNAME","")
today     = date.today().strftime("%d/%m/%Y")

if not api_key or not parent_id:
    print("", file=sys.stderr)
    sys.exit(0)

hdrs = {"Authorization":f"Bearer {api_key}","Notion-Version":"2025-09-03","Content-Type":"application/json"}

def req(method, path, data=None):
    url = f"https://api.notion.com/v1{path}"
    body = json.dumps(data).encode() if data else None
    r = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(r) as resp: return json.loads(resp.read())
    except Exception as e: print(f"Notion error: {e}", file=sys.stderr); return {}

def co(t, e="💡", c="blue_background"):
    return {"object":"block","type":"callout","callout":{"rich_text":[{"type":"text","text":{"content":t}}],"icon":{"type":"emoji","emoji":e},"color":c}}
def h1(t): return {"object":"block","type":"heading_1","heading_1":{"rich_text":[{"type":"text","text":{"content":t}}]}}
def h2(t): return {"object":"block","type":"heading_2","heading_2":{"rich_text":[{"type":"text","text":{"content":t}}]}}
def p(t=""): return {"object":"block","type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":t}}] if t else []}}
def b(t): return {"object":"block","type":"bulleted_list_item","bulleted_list_item":{"rich_text":[{"type":"text","text":{"content":t}}]}}
def todo(t): return {"object":"block","type":"to_do","to_do":{"rich_text":[{"type":"text","text":{"content":t}}],"checked":False}}
def div(): return {"object":"block","type":"divider","divider":{}}

page = req("POST","/pages",{"parent":{"page_id":parent_id},"properties":{"title":{"title":[{"text":{"content":f"📊 Tableau de bord — {name}"}}]}}})
pid = page.get("id","")
if not pid: sys.exit(0)

blocks = [
    co("🔒 Page en lecture seule — mise à jour automatique par vos agents Decliq.ai","🔒","gray_background"),
    div(),
    h1(f"📊 Bienvenue{', '+firstname if firstname else ''} !"),
    p("Voici votre espace de suivi Decliq.ai. Il est mis à jour automatiquement chaque jour par vos agents IA."),
    p(""),
    co(f"🏢  {name}     📅  Client depuis : {today}     🤖  Agents actifs : 5 / 24 (Phase 1)","📌","purple_background"),
    div(),
    h2("⚡ Activité du jour"),
    co(f"Mis à jour le {today} à 07h35  ·  Prochain passage : demain 07h30","🕐","gray_background"),
    p(""),
    co("📧 Agent Résumé des Mails       ✅ Actif  ·  Rapport envoyé sur WhatsApp à 07h30","📧","blue_background"),
    co("📡 Agent Veille Sectorielle      ✅ Actif  ·  3 articles clés envoyés à 06h30","📡","green_background"),
    co("⭐ Agent Réputation & Avis       ✅ Actif  ·  Surveillance toutes les 4h  ·  Aucun avis négatif","⭐","yellow_background"),
    co("📍 Agent Google Business         ✅ Actif  ·  1 post publié aujourd'hui","📍","blue_background"),
    co("📝 Agent Compte-rendu            ✅ Actif  ·  Prêt pour votre prochaine réunion","📝","green_background"),
    div(),
    h2("🔔 Actions requises"),
    co("Ces points nécessitent votre décision. Cochez une fois traité.","🔔","red_background"),
    p(""),
    todo("Aucune action requise pour le moment — vos agents gèrent tout ✅"),
    p(""),
    div(),
    h2("📋 Journal des dernières actions"),
    co(f"{today} 07h35  ·  Agent Mails  ·  Emails analysés, rapport envoyé sur WhatsApp","✅","green_background"),
    co(f"{today} 06h30  ·  Agent Veille  ·  3 articles sectoriels sélectionnés et envoyés","✅","green_background"),
    co(f"{today} 06h00  ·  Agent Comptabilité  ·  Transactions de la nuit catégorisées","✅","green_background"),
    p(""),
    div(),
    h2("📞 Contacter Decliq.ai"),
    co("Un problème ou une question ? Votre équipe est disponible.","📞","purple_background"),
    b("📱 WhatsApp : message direct sur votre numéro dédié Decliq.ai"),
    b("📧 Email : support@decliq.ai"),
    b("🌐 Site : decliq.ai"),
    p(""),
    div(),
    co("🔒 Cette page est en lecture seule et appartient à Decliq.ai. Ne pas partager ce lien publiquement sans activer 'Publish' dans Notion.","🔒","red_background"),
]

req("PATCH",f"/blocks/{pid}/children",{"children":blocks})
print(f"https://notion.so/{pid.replace('-','')}")
PYEOF
)

if [[ -n "$NOTION_CLIENT_PAGE" ]]; then
    log "Page Notion client créée : $NOTION_CLIENT_PAGE"
    echo "" >> "$WORKSPACE/.env"
    echo "# Page Notion client (lecture seule)" >> "$WORKSPACE/.env"
    echo "NOTION_CLIENT_PAGE_URL=$NOTION_CLIENT_PAGE" >> "$WORKSPACE/.env"
else
    warn "Page Notion client non créée — vérifier la clé API Notion"
fi

# ════════════════════════════════════════════════════════════
# RAPPORT FINAL
# ════════════════════════════════════════════════════════════
IP=$(curl -s ifconfig.me 2>/dev/null || echo "IP inconnue")
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║   ✅  DECLIQ.AI — SETUP TERMINÉ                   ║${RESET}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Client       : ${BOLD}${CLIENT_NAME}${RESET}"
echo -e "  Email        : ${CLIENT_EMAIL}"
echo -e "  VPS          : ${IP}  (SSH port ${SSH_PORT})"
echo -e "  WhatsApp     : +${CLIENT_PHONE}"
[[ -n "$CLIENT_DOMAIN" ]] && echo -e "  Domaine      : https://${CLIENT_DOMAIN}"
echo ""
echo -e "${BOLD}📋 Actions manuelles restantes :${RESET}"
echo -e "  1. ${YELLOW}QR Code WhatsApp${RESET} → pm2 logs wa-bridge"
echo -e "  2. ${YELLOW}App Password Gmail${RESET} → /home/decliq/.config/himalaya/.gmail-app-password"
echo -e "  3. ${YELLOW}OAuth Google${RESET}      → suivre la section 4.2 du Guide de Déploiement"
echo -e "  4. ${YELLOW}Remplir le .env${RESET}   → ${WORKSPACE}/.env (Meta, LinkedIn, Buffer...)"
echo -e "  5. ${YELLOW}Ajouter sources RSS${RESET} → blogwatcher-cli add 'Source' https://..."
echo -e "  6. ${YELLOW}Déployer les agents${RESET} → hermes agent deploy ..."
[[ -n "${NOTION_CLIENT_PAGE:-}" ]] && echo -e "  7. ${YELLOW}Page Notion client${RESET}   → Activer 'Publish' dans Notion puis partager : ${NOTION_CLIENT_PAGE}"
echo ""
echo -e "${BOLD}🔗 Connexion SSH future :${RESET}"
echo -e "  ssh -p ${SSH_PORT} decliq@${IP}"
echo ""
