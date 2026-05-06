#!/usr/bin/env python3
# ============================================================
# Decliq.ai — Routeur WhatsApp ↔ Agents
# Fichier : /home/decliq/decliq-client/router.py
# Lancé via PM2 — écoute sur le port 8645
# ============================================================

import os, json, subprocess, re, time
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime

# ── Configuration
ALLOWED_NUMBER = os.getenv("CLIENT_WHATSAPP", "")   # "336XXXXXXXX@s.whatsapp.net"
WA_BRIDGE      = "http://localhost:3000/send"
ANTHROPIC_KEY  = os.getenv("ANTHROPIC_API_KEY", "")
LOG_FILE       = "/home/decliq/decliq-client/data/logs/router.log"
ROUTER_PORT    = int(os.getenv("ROUTER_PORT", "8645"))
MAX_MSG_PER_MIN = 10

# ── Mapping intentions → IDs agents Hermes
AGENT_MAP = {
    "mails": "01-resume-mails", "email": "01-resume-mails",
    "devis": "08-devis-facturation", "facture": "08-devis-facturation", "impayé": "08-devis-facturation",
    "agenda": "18-agenda", "rendez-vous": "18-agenda", "rdv": "18-agenda",
    "contenu": "03-creation-contenu", "article": "03-creation-contenu",
    "post": "02-community-manager", "linkedin": "02-community-manager", "instagram": "02-community-manager",
    "stats": "15-analytics", "analytics": "15-analytics", "performance": "15-analytics",
    "avis": "05-reputation-avis", "réputation": "05-reputation-avis", "google": "05-reputation-avis",
    "veille": "22-veille-sectorielle", "actualités": "22-veille-sectorielle",
    "concurrents": "20-veille-concurrentielle",
    "prospect": "06-prospection", "prospection": "06-prospection",
    "appels d'offres": "23-appels-offres",
    "trésorerie": "11-tresorerie", "cash": "11-tresorerie",
    "comptabilité": "10-comptabilite",
    "sav": "07-sav-chatbot", "service client": "07-sav-chatbot",
    "seo": "14-webmaster-seo", "site": "14-webmaster-seo",
    "google business": "17-google-business",
    "newsletter": "04-newsletter",
    "crm": "09-suivi-crm", "contact": "09-suivi-crm",
    "rh": "12-rh", "congés": "12-rh",
    "benchmark": "24-benchmark-prix", "prix": "24-benchmark-prix",
    "onboarding": "21-onboarding",
}

# ── Rate limiting
_rate_store: dict = {}

def is_rate_limited(sender: str) -> bool:
    now = time.time()
    times = [t for t in _rate_store.get(sender, []) if now - t < 60]
    _rate_store[sender] = times
    if len(times) >= MAX_MSG_PER_MIN:
        return True
    _rate_store[sender].append(now)
    return False

# ── Mémoire de contexte (session en cours par expéditeur)
_context: dict = {}

def get_ctx(sender):
    return _context.setdefault(sender, {"pending_action": None, "last_agent": None})

# ── Utilitaires
def log(msg: str):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass

def send_wa(message: str, chat_id: str = None):
    import urllib.request
    target = chat_id or ALLOWED_NUMBER
    payload = json.dumps({"chatId": target, "message": message}).encode()
    req = urllib.request.Request(
        WA_BRIDGE, data=payload,
        headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        log(f"WA send error: {e}")

# ── Analyse d'intention via Claude
SYSTEM_PROMPT = """Tu es le routeur d'un assistant IA pour TPE/PME françaises.
Analyse le message WhatsApp du client et réponds UNIQUEMENT en JSON valide.
Format attendu :
{
  "intent": "description courte de l'intention (max 10 mots)",
  "agent": "clé d'agent parmi la liste fournie ou null",
  "params": {"clé": "valeur extraite du message"},
  "needs_confirmation": true ou false,
  "confirmation_message": "message de confirmation si needs_confirmation=true, sinon null",
  "direct_response": "réponse directe si pas d'agent nécessaire, sinon null"
}
needs_confirmation=true si : envoyer email client, créer/envoyer devis ou facture, publier RS, relancer prospect.
needs_confirmation=false si : lecture (stats, résumé, agenda, veille), demande d'info."""

def analyze_intent(message: str) -> dict:
    import urllib.request
    agents_list = list(AGENT_MAP.keys())
    user_prompt = f'Message du client : "{message}"\nAgents disponibles : {agents_list}'
    payload = json.dumps({
        "model": "claude-sonnet-4-5",
        "max_tokens": 400,
        "system": SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": user_prompt}]
    }).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages", data=payload,
        headers={"x-api-key": ANTHROPIC_KEY, "anthropic-version": "2023-06-01",
                 "content-type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read())
            text = data["content"][0]["text"]
            match = re.search(r'\{.*\}', text, re.DOTALL)
            if match:
                return json.loads(match.group())
    except Exception as e:
        log(f"Claude error: {e}")
    return {"intent": "inconnu", "agent": None, "params": {},
            "needs_confirmation": False, "direct_response": None,
            "confirmation_message": None}

def trigger_agent(agent_key: str, params: dict, original_message: str) -> bool:
    agent_id = AGENT_MAP.get(agent_key, agent_key)
    env = os.environ.copy()
    env["AGENT_TRIGGER_MESSAGE"] = original_message
    env["AGENT_TRIGGER_PARAMS"]  = json.dumps(params)
    try:
        result = subprocess.run(
            ["hermes", "cronjob", "run", "--agent", agent_id,
             "--context", original_message],
            capture_output=True, text=True, timeout=60, env=env,
            cwd="/home/decliq/decliq-client"
        )
        log(f"Agent '{agent_id}' → exit {result.returncode}")
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        log(f"Agent '{agent_id}' timeout"); return False
    except Exception as e:
        log(f"Agent trigger error: {e}"); return False

# ── Message d'aide
HELP_MESSAGE = """🤖 *Vos agents Decliq.ai* — Écrivez simplement ce que vous voulez faire :

📧 *Emails* : "résume mes mails", "réponds à [nom]"
📄 *Devis/Factures* : "fais un devis pour [client]", "impayés ?"
📅 *Agenda* : "mon agenda demain", "RDV avec [nom] cette semaine"
✍️ *Contenu* : "post LinkedIn sur [sujet]", "article de blog sur [thème]"
📊 *Stats* : "mes stats semaine", "meilleur post", "note Google"
🔍 *Veille* : "actus secteur", "que font mes concurrents"
🎯 *Prospection* : "nouveaux prospects", "opportunités du moment"
💶 *Finance* : "trésorerie", "impayés", "état des devis"

Tapez *aide* à tout moment pour revoir ce message."""

# ── Serveur HTTP
class RouterHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass  # silence log HTTP natif

    def do_POST(self):
        length  = int(self.headers.get("Content-Length", 0))
        payload = json.loads(self.rfile.read(length)) if length else {}
        sender  = payload.get("from", "").strip()
        message = payload.get("body", "").strip()

        self._respond(200, "ok")  # Répondre immédiatement au bridge

        # ── Sécurité : whitelist numéro
        if ALLOWED_NUMBER and sender != ALLOWED_NUMBER:
            log(f"Ignoré (non autorisé) : {sender[:20]}")
            return
        if not message:
            return

        # ── Rate limiting
        if is_rate_limited(sender):
            send_wa("⚠️ Trop de messages. Attendez une minute.", sender)
            return

        log(f"MSG [{sender[:15]}] : {message[:60]}")
        ctx = get_ctx(sender)

        # ── Réponse à une confirmation en attente
        if ctx.get("pending_action"):
            m = message.lower()
            if m in ["oui", "yes", "ok", "confirme", "✅", "👍", "o"]:
                action = ctx["pending_action"]
                ctx["pending_action"] = None
                send_wa("⏳ Action en cours...", sender)
                ok = trigger_agent(action["agent"], action["params"], action["original"])
                send_wa("✅ C'est fait !" if ok else "❌ Erreur. Réessayez ou contactez Decliq.ai.", sender)
            elif m in ["non", "no", "annule", "stop", "❌", "👎", "n"]:
                ctx["pending_action"] = None
                send_wa("↩️ Action annulée.", sender)
            else:
                send_wa("Répondez *oui* pour confirmer ou *non* pour annuler.", sender)
            return

        # ── Commandes spéciales directes
        m = message.lower()
        if m in ["aide", "help", "commandes", "?"]:
            send_wa(HELP_MESSAGE, sender); return
        if m in ["statut", "status"]:
            send_wa("📊 Statut de vos agents → consultez votre tableau de bord Notion.", sender); return
        if m in ["bonjour", "salut", "hello", "bonsoir"]:
            send_wa(f"Bonjour ! 👋 Comment puis-je vous aider ? Tapez *aide* pour voir ce que je sais faire.", sender); return

        # ── Analyse Claude
        send_wa("⏳", sender)
        intent = analyze_intent(message)
        log(f"Intent: {intent.get('intent','?')} | agent: {intent.get('agent','?')}")

        # Réponse directe sans agent
        if intent.get("direct_response"):
            send_wa(intent["direct_response"], sender); return

        # Agent non identifié
        if not intent.get("agent"):
            send_wa("Je n'ai pas compris 🤔 Tapez *aide* pour voir ce que je peux faire.", sender); return

        # Confirmation requise
        if intent.get("needs_confirmation"):
            ctx["pending_action"] = {
                "agent":    intent["agent"],
                "params":   intent.get("params", {}),
                "original": message
            }
            confirm = intent.get("confirmation_message") or f"Confirmer : {intent['intent']} ? (*oui* / *non*)"
            send_wa(confirm, sender); return

        # Déclencher l'agent directement
        ok = trigger_agent(intent["agent"], intent.get("params", {}), message)
        if not ok:
            send_wa("⚠️ L'agent n'a pas répondu. Réessayez dans quelques instants.", sender)

    def _respond(self, code, body):
        self.send_response(code)
        self.end_headers()
        self.wfile.write(body.encode())

if __name__ == "__main__":
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    log(f"🚀 Routeur Decliq.ai démarré — port {ROUTER_PORT} — client : {ALLOWED_NUMBER}")
    HTTPServer(("0.0.0.0", ROUTER_PORT), RouterHandler).serve_forever()
