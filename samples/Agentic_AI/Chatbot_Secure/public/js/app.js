/**
 * Flogo Chatbot (Secure Proxy) - Main Application JavaScript
 * Handles sign-in, WebSocket connections, chat sessions, and UI interactions.
 *
 * Proxy mode (default): the user's JWT is POSTed once to /auth/session and kept
 * on the server; the page never stores it. The page opens its WebSocket to this
 * server (/proxy?target=...), which connects to the upstream Flogo orchestrator
 * with an Authorization: Bearer header.
 */

class FlogoChatbot {
    constructor() {
        // WebSocket connection
        this.ws = null;
        this.wsUrl = 'ws://localhost:9970/retailbanking';
        this.isConnected = false;

        // Server-provided settings and sign-in state (no token is kept in the page)
        this.clientConfig = { allowedUpstreams: [], defaultUpstream: this.wsUrl, directMode: false };
        this.auth = { signedIn: false };
        
        // Chat sessions management. History belongs to one signed-in user (chatOwner = their sub); it is restored
        // only once the server confirms that user's session, and never shown while signed out.
        this.chats = new Map();
        this.currentChatId = null;
        this.chatCounter = 0;
        this.chatOwner = null;
        
        // DOM elements
        this.elements = {
            connectBtn: document.getElementById('connectBtn'),
            disconnectBtn: document.getElementById('disconnectBtn'),
            statusIndicator: document.getElementById('statusIndicator'),
            statusText: document.getElementById('statusText'),
            wsUrlInput: document.getElementById('wsUrlInput'),
            updateWsUrlBtn: document.getElementById('updateWsUrlBtn'),
            newChatBtn: document.getElementById('newChatBtn'),
            chatSessions: document.getElementById('chatSessions'),
            messagesContainer: document.getElementById('messagesContainer'),
            messageInput: document.getElementById('messageInput'),
            sendBtn: document.getElementById('sendBtn'),
            currentChatTitle: document.getElementById('currentChatTitle'),
            upstreamList: document.getElementById('upstreamList'),
            directToggle: document.getElementById('directToggle'),
            directModeInput: document.getElementById('directModeInput'),
            jwtInput: document.getElementById('jwtInput'),
            signInBtn: document.getElementById('signInBtn'),
            signOutBtn: document.getElementById('signOutBtn'),
            authSignedOut: document.getElementById('authSignedOut'),
            authSignedIn: document.getElementById('authSignedIn'),
            authError: document.getElementById('authError'),
            authName: document.getElementById('authName'),
            authSub: document.getElementById('authSub'),
            authExp: document.getElementById('authExp'),
            authScopes: document.getElementById('authScopes')
        };
        
        // Initialize application
        this.init();
    }
    
    /**
     * Initialize the application
     */
    async init() {
        this.loadSettingsFromStorage();
        this.setupEventListeners();
        this.updateUI(); // no history yet: it is restored only after the session check, for its owner
        await this.loadClientConfig();
        await this.refreshAuthStatus();
        // Another tab signed in or out (the session cookie is shared): check the session again
        window.addEventListener('storage', (e) => {
            if (e.key === null || e.key === 'flogoChatbotSecure_owner') this.refreshAuthStatus();
        });
    }

    /**
     * Load non-secret settings (allowed upstreams, direct mode) from the server
     */
    async loadClientConfig() {
        try {
            const res = await fetch('/client-config', { credentials: 'same-origin', cache: 'no-store' });
            if (!res.ok) return;
            this.clientConfig = await res.json();
        } catch (error) {
            console.error('Could not load client config:', error);
            return;
        }

        const allowed = this.clientConfig.allowedUpstreams || [];
        this.elements.upstreamList.innerHTML = '';
        allowed.forEach(url => {
            const option = document.createElement('option');
            option.value = url;
            this.elements.upstreamList.appendChild(option);
        });

        // A remembered URL that is no longer allowed falls back to the default
        if (!allowed.includes(this.wsUrl) && this.clientConfig.defaultUpstream) {
            this.wsUrl = this.clientConfig.defaultUpstream;
        }
        this.elements.wsUrlInput.value = this.wsUrl;

        this.elements.directToggle.hidden = !this.clientConfig.directMode;
        if (!this.clientConfig.directMode) this.elements.directModeInput.checked = false;
    }

    /**
     * True when the user chose direct (unauthenticated) mode and the server allows it
     */
    isDirectMode() {
        return !!(this.clientConfig.directMode && this.elements.directModeInput.checked);
    }

    /**
     * Ask the server whether this browser has a live session (non-secret claims only)
     */
    async refreshAuthStatus() {
        try {
            const res = await fetch('/auth/session', { credentials: 'same-origin', cache: 'no-store' });
            this.auth = res.ok ? await res.json() : { signedIn: false };
        } catch (error) {
            this.auth = { signedIn: false };
        }
        this.renderAuth();
        return this.auth;
    }

    /**
     * Send the pasted JWT to the server ONCE; the server keeps it and sets an HttpOnly cookie
     */
    async signIn() {
        const input = this.elements.jwtInput;
        const token = input.value.trim();
        input.value = ''; // never keep the token in the page
        this.showAuthError('');
        if (!token) {
            this.showAuthError('Paste a token first.');
            return;
        }

        this.elements.signInBtn.disabled = true;
        try {
            const res = await fetch('/auth/session', {
                method: 'POST',
                credentials: 'same-origin',
                cache: 'no-store',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ token })
            });
            const body = await res.json().catch(() => ({}));
            if (!res.ok) {
                this.showAuthError(body.error || `Sign-in failed (${res.status})`);
                this.auth = { signedIn: false };
            } else {
                this.auth = body;
            }
        } catch (error) {
            this.showAuthError('Sign-in failed: server unreachable.');
        } finally {
            this.elements.signInBtn.disabled = false;
        }
        this.renderAuth();
    }

    /**
     * Sign out: drop the server session (closes proxied connections) and clear local chat history
     */
    async signOut() {
        this.disconnect();
        try {
            await fetch('/auth/session', { method: 'DELETE', credentials: 'same-origin', cache: 'no-store' });
        } catch (error) {
            console.error('Sign-out request failed:', error);
        }
        this.auth = { signedIn: false };
        this.renderAuth(); // signed out: drops the history (releaseChats)
    }

    showAuthError(text) {
        this.elements.authError.textContent = text;
        this.elements.authError.hidden = !text;
    }

    /**
     * Render the sign-in panel (textContent only: claims are untrusted input)
     */
    renderAuth() {
        const signedIn = !!(this.auth && this.auth.signedIn);
        this.elements.authSignedOut.hidden = signedIn;
        this.elements.authSignedIn.hidden = !signedIn;
        if (signedIn) {
            this.claimChats(this.auth.sub);
            this.elements.authName.textContent = this.auth.name || '(no name claim)';
            this.elements.authSub.textContent = `sub: ${this.auth.sub || '-'}`;
            const exp = this.auth.exp ? new Date(this.auth.exp * 1000) : null;
            this.elements.authExp.textContent = exp ? `Token expires: ${exp.toLocaleString()}` : 'Token has no exp claim';
            this.elements.authScopes.innerHTML = '';
            (this.auth.scp || []).forEach(scope => {
                const chip = document.createElement('span');
                chip.className = 'scope-chip';
                chip.textContent = scope;
                this.elements.authScopes.appendChild(chip);
            });
        } else {
            this.releaseChats();
        }
        this.updateConnectionStatus(this.isConnected);
    }

    /**
     * Chats in localStorage belong to one signed-in user. Restore them only for that user; anyone else (a different
     * user, also after a sign-in from another tab) starts from an empty history and the stored one is deleted.
     */
    claimChats(sub) {
        const owner = sub || '-';
        if (this.chatOwner === owner) return;
        if (this.isConnected) return; // never replace the conversation that is on screen
        this.resetChats();
        if (localStorage.getItem('flogoChatbotSecure_owner') === owner) {
            this.loadChatsFromStorage();
        } else {
            this.forgetStoredChats();
            localStorage.setItem('flogoChatbotSecure_owner', owner);
        }
        this.chatOwner = owner;
        this.updateUI();
    }

    /**
     * Signed out (sign-out, an expired session, a server restart, another tab): the history is neither shown nor kept,
     * so the next person at this browser cannot read it.
     */
    releaseChats() {
        if (this.isConnected) return; // a live direct-mode conversation (no sign-in) stays on screen
        if (this.chatOwner !== null) {
            this.resetChats();
            this.chatOwner = null;
            this.updateUI();
        }
        this.forgetStoredChats();
        localStorage.removeItem('flogoChatbotSecure_owner');
    }

    /**
     * Empty the chats in memory (the stored copy is handled by the caller)
     */
    resetChats() {
        this.chats.clear();
        this.currentChatId = null;
        this.chatCounter = 0;
    }

    /**
     * Delete the stored chat history (the upstream URL setting is kept)
     */
    forgetStoredChats() {
        localStorage.removeItem('flogoChatbotSecure_chats');
        localStorage.removeItem('flogoChatbotSecure_currentChatId');
        localStorage.removeItem('flogoChatbotSecure_chatCounter');
    }
    
    /**
     * Set up all event listeners
     */
    setupEventListeners() {
        // Connection controls
        this.elements.connectBtn.addEventListener('click', () => this.connect());
        this.elements.disconnectBtn.addEventListener('click', () => this.disconnect());
        this.elements.updateWsUrlBtn.addEventListener('click', () => this.updateWsUrl());

        // Sign in / out
        this.elements.signInBtn.addEventListener('click', () => this.signIn());
        this.elements.jwtInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') {
                e.preventDefault();
                this.signIn();
            }
        });
        this.elements.signOutBtn.addEventListener('click', () => this.signOut());
        this.elements.directModeInput.addEventListener('change', () => this.updateConnectionStatus(this.isConnected));
        
        // Chat management
        this.elements.newChatBtn.addEventListener('click', () => this.createNewChat());
        
        // Message sending
        this.elements.sendBtn.addEventListener('click', () => this.sendMessage());
        this.elements.messageInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                this.sendMessage();
            }
        });
        
        // Auto-resize textarea
        this.elements.messageInput.addEventListener('input', () => {
            this.elements.messageInput.style.height = 'auto';
            this.elements.messageInput.style.height = this.elements.messageInput.scrollHeight + 'px';
        });
    }
    
    /**
     * Update WebSocket URL from input field
     */
    updateWsUrl() {
        const newUrl = this.elements.wsUrlInput.value.trim();
        if (newUrl && (newUrl.startsWith('ws://') || newUrl.startsWith('wss://'))) {
            if (this.isConnected) {
                alert('Please disconnect before changing the WebSocket URL');
                return;
            }
            const allowed = this.clientConfig.allowedUpstreams || [];
            if (!this.isDirectMode() && !allowed.includes(newUrl)) {
                alert('That URL is not on the server allow-list (ALLOWED_UPSTREAMS):\n' + allowed.join('\n'));
                return;
            }
            this.wsUrl = newUrl;
            alert('WebSocket URL updated. Click Connect to use the new URL.');
        } else {
            alert('Please enter a valid WebSocket URL (starting with ws:// or wss://)');
        }
    }
    
    /**
     * Connect to WebSocket server
     */
    connect() {
        if (this.isConnected || (this.ws && this.ws.readyState === WebSocket.CONNECTING)) {
            console.log('Already connected or connecting');
            return;
        }
        
        const direct = this.isDirectMode();
        if (!direct && !(this.auth && this.auth.signedIn)) {
            alert('Please sign in first.');
            return;
        }
        if (!this.currentChatId) {
            this.createNewChat(); // so connection status messages have somewhere to appear
        }

        // Proxy mode: connect to this server; it adds the Authorization header upstream.
        // Direct mode: connect straight to the upstream (no token is ever sent).
        const scheme = window.location.protocol === 'https:' ? 'wss' : 'ws';
        const url = direct
            ? this.wsUrl
            : `${scheme}://${window.location.host}/proxy?target=${encodeURIComponent(this.wsUrl)}`;

        try {
            console.log(`Connecting to ${this.wsUrl}${direct ? ' (direct)' : ' via proxy'}...`);
            const ws = new WebSocket(url);
            this.ws = ws;
            let opened = false;
            this.updateConnectionStatus(false); // disables Connect while the handshake is in progress

            // Connection opened
            ws.onopen = () => {
                if (this.ws !== ws) return;
                console.log('WebSocket connected');
                opened = true;
                this.isConnected = true;
                this.updateConnectionStatus(true);
                this.addSystemMessage('Connected to server');
            };
            
            // Message received
            ws.onmessage = (event) => {
                if (this.ws !== ws) return;
                try {
                    const data = JSON.parse(event.data);
                    this.handleIncomingMessage(data);
                } catch (e) {
                    // If not JSON, treat as plain text
                    this.handleIncomingMessage({ message: event.data });
                }
            };
            
            // Connection closed
            ws.onclose = async (event) => {
                if (this.ws !== ws && this.ws !== null) return; // a newer connection replaced this one
                if (this.ws === ws) this.ws = null;
                console.log('WebSocket disconnected');
                this.isConnected = false;
                this.updateConnectionStatus(false);
                if (!direct) {
                    const auth = await this.refreshAuthStatus();
                    if (!auth.signedIn) {
                        this.showAuthError('Not signed in (or the session ended). Please sign in again.');
                        return;
                    }
                    if (!opened) {
                        this.addSystemMessage('Could not reach the orchestrator through the proxy. Check it is running and the URL is allowed.');
                        return;
                    }
                }
                this.addSystemMessage(event && event.reason ? `Disconnected: ${event.reason}` : 'Disconnected from server');
            };

            // Error handling (details are reported by onclose)
            ws.onerror = (error) => {
                if (this.ws !== ws) return;
                console.error('WebSocket error:', error);
                this.isConnected = false;
                this.updateConnectionStatus(false);
            };
            
        } catch (error) {
            console.error('Failed to connect:', error);
            alert('Failed to connect to WebSocket server. Please check the URL and try again.');
            this.isConnected = false;
            this.updateConnectionStatus(false);
        }
    }
    
    /**
     * Disconnect from WebSocket server
     */
    disconnect() {
        if (this.ws) {
            this.ws.close();
            this.ws = null;
        }
        this.isConnected = false;
        this.updateConnectionStatus(false);
    }
    
    /**
     * Update connection status UI
     */
    updateConnectionStatus(connected) {
        const indicator = this.elements.statusIndicator;
        const statusText = this.elements.statusText;
        
        if (connected) {
            indicator.classList.add('connected');
            statusText.textContent = 'Connected';
            this.elements.connectBtn.disabled = true;
            this.elements.disconnectBtn.disabled = false;
            this.elements.messageInput.disabled = false;
            this.elements.sendBtn.disabled = false;
        } else {
            indicator.classList.remove('connected');
            statusText.textContent = 'Disconnected';
            const connecting = !!(this.ws && this.ws.readyState === WebSocket.CONNECTING);
            this.elements.connectBtn.disabled = connecting || !(this.isDirectMode() || (this.auth && this.auth.signedIn));
            this.elements.disconnectBtn.disabled = true;
            this.elements.messageInput.disabled = true;
            this.elements.sendBtn.disabled = true;
        }
    }
    
    /**
     * Handle incoming message from WebSocket
     */
    handleIncomingMessage(data) {
        if (!this.currentChatId) {
            // Create a new chat if none exists
            this.createNewChat();
        }
        
        const message = {
            type: 'bot',
            content: [data.message, data.text].find(v => typeof v === 'string' && v) ||
                JSON.stringify(data.message && typeof data.message === 'object' ? data.message : data),
            timestamp: new Date()
        };
        
        this.addMessageToChat(this.currentChatId, message);
        this.saveChatsToStorage();
    }
    
    /**
     * Send message to WebSocket server
     */
    sendMessage() {
        const input = this.elements.messageInput;
        const message = input.value.trim();
        
        if (!message || !this.isConnected || !this.ws) {
            return;
        }
        
        if (!this.currentChatId) {
            this.createNewChat();
        }
        
        // Add user message to chat
        const userMessage = {
            type: 'user',
            content: message,
            timestamp: new Date()
        };
        
        this.addMessageToChat(this.currentChatId, userMessage);
        
        // Send to WebSocket server
        try {
            if (this.ws.readyState === WebSocket.OPEN) {
                // Try to send as JSON, fallback to plain text
                const payload = JSON.stringify({ message: message });
                this.ws.send(payload);
            } else {
                this.addSystemMessage('Connection lost. Please reconnect.');
            }
        } catch (error) {
            console.error('Error sending message:', error);
            this.addSystemMessage('Error sending message. Please try again.');
        }
        
        // Clear input
        input.value = '';
        input.style.height = 'auto';
        this.saveChatsToStorage();
    }
    
    /**
     * Create a new chat session
     */
    createNewChat() {
        this.chatCounter++;
        const chatId = `chat-${this.chatCounter}`;
        const chatTitle = `Chat ${this.chatCounter}`;
        
        const chat = {
            id: chatId,
            title: chatTitle,
            messages: [],
            createdAt: new Date()
        };
        
        this.chats.set(chatId, chat);
        this.currentChatId = chatId;
        
        this.updateChatSessionsList();
        this.displayChat(chatId);
        this.saveChatsToStorage();
    }
    
    /**
     * Switch to a different chat session
     */
    switchChat(chatId) {
        if (this.chats.has(chatId)) {
            this.currentChatId = chatId;
            this.displayChat(chatId);
            this.updateChatSessionsList();
        }
    }
    
    /**
     * Delete a chat session
     */
    deleteChat(chatId) {
        if (this.chats.size <= 1) {
            alert('Cannot delete the last chat session. Create a new one first.');
            return;
        }
        
        if (confirm('Are you sure you want to delete this chat session?')) {
            this.chats.delete(chatId);
            
            if (this.currentChatId === chatId) {
                // Switch to the first available chat
                const firstChatId = Array.from(this.chats.keys())[0];
                this.currentChatId = firstChatId;
                this.displayChat(firstChatId);
            }
            
            this.updateChatSessionsList();
            this.saveChatsToStorage();
        }
    }
    
    /**
     * Display a chat session
     */
    displayChat(chatId) {
        const chat = this.chats.get(chatId);
        if (!chat) return;
        
        // Update title
        this.elements.currentChatTitle.textContent = chat.title;
        
        // Clear messages container
        this.elements.messagesContainer.innerHTML = '';
        
        // Display all messages
        if (chat.messages.length === 0) {
            this.showWelcomeMessage();
        } else {
            chat.messages.forEach(msg => {
                this.renderMessage(msg);
            });
        }
        
        // Scroll to bottom
        this.scrollToBottom();
    }
    
    /**
     * Add message to a chat
     */
    addMessageToChat(chatId, message) {
        const chat = this.chats.get(chatId);
        if (!chat) return;
        
        chat.messages.push(message);
        this.renderMessage(message);
        this.scrollToBottom();
    }
    
    /**
     * Add system message
     */
    addSystemMessage(content) {
        if (!this.currentChatId) return;
        
        const message = {
            type: 'system',
            content: content,
            timestamp: new Date()
        };
        
        this.addMessageToChat(this.currentChatId, message);
    }
    
    /**
     * Render a message in the UI
     */
    renderMessage(message) {
        const container = this.elements.messagesContainer;
        
        // Remove welcome message if present
        const welcomeMsg = container.querySelector('.welcome-message');
        if (welcomeMsg) {
            welcomeMsg.remove();
        }
        
        const messageDiv = document.createElement('div');
        messageDiv.className = `message ${message.type}`;
        
        const timeStr = this.formatTimestamp(message.timestamp);
        
        if (message.type === 'system') {
            messageDiv.innerHTML = `
                <div class="message-content" style="margin-left: 0; background-color: #fef3c7; color: #92400e; text-align: center; font-size: 0.875rem;">
                    <i class="fas fa-info-circle"></i> ${this.escapeHtml(message.content)}
                </div>
            `;
        } else {
            const avatar = message.type === 'user' ? 'U' : 'B';
            const sender = message.type === 'user' ? 'You' : 'Bot';
            
            messageDiv.innerHTML = `
                <div class="message-header">
                    <div class="message-avatar">${avatar}</div>
                    <span class="message-sender">${sender}</span>
                    <span class="message-time">${timeStr}</span>
                </div>
                <div class="message-content">${this.formatMessageContent(message.content)}</div>
            `;
        }
        
        container.appendChild(messageDiv);
    }
    
    /**
     * Show welcome message
     */
    showWelcomeMessage() {
        const container = this.elements.messagesContainer;
        container.innerHTML = `
            <div class="welcome-message">
                <i class="fas fa-shield-halved"></i>
                <h2>Welcome to Flogo Chatbot (Secure Proxy)</h2>
                <p>Start a conversation by typing a message below</p>
            </div>
        `;
    }
    
    /**
     * Update chat sessions list in sidebar
     */
    updateChatSessionsList() {
        const container = this.elements.chatSessions;
        container.innerHTML = '';
        
        this.chats.forEach((chat, chatId) => {
            const sessionDiv = document.createElement('div');
            sessionDiv.className = `chat-session ${chatId === this.currentChatId ? 'active' : ''}`;
            sessionDiv.innerHTML = `
                <span class="chat-session-title" title="${chat.title}">${chat.title}</span>
                <button class="chat-session-delete" onclick="event.stopPropagation(); chatbot.deleteChat('${chatId}')" title="Delete chat">
                    <i class="fas fa-trash"></i>
                </button>
            `;
            
            sessionDiv.addEventListener('click', () => this.switchChat(chatId));
            container.appendChild(sessionDiv);
        });
    }
    
    /**
     * Update UI state
     */
    updateUI() {
        this.updateConnectionStatus(this.isConnected);
        this.updateChatSessionsList();
        
        if (this.currentChatId) {
            this.displayChat(this.currentChatId);
        } else {
            this.elements.messagesContainer.innerHTML = `
                <div class="welcome-message">
                    <i class="fas fa-shield-halved"></i>
                    <h2>Welcome to Flogo Chatbot (Secure Proxy)</h2>
                    <p>Sign in, then click Connect to start a conversation</p>
                </div>
            `;
        }
    }
    
    /**
     * Scroll messages container to bottom
     */
    scrollToBottom() {
        const container = this.elements.messagesContainer;
        container.scrollTop = container.scrollHeight;
    }
    
    /**
     * Format timestamp for display
     */
    formatTimestamp(date) {
        const d = new Date(date);
        const hours = String(d.getHours()).padStart(2, '0');
        const minutes = String(d.getMinutes()).padStart(2, '0');
        return `${hours}:${minutes}`;
    }
    
    /**
     * Escape HTML to prevent XSS
     */
    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
    
    /**
     * Format message content with proper line breaks and spacing for readability
     */
    formatMessageContent(text) {
        if (!text) return '';
        
        // Escape HTML first to prevent XSS
        const div = document.createElement('div');
        div.textContent = text;
        let escaped = div.innerHTML;
        
        // Normalize multiple consecutive newlines (3+ becomes 2)
        escaped = escaped.replace(/\n{3,}/g, '\n\n');
        
        // Split by double newlines to create paragraphs
        const paragraphs = escaped.split(/\n\n/);
        
        // Format each paragraph: convert single newlines to <br> and wrap in <p>
        const formattedParagraphs = paragraphs.map(para => {
            // Trim whitespace and convert single newlines to <br>
            const trimmed = para.trim();
            if (!trimmed) return '';
            const withBreaks = trimmed.replace(/\n/g, '<br>');
            return `<p>${withBreaks}</p>`;
        }).filter(p => p !== ''); // Remove empty paragraphs
        
        // If we have multiple paragraphs, join them; otherwise return single formatted text
        if (formattedParagraphs.length > 1) {
            return formattedParagraphs.join('');
        } else if (formattedParagraphs.length === 1) {
            return formattedParagraphs[0];
        } else {
            // Fallback: just convert newlines to <br>
            return escaped.replace(/\n/g, '<br>');
        }
    }
    
    /**
     * Save chats to localStorage - only for the signed-in user who owns the stored history (direct-mode chats,
     * without a sign-in, are not kept)
     */
    saveChatsToStorage() {
        try {
            localStorage.setItem('flogoChatbotSecure_wsUrl', this.wsUrl);
            if (!this.chatOwner || localStorage.getItem('flogoChatbotSecure_owner') !== this.chatOwner) return;
            const chatsData = Array.from(this.chats.entries()).map(([id, chat]) => ({
                id: chat.id,
                title: chat.title,
                messages: chat.messages.map(msg => ({
                    type: msg.type,
                    content: msg.content,
                    timestamp: msg.timestamp.toISOString()
                })),
                createdAt: chat.createdAt.toISOString()
            }));
            
            localStorage.setItem('flogoChatbotSecure_chats', JSON.stringify(chatsData));
            localStorage.setItem('flogoChatbotSecure_currentChatId', this.currentChatId);
            localStorage.setItem('flogoChatbotSecure_chatCounter', this.chatCounter.toString());
        } catch (error) {
            console.error('Error saving chats to storage:', error);
        }
    }
    
    /**
     * Load non-secret settings (the upstream URL) from localStorage
     */
    loadSettingsFromStorage() {
        const wsUrl = localStorage.getItem('flogoChatbotSecure_wsUrl');
        if (wsUrl) {
            this.wsUrl = wsUrl;
            this.elements.wsUrlInput.value = wsUrl;
        }
    }

    /**
     * Load chats from localStorage (only called by claimChats, for the stored history's owner)
     */
    loadChatsFromStorage() {
        try {
            const chatsData = localStorage.getItem('flogoChatbotSecure_chats');
            const currentChatId = localStorage.getItem('flogoChatbotSecure_currentChatId');
            const chatCounter = localStorage.getItem('flogoChatbotSecure_chatCounter');
            
            if (chatCounter) {
                this.chatCounter = parseInt(chatCounter, 10);
            }
            
            if (chatsData) {
                const parsed = JSON.parse(chatsData);
                parsed.forEach(chatData => {
                    const chat = {
                        id: chatData.id,
                        title: chatData.title,
                        messages: chatData.messages.map(msg => ({
                            type: msg.type,
                            content: msg.content,
                            timestamp: new Date(msg.timestamp)
                        })),
                        createdAt: new Date(chatData.createdAt)
                    };
                    this.chats.set(chat.id, chat);
                });
                
                if (currentChatId && this.chats.has(currentChatId)) {
                    this.currentChatId = currentChatId;
                } else if (this.chats.size > 0) {
                    this.currentChatId = Array.from(this.chats.keys())[0];
                }
            }
        } catch (error) {
            console.error('Error loading chats from storage:', error);
        }
    }
}

// Initialize the application when DOM is loaded
let chatbot;
document.addEventListener('DOMContentLoaded', () => {
    chatbot = new FlogoChatbot();
});

