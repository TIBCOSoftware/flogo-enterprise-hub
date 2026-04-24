package postgreslistener

import (
	"context"
	"os"
	"reflect"
	"testing"

	"github.com/project-flogo/core/support/log"
	"github.com/project-flogo/core/trigger"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
	"github.com/stretchr/testify/require"
)

// MockHandler for testing trigger handlers
type MockHandler struct {
	mock.Mock
}

func (m *MockHandler) Handle(ctx context.Context, data map[string]interface{}) (map[string]interface{}, error) {
	args := m.Called(ctx, data)
	return args.Get(0).(map[string]interface{}), args.Error(1)
}

// MockInitContext for testing trigger initialization
type MockInitContext struct {
	mock.Mock
	logger   log.Logger
	handlers []trigger.Handler
}

func (m *MockInitContext) Logger() log.Logger {
	return m.logger
}

func (m *MockInitContext) GetHandlers() []trigger.Handler {
	return m.handlers
}

// MockTriggerHandler implements trigger.Handler
type MockTriggerHandler struct {
	mock.Mock
	settings map[string]interface{}
}

func (m *MockTriggerHandler) Handle(ctx context.Context, data map[string]interface{}) (map[string]interface{}, error) {
	args := m.Called(ctx, data)
	return args.Get(0).(map[string]interface{}), args.Error(1)
}

func (m *MockTriggerHandler) Settings() map[string]interface{} {
	return m.settings
}

func TestFactory_Metadata(t *testing.T) {
	factory := &Factory{}
	metadata := factory.Metadata()

	assert.NotNil(t, metadata)
	assert.NotNil(t, metadata.Settings)
	assert.NotNil(t, metadata.HandlerSettings)
	assert.NotNil(t, metadata.Output)
}

func TestTrigger_Metadata(t *testing.T) {
	// Create a trigger instance
	config := &trigger.Config{
		Id: "test-trigger",
		Settings: map[string]interface{}{
			"host":         "localhost",
			"port":         5432,
			"databaseName": "testdb",
			"user":         "testuser",
			"password":     "testpass",
		},
	}

	factory := &Factory{}
	trig, err := factory.New(config)
	require.NoError(t, err)
	require.NotNil(t, trig)

	// Test Metadata method
	md := trig.(*Trigger).Metadata()
	assert.NotNil(t, md)
	assert.Equal(t, triggerMd, md)
}

func TestFactory_New(t *testing.T) {
	factory := &Factory{}

	tests := []struct {
		name        string
		config      *trigger.Config
		expectError bool
		errorMsg    string
	}{
		{
			name: "Valid config",
			config: &trigger.Config{
				Settings: map[string]interface{}{
					"host":         "localhost",
					"port":         5432,
					"user":         "postgres",
					"password":     "password",
					"databaseName": "testdb",
				},
			},
			expectError: false,
		},
		{
			name: "Invalid config - missing required field",
			config: &trigger.Config{
				Settings: map[string]interface{}{
					"host": "localhost",
					// missing other required fields
				},
			},
			expectError: true, // Factory.New validates during metadata mapping
			errorMsg:    "field 'port' is required",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			trigger, err := factory.New(tt.config)

			if tt.expectError {
				assert.Error(t, err)
				if tt.errorMsg != "" {
					assert.Contains(t, err.Error(), tt.errorMsg)
				}
			} else {
				assert.NoError(t, err)
				assert.NotNil(t, trigger)
				assert.IsType(t, &Trigger{}, trigger)
			}
		})
	}
}

func TestSettings_GetConnectionDetails(t *testing.T) {
	tests := []struct {
		name        string
		settings    *Settings
		expectError bool
		errorMsg    string
		expected    *ConnectionDetails
	}{
		{
			name: "Valid settings",
			settings: &Settings{
				Host:         "localhost",
				Port:         5432,
				User:         "postgres",
				Password:     "password",
				DatabaseName: "testdb",
				SSLMode:      "disable",
			},
			expectError: false,
			expected: &ConnectionDetails{
				Host:         "localhost",
				Port:         5432,
				User:         "postgres",
				Password:     "password",
				DatabaseName: "testdb",
				SSLMode:      "disable",
			},
		},
		{
			name: "Missing host",
			settings: &Settings{
				Port:         5432,
				User:         "postgres",
				Password:     "password",
				DatabaseName: "testdb",
			},
			expectError: true,
			errorMsg:    "host, port, user, and databaseName are required",
		},
		{
			name: "Missing port",
			settings: &Settings{
				Host:         "localhost",
				User:         "postgres",
				Password:     "password",
				DatabaseName: "testdb",
			},
			expectError: true,
			errorMsg:    "host, port, user, and databaseName are required",
		},
		{
			name: "Missing user",
			settings: &Settings{
				Host:         "localhost",
				Port:         5432,
				Password:     "password",
				DatabaseName: "testdb",
			},
			expectError: true,
			errorMsg:    "host, port, user, and databaseName are required",
		},
		{
			name: "Missing database name",
			settings: &Settings{
				Host:     "localhost",
				Port:     5432,
				User:     "postgres",
				Password: "password",
			},
			expectError: true,
			errorMsg:    "host, port, user, and databaseName are required",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := tt.settings.GetConnectionDetails()

			if tt.expectError {
				assert.Error(t, err)
				if tt.errorMsg != "" {
					assert.Contains(t, err.Error(), tt.errorMsg)
				}
				assert.Nil(t, result)
			} else {
				assert.NoError(t, err)
				assert.NotNil(t, result)
				assert.Equal(t, tt.expected, result)
			}
		})
	}
}

func TestOutput_ToMap(t *testing.T) {
	output := &Output{
		Payload: "test payload",
	}

	result := output.ToMap()
	expected := map[string]interface{}{
		"payload": "test payload",
	}

	assert.Equal(t, expected, result)
}

func TestOutput_FromMap(t *testing.T) {
	tests := []struct {
		name        string
		input       map[string]interface{}
		expectError bool
		expected    *Output
	}{
		{
			name: "Valid string payload",
			input: map[string]interface{}{
				"payload": "test payload",
			},
			expectError: false,
			expected: &Output{
				Payload: "test payload",
			},
		},
		{
			name: "Numeric payload (should convert to string)",
			input: map[string]interface{}{
				"payload": 12345,
			},
			expectError: false,
			expected: &Output{
				Payload: "12345",
			},
		},
		{
			name: "Boolean payload (should convert to string)",
			input: map[string]interface{}{
				"payload": true,
			},
			expectError: false,
			expected: &Output{
				Payload: "true",
			},
		},
		{
			name: "Nil payload",
			input: map[string]interface{}{
				"payload": nil,
			},
			expectError: false,
			expected: &Output{
				Payload: "",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			output := &Output{}
			err := output.FromMap(tt.input)

			if tt.expectError {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
				assert.Equal(t, tt.expected.Payload, output.Payload)
			}
		})
	}
}

func TestTrigger_validateSettings(t *testing.T) {
	tests := []struct {
		name        string
		settings    *Settings
		expectError bool
		errorMsg    string
	}{
		{
			name: "Valid settings",
			settings: &Settings{
				Host:                 "localhost",
				Port:                 5432,
				User:                 "postgres",
				Password:             "password",
				DatabaseName:         "testdb",
				SSLMode:              "disable",
				MaxConnRetryAttempts: 3,
				ConnectionRetryDelay: 5,
				ConnectionTimeout:    30,
			},
			expectError: false,
		},
		{
			name: "Missing host",
			settings: &Settings{
				Port:         5432,
				User:         "postgres",
				Password:     "password",
				DatabaseName: "testdb",
			},
			expectError: true,
			errorMsg:    "host is required",
		},
		{
			name: "Invalid port - zero",
			settings: &Settings{
				Host:         "localhost",
				Port:         0,
				User:         "postgres",
				Password:     "password",
				DatabaseName: "testdb",
			},
			expectError: true,
			errorMsg:    "port must be between 1 and 65535",
		},
		{
			name: "Invalid port - too high",
			settings: &Settings{
				Host:         "localhost",
				Port:         70000,
				User:         "postgres",
				Password:     "password",
				DatabaseName: "testdb",
			},
			expectError: true,
			errorMsg:    "port must be between 1 and 65535",
		},
		{
			name: "Missing user",
			settings: &Settings{
				Host:         "localhost",
				Port:         5432,
				Password:     "password",
				DatabaseName: "testdb",
			},
			expectError: true,
			errorMsg:    "user is required",
		},
		{
			name: "Missing password",
			settings: &Settings{
				Host:         "localhost",
				Port:         5432,
				User:         "postgres",
				DatabaseName: "testdb",
			},
			expectError: true,
			errorMsg:    "password is required",
		},
		{
			name: "Missing database name",
			settings: &Settings{
				Host:     "localhost",
				Port:     5432,
				User:     "postgres",
				Password: "password",
			},
			expectError: true,
			errorMsg:    "databaseName is required",
		},
		{
			name: "TLS config enabled but SSL disabled",
			settings: &Settings{
				Host:         "localhost",
				Port:         5432,
				User:         "postgres",
				Password:     "password",
				DatabaseName: "testdb",
				SSLMode:      "disable",
				TLSConfig:    true,
			},
			expectError: true,
			errorMsg:    "TLS configuration enabled but SSL mode is disabled",
		},
		{
			name: "Negative retry attempts",
			settings: &Settings{
				Host:                 "localhost",
				Port:                 5432,
				User:                 "postgres",
				Password:             "password",
				DatabaseName:         "testdb",
				MaxConnRetryAttempts: -1,
			},
			expectError: true,
			errorMsg:    "maxConnectAttempts cannot be negative",
		},
		{
			name: "Negative retry delay",
			settings: &Settings{
				Host:                 "localhost",
				Port:                 5432,
				User:                 "postgres",
				Password:             "password",
				DatabaseName:         "testdb",
				ConnectionRetryDelay: -1,
			},
			expectError: true,
			errorMsg:    "connectionRetryDelay cannot be negative",
		},
		{
			name: "Negative connection timeout",
			settings: &Settings{
				Host:              "localhost",
				Port:              5432,
				User:              "postgres",
				Password:          "password",
				DatabaseName:      "testdb",
				ConnectionTimeout: -1,
			},
			expectError: true,
			errorMsg:    "connectionTimeout cannot be negative",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			trigger := &Trigger{settings: tt.settings}
			err := trigger.validateSettings()

			if tt.expectError {
				assert.Error(t, err)
				if tt.errorMsg != "" {
					assert.Contains(t, err.Error(), tt.errorMsg)
				}
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestBuildConnectionString(t *testing.T) {
	tests := []struct {
		name        string
		settings    *Settings
		expectError bool
		errorMsg    string
		checkResult func(t *testing.T, connStr string, tempFiles []string)
	}{
		{
			name: "Basic connection string",
			settings: &Settings{
				Host:         "localhost",
				Port:         5432,
				User:         "postgres",
				Password:     "password",
				DatabaseName: "testdb",
				SSLMode:      "disable",
			},
			expectError: false,
			checkResult: func(t *testing.T, connStr string, tempFiles []string) {
				assert.Contains(t, connStr, "postgres://postgres:")
				assert.Contains(t, connStr, "@localhost:5432/testdb")
				assert.Contains(t, connStr, "sslmode=disable")
				assert.Empty(t, tempFiles)
			},
		},
		{
			name: "Connection string with special characters in password",
			settings: &Settings{
				Host:         "localhost",
				Port:         5432,
				User:         "postgres",
				Password:     "pa$$w@rd!",
				DatabaseName: "testdb",
				SSLMode:      "disable",
			},
			expectError: false,
			checkResult: func(t *testing.T, connStr string, tempFiles []string) {
				// Password should be URL encoded
				assert.Contains(t, connStr, "pa%24%24w%40rd%21")
				assert.Empty(t, tempFiles)
			},
		},
		{
			name: "Connection string with timeout",
			settings: &Settings{
				Host:              "localhost",
				Port:              5432,
				User:              "postgres",
				Password:          "password",
				DatabaseName:      "testdb",
				SSLMode:           "disable",
				ConnectionTimeout: 60,
			},
			expectError: false,
			checkResult: func(t *testing.T, connStr string, tempFiles []string) {
				assert.Contains(t, connStr, "connect_timeout=60")
				assert.Empty(t, tempFiles)
			},
		},
		{
			name: "TLS mode verification",
			settings: &Settings{
				Host:         "localhost",
				Port:         5432,
				User:         "postgres",
				Password:     "password",
				DatabaseName: "testdb",
				TLSConfig:    true,
				TLSMode:      "VerifyCA",
			},
			expectError: false,
			checkResult: func(t *testing.T, connStr string, tempFiles []string) {
				assert.Contains(t, connStr, "sslmode=verify-ca")
				assert.Empty(t, tempFiles)
			},
		},
		{
			name: "TLS mode verify full",
			settings: &Settings{
				Host:         "localhost",
				Port:         5432,
				User:         "postgres",
				Password:     "password",
				DatabaseName: "testdb",
				TLSConfig:    true,
				TLSMode:      "VerifyFull",
			},
			expectError: false,
			checkResult: func(t *testing.T, connStr string, tempFiles []string) {
				assert.Contains(t, connStr, "sslmode=verify-full")
				assert.Empty(t, tempFiles)
			},
		},
		{
			name: "Invalid connection details",
			settings: &Settings{
				Host: "localhost",
				// Missing required fields
			},
			expectError: true,
			errorMsg:    "failed to get connection details",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			connStr, tempFiles, err := buildConnectionString(tt.settings)

			if tt.expectError {
				assert.Error(t, err)
				if tt.errorMsg != "" {
					assert.Contains(t, err.Error(), tt.errorMsg)
				}
			} else {
				assert.NoError(t, err)
				assert.NotEmpty(t, connStr)
				if tt.checkResult != nil {
					tt.checkResult(t, connStr, tempFiles)
				}
			}

			// Clean up any temp files created during test
			for _, file := range tempFiles {
				os.Remove(file)
			}
		})
	}
}

func TestCopyCertToTempFile(t *testing.T) {
	tests := []struct {
		name        string
		certData    []byte
		prefix      string
		expectError bool
		checkResult func(t *testing.T, path string)
	}{
		{
			name:        "Valid certificate data",
			certData:    []byte("-----BEGIN CERTIFICATE-----\nMIIC...\n-----END CERTIFICATE-----"),
			prefix:      "test_cert",
			expectError: false,
			checkResult: func(t *testing.T, path string) {
				assert.NotEmpty(t, path)
				assert.Contains(t, path, "test_cert")
				assert.Contains(t, path, ".pem")

				// Check file exists and has correct permissions
				info, err := os.Stat(path)
				assert.NoError(t, err)
				assert.Equal(t, os.FileMode(0600), info.Mode())

				// Clean up
				os.Remove(path)
			},
		},
		{
			name:        "Base64 encoded certificate",
			certData:    []byte("LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t"), // base64 encoded
			prefix:      "b64_cert",
			expectError: false,
			checkResult: func(t *testing.T, path string) {
				assert.NotEmpty(t, path)

				// Read the file content to verify it was decoded
				content, err := os.ReadFile(path)
				assert.NoError(t, err)
				assert.Contains(t, string(content), "-----BEGIN CERTIFICATE-----")

				// Clean up
				os.Remove(path)
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path, err := copyCertToTempFile(tt.certData, tt.prefix)

			if tt.expectError {
				assert.Error(t, err)
				assert.Empty(t, path)
			} else {
				assert.NoError(t, err)
				if tt.checkResult != nil {
					tt.checkResult(t, path)
				}
			}
		})
	}
}

func TestTriggerLifecycle(t *testing.T) {
	// This test verifies the complete lifecycle without actual database connection
	settings := &Settings{
		Host:                 "localhost",
		Port:                 5432,
		User:                 "postgres",
		Password:             "password",
		DatabaseName:         "testdb",
		SSLMode:              "disable",
		MaxConnRetryAttempts: 1,
		ConnectionRetryDelay: 1,
		ConnectionTimeout:    5,
	}

	factory := &Factory{}
	config := &trigger.Config{
		Settings: map[string]interface{}{
			"host":                 settings.Host,
			"port":                 settings.Port,
			"user":                 settings.User,
			"password":             settings.Password,
			"databaseName":         settings.DatabaseName,
			"sslMode":              settings.SSLMode,
			"maxConnRetryAttempts": settings.MaxConnRetryAttempts,
			"connectionRetryDelay": settings.ConnectionRetryDelay,
			"connectionTimeout":    settings.ConnectionTimeout,
		},
	}

	triggerInstance, err := factory.New(config)
	require.NoError(t, err)
	require.NotNil(t, triggerInstance)

	trigger := triggerInstance.(*Trigger)
	assert.Equal(t, settings.Host, trigger.settings.Host)
	assert.Equal(t, settings.Port, trigger.settings.Port)
	assert.Equal(t, settings.User, trigger.settings.User)

	// Test validation
	err = trigger.validateSettings()
	assert.NoError(t, err)
}

// Benchmark tests for performance
func BenchmarkConnectionStringBuilding(b *testing.B) {
	settings := &Settings{
		Host:         "localhost",
		Port:         5432,
		User:         "postgres",
		Password:     "password",
		DatabaseName: "testdb",
		SSLMode:      "disable",
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		connStr, tempFiles, err := buildConnectionString(settings)
		if err != nil {
			b.Error(err)
		}
		if connStr == "" {
			b.Error("Empty connection string")
		}
		// Clean up temp files
		for _, file := range tempFiles {
			os.Remove(file)
		}
	}
}

func BenchmarkOutputToMap(b *testing.B) {
	output := &Output{Payload: "test payload data for benchmarking"}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		result := output.ToMap()
		if len(result) == 0 {
			b.Error("Empty result")
		}
	}
}

// Integration test helper functions
func createTestTrigger(t *testing.T) *Trigger {
	settings := &Settings{
		Host:                 "localhost",
		Port:                 5432,
		User:                 "postgres",
		Password:             "password",
		DatabaseName:         "testdb",
		SSLMode:              "disable",
		MaxConnRetryAttempts: 1,
		ConnectionRetryDelay: 1,
		ConnectionTimeout:    5,
	}

	return &Trigger{
		settings: settings,
		logger:   log.RootLogger(),
		handlers: []*Handler{},
		ctx:      context.Background(),
	}
}

func TestTriggerCleanup(t *testing.T) {
	trigger := createTestTrigger(t)

	// Create some temp files to test cleanup
	tempFile1, err := os.CreateTemp("", "test_cert_*.pem")
	require.NoError(t, err)
	tempFile1.Close()

	tempFile2, err := os.CreateTemp("", "test_key_*.pem")
	require.NoError(t, err)
	tempFile2.Close()

	trigger.tempFiles = []string{tempFile1.Name(), tempFile2.Name()}

	// Test cleanup
	trigger.cleanup()

	// Verify files are removed
	_, err1 := os.Stat(tempFile1.Name())
	_, err2 := os.Stat(tempFile2.Name())
	assert.True(t, os.IsNotExist(err1))
	assert.True(t, os.IsNotExist(err2))
	assert.Nil(t, trigger.tempFiles)
}

func TestFeatureCompleteness(t *testing.T) {
	// This test ensures all features mentioned in trigger.json are implemented

	// Test that all settings fields are present in Settings struct
	settingsType := reflect.TypeOf(Settings{})

	expectedFields := []string{
		"Host", "Port", "User", "Password", "DatabaseName",
		"SSLMode", "TLSConfig", "TLSMode",
		"Cacert", "Clientcert", "Clientkey",
		"ConnectionTimeout", "MaxConnRetryAttempts", "ConnectionRetryDelay",
	}

	for _, fieldName := range expectedFields {
		_, found := settingsType.FieldByName(fieldName)
		assert.True(t, found, "Settings struct missing field: %s", fieldName)
	}

	// Test that HandlerSettings has required fields
	handlerType := reflect.TypeOf(HandlerSettings{})
	_, found := handlerType.FieldByName("Channel")
	assert.True(t, found, "HandlerSettings struct missing Channel field")

	// Test that Output has required fields
	outputType := reflect.TypeOf(Output{})
	_, found = outputType.FieldByName("Payload")
	assert.True(t, found, "Output struct missing Payload field")
}
