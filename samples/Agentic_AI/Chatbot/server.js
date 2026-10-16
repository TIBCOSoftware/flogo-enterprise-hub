/**
 * Main server file for Flogo Chatbot application
 * Sets up Express server and serves the application
 */

const express = require('express');
const path = require('path');
const config = require('./config/config');

const app = express();

// Middleware
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Serve static files from public directory
app.use(express.static(path.join(__dirname, 'public')));

// Routes
app.use('/', require('./routes/index'));

// Error handling middleware
app.use((err, req, res, next) => {
  console.error('Error:', err);
  res.status(500).json({ error: 'Internal server error' });
});

// Start server
const PORT = config.port;
app.listen(PORT, () => {
  console.log(`Flogo Chatbot server running on http://localhost:${PORT}`);
  console.log(`WebSocket backend URL: ${config.wsUrl}`);
});

