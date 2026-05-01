'use strict';

const express = require('express');
const path = require('path');
const http = require('http');
const os = require('os');

const app = express();
const PORT = process.env.PORT || 3000;
const ENV_COLOR = process.env.ENV_COLOR || 'blue';
const APP_VERSION = process.env.APP_VERSION || '1.0.0';

// ─── Middleware ────────────────────────────────────────────────────────────────
app.use(express.json());
app.use(express.static(path.join(__dirname, '..', 'public')));

// ─── EC2 Instance Metadata (IMDSv2) ───────────────────────────────────────────
async function getInstanceId() {
  return new Promise((resolve) => {
    // Step 1: Get IMDSv2 token
    const tokenReq = http.request(
      {
        hostname: '169.254.169.254',
        path: '/latest/api/token',
        method: 'PUT',
        headers: { 'X-aws-ec2-metadata-token-ttl-seconds': '21600' },
        timeout: 1500,
      },
      (res) => {
        let token = '';
        res.on('data', (chunk) => (token += chunk));
        res.on('end', () => {
          // Step 2: Use token to get instance-id
          const idReq = http.request(
            {
              hostname: '169.254.169.254',
              path: '/latest/meta-data/instance-id',
              method: 'GET',
              headers: { 'X-aws-ec2-metadata-token': token.trim() },
              timeout: 1500,
            },
            (r) => {
              let id = '';
              r.on('data', (c) => (id += c));
              r.on('end', () => resolve(id.trim() || 'i-local-dev'));
            }
          );
          idReq.on('error', () => resolve('i-local-dev'));
          idReq.on('timeout', () => { idReq.destroy(); resolve('i-local-dev'); });
          idReq.end();
        });
      }
    );
    tokenReq.on('error', () => resolve('i-local-dev'));
    tokenReq.on('timeout', () => { tokenReq.destroy(); resolve('i-local-dev'); });
    tokenReq.end();
  });
}

// ─── Routes ───────────────────────────────────────────────────────────────────

/** Dashboard data API */
app.get('/api/info', async (req, res) => {
  const instanceId = await getInstanceId();
  res.json({
    environment: ENV_COLOR,
    version: APP_VERSION,
    instanceId,
    hostname: os.hostname(),
    uptime: Math.floor(process.uptime()),
    nodeVersion: process.version,
    platform: os.platform(),
    cpuCores: os.cpus().length,
    totalMemMb: Math.round(os.totalmem() / 1024 / 1024),
    freeMemMb: Math.round(os.freemem() / 1024 / 1024),
    loadAvg: os.loadavg().map((n) => n.toFixed(2)),
    timestamp: new Date().toISOString(),
  });
});

/** Health check – used by the CI/CD pipeline */
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'healthy',
    environment: ENV_COLOR,
    version: APP_VERSION,
    timestamp: new Date().toISOString(),
  });
});

/** CPU stress endpoint – burns CPU for <duration> seconds (max 30s) */
app.get('/load', (req, res) => {
  const duration = Math.min(parseInt(req.query.duration, 10) || 5, 30);
  const start = Date.now();
  let iterations = 0;

  while (Date.now() - start < duration * 1000) {
    Math.sqrt(Math.random() * 1e9);
    iterations++;
  }

  res.json({
    message: `CPU stress complete`,
    duration: `${duration}s`,
    iterations,
    environment: ENV_COLOR,
  });
});

/** Serve SPA for all other routes */
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, '..', 'public', 'index.html'));
});

// ─── Start Server ─────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  console.log(`[${ENV_COLOR.toUpperCase()}] v${APP_VERSION} running on port ${PORT}`);
});

module.exports = app;
