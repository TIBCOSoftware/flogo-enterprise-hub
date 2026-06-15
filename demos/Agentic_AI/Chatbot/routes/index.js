/**
 * Main routes for the Flogo Chatbot application
 */

const express = require('express');
const router = express.Router();
const path = require('path');

// Serve the main HTML page
router.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, '../views/index.html'));
});

module.exports = router;

