package writelog

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/data/metadata"
	"github.com/project-flogo/core/support/log"
)

var activityMd = activity.ToMetadata(&Settings{}, &Input{})

func init() {
	_ = activity.Register(&Activity{}, New)
}

// Activity represents the write log activity
type Activity struct {
	settings *Settings
	logger   log.Logger
}

// Settings for the write log activity
type Settings struct {
	LogLevel        string      `md:"logLevel,required"`
	IncludeFlowInfo bool        `md:"includeFlowInfo"`
	OutputFormat    string      `md:"outputFormat,required"`
	AddFlowDetails  bool        `md:"addFlowDetails"`
	FieldFilters    interface{} `md:"fieldFilters"`
}

// Input for the write log activity
type Input struct {
	LogObject       interface{} `md:"logObject"`
	LogLevel        string      `md:"logLevel"`
	SensitiveFields interface{} `md:"sensitiveFields"`
}

// New creates a new Activity instance
func New(ctx activity.InitContext) (activity.Activity, error) {
	if ctx == nil {
		return nil, fmt.Errorf("initialization context cannot be nil")
	}

	s := &Settings{}
	err := metadata.MapToStruct(ctx.Settings(), s, true)
	if err != nil {
		return nil, fmt.Errorf("failed to map settings: %w", err)
	}

	logger := ctx.Logger()
	if logger == nil {
		return nil, fmt.Errorf("logger cannot be nil")
	}

	logger.Info("Write Log Activity initialized with enterprise tracing support")

	activity := &Activity{
		settings: s,
		logger:   logger,
	}

	// Initialize context-aware logger
	activity.logger = activity.initializeContextLogger(logger, ctx)

	return activity, nil
}

// Metadata returns the activity's metadata
func (a *Activity) Metadata() *activity.Metadata {
	return activityMd
}

// initializeContextLogger enhances the logger with context-aware fields
func (a *Activity) initializeContextLogger(logger log.Logger, ctx activity.InitContext) log.Logger {
	// For now, return the original logger
	// In a full enterprise implementation, this would add structured fields
	return logger
}

// Eval executes the activity
func (a *Activity) Eval(ctx activity.Context) (done bool, err error) {
	if ctx == nil {
		return false, fmt.Errorf("activity context cannot be nil")
	}

	if a == nil {
		return false, fmt.Errorf("activity instance cannot be nil")
	}

	if a.settings == nil {
		return false, fmt.Errorf("activity settings cannot be nil")
	}

	if a.logger == nil {
		return false, fmt.Errorf("activity logger cannot be nil")
	}

	// Get inputs using metadata mapping
	logObject := ctx.GetInput("logObject")
	logLevel := ctx.GetInput("logLevel")
	sensitiveFields := ctx.GetInput("sensitiveFields")
	fieldFilters := ctx.GetInput("fieldFilters")

	// Step 2: Determine effective log level (input overrides settings)
	effectiveLogLevel := a.determineLogLevel(logLevel)

	// Step 3 & 4 & 6: Format the log entry with flow info according to output format
	formattedMessage := a.formatLogEntry(ctx, logObject, effectiveLogLevel, sensitiveFields, fieldFilters)

	// Log using the determined level
	a.logAtLevel(effectiveLogLevel, formattedMessage)

	return true, nil
}

// determineLogLevel determines the effective log level
// Priority: Input logLevel > Environment Variables > Settings logLevel
func (a *Activity) determineLogLevel(inputLogLevel interface{}) string {
	// Priority 1: Input logLevel overrides everything
	if inputLogLevel != nil {
		if levelStr, ok := inputLogLevel.(string); ok && levelStr != "" {
			return strings.ToUpper(levelStr)
		}
	}

	// Priority 2: Environment variables (in order of precedence)
	envVars := []string{
		"FLOGO_LOG_LEVEL",
		"FLOGO_DYNAMICLOG_LOG_LEVEL",
		"FLOGO_LOGACTIVITY_LOG_LEVEL",
	}

	for _, envVar := range envVars {
		if envLevel := os.Getenv(envVar); envLevel != "" {
			return strings.ToUpper(envLevel)
		}
	}

	// Priority 3: Fall back to settings log level
	return strings.ToUpper(a.settings.LogLevel)
}

// formatBasicMessage converts logObject to a basic string representation
func (a *Activity) formatBasicMessage(logObject interface{}) string {
	if logObject == nil {
		return ""
	}

	switch v := logObject.(type) {
	case string:
		return v
	case map[string]interface{}:
		// Try to get a "message" field, otherwise JSON marshal
		if msg, exists := v["message"]; exists {
			return fmt.Sprintf("%v", msg)
		}
		// Marshal as JSON for structured data
		if data, err := json.Marshal(v); err == nil {
			return string(data)
		}
		return fmt.Sprintf("%v", v)
	default:
		return fmt.Sprintf("%v", v)
	}
}

// logAtLevel logs the message at the specified level
func (a *Activity) logAtLevel(level, message string) {
	switch strings.ToUpper(level) {
	case "TRACE":
		a.logger.Debug("TRACE: " + message) // Flogo doesn't have TRACE, use DEBUG
	case "DEBUG":
		a.logger.Debug(message)
	case "INFO":
		a.logger.Info(message)
	case "WARN", "WARNING":
		a.logger.Warn(message)
	case "ERROR":
		a.logger.Error(message)
	case "FATAL":
		a.logger.Error("FATAL: " + message) // Flogo doesn't have FATAL, use ERROR
	default:
		a.logger.Info(message) // Default to INFO for unknown levels
	}
}

// formatLogEntry formats the log entry according to the configured output format
func (a *Activity) formatLogEntry(ctx activity.Context, logObject interface{}, level string, sensitiveFields interface{}, fieldFilters interface{}) string {
	// Step 1: Create the main log entry (user data + system fields)
	entry := a.createMainLogEntry(logObject, level, sensitiveFields, fieldFilters)

	// Step 2: Format the main content according to output format setting
	outputFormat := strings.ToUpper(a.settings.OutputFormat)
	var mainContent string
	switch outputFormat {
	case "JSON":
		mainContent = a.formatAsJSON(entry)
	case "KEY_VALUE":
		mainContent = a.formatAsKeyValue(entry)
	case "LOGFMT":
		mainContent = a.formatAsLogfmt(entry)
	default:
		mainContent = a.formatAsJSON(entry) // Default to JSON
	}

	// Step 3: Append flow information as readable suffix (like official Log activity)
	if a.settings.AddFlowDetails {
		return a.appendFlowSuffix(ctx, mainContent)
	}

	return mainContent
}

// createMainLogEntry creates the main log entry (user data + system fields) without flow details
func (a *Activity) createMainLogEntry(logObject interface{}, level string, sensitiveFields interface{}, fieldFilters interface{}) map[string]interface{} {
	entry := make(map[string]interface{})

	// Add level - always required
	entry["level"] = strings.ToUpper(level)

	// Add timestamp only if ECS is enabled
	if a.settings.IncludeFlowInfo {
		entry["@timestamp"] = time.Now().UTC().Format(time.RFC3339)
	}

	// Add ECS fields if includeFlowInfo is enabled (but not flow details)
	if a.settings.IncludeFlowInfo {
		a.addECSFields(entry)
	}

	// Process the log object
	if logObject != nil {
		switch v := logObject.(type) {
		case string:
			entry["message"] = v
		case map[string]interface{}:
			// If it has a message field, extract it
			if msg, exists := v["message"]; exists {
				entry["message"] = fmt.Sprintf("%v", msg)
				// Add other fields from the map
				for k, val := range v {
					if k != "message" {
						entry[k] = val
					}
				}
			} else {
				// No specific message field, add all fields
				for k, val := range v {
					entry[k] = val
				}
				// Don't add an automatic message field
			}
		default:
			entry["message"] = fmt.Sprintf("%v", v)
		}
	} else {
		// No log object provided, no message field added
	}

	// Step 5: Apply field filtering FIRST if configured
	if fieldFilters != nil {
		entry = a.applyFieldFiltersFromInput(entry, fieldFilters)
	}

	// Step 6: Apply sensitive field masking AFTER filtering
	if sensitiveFields != nil {
		entry = a.applySensitiveFieldMasking(entry, sensitiveFields)
	}

	return entry
}

// formatAsJSON formats the entry as JSON
func (a *Activity) formatAsJSON(entry map[string]interface{}) string {
	data, err := json.Marshal(entry)
	if err != nil {
		return fmt.Sprintf(`{"error": "failed to marshal log entry: %s"}`, err.Error())
	}
	return string(data)
}

// formatAsKeyValue formats the entry as key=value pairs
func (a *Activity) formatAsKeyValue(entry map[string]interface{}) string {
	// Flatten nested objects first
	flattened := a.flattenMap(entry, "")

	var parts []string

	// Sort keys for consistent output
	keys := make([]string, 0, len(flattened))
	for k := range flattened {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	for _, k := range keys {
		v := flattened[k]
		if str, ok := v.(string); ok {
			// Quote strings that contain spaces
			if strings.Contains(str, " ") || strings.Contains(str, "\t") {
				parts = append(parts, fmt.Sprintf("%s=%q", k, str))
			} else {
				parts = append(parts, fmt.Sprintf("%s=%s", k, str))
			}
		} else {
			// For non-strings, convert to string format
			parts = append(parts, fmt.Sprintf("%s=%v", k, v))
		}
	}

	return strings.Join(parts, " ")
}

// flattenMap flattens nested maps into dot-notation keys
func (a *Activity) flattenMap(data map[string]interface{}, prefix string) map[string]interface{} {
	result := make(map[string]interface{})

	for key, value := range data {
		var newKey string
		if prefix == "" {
			newKey = key
		} else {
			newKey = prefix + "." + key
		}

		switch v := value.(type) {
		case map[string]interface{}:
			// Recursively flatten nested maps
			nested := a.flattenMap(v, newKey)
			for nestedKey, nestedValue := range nested {
				result[nestedKey] = nestedValue
			}
		case []interface{}:
			// Handle arrays - convert to JSON string for readability
			if jsonBytes, err := json.Marshal(v); err == nil {
				result[newKey] = string(jsonBytes)
			} else {
				result[newKey] = fmt.Sprintf("%v", v)
			}
		default:
			result[newKey] = value
		}
	}

	return result
}

// formatAsLogfmt formats the entry in logfmt style
func (a *Activity) formatAsLogfmt(entry map[string]interface{}) string {
	// Flatten nested objects first
	flattened := a.flattenMap(entry, "")

	var parts []string

	// Sort keys for consistent output
	keys := make([]string, 0, len(flattened))
	for k := range flattened {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	for _, k := range keys {
		v := flattened[k]
		valueStr := fmt.Sprintf("%v", v)

		// Quote if needed for logfmt
		if a.needsQuoting(valueStr) {
			parts = append(parts, fmt.Sprintf("%s=%s", k, strconv.Quote(valueStr)))
		} else {
			parts = append(parts, fmt.Sprintf("%s=%s", k, valueStr))
		}
	}

	return strings.Join(parts, " ")
}

// needsQuoting determines if a value needs quoting in logfmt
func (a *Activity) needsQuoting(s string) bool {
	if s == "" {
		return true
	}
	for _, r := range s {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == '"' || r == '\\' {
			return true
		}
	}
	return false
}

// addECSFields adds Elastic Common Schema (ECS) fields to the log entry
// Following ECS specification v8.x
func (a *Activity) addECSFields(entry map[string]interface{}) {
	// ECS version - indicates which version of ECS this event complies with
	entry["ecs"] = map[string]interface{}{
		"version": "8.11",
	}

	// @timestamp is already added in createMainLogEntry when ECS is enabled

	// Log level mapping to ECS log.level
	if level, exists := entry["level"]; exists {
		entry["log"] = map[string]interface{}{
			"level":  level,
			"logger": "flogo.activity.write-log", // Match the new module name
		}
		// Keep the original level field for backward compatibility
	}

	// Service information (should come from environment variables in production)
	service := map[string]interface{}{
		"name": a.getServiceName(),
		"type": "application",
	}
	if version := a.getServiceVersion(); version != "" {
		service["version"] = version
	}
	if env := a.getEnvironment(); env != "" {
		service["environment"] = env
	}
	entry["service"] = service

	// Agent information (the software that generated this event)
	agent := map[string]interface{}{
		"name":    "flogo-activity-write-log", // Match the new module name
		"type":    "logging",
		"version": "1.0.0",
	}
	entry["agent"] = agent

	// Host information
	host := map[string]interface{}{
		"name": a.getHostname(),
	}
	if hostname, err := os.Hostname(); err == nil {
		host["hostname"] = hostname
	}
	// Add OS information if available
	if os := a.getOSInfo(); len(os) > 0 {
		host["os"] = os
	}
	entry["host"] = host

	// Process information
	process := map[string]interface{}{
		"name": "flogo",
		"pid":  os.Getpid(),
	}
	if executable, err := os.Executable(); err == nil {
		process["executable"] = executable
	}
	entry["process"] = process

	// Event information - describes the type of event
	event := map[string]interface{}{
		"kind":     "event",
		"category": []string{"application"}, // Correct category for application logs
		"type":     []string{"info"},        // This should be dynamic based on log level
		"dataset":  "flogo.application.logs",
		"module":   "flogo",
		"action":   "log",
	}

	// Set event type based on log level
	if level, exists := entry["level"]; exists {
		switch strings.ToUpper(fmt.Sprintf("%v", level)) {
		case "ERROR", "FATAL":
			event["type"] = []string{"error"}
			event["outcome"] = "failure"
		case "WARN", "WARNING":
			event["type"] = []string{"info"}
			event["outcome"] = "unknown"
		default:
			event["type"] = []string{"info"}
			event["outcome"] = "success"
		}
	}
	entry["event"] = event

	// Labels - for custom key-value pairs (optional)
	labels := map[string]interface{}{
		"framework": "flogo",
		"activity":  "write-log", // Match the new consistent naming
	}
	entry["labels"] = labels
}

// addFlowDetails adds Flogo flow-specific details to the log entry
// NOTE: This method is deprecated in favor of appendFlowSuffix for inline flow information
// (kept for potential future use or backward compatibility)
/*
func (a *Activity) addFlowDetails(ctx activity.Context, entry map[string]interface{}) {
	// Create flogo-specific namespace for minimal, useful flow context
	flogo := make(map[string]interface{})

	// Add essential flow context information
	if host := ctx.ActivityHost(); host != nil {
		if name := host.Name(); name != "" {
			flogo["flow"] = name
		}
		if id := host.ID(); id != "" {
			flogo["instance_id"] = id
		}
	}

	// Add OpenTelemetry/tracing context if available
	tracing := make(map[string]interface{})

	if tracingCtx := ctx.GetTracingContext(); tracingCtx != nil {
		// Try to extract tracer and inject context for correlation
		if tracer := trace.GetTracer(); tracer != nil {
			// Add basic tracing information
			tracing["tracer_enabled"] = "true"

			// Try to extract any tracing headers or context using HTTP headers format
			headers := make(map[string]string)
			tracer.Inject(tracingCtx, trace.HTTPHeaders, headers)
			if len(headers) > 0 {
				tracing["trace_headers"] = headers
			}
		}
	}

	// Always check for OpenTelemetry environment variables regardless of active tracing context
	if serviceName := os.Getenv("OTEL_SERVICE_NAME"); serviceName != "" {
		tracing["service_name"] = serviceName
	}
	if serviceVersion := os.Getenv("OTEL_SERVICE_VERSION"); serviceVersion != "" {
		tracing["service_version"] = serviceVersion
	}
	if resourceAttrs := os.Getenv("OTEL_RESOURCE_ATTRIBUTES"); resourceAttrs != "" {
		tracing["resource_attributes"] = resourceAttrs
	}
	if endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT"); endpoint != "" {
		tracing["otlp_endpoint"] = endpoint
	}

	// Only add tracing section if we have meaningful data
	if len(tracing) > 0 {
		flogo["tracing"] = tracing
	}

	// Only add flogo section if we have meaningful data
	if len(flogo) > 0 {
		entry["flogo"] = flogo
	}
}
*/

// getHostname returns the hostname (simplified for this implementation)
func (a *Activity) getHostname() string {
	// Try to get actual hostname first
	if hostname, err := os.Hostname(); err == nil {
		return hostname
	}
	// Fallback to environment variable or default
	if hostname := os.Getenv("HOSTNAME"); hostname != "" {
		return hostname
	}
	return "flogo-host"
}

// getServiceName returns the service name from environment or default
func (a *Activity) getServiceName() string {
	// Check common service name environment variables
	if name := os.Getenv("SERVICE_NAME"); name != "" {
		return name
	}
	if name := os.Getenv("FLOGO_APP_NAME"); name != "" {
		return name
	}
	if name := os.Getenv("APP_NAME"); name != "" {
		return name
	}
	// Default service name
	return "flogo-application"
}

// getServiceVersion returns the service version from environment or default
func (a *Activity) getServiceVersion() string {
	// Check common version environment variables
	if version := os.Getenv("SERVICE_VERSION"); version != "" {
		return version
	}
	if version := os.Getenv("FLOGO_APP_VERSION"); version != "" {
		return version
	}
	if version := os.Getenv("APP_VERSION"); version != "" {
		return version
	}
	// Don't return a default version - let it be empty if not set
	return ""
}

// getEnvironment returns the deployment environment from environment variables
func (a *Activity) getEnvironment() string {
	// Check common environment variables
	if env := os.Getenv("ENVIRONMENT"); env != "" {
		return env
	}
	if env := os.Getenv("DEPLOYMENT_ENVIRONMENT"); env != "" {
		return env
	}
	if env := os.Getenv("FLOGO_ENVIRONMENT"); env != "" {
		return env
	}
	if env := os.Getenv("NODE_ENV"); env != "" {
		return env
	}
	// Don't return a default environment - let it be empty if not set
	return ""
}

// getOSInfo returns basic OS information for ECS host.os field
func (a *Activity) getOSInfo() map[string]interface{} {
	osInfo := make(map[string]interface{})

	// Get OS platform information
	if platform := os.Getenv("GOOS"); platform != "" {
		osInfo["platform"] = platform
	}

	// Try to get more detailed OS info from environment
	if family := os.Getenv("OS_FAMILY"); family != "" {
		osInfo["family"] = family
	}
	if kernel := os.Getenv("OS_KERNEL"); kernel != "" {
		osInfo["kernel"] = kernel
	}
	if name := os.Getenv("OS_NAME"); name != "" {
		osInfo["name"] = name
	}
	if version := os.Getenv("OS_VERSION"); version != "" {
		osInfo["version"] = version
	}

	return osInfo
}

// appendFlowSuffix appends flow information as readable suffix (like official Log activity)
func (a *Activity) appendFlowSuffix(ctx activity.Context, mainContent string) string {
	var parts []string

	// Get flow context information
	if host := ctx.ActivityHost(); host != nil {
		if id := host.ID(); id != "" {
			parts = append(parts, fmt.Sprintf("FlowInstanceID [%s]", id))
		}
		if name := host.Name(); name != "" {
			parts = append(parts, fmt.Sprintf("Flow [%s]", name))
		}
	}

	// Get activity name from context if available
	if name := ctx.Name(); name != "" {
		parts = append(parts, fmt.Sprintf("Activity [%s]", name))
	}

	// If we have flow parts, append them with proper formatting
	if len(parts) > 0 {
		return fmt.Sprintf("%s. %s.", mainContent, strings.Join(parts, ", "))
	}

	return mainContent
}

// getSystemFields returns the list of system fields that should be preserved during filtering
func (a *Activity) getSystemFields() []string {
	var systemFields []string

	// Always preserve basic system fields
	systemFields = append(systemFields, "level")

	// Add @timestamp only if ECS is enabled
	if a.settings.IncludeFlowInfo {
		systemFields = append(systemFields, "@timestamp")
	}

	// Add ECS fields if enabled
	if a.settings.IncludeFlowInfo {
		systemFields = append(systemFields,
			"service", "agent", "host", "process", "event")
	}

	// Note: Flow details are now handled as suffix, not as JSON fields

	return systemFields
}

// FieldFilter represents the field filtering configuration
type FieldFilter struct {
	Include []string `json:"include"`
	Exclude []string `json:"exclude"`
}

// applyFieldFiltersFromInput applies field filtering based on input configuration
func (a *Activity) applyFieldFiltersFromInput(entry map[string]interface{}, fieldFilters interface{}) map[string]interface{} {
	filter, err := a.parseFieldFiltersFromInput(fieldFilters)
	if err != nil {
		// If parsing fails, return original entry
		a.logger.Warn("Failed to parse field filters from input:", err)
		return entry
	}

	if filter == nil {
		return entry
	}

	// If include list is specified, start with empty map and only include specified fields
	if len(filter.Include) > 0 {
		filtered := make(map[string]interface{})

		// Create an enhanced include list that preserves system fields
		enhancedInclude := make([]string, len(filter.Include))
		copy(enhancedInclude, filter.Include)

		// Automatically include system fields if they're enabled
		systemFields := a.getSystemFields()
		enhancedInclude = append(enhancedInclude, systemFields...)

		for _, field := range enhancedInclude {
			if value, exists := entry[field]; exists {
				filtered[field] = value
			} else if a.matchesWildcard(entry, field, filtered) {
				// matchesWildcard handles wildcard patterns and adds matches to filtered
			}
		}

		entry = filtered
	}

	// Apply exclude list (remove specified fields)
	if len(filter.Exclude) > 0 {
		for _, field := range filter.Exclude {
			if a.containsWildcard(field) {
				a.removeWildcardMatches(entry, field)
			} else {
				delete(entry, field)
			}
		}
	}

	return entry
}

// parseFieldFiltersFromInput parses the fieldFilters input into a FieldFilter struct
func (a *Activity) parseFieldFiltersFromInput(fieldFilters interface{}) (*FieldFilter, error) {
	if fieldFilters == nil {
		return nil, nil
	}

	var filter FieldFilter

	switch v := fieldFilters.(type) {
	case map[string]interface{}:
		// Convert map to JSON and then unmarshal to struct
		data, err := json.Marshal(v)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal field filters: %w", err)
		}

		err = json.Unmarshal(data, &filter)
		if err != nil {
			return nil, fmt.Errorf("failed to unmarshal field filters: %w", err)
		}

	case string:
		// Parse JSON string
		err := json.Unmarshal([]byte(v), &filter)
		if err != nil {
			return nil, fmt.Errorf("failed to parse field filters JSON: %w", err)
		}

	default:
		return nil, fmt.Errorf("unsupported field filters type: %T", v)
	}

	return &filter, nil
}

// parseFieldFilters parses the fieldFilters setting into a FieldFilter struct
func (a *Activity) parseFieldFilters() (*FieldFilter, error) {
	if a.settings.FieldFilters == nil {
		return nil, nil
	}

	var filter FieldFilter

	switch v := a.settings.FieldFilters.(type) {
	case map[string]interface{}:
		// Convert map to JSON and then unmarshal to struct
		data, err := json.Marshal(v)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal field filters: %w", err)
		}

		err = json.Unmarshal(data, &filter)
		if err != nil {
			return nil, fmt.Errorf("failed to unmarshal field filters: %w", err)
		}

	case string:
		// Parse JSON string
		err := json.Unmarshal([]byte(v), &filter)
		if err != nil {
			return nil, fmt.Errorf("failed to parse field filters JSON: %w", err)
		}

	default:
		return nil, fmt.Errorf("unsupported field filters type: %T", v)
	}

	return &filter, nil
}

// matchesWildcard checks if any fields match a wildcard pattern and adds them to filtered map
func (a *Activity) matchesWildcard(entry map[string]interface{}, pattern string, filtered map[string]interface{}) bool {
	if !a.containsWildcard(pattern) {
		return false
	}

	matched := false
	for key, value := range entry {
		if a.matchWildcardPattern(key, pattern) {
			filtered[key] = value
			matched = true
		}
	}

	return matched
}

// removeWildcardMatches removes all fields that match a wildcard pattern
func (a *Activity) removeWildcardMatches(entry map[string]interface{}, pattern string) {
	var keysToRemove []string

	for key := range entry {
		if a.matchWildcardPattern(key, pattern) {
			keysToRemove = append(keysToRemove, key)
		}
	}

	for _, key := range keysToRemove {
		delete(entry, key)
	}
}

// containsWildcard checks if a pattern contains wildcard characters
func (a *Activity) containsWildcard(pattern string) bool {
	return strings.Contains(pattern, "*") || strings.Contains(pattern, "?")
}

// matchWildcardPattern matches a string against a wildcard pattern
func (a *Activity) matchWildcardPattern(str, pattern string) bool {
	if pattern == "*" {
		return true
	}

	if !a.containsWildcard(pattern) {
		return str == pattern
	}

	// Handle patterns with * wildcards
	if strings.Contains(pattern, "*") {
		// Split by * to get parts that must be present
		parts := strings.Split(pattern, "*")

		// Remove empty parts
		var nonEmptyParts []string
		for _, part := range parts {
			if part != "" {
				nonEmptyParts = append(nonEmptyParts, part)
			}
		}

		if len(nonEmptyParts) == 0 {
			return true // Pattern is just "*"
		}

		// Check if all parts are present in order
		searchStr := str
		for i, part := range nonEmptyParts {
			index := strings.Index(searchStr, part)
			if index == -1 {
				return false
			}

			// For first part, check if pattern starts with *
			if i == 0 && !strings.HasPrefix(pattern, "*") && index != 0 {
				return false
			}

			// Move search position past this part
			searchStr = searchStr[index+len(part):]
		}

		// For last part, check if pattern ends with *
		lastPart := nonEmptyParts[len(nonEmptyParts)-1]
		if !strings.HasSuffix(pattern, "*") && !strings.HasSuffix(str, lastPart) {
			return false
		}

		return true
	}

	// For more complex patterns, you could use filepath.Match or regex
	return false
}

// SensitiveFieldConfig represents the configuration for sensitive field masking
type SensitiveFieldConfig struct {
	FieldNamesToHide []string `json:"fieldNamesToHide"` // List of field names to mask
	Fields           []string `json:"fields"`           // Backwards compatibility
	MaskWith         string   `json:"maskWith"`         // What to mask with (default: "***")
	MaskLength       int      `json:"maskLength"`       // Length of mask (0 = replace entire value)
}

// getEffectiveFields returns the field list, prioritizing new field name over legacy
func (c *SensitiveFieldConfig) getEffectiveFields() []string {
	if len(c.FieldNamesToHide) > 0 {
		return c.FieldNamesToHide
	}
	return c.Fields
}

// applySensitiveFieldMasking applies sensitive field masking to log entries
func (a *Activity) applySensitiveFieldMasking(entry map[string]interface{}, sensitiveFields interface{}) map[string]interface{} {
	config, err := a.parseSensitiveFields(sensitiveFields)
	if err != nil {
		a.logger.Warn("Failed to parse sensitive fields:", err)
		return entry
	}

	if config == nil || len(config.getEffectiveFields()) == 0 {
		return entry
	}

	// Default mask
	maskWith := config.MaskWith
	if maskWith == "" {
		maskWith = "***"
	}

	// Apply masking to specified fields
	for _, fieldName := range config.getEffectiveFields() {
		if a.containsWildcard(fieldName) {
			// Handle wildcard patterns
			a.maskWildcardFields(entry, fieldName, maskWith, config.MaskLength)
		} else {
			// Handle exact field match
			if value, exists := entry[fieldName]; exists {
				entry[fieldName] = a.maskValue(value, maskWith, config.MaskLength)
			}
		}
	}

	return entry
}

// parseSensitiveFields parses the sensitiveFields input into a SensitiveFieldConfig
func (a *Activity) parseSensitiveFields(sensitiveFields interface{}) (*SensitiveFieldConfig, error) {
	if sensitiveFields == nil {
		return nil, nil
	}

	var config SensitiveFieldConfig

	switch v := sensitiveFields.(type) {
	case map[string]interface{}:
		// Convert map to JSON and then unmarshal to struct
		data, err := json.Marshal(v)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal sensitive fields: %w", err)
		}

		err = json.Unmarshal(data, &config)
		if err != nil {
			return nil, fmt.Errorf("failed to unmarshal sensitive fields: %w", err)
		}

	case string:
		// Parse JSON string
		err := json.Unmarshal([]byte(v), &config)
		if err != nil {
			return nil, fmt.Errorf("failed to parse sensitive fields JSON: %w", err)
		}

	case []interface{}:
		// Simple array of field names - use new field name
		for _, item := range v {
			if fieldName, ok := item.(string); ok {
				config.FieldNamesToHide = append(config.FieldNamesToHide, fieldName)
			}
		}

	case []string:
		// Array of field names - use new field name
		config.FieldNamesToHide = v

	default:
		return nil, fmt.Errorf("unsupported sensitive fields type: %T", v)
	}

	return &config, nil
}

// maskWildcardFields masks all fields that match a wildcard pattern
func (a *Activity) maskWildcardFields(entry map[string]interface{}, pattern, maskWith string, maskLength int) {
	for key, value := range entry {
		if a.matchWildcardPattern(key, pattern) {
			entry[key] = a.maskValue(value, maskWith, maskLength)
		}
	}
}

// maskValue masks a field value according to the masking configuration
func (a *Activity) maskValue(value interface{}, maskWith string, maskLength int) interface{} {
	if value == nil {
		return value
	}

	// Convert value to string for masking
	strValue := fmt.Sprintf("%v", value)

	if maskLength > 0 {
		// Partial masking - keep first characters based on maskLength
		keepChars := maskLength
		if keepChars > 3 {
			keepChars = 3 // Don't show too much of sensitive data
		}

		if keepChars >= len(strValue) {
			// If keepChars is >= string length, return full mask
			return maskWith
		}

		// Keep the first characters and mask the rest
		return strValue[:keepChars] + maskWith
	}

	// Full masking
	return maskWith
}
