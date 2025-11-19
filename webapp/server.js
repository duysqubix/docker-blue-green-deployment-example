const http = require('node:http');
const os = require('node:os');

const port = Number(process.env.PORT || 3000);
const deployColor = (process.env.DEPLOY_COLOR || 'unknown').toLowerCase();
const traefikEnabled = process.env.TRAEFIK_ENABLE || 'unknown';
const hostname = os.hostname();

const palette = {
  blue: '#1e3a8a',
  green: '#166534',
};

const accentColor = palette[deployColor] || '#0f172a';

const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Blue/Green Demo</title>
  <style>
    :root {
      color-scheme: light dark;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    body {
      margin: 0;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      background: radial-gradient(circle at top, ${accentColor}aa 0%, #020617 70%);
      color: #f8fafc;
    }
    .card {
      background: rgba(15, 23, 42, 0.8);
      padding: 2.5rem 3rem;
      border-radius: 1.25rem;
      box-shadow: 0 25px 50px -12px rgba(15, 23, 42, 0.9);
      text-align: center;
      border: 1px solid rgba(248, 250, 252, 0.1);
      max-width: 34rem;
    }
    h1 {
      font-size: clamp(2.5rem, 4vw, 3.5rem);
      margin: 0;
      text-transform: capitalize;
      color: ${accentColor};
    }
    p {
      margin: 0.35rem 0;
      font-size: 1.05rem;
      color: #e2e8f0;
    }
    .color-dot {
      display: inline-block;
      width: 0.65rem;
      height: 0.65rem;
      border-radius: 999px;
      background: ${accentColor};
      margin-right: 0.35rem;
    }
    .meta {
      margin-top: 1.5rem;
      padding-top: 1rem;
      border-top: 1px solid rgba(248, 250, 252, 0.12);
      font-size: 0.95rem;
    }
    code {
      background: rgba(15, 23, 42, 0.65);
      padding: 0.1rem 0.4rem;
      border-radius: 0.35rem;
      font-size: 0.9rem;
    }
  </style>
</head>
<body>
  <section class="card">
    <p>Currently serving</p>
    <h1>${deployColor} deployment</h1>
    <div class="meta">
      <p><span class="color-dot"></span><strong>Container:</strong> <code>${hostname}</code></p>
      <p><strong>Port:</strong> <code>${port}</code></p>
      <p><strong>Traefik enabled:</strong> <code>${traefikEnabled}</code></p>
      <p><strong>Timestamp:</strong> <code>${new Date().toISOString()}</code></p>
    </div>
  </section>
</body>
</html>`;

const server = http.createServer((req, res) => {
  const pathname = (() => {
    try {
      return new URL(req.url, `http://${req.headers.host || 'localhost'}`).pathname;
    } catch {
      return '/';
    }
  })();

  if (pathname === '/color') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ color: deployColor }));
    return;
  }

  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(html);
});

server.listen(port, () => {
  console.log(`Webapp listening on http://0.0.0.0:${port} as ${deployColor} deployment`);
});
