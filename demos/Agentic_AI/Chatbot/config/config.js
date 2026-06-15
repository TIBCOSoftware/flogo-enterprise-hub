/**
 * Configuration module for the Flogo Chatbot application
 * Loads environment variables with sensible defaults
 */

require('dotenv').config();

module.exports = {
  // Server port (default: 3000)
  port: process.env.PORT || 3000,
  
  // WebSocket backend URL (default: ws://localhost:8082/ws/chat)
  wsUrl: process.env.WS_URL || 'ws://localhost:8082/ws/chat',
  
  // Application name
  appName: 'Flogo Chatbot'
};

