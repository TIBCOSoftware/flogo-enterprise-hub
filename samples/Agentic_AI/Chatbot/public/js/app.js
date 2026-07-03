/**
 * Flogo Chatbot - Main Application JavaScript
 * Handles WebSocket connections, chat sessions, and UI interactions
 */

class FlogoChatbot {
    constructor() {
        // WebSocket connection
        this.ws = null;
        this.wsUrl = 'ws://localhost:8082/ws/chat';
        this.isConnected = false;
        
        // Chat sessions management
        this.chats = new Map();
        this.currentChatId = null;
        this.chatCounter = 0;
        
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
            clearChatBtn: document.getElementById('clearChatBtn')
        };
        
        // Initialize application
        this.init();
    }
    
    /**
     * Initialize the application
     */
    init() {
        this.loadChatsFromStorage();
        this.setupEventListeners();
        this.updateUI();
    }
    
    /**
     * Set up all event listeners
     */
    setupEventListeners() {
        // Connection controls
        this.elements.connectBtn.addEventListener('click', () => this.connect());
        this.elements.disconnectBtn.addEventListener('click', () => this.disconnect());
        this.elements.updateWsUrlBtn.addEventListener('click', () => this.updateWsUrl());
        
        // Chat management
        this.elements.newChatBtn.addEventListener('click', () => this.createNewChat());
        this.elements.clearChatBtn.addEventListener('click', () => this.clearCurrentChat());
        
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
        if (newUrl && newUrl.startsWith('ws://') || newUrl.startsWith('wss://')) {
            if (this.isConnected) {
                alert('Please disconnect before changing the WebSocket URL');
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
        if (this.isConnected) {
            console.log('Already connected');
            return;
        }
        
        try {
            console.log(`Connecting to ${this.wsUrl}...`);
            this.ws = new WebSocket(this.wsUrl);
            
            // Connection opened
            this.ws.onopen = () => {
                console.log('WebSocket connected');
                this.isConnected = true;
                this.updateConnectionStatus(true);
                this.addSystemMessage('Connected to server', 'success');
            };
            
            // Message received
            this.ws.onmessage = (event) => {
                try {
                    const data = JSON.parse(event.data);
                    this.handleIncomingMessage(data);
                } catch (e) {
                    // If not JSON, treat as plain text
                    this.handleIncomingMessage({ message: event.data });
                }
            };
            
            // Connection closed
            this.ws.onclose = () => {
                console.log('WebSocket disconnected');
                this.isConnected = false;
                this.updateConnectionStatus(false);
                this.addSystemMessage('Disconnected from server', 'warning');
            };
            
            // Error handling
            this.ws.onerror = (error) => {
                console.error('WebSocket error:', error);
                this.addSystemMessage('Connection error. Please check the WebSocket URL and try again.', 'error');
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
            this.elements.connectBtn.disabled = false;
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
            content: data.message || data.text || JSON.stringify(data),
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
                this.ws.send(message);
            } else {
                this.addSystemMessage('Connection lost. Please reconnect.', 'error');
            }
        } catch (error) {
            console.error('Error sending message:', error);
            this.addSystemMessage('Error sending message. Please try again.', 'error');
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
     * Clear messages in the current chat session
     */
    clearCurrentChat() {
        if (!this.currentChatId) return;
        const chat = this.chats.get(this.currentChatId);
        if (!chat) return;
        chat.messages = [];
        this.displayChat(this.currentChatId);
        this.saveChatsToStorage();
    }

    startRename(chatId) {
        const chat = this.chats.get(chatId);
        if (!chat) return;

        const sessionDiv = document.querySelector(`.chat-session[data-chat-id="${chatId}"]`);
        if (!sessionDiv) return;
        const titleSpan = sessionDiv.querySelector('.chat-session-title');
        if (!titleSpan) return;

        const input = document.createElement('input');
        input.type = 'text';
        input.value = chat.title;
        input.className = 'chat-session-rename';

        const save = () => {
            const newTitle = input.value.trim() || chat.title;
            chat.title = newTitle;
            if (this.currentChatId === chatId) {
                this.elements.currentChatTitle.textContent = newTitle;
            }
            this.saveChatsToStorage();
            this.updateChatSessionsList();
        };

        input.addEventListener('blur', save);
        input.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') input.blur();
            if (e.key === 'Escape') { input.value = chat.title; input.blur(); }
        });

        titleSpan.replaceWith(input);
        input.focus();
        input.select();
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
    addSystemMessage(content, level = 'warning') {
        if (!this.currentChatId) return;

        const message = {
            type: 'system',
            level: level,
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
            const colors = {
                success: { bg: '#d1fae5', text: '#065f46' },
                warning: { bg: '#fef3c7', text: '#92400e' },
                error:   { bg: '#fee2e2', text: '#991b1b' }
            };
            const c = colors[message.level] || colors.warning;
            messageDiv.innerHTML = `
                <div class="message-content" style="margin-left: 0; background-color: ${c.bg}; color: ${c.text}; text-align: center; font-size: 0.875rem;">
                    <i class="fas fa-info-circle"></i> ${message.content}
                </div>
            `;
        } else {
            const avatar = message.type === 'user' ? 'U' : 'A';
            const sender = message.type === 'user' ? 'You' : 'Agent';
            
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
                <i class="fas fa-robot"></i>
                <h2>Welcome to Flogo Chatbot</h2>
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
            sessionDiv.dataset.chatId = chatId;
            sessionDiv.innerHTML = `
                <span class="chat-session-title" title="${chat.title}">${chat.title}</span>
                <div class="chat-session-actions">
                    <button class="chat-session-btn" onclick="event.stopPropagation(); chatbot.startRename('${chatId}')" title="Rename chat">
                        <i class="fas fa-pen"></i>
                    </button>
                    <button class="chat-session-btn" onclick="event.stopPropagation(); chatbot.deleteChat('${chatId}')" title="Delete chat">
                        <i class="fas fa-trash"></i>
                    </button>
                </div>
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
                    <i class="fas fa-robot"></i>
                    <h2>Welcome to Flogo Chatbot</h2>
                    <p>Create a new chat session to get started</p>
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
     * Save chats to localStorage
     */
    saveChatsToStorage() {
        try {
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
            
            localStorage.setItem('flogoChatbot_chats', JSON.stringify(chatsData));
            localStorage.setItem('flogoChatbot_currentChatId', this.currentChatId);
            localStorage.setItem('flogoChatbot_chatCounter', this.chatCounter.toString());
            localStorage.setItem('flogoChatbot_wsUrl', this.wsUrl);
        } catch (error) {
            console.error('Error saving chats to storage:', error);
        }
    }
    
    /**
     * Load chats from localStorage
     */
    loadChatsFromStorage() {
        try {
            const chatsData = localStorage.getItem('flogoChatbot_chats');
            const currentChatId = localStorage.getItem('flogoChatbot_currentChatId');
            const chatCounter = localStorage.getItem('flogoChatbot_chatCounter');
            const wsUrl = localStorage.getItem('flogoChatbot_wsUrl');
            
            if (chatCounter) {
                this.chatCounter = parseInt(chatCounter, 10);
            }
            
            if (wsUrl) {
                this.wsUrl = wsUrl;
                this.elements.wsUrlInput.value = wsUrl;
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

