# Test a use case in the chatbot

Every Agentic AI use case is tested through the same browser client:
**`samples/Agentic_AI/Chatbot/`** (from a use-case folder: `../Chatbot`). It has no apps of its own. It
just opens a WebSocket to the use case's AI Orchestrator.

Give the user these steps at the end of every build, **filled in** with the use case's real URL
(`ws://localhost:<WebSocket_PORT><handler path>`, from the orchestrator's `tr_wsserver` port property and
handler `path`), and put the same steps in the use case README.

```markdown
### Test it in the chatbot

1. Start the apps in order: **MCP Server → A2A Agents → AI Orchestrator**.
2. Start the chat client (Node.js 16+). It lives in `samples/Agentic_AI/Chatbot`:
   ```bash
   cd samples/Agentic_AI/Chatbot
   npm install    # first time only
   npm start
   ```
3. Open **http://localhost:3000**.
4. In the URL box at the top right, replace the default with **`ws://localhost:<port>/<path>`**.
5. **Click the ↻ (refresh) icon next to the URL box.** Typing the URL alone does nothing: ↻ applies it, and
   an alert confirms *"WebSocket URL updated. Click Connect to use the new URL."*
6. Click **Connect**. The status turns green: **● Connected**.
7. Send a prompt from `prompts.md`.

**Won't connect?** Click **Disconnect** (↻ is refused while connected), check the URL, click **↻** again,
then **Connect**. Make sure the orchestrator is running and its port and path match the URL.
```

Notes:
- The chatbot remembers the last applied URL in the browser, so a URL left over from another use case is a
  common cause of "connected but no answer". Always re-apply the URL with ↻.
- The chatbot's own port is `3000` (`PORT` in `Chatbot/.env`, copied from `env.example`).
