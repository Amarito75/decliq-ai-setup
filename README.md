# Decliq.ai — Setup automatique VPS + Hermes

Setup complet d'un VPS Ubuntu 22.04 pour la plateforme **Decliq.ai** en une seule commande.

## 🚀 Installation

Se connecter en root sur le VPS vierge, puis :

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Amarito75/decliq-ai-setup/main/install.sh)
```

## Ce que fait le script

Le script est interactif — il pose les questions essentielles puis configure tout automatiquement en ~15 minutes :

| Étape | Description |
|-------|-------------|
| 0/12 | Collecte des informations client (nom, email, WhatsApp, domaine, clés API) |
| 1/12 | Mise à jour système + paquets de base |
| 2/12 | Utilisateur `decliq` + SSH sécurisé (port 2222) + UFW + Fail2Ban |
| 3/12 | Node.js 20 LTS + PM2 |
| 4/12 | Hermes (pip) + workspace client |
| 5/12 | Génération automatique `config.yaml` + `.env` |
| 6/12 | **himalaya** — CLI email IMAP/SMTP (Agent Résumé des Mails) |
| 7/12 | **blogwatcher** — veille RSS (Agent Veille Sectorielle) |
| 8/12 | **ocr-and-documents** — scan factures + watcher inotify |
| 9/12 | **MCP** — dépendances pour connecteurs avancés |
| 10/12 | Bridge WhatsApp (whatsapp-web.js + PM2) |
| 11/12 | Crons : health check 15min + backup quotidien + rappel tokens mensuel |
| 12/12 | SSL Let's Encrypt (si domaine fourni) + rapport final |

## Après le script — 6 actions manuelles

1. **QR Code WhatsApp** → `pm2 logs wa-bridge`
2. **App Password Gmail** → stocker dans `/home/decliq/.config/himalaya/.gmail-app-password`
3. **OAuth Google** → suivre la section 4.2 du Guide de Déploiement Notion
4. **Remplir le `.env`** → Meta, LinkedIn, Buffer, Brevo, CRM, facturation
5. **Sources RSS sectorielles** → `blogwatcher-cli add "Nom" https://url`
6. **Déployer les agents** → `hermes agent deploy 01-resume-mails` ...

## Connexion SSH après installation

```bash
ssh -p 2222 decliq@IP_VPS
```

## Prérequis

- VPS Ubuntu 22.04 LTS (Hostinger KVM2 minimum — 2 vCPU / 8 Go RAM)
- Accès root initial
- Clé API Anthropic (`sk-ant-...`)
- Clé API Notion (`ntn_...`)
- (Optionnel) Domaine DNS pointant sur le VPS pour SSL automatique

## Compatibilité

- ✅ Ubuntu 22.04 LTS (Jammy)
- ✅ Debian 12 (Bookworm)
- ⚠️ Autres distros : non testées

## Licence

MIT — [Decliq.ai](https://decliq.ai)
