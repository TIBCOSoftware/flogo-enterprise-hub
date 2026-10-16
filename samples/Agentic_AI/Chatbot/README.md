# Flogo Agentic AI Chatbot

A minimalist, domain-agnostic chatbot web application with WebSocket support, multiple chat sessions, and a clean, modern UI. It is the shared browser front-end for every use case under `samples/Agentic_AI/`.

> **Shared UI for all Agentic AI use cases.** This is the common front-end web chat client used by
> every demo under `samples/Agentic_AI/` (Power Distribution, Retail Banking, Semiconductor, Telecom,
> and others). It has **no backend or apps of its own** — it simply connects to a use case's **AI
> Orchestrator WebSocket endpoint**. Examples: Power Distribution `ws://localhost:9680/grid` ·
> Retail Banking `ws://localhost:8088/banking` · Semiconductor `ws://localhost:9310/semiconductor`.
> Each use case's README lists its exact URL.

### 🔌 Connecting to a use case (the step people miss)

1. `npm install` (first time only), then `npm start`, and open **http://localhost:3000**.
2. In the URL box at the top right, enter the use case's orchestrator URL, e.g. `ws://localhost:9840/authorservices`.
3. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it, and
   an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
4. Click **Connect**. The status turns green: **● Connected**.

Won't connect? Click **Disconnect** first (↻ is refused while connected), click **↻** again, then
**Connect**. The browser remembers the last URL you applied, so a URL from a previous demo is a common
cause. `WS_URL` in `.env` does **not** set the browser's URL; the server only prints it at startup.

## ✨ Features

- **Multiple Chat Sessions**: Create, switch between, and manage multiple chat conversations
- **WebSocket Integration**: Real-time communication with backend WebSocket server
- **Configurable Backend URL**: Update WebSocket URL directly from the UI
- **Connection Management**: Visual connection status indicator with connect/disconnect controls
- **Message History**: Persistent chat history with timestamps
- **Responsive Design**: Works seamlessly on desktop and mobile devices
- **Clean, Minimalist Theme**: Modern design with configurable accent colors

## 📋 Prerequisites

Before you begin, ensure you have the following installed:

- **Node.js**: Version 16.0.0 or higher
- **npm**: Usually comes with Node.js (version 6.0.0 or higher)

To check your versions:
```bash
node --version
npm --version
```

## 🚀 Installation

1. **Clone or download the project** to your local machine

2. **Navigate to the project directory**:
   ```bash
   cd Chatbot
   ```

3. **Install dependencies**:
   ```bash
   npm install
   ```

4. **Set up environment variables** (optional):
   ```bash
   cp env.example .env
   ```
   
   Edit the `.env` file if you want to customize:
   - `PORT`: Server port (default: 3000)
   - `WS_URL`: printed by the server at startup only; it does not set the browser's URL (use the URL box + ↻)

## 🏃 Running the Application

### Start the Server

```bash
npm start
```

For development with auto-reload (requires nodemon):
```bash
npm run dev
```

The application will be available at: **http://localhost:3000**

### Start the WebSocket Backend

Make sure your WebSocket backend server is running on `ws://localhost:9600/lifepensions` (or update the URL in the UI).

## 📖 Usage

### Connecting to WebSocket Server

1. **Configure WebSocket URL** (if needed):
   - Enter your WebSocket URL in the input field at the top of the chat area
   - Click the refresh icon (🔄) to update the URL
   - Default URL: `ws://localhost:9600/lifepensions`

2. **Connect**:
   - Click the "Connect" button in the header
   - The connection status indicator will turn green when connected
   - You can now send messages

3. **Disconnect**:
   - Click the "Disconnect" button to close the connection

### Managing Chat Sessions

1. **Create New Chat**:
   - Click the "+" button in the sidebar
   - A new chat session will be created

2. **Switch Between Chats**:
   - Click on any chat session in the sidebar
   - The active chat is highlighted in blue

3. **Delete Chat**:
   - Click the trash icon (🗑️) on any chat session
   - Confirm deletion when prompted
   - Note: You cannot delete the last remaining chat

### Sending Messages

1. **Type your message** in the input area at the bottom
2. **Press Enter** or click the send button (✈️)
3. **Messages are displayed** with timestamps and sender information
4. **Bot responses** appear automatically when received from the WebSocket server

### Message Types

- **User Messages**: Displayed in blue bubbles on the right
- **Bot Messages**: Displayed in gray bubbles on the left
- **System Messages**: Yellow notifications for connection status

## 🏗️ Project Structure

```
Chatbot/
├── config/
│   └── config.js          # Configuration module (loads env variables)
├── public/
│   ├── css/
│   │   └── style.css      # Main stylesheet (theme)
│   └── js/
│       └── app.js         # Main application JavaScript
├── routes/
│   └── index.js           # Express routes
├── views/
│   └── index.html         # Main HTML template
├── .env                   # Environment variables (create from env.example)
├── .gitignore            # Git ignore file
├── package.json          # Node.js dependencies and scripts
├── server.js             # Express server entry point
└── README.md             # This file
```

## ⚙️ Configuration

### Environment Variables

Create a `.env` file in the root directory:

```env
PORT=3000
WS_URL=ws://localhost:9600/lifepensions
```

### WebSocket Message Format

The application sends messages in JSON format:
```json
{
  "message": "Your message text here"
}
```

The application expects responses in one of these formats:
- JSON: `{"message": "Response text"}`
- Plain text: `"Response text"`

## 🔧 Development

### Project Dependencies

- **express**: Web server framework
- **ws**: WebSocket client library
- **dotenv**: Environment variable management

### Code Structure

- **Frontend**: Vanilla JavaScript (ES6+), no frameworks
- **Backend**: Express.js for serving static files
- **Storage**: localStorage for chat persistence
- **Styling**: Pure CSS with CSS variables for theming

## 🐛 Troubleshooting

### Connection Issues

1. **Cannot connect to WebSocket**:
   - Verify the WebSocket backend is running
   - Check the WebSocket URL is correct
   - Ensure the URL starts with `ws://` or `wss://`
   - Check browser console for error messages

2. **Connection drops frequently**:
   - Check network stability
   - Verify backend server is not restarting
   - Review backend logs for errors

### Port Already in Use

If port 3000 is already in use:
1. Change the `PORT` in `.env` file
2. Or kill the process using port 3000:
   ```bash
   # macOS/Linux
   lsof -ti:3000 | xargs kill
   
   # Windows
   netstat -ano | findstr :3000
   taskkill /PID <PID> /F
   ```

### Chat History Not Persisting

- Check browser localStorage is enabled
- Clear browser cache if issues persist
- Check browser console for storage errors

## 📝 Notes

- Chat sessions are stored in browser localStorage
- Data persists across browser sessions
- Each browser/device maintains its own chat history
- WebSocket connection must be established before sending messages

## 🔒 Security Considerations

- This is a local development application
- For production use, consider:
  - Adding authentication
  - Implementing HTTPS/WSS
  - Input validation and sanitization
  - Rate limiting
  - CORS configuration

## 📄 License

MIT License - feel free to use this project for your own purposes.

## 🤝 Contributing

This is a standalone project. Feel free to fork and modify as needed.

## 📞 Support

For issues or questions:
1. Check the troubleshooting section
2. Review browser console for errors
3. Verify WebSocket backend is functioning correctly

---

**A shared WebSocket test client for TIBCO Flogo® Agentic AI demos**

