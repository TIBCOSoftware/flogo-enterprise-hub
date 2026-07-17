# Flogo Chatbot — WebSocket Test Client

A browser-based chat UI for testing any TIBCO Flogo Agentic AI sample that exposes a WebSocket endpoint. It provides multiple chat sessions, a configurable WebSocket URL (editable from the UI), and connection status feedback — so you can interact with your Flogo agents without installing Postman or learning CLI tools.

## Prerequisites

- **Node.js** 14+ and **npm** 6+

## Quick Start

```bash
cd samples/Agentic_AI/Chatbot
npm install
npm start
```

Open **http://localhost:3000** in your browser.

If port 3000 is already in use, start on a different port:

```bash
PORT=3001 npm start
```

Then open **http://localhost:3001** instead.

## Connecting to a Flogo WebSocket App

1. The default WebSocket URL is pre-filled: `ws://localhost:8082/ws/chat`. Update it to match your Flogo sample's WebSocket endpoint (see the table below).
2. To change the URL, edit the input field at the top of the chat area and click the refresh icon to apply.
3. Click **Connect** in the header — the status indicator turns green when connected.
4. Type a message and press **Enter** to send.

### Example WebSocket URLs for Flogo Samples

| Sample | WebSocket URL |
|---|---|
| [IT Help Desk Advisor](../LLMClient-Dynamic-Config-And-Memory/) | `ws://localhost:9200/helpdesk?sessionId=session-001` |
| [Smart Supply Chain Assistant](../Smart-Supply-Chain-Assistant/) | `ws://localhost:9090/ws/supply-chain` |
| [Healthcare Patient Support Agent](../Healthcare-Compliance-Agent/) | `ws://localhost:9090/ws/patient` |
| [Mobile Customer Care Hub](../Mobile-Customer-Care-Multi-Agent/) | `ws://localhost:9090/ws/care` |

> **Note**: Check each sample's README for the exact WebSocket URL and port.

## Features

- **Multiple Chat Sessions** — create, switch between, and delete chat conversations
- **Configurable WebSocket URL** — update the target URL directly from the UI
- **Connection Status** — visual indicator with connect/disconnect controls
- **Chat History** — persistent chat history in browser localStorage
- **Plain Text Messages** — sends raw text strings, compatible with Flogo WebSocket triggers (`format: "String"`)

## Environment Variables (Optional)

```bash
cp env.example .env
```

| Variable | Default | Description |
|---|---|---|
| `PORT` | `3000` | Chatbot server port |
| `WS_URL` | `ws://localhost:8082/ws/chat` | Default WebSocket backend URL |

## Project Structure

```
Chatbot/
├── config/config.js       # Configuration (loads env variables)
├── public/
│   ├── css/style.css      # Stylesheet
│   └── js/app.js          # Main application JavaScript
├── routes/index.js        # Express routes
├── views/index.html       # HTML template
├── env.example            # Environment variable template
├── package.json           # Dependencies
├── server.js              # Express server entry point
└── README.md
```

## Troubleshooting

- **Cannot connect**: Verify the Flogo WebSocket app is running and the URL is correct (must start with `ws://` or `wss://`)
- **Port 3000 in use**: Change `PORT` in `.env` or run `lsof -ti:3000 | xargs kill`
- **WebSocket URL not updating**: The chatbot saves the WebSocket URL in browser localStorage. If you see an old URL after changing the default, either update it manually in the UI (and click the refresh icon), or clear it from the browser console: `localStorage.removeItem('flogoChatbot_wsUrl')` then refresh the page
- **No response from agent**: Ensure the Flogo app's LLM provider API key is configured and the MCP/A2A backend servers are running
