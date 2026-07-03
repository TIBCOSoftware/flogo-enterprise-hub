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
const server = app.listen(PORT, () => {
  console.log(`Flogo Chatbot server running on http://localhost:${PORT}`);
  console.log(`WebSocket backend URL: ${config.wsUrl}`);
  console.log(`Press Ctrl+C to stop the server`);
});

process.on('SIGINT', () => {
  console.log('\nStopping Flogo Chatbot server...');
  server.close(() => process.exit(0));
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`\nError: Port ${PORT} is already in use.`);
    console.error(`Fix: Run with a different port, e.g.  PORT=3001 npm start\n`);
  } else {
    console.error('Server error:', err);
  }
  process.exit(1);
});

