/**
 * Main routes for the Flogo Chatbot (Secure Proxy) application
 */

const express = require('express');
const router = express.Router();
const path = require('path');
const config = require('../config/config');

// Serve the main HTML page
router.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, '../views/index.html'));
});

// Non-secret settings the page needs (no tokens here)
router.get('/client-config', (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.json({
    appName: config.appName,
    defaultUpstream: config.wsUrl,
    allowedUpstreams: config.allowedUpstreams,
    directMode: config.directMode
  });
});

module.exports = router;
