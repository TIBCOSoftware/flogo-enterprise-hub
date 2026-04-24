package postgreslistener

import (
	"context"
	"crypto/rand"
	"database/sql"
	"database/sql/driver"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/url"
	"os"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/lib/pq"
	"github.com/project-flogo/core/data/metadata"
	"github.com/project-flogo/core/support/log"
	"github.com/project-flogo/core/support/trace"
	"github.com/project-flogo/core/trigger"
)

var triggerMd = trigger.NewMetadata(&Settings{}, &HandlerSettings{}, &Output{})

// Enhanced logging helpers for better troubleshooting
type LogContext struct {
	TriggerID     string
	CorrelationID string
	Channel       string
	Operation     string
	StartTime     time.Time
}

// generateCorrelationID creates a unique correlation ID for request tracing
func generateCorrelationID() string {
	bytes := make([]byte, 8)
	rand.Read(bytes)
	return hex.EncodeToString(bytes)
}

// logWithContext provides structured logging with enhanced context
func (lc *LogContext) logWithContext(logger log.Logger, level string, message string, fields ...interface{}) {
	var contextDetails []string

	// Build context string
	contextDetails = append(contextDetails,
		fmt.Sprintf("corr_id=%s", lc.CorrelationID),
		fmt.Sprintf("trigger=%s", lc.TriggerID),
		fmt.Sprintf("op=%s", lc.Operation),
	)

	if lc.Channel != "" {
		contextDetails = append(contextDetails, fmt.Sprintf("channel=%s", lc.Channel))
	}

	if !lc.StartTime.IsZero() {
		contextDetails = append(contextDetails, fmt.Sprintf("elapsed=%v", time.Since(lc.StartTime)))
	}

	// Add runtime context in debug mode
	if logger.DebugEnabled() {
		_, file, line, ok := runtime.Caller(2)
		if ok {
			contextDetails = append(contextDetails,
				fmt.Sprintf("src=%s:%d", file[strings.LastIndex(file, "/")+1:], line),
				fmt.Sprintf("goroutines=%d", runtime.NumGoroutine()),
			)
		}
	}

	// Add user-provided fields
	for i := 0; i < len(fields); i += 2 {
		if i+1 < len(fields) {
			contextDetails = append(contextDetails, fmt.Sprintf("%v=%v", fields[i], fields[i+1]))
		}
	}

	// Format the message with context
	contextStr := strings.Join(contextDetails, " ")
	fullMessage := fmt.Sprintf("[%s] %s [%s]", lc.Operation, message, contextStr)

	switch strings.ToUpper(level) {
	case "DEBUG":
		logger.Debug(fullMessage)
	case "INFO":
		logger.Info(fullMessage)
	case "WARN":
		logger.Warn(fullMessage)
	case "ERROR":
		logger.Error(fullMessage)
	default:
		logger.Info(fullMessage)
	}
}

// getMemoryStats returns current memory usage statistics
func getMemoryStats() map[string]interface{} {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	return map[string]interface{}{
		"alloc_mb":       bToMb(m.Alloc),
		"total_alloc_mb": bToMb(m.TotalAlloc),
		"sys_mb":         bToMb(m.Sys),
		"gc_runs":        m.NumGC,
	}
}

func bToMb(b uint64) uint64 {
	return b / 1024 / 1024
}

func init() {
	_ = trigger.Register(&Trigger{}, &Factory{})
}

// Trigger is a Flogo trigger for PostgreSQL LISTEN/NOTIFY
type Trigger struct {
	settings      *Settings
	logger        log.Logger
	handlers      []*Handler
	listeners     []*pq.Listener
	db            *sql.DB  // Main database connection for health checks
	tempFiles     []string // Temporary certificate files to clean up
	ctx           context.Context
	cancel        context.CancelFunc
	wg            sync.WaitGroup // Wait group for graceful shutdown
	healthTicker  *time.Ticker   // Health check ticker
	correlationID string         // Unique ID for this trigger instance
	startTime     time.Time      // Trigger start time for metrics
	statsLogger   *time.Ticker   // Periodic stats logging
}

// Handler is a specific listener for a channel
type Handler struct {
	runner  trigger.Handler
	channel string
}

// Factory is a trigger factory
type Factory struct{}

// Metadata returns the trigger's metadata
func (*Factory) Metadata() *trigger.Metadata {
	return triggerMd
}

// New creates a new trigger instance
func (*Factory) New(config *trigger.Config) (trigger.Trigger, error) {
	s := &Settings{}
	err := metadata.MapToStruct(config.Settings, s, true)
	if err != nil {
		return nil, fmt.Errorf("failed to map trigger settings: %v", err)
	}

	trigger := &Trigger{
		settings:      s,
		correlationID: generateCorrelationID(),
		startTime:     time.Now(),
	}

	return trigger, nil
}

// Metadata returns the trigger's metadata (optional implementation)
func (t *Trigger) Metadata() *trigger.Metadata {
	return triggerMd
}

// Initialize initializes the trigger.
func (t *Trigger) Initialize(ctx trigger.InitContext) error {
	t.logger = ctx.Logger()

	// Create enhanced logging context
	logCtx := &LogContext{
		TriggerID:     fmt.Sprintf("postgres-listener-%s", t.correlationID[:8]),
		CorrelationID: t.correlationID,
		Operation:     "INITIALIZE",
		StartTime:     time.Now(),
	}

	logCtx.logWithContext(t.logger, "INFO", fmt.Sprintf("Starting PostgreSQL Listener Trigger initialization with %d handlers", len(ctx.GetHandlers())),
		"version", "enhanced",
		"pid", os.Getpid(),
		"memory_stats", getMemoryStats(),
	)

	// Log settings for debugging (with sensitive data redacted)
	logCtx.logWithContext(t.logger, "DEBUG", "Configuration details",
		"host", t.settings.Host,
		"port", t.settings.Port,
		"database", t.settings.DatabaseName,
		"user", t.settings.User,
		"ssl_mode", t.settings.SSLMode,
		"tls_config", t.settings.TLSConfig,
		"connection_timeout", t.settings.ConnectionTimeout,
		"max_retry_attempts", t.settings.MaxConnRetryAttempts,
		"retry_delay", t.settings.ConnectionRetryDelay,
	)

	// Validate settings
	logCtx.logWithContext(t.logger, "DEBUG", "Starting settings validation")
	if err := t.validateSettings(); err != nil {
		logCtx.logWithContext(t.logger, "ERROR", "Settings validation failed", "error", err, "suggestion", "Check trigger configuration")
		return fmt.Errorf("invalid trigger settings: %v", err)
	}
	logCtx.logWithContext(t.logger, "DEBUG", "Settings validation completed successfully")

	// Create context for graceful shutdown management
	t.ctx, t.cancel = context.WithCancel(context.Background())
	logCtx.logWithContext(t.logger, "DEBUG", "Created graceful shutdown context")

	// Build the connection string using the trigger's direct settings
	logCtx.logWithContext(t.logger, "DEBUG", "Building PostgreSQL connection string")
	connStr, tempFiles, err := buildConnectionString(t.settings)
	if err != nil {
		logCtx.logWithContext(t.logger, "ERROR", "Failed to build connection string", "error", err, "suggestion", "Verify database connection settings and certificates")
		return fmt.Errorf("failed to build connection string: %v", err)
	}
	t.tempFiles = tempFiles // Store for cleanup
	logCtx.logWithContext(t.logger, "DEBUG", "Connection string built successfully", "temp_cert_files", len(tempFiles))

	// Optional: Ping the database once to ensure initial connectivity
	logCtx.logWithContext(t.logger, "DEBUG", "Opening initial database connection for validation")
	db, err := sql.Open("postgres", connStr)
	if err != nil {
		logCtx.logWithContext(t.logger, "ERROR", "Failed to open initial database connection", "error", err, "suggestion", "Check connection string and database availability")
		t.cleanup() // Clean up temp files if connection fails
		return fmt.Errorf("failed to open initial database connection: %v", err)
	}
	t.db = db // Store for potential health checks or other uses

	// Ping with retry logic
	logCtx.logWithContext(t.logger, "DEBUG", "Testing database connectivity with retry logic",
		"max_attempts", t.settings.MaxConnRetryAttempts,
		"retry_delay_seconds", t.settings.ConnectionRetryDelay,
	)
	err = pingDBWithRetry(t.db, t.settings.MaxConnRetryAttempts, t.settings.ConnectionRetryDelay, t.logger)
	if err != nil {
		logCtx.logWithContext(t.logger, "ERROR", "Initial database connection ping failed after retries", "error", err, "suggestion", "Check database server status and network connectivity")
		t.cleanup() // Clean up on failure
		return fmt.Errorf("initial database connection ping failed: %v", err)
	}
	logCtx.logWithContext(t.logger, "INFO", "Successfully established database connection")

	logCtx.logWithContext(t.logger, "DEBUG", "Setting up channel handlers", "handler_count", len(ctx.GetHandlers()))

	for i, handlerCfg := range ctx.GetHandlers() {
		t.logger.Debugf("Processing handler %d/%d...", i+1, len(ctx.GetHandlers()))

		handlerSettings := &HandlerSettings{}
		err := metadata.MapToStruct(handlerCfg.Settings(), handlerSettings, true)
		if err != nil {
			t.logger.Errorf("Failed to map handler %d settings: %v", i+1, err)
			t.cleanup()
			return fmt.Errorf("failed to map handler settings: %v", err)
		}

		if handlerSettings.Channel == "" {
			t.logger.Errorf("Handler %d missing required channel name", i+1)
			t.cleanup()
			return fmt.Errorf("channel name is required for handler")
		}

		t.logger.Debugf("Handler %d will listen on channel: '%s'", i+1, handlerSettings.Channel)
		handler := &Handler{runner: handlerCfg, channel: handlerSettings.Channel}
		t.handlers = append(t.handlers, handler)

		// Create a new pq.Listener for each channel.
		// The listener will manage its own connection to the database using connStr.
		t.logger.Debugf("Creating PostgreSQL listener for channel '%s' with timeout %ds...",
			handlerSettings.Channel, t.settings.ConnectionTimeout)
		listener := pq.NewListener(connStr,
			time.Duration(t.settings.ConnectionTimeout)*time.Second, // Fallback for minReconnectInterval
			time.Minute, // Max reconnect interval
			func(ev pq.ListenerEventType, err error) {
				if err != nil {
					t.logger.Errorf("PostgreSQL Listener event error for channel '%s': Type: %d, Error: %v", handler.channel, ev, err)
				} else {
					t.logger.Debugf("PostgreSQL Listener event for channel '%s': Type: %d", handler.channel, ev)
				}
			})

		t.listeners = append(t.listeners, listener)
		t.logger.Debugf("Successfully created listener for channel '%s'", handlerSettings.Channel)
	}

	t.logger.Infof("PostgreSQL Listener trigger initialized successfully with %d handlers on channels: %v",
		len(t.handlers), func() []string {
			channels := make([]string, len(t.handlers))
			for i, h := range t.handlers {
				channels[i] = h.channel
			}
			return channels
		}())
	return nil
}

// Start starts the trigger
func (t *Trigger) Start() error {
	t.logger.Infof("Starting PostgreSQL Listener trigger with %d handlers", len(t.handlers))

	// Start health monitoring
	t.logger.Debug("Starting health monitoring with 30-second intervals...")
	t.healthTicker = time.NewTicker(30 * time.Second)
	t.wg.Add(1)
	go t.monitorHealth()

	// Start each listener in a separate goroutine
	for i, handler := range t.handlers {
		t.logger.Debugf("Starting listener %d/%d for channel '%s'...", i+1, len(t.handlers), handler.channel)
		t.wg.Add(1)
		go t.listen(handler, t.listeners[i])
	}

	t.logger.Infof("PostgreSQL Listener trigger started successfully - monitoring %d channels", len(t.handlers))
	return nil
}

// Stop stops the trigger
func (t *Trigger) Stop() error {
	t.logger.Infof("Stopping PostgreSQL Listener trigger with %d active listeners", len(t.listeners))

	// Cancel context to signal shutdown
	if t.cancel != nil {
		t.logger.Debug("Canceling context to signal shutdown to all goroutines")
		t.cancel()
	}

	// Stop health monitoring
	if t.healthTicker != nil {
		t.logger.Debug("Stopping health monitoring ticker")
		t.healthTicker.Stop()
	}

	// Close all pq.Listener connections
	t.logger.Debugf("Closing %d PostgreSQL listener connections...", len(t.listeners))
	for i, listener := range t.listeners {
		if listener != nil {
			channelName := "unknown"
			if i < len(t.handlers) {
				channelName = t.handlers[i].channel
			}
			t.logger.Debugf("Closing listener %d for channel '%s'", i+1, channelName)
			if err := listener.Close(); err != nil {
				t.logger.Warnf("Error closing listener %d (channel: %s): %v", i+1, channelName, err)
			} else {
				t.logger.Debugf("Successfully closed listener %d (channel: %s)", i+1, channelName)
			}
		}
	}

	// Wait for all goroutines to finish
	t.logger.Debug("Waiting for all goroutines to finish...")
	t.wg.Wait()
	t.logger.Debug("All goroutines have finished")

	// Close the main DB connection
	if t.db != nil {
		t.logger.Debug("Closing main database connection")
		if err := t.db.Close(); err != nil {
			t.logger.Warnf("Error closing main database connection: %v", err)
		} else {
			t.logger.Debug("Main database connection closed successfully")
		}
	}

	// Clean up temporary files
	t.logger.Debug("Cleaning up temporary certificate files...")
	t.cleanup()

	t.logger.Info("PostgreSQL Listener trigger stopped successfully")
	return nil
}

// listen is the main goroutine for a single channel listener
func (t *Trigger) listen(handler *Handler, listener *pq.Listener) {
	defer t.wg.Done()

	startTime := time.Now()
	channelLogCtx := &LogContext{
		TriggerID:     fmt.Sprintf("postgres-listener-%s", t.correlationID[:8]),
		CorrelationID: t.correlationID,
		Channel:       handler.channel,
		Operation:     "LISTEN",
		StartTime:     startTime,
	}

	channelLogCtx.logWithContext(t.logger, "INFO", "Starting listener goroutine")

	// Start listening on the specified channel
	channelLogCtx.logWithContext(t.logger, "DEBUG", "Executing LISTEN command")
	err := listener.Listen(handler.channel)
	if err != nil {
		channelLogCtx.logWithContext(t.logger, "ERROR", "Failed to start listening", "error", err, "suggestion", "Check channel name and database connection")
		return
	}

	channelLogCtx.logWithContext(t.logger, "INFO", "Successfully started listening", "startup_time", time.Since(startTime))

	notificationCount := 0
	lastNotificationTime := time.Time{}

	// Loop to receive notifications with context cancellation support
	for {
		select {
		case notification := <-listener.Notify:
			if notification == nil {
				channelLogCtx.logWithContext(t.logger, "WARN", "Received nil notification - listener might be reconnecting", "suggestion", "Monitor connection health")
				continue
			}

			notificationCount++
			processingStart := time.Now()
			notificationLogCtx := &LogContext{
				TriggerID:     fmt.Sprintf("postgres-listener-%s", t.correlationID[:8]),
				CorrelationID: generateCorrelationID(), // New correlation ID for each notification
				Channel:       handler.channel,
				Operation:     "PROCESS_NOTIFICATION",
				StartTime:     processingStart,
			}

			// Calculate time since last notification for rate monitoring
			timeSinceLastNotification := ""
			if !lastNotificationTime.IsZero() {
				timeSinceLastNotification = time.Since(lastNotificationTime).String()
			}
			lastNotificationTime = processingStart

			notificationLogCtx.logWithContext(t.logger, "DEBUG", "Received notification",
				"notification_number", notificationCount,
				"payload_length", len(notification.Extra),
				"source_pid", notification.BePid,
				"time_since_last", timeSinceLastNotification,
				"memory_stats", getMemoryStats(),
			)

			// Log payload content (with size limits for large payloads)
			payloadPreview := notification.Extra
			if len(payloadPreview) > 200 {
				payloadPreview = payloadPreview[:200] + "... [truncated]"
			}
			notificationLogCtx.logWithContext(t.logger, "DEBUG", "Notification payload preview", "payload", payloadPreview)

			// Create the output payload for the Flogo flow
			output := &Output{Payload: notification.Extra}

			// Create trace context for OpenTelemetry/distributed tracing support
			ctx := context.Background()
			var traceContext trace.TracingContext
			if trace.Enabled() {
				// Create trace configuration for PostgreSQL notification processing
				traceConfig := trace.Config{
					Operation: "postgres-notification-processing",
					Tags: map[string]interface{}{
						"postgres.channel":        handler.channel,
						"postgres.source_pid":     notification.BePid,
						"postgres.correlation_id": notificationLogCtx.CorrelationID,
						"postgres.trigger_id":     notificationLogCtx.TriggerID,
						"postgres.payload_size":   len(notification.Extra),
						"postgres.timestamp":      processingStart.Format(time.RFC3339),
					},
				}

				// Start a new trace span for this notification processing
				tc, err := trace.GetTracer().StartTrace(traceConfig, nil)
				if err == nil && tc != nil {
					traceContext = tc
					ctx = trace.AppendTracingContext(ctx, tc)
					notificationLogCtx.logWithContext(t.logger, "DEBUG", "Started distributed trace for notification",
						"trace_id", tc.TraceID(),
						"span_id", tc.SpanID(),
						"operation", traceConfig.Operation,
					)
				} else if err != nil {
					notificationLogCtx.logWithContext(t.logger, "DEBUG", "Failed to start distributed trace", "error", err)
				}
			}

			// Handle the trigger event by executing the associated Flogo flow
			notificationLogCtx.logWithContext(t.logger, "DEBUG", "Starting Flogo flow execution")
			result, err := handler.runner.Handle(ctx, output.ToMap())
			processingTime := time.Since(processingStart)

			// Complete the trace span with processing results
			if traceContext != nil {
				finishTags := map[string]interface{}{
					"postgres.processing_time_ms":  processingTime.Seconds() * 1000,
					"postgres.notifications_total": notificationCount,
				}

				if err != nil {
					finishTags["error"] = true
					finishTags["error.message"] = err.Error()
					traceContext.SetTags(finishTags)
					trace.GetTracer().FinishTrace(traceContext, err)
				} else {
					finishTags["success"] = true
					traceContext.SetTags(finishTags)
					trace.GetTracer().FinishTrace(traceContext, nil)
				}
			}

			if err != nil {
				notificationLogCtx.logWithContext(t.logger, "ERROR", "Flow execution failed",
					"error", err,
					"processing_time", processingTime,
					"payload_size", len(notification.Extra),
					"suggestion", "Check flow configuration and error handling",
				)
			} else {
				notificationLogCtx.logWithContext(t.logger, "INFO", "Flow execution completed successfully",
					"processing_time", processingTime,
					"result_fields", len(result),
					"total_processed", notificationCount,
				)

				if t.logger.DebugEnabled() && len(result) > 0 {
					notificationLogCtx.logWithContext(t.logger, "DEBUG", "Flow execution result details", "result", result)
				}
			}

		case <-t.ctx.Done():
			channelLogCtx.logWithContext(t.logger, "INFO", "Stopping listener due to context cancellation",
				"total_notifications_processed", notificationCount,
				"uptime", time.Since(startTime),
			)
			return
		}
	}
}

// buildConnectionString creates a PostgreSQL connection string from the trigger's settings.
func buildConnectionString(s *Settings) (string, []string, error) {
	var tempFiles []string // Initialize empty slice

	// Log connection string building process (without sensitive data)
	log.RootLogger().Debugf("Building PostgreSQL connection string for host: %s:%d, database: %s, user: %s, sslMode: %s",
		s.Host, s.Port, s.DatabaseName, s.User, s.SSLMode)

	// Get connection details from either connection resource or individual settings
	connDetails, err := s.GetConnectionDetails()
	if err != nil {
		log.RootLogger().Errorf("Failed to get connection details: %v", err)
		return "", nil, fmt.Errorf("failed to get connection details: %v", err)
	}

	// Determine sslmode based on TLS settings
	sslMode := s.SSLMode
	if sslMode == "" {
		sslMode = connDetails.SSLMode
	}
	if s.TLSConfig {
		log.RootLogger().Debugf("TLS Config enabled with mode: %s", s.TLSMode)
		switch s.TLSMode {
		case "VerifyCA":
			sslMode = "verify-ca"
		case "VerifyFull":
			sslMode = "verify-full"
		default:
			// If tlsParam is unknown or empty, default to disable for safety
			sslMode = "disable"
			log.RootLogger().Warnf("Unknown TLS mode '%s', defaulting to 'disable'", s.TLSMode)
		}
	} else if sslMode == "" {
		// If TLSConfig is false and sslmode is not explicitly set, default to disable
		sslMode = "disable"
	}
	log.RootLogger().Debugf("Final SSL mode determined: %s", sslMode)

	// Ensure required parameters are present
	if connDetails.Host == "" || connDetails.Port == 0 || connDetails.User == "" || connDetails.DatabaseName == "" {
		return "", nil, fmt.Errorf("host, port, user, and databaseName are required")
	}

	// Properly escape the password for URL inclusion to handle special characters.
	escapedPassword := url.QueryEscape(connDetails.Password)

	// Construct the base connection string
	connStr := fmt.Sprintf("postgres://%s:%s@%s:%d/%s?sslmode=%s",
		connDetails.User, escapedPassword, connDetails.Host, connDetails.Port, connDetails.DatabaseName, sslMode)

	// Add connection timeout if specified
	if s.ConnectionTimeout > 0 {
		connStr += fmt.Sprintf("&connect_timeout=%d", s.ConnectionTimeout)
		log.RootLogger().Debugf("Added connection timeout: %d seconds", s.ConnectionTimeout)
	}

	// Handle TLS certificates if TLSConfig is true and certificates are provided
	if s.TLSConfig {
		log.RootLogger().Debug("Processing TLS certificates...")
		if s.Cacert != "" {
			log.RootLogger().Debug("Processing CA certificate...")
			caCertPath, err := copyCertToTempFile([]byte(s.Cacert), "ca_cert")
			if err != nil {
				// Clean up any files created so far
				for _, file := range tempFiles {
					os.Remove(file)
				}
				return "", nil, fmt.Errorf("failed to process CA certificate: %v", err)
			}
			tempFiles = append(tempFiles, caCertPath)
			connStr += fmt.Sprintf("&sslrootcert=%s", caCertPath)
			log.RootLogger().Debugf("CA certificate processed and added to connection string: %s", caCertPath)
		}
		if s.Clientcert != "" {
			log.RootLogger().Debug("Processing client certificate...")
			clientCertPath, err := copyCertToTempFile([]byte(s.Clientcert), "client_cert")
			if err != nil {
				// Clean up any files created so far
				for _, file := range tempFiles {
					os.Remove(file)
				}
				return "", nil, fmt.Errorf("failed to process client certificate: %v", err)
			}
			tempFiles = append(tempFiles, clientCertPath)
			connStr += fmt.Sprintf("&sslcert=%s", clientCertPath)
			log.RootLogger().Debugf("Client certificate processed and added to connection string: %s", clientCertPath)
		}
		if s.Clientkey != "" {
			log.RootLogger().Debug("Processing client key...")
			clientKeyPath, err := copyCertToTempFile([]byte(s.Clientkey), "client_key")
			if err != nil {
				// Clean up any files created so far
				for _, file := range tempFiles {
					os.Remove(file)
				}
				return "", nil, fmt.Errorf("failed to process client key: %v", err)
			}
			tempFiles = append(tempFiles, clientKeyPath)
			connStr += fmt.Sprintf("&sslkey=%s", clientKeyPath)
			log.RootLogger().Debugf("Client key processed and added to connection string: %s", clientKeyPath)
		}
	}

	log.RootLogger().Debugf("Connection string built successfully with %d temporary certificate files", len(tempFiles))
	return connStr, tempFiles, nil
}

// copyCertToTempFile writes certificate data to a temporary file and returns its path.
// This is a simplified version; in a production trigger, you'd handle base64 decoding
// and robust temporary file management.
func copyCertToTempFile(certData []byte, prefix string) (string, error) {
	// Decode base64 if the input is base64 encoded
	decodedCertData, err := base64.StdEncoding.DecodeString(string(certData))
	if err != nil {
		// If not base64, assume it's raw PEM content
		decodedCertData = certData
	}

	tmpfile, err := os.CreateTemp("", prefix+"_*.pem")
	if err != nil {
		return "", fmt.Errorf("failed to create temporary certificate file: %v", err)
	}
	defer tmpfile.Close() // Ensure file is closed

	if _, err := tmpfile.Write(decodedCertData); err != nil {
		os.Remove(tmpfile.Name()) // Clean up on write error
		return "", fmt.Errorf("failed to write certificate data to temporary file: %v", err)
	}

	// Ensure file permissions are restrictive
	if err := os.Chmod(tmpfile.Name(), 0600); err != nil {
		os.Remove(tmpfile.Name())
		return "", fmt.Errorf("failed to set permissions on temporary certificate file: %v", err)
	}

	return tmpfile.Name(), nil
}

// pingDBWithRetry attempts to ping the database with retries.
func pingDBWithRetry(db *sql.DB, maxAttempts int, retryDelay int, logger log.Logger) error {
	if maxAttempts == 0 {
		return db.Ping() // No retries, just try once
	}

	for i := 0; i <= maxAttempts; i++ {
		err := db.Ping()
		if err == nil {
			return nil // Success
		}

		// Check for specific transient errors that warrant a retry
		if err == driver.ErrBadConn || strings.Contains(err.Error(), "connection refused") ||
			strings.Contains(err.Error(), "network is unreachable") ||
			strings.Contains(err.Error(), "connection reset by peer") ||
			strings.Contains(err.Error(), "dial tcp: lookup") || // DNS resolution issues
			strings.Contains(err.Error(), "timeout") ||
			strings.Contains(err.Error(), "i/o timeout") {

			logger.Warnf("Database ping failed (attempt %d/%d): %v. Retrying in %d seconds...", i+1, maxAttempts+1, err, retryDelay)
			time.Sleep(time.Duration(retryDelay) * time.Second)
			continue
		} else {
			// Non-retriable error (e.g., invalid credentials, syntax error)
			return fmt.Errorf("non-retriable database ping error: %v", err)
		}
	}
	return fmt.Errorf("failed to connect to database after %d attempts", maxAttempts+1)
}

// validateSettings validates the trigger settings
func (t *Trigger) validateSettings() error {
	// Validate individual connection settings
	if t.settings.Host == "" {
		return fmt.Errorf("host is required")
	}
	if t.settings.Port <= 0 || t.settings.Port > 65535 {
		return fmt.Errorf("port must be between 1 and 65535")
	}
	if t.settings.User == "" {
		return fmt.Errorf("user is required")
	}
	if t.settings.Password == "" {
		return fmt.Errorf("password is required")
	}
	if t.settings.DatabaseName == "" {
		return fmt.Errorf("databaseName is required")
	}
	if t.settings.TLSConfig && t.settings.SSLMode == "disable" {
		return fmt.Errorf("TLS configuration enabled but SSL mode is disabled")
	}
	if t.settings.MaxConnRetryAttempts < 0 {
		return fmt.Errorf("maxConnectAttempts cannot be negative")
	}
	if t.settings.ConnectionRetryDelay < 0 {
		return fmt.Errorf("connectionRetryDelay cannot be negative")
	}
	if t.settings.ConnectionTimeout < 0 {
		return fmt.Errorf("connectionTimeout cannot be negative")
	}
	return nil
}

// cleanup removes temporary certificate files
func (t *Trigger) cleanup() {
	if t.tempFiles == nil {
		return
	}
	for _, file := range t.tempFiles {
		if _, err := os.Stat(file); err == nil {
			if err := os.Remove(file); err != nil {
				t.logger.Warnf("Failed to remove temporary file %s: %v", file, err)
			} else {
				t.logger.Debugf("Successfully removed temporary file: %s", file)
			}
		}
	}
	t.tempFiles = nil
}

// monitorHealth periodically checks the health of database connections
func (t *Trigger) monitorHealth() {
	defer t.wg.Done()
	defer t.healthTicker.Stop()

	healthLogCtx := &LogContext{
		TriggerID:     fmt.Sprintf("postgres-listener-%s", t.correlationID[:8]),
		CorrelationID: t.correlationID,
		Operation:     "HEALTH_MONITOR",
		StartTime:     time.Now(),
	}

	healthLogCtx.logWithContext(t.logger, "INFO", "Starting health monitoring daemon")
	checkCount := 0

	for {
		select {
		case <-t.healthTicker.C:
			checkCount++
			healthCheckStart := time.Now()

			// Collect health metrics
			healthMetrics := map[string]interface{}{
				"check_number":    checkCount,
				"uptime":          time.Since(t.startTime),
				"memory_stats":    getMemoryStats(),
				"goroutine_count": runtime.NumGoroutine(),
			}

			var healthIssues []string

			// Check main database connection health
			if t.db != nil {
				dbStats := t.db.Stats()
				healthMetrics["db_open_connections"] = dbStats.OpenConnections
				healthMetrics["db_in_use"] = dbStats.InUse
				healthMetrics["db_idle"] = dbStats.Idle

				if err := t.db.Ping(); err != nil {
					healthIssues = append(healthIssues, fmt.Sprintf("main_db: %v", err))
					healthLogCtx.logWithContext(t.logger, "WARN", "Main database connection health check failed",
						"error", err,
						"suggestion", "Check database server status and connection pool settings",
					)
				} else {
					healthLogCtx.logWithContext(t.logger, "DEBUG", "Main database connection is healthy")
				}
			}

			// Check listener connections health
			healthyListeners := 0
			for i, listener := range t.listeners {
				channelName := "unknown"
				if i < len(t.handlers) {
					channelName = t.handlers[i].channel
				}

				if listener != nil {
					if err := listener.Ping(); err != nil {
						healthIssues = append(healthIssues, fmt.Sprintf("listener_%s: %v", channelName, err))
						healthLogCtx.logWithContext(t.logger, "WARN", "Listener health check failed",
							"channel", channelName,
							"listener_index", i,
							"error", err,
							"suggestion", "Listener may be reconnecting automatically",
						)
					} else {
						healthyListeners++
						healthLogCtx.logWithContext(t.logger, "DEBUG", "Listener is healthy", "channel", channelName)
					}
				}
			}

			healthMetrics["healthy_listeners"] = healthyListeners
			healthMetrics["total_listeners"] = len(t.listeners)
			healthCheckDuration := time.Since(healthCheckStart)
			healthMetrics["health_check_duration"] = healthCheckDuration

			// Log overall health status
			if len(healthIssues) == 0 {
				healthLogCtx.logWithContext(t.logger, "DEBUG", "All connections healthy",
					"metrics", healthMetrics,
				)
			} else {
				healthLogCtx.logWithContext(t.logger, "WARN", "Health check detected issues",
					"issues", healthIssues,
					"metrics", healthMetrics,
					"suggestion", "Monitor connection stability and check PostgreSQL server status",
				)
			}

			// Periodic summary every 10 checks (5 minutes)
			if checkCount%10 == 0 {
				healthLogCtx.logWithContext(t.logger, "INFO", "Periodic health summary",
					"total_checks", checkCount,
					"uptime", time.Since(t.startTime),
					"current_issues", len(healthIssues),
					"metrics", healthMetrics,
				)
			}

		case <-t.ctx.Done():
			healthLogCtx.logWithContext(t.logger, "INFO", "Stopping health monitoring daemon",
				"total_checks_performed", checkCount,
				"uptime", time.Since(t.startTime),
			)
			return
		}
	}
}
