/**
 * Configuration module for the Flogo Chatbot application
 * Loads environment variables with sensible defaults
 */

require('dotenv').config();

module.exports = {
  // Server port (default: 3000)
  port: process.env.PORT || 3000,
  
  // WebSocket backend URL (default: ws://localhost:9600/lifepensions)
  wsUrl: process.env.WS_URL || 'ws://localhost:9600/lifepensions',
  
  // Application name
  appName: 'Flogo Chatbot'
};

