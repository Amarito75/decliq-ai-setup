
// ── Forward messages entrants vers le routeur Decliq.ai ──
client.on('message', async msg => {
    if (msg.fromMe) return;  // ignorer les messages envoyés par le bot

    const payload = JSON.stringify({
        from:      msg.from,
        body:      msg.body || '',
        type:      msg.type,
        timestamp: msg.timestamp,
        hasMedia:  msg.hasMedia
    });

    try {
        const http = require('http');
        const options = {
            hostname: 'localhost',
            port: 8645,
            path: '/',
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) }
        };
        const req = http.request(options);
        req.on('error', e => console.error('Router forward error:', e.message));
        req.write(payload);
        req.end();
    } catch(e) {
        console.error('Router forward error:', e.message);
    }
});
