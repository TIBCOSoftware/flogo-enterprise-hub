package postgreslistener

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TriggerDescriptor represents the structure of trigger.json
type TriggerDescriptor struct {
	Name        string              `json:"name"`
	Type        string              `json:"type"`
	Title       string              `json:"title"`
	Version     string              `json:"version"`
	Author      string              `json:"author"`
	Description string              `json:"description"`
	Settings    []SettingDescriptor `json:"settings"`
	Handler     HandlerDescriptor   `json:"handler"`
	Outputs     []OutputDescriptor  `json:"outputs"`
	Ref         string              `json:"ref"`
}

type SettingDescriptor struct {
	Name     string          `json:"name"`
	Type     string          `json:"type"`
	Required bool            `json:"required"`
	Value    interface{}     `json:"value,omitempty"`
	Allowed  []string        `json:"allowed,omitempty"`
	Display  DisplaySettings `json:"display"`
}

type DisplaySettings struct {
	Name               string `json:"name"`
	Description        string `json:"description"`
	Type               string `json:"type,omitempty"`
	AppPropertySupport bool   `json:"appPropertySupport,omitempty"`
	Visible            string `json:"visible,omitempty"`
}

type HandlerDescriptor struct {
	Settings []SettingDescriptor `json:"settings"`
}

type OutputDescriptor struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

func TestFeatureCoverageAnalysis(t *testing.T) {
	// Load and parse trigger.json
	descriptorData, err := os.ReadFile("trigger.json")
	require.NoError(t, err, "Failed to read trigger.json")

	var descriptor TriggerDescriptor
	err = json.Unmarshal(descriptorData, &descriptor)
	require.NoError(t, err, "Failed to parse trigger.json")

	t.Run("Settings Implementation Coverage", func(t *testing.T) {
		testSettingsImplementation(t, descriptor.Settings)
	})

	t.Run("Handler Settings Implementation Coverage", func(t *testing.T) {
		testHandlerSettingsImplementation(t, descriptor.Handler.Settings)
	})

	t.Run("Output Implementation Coverage", func(t *testing.T) {
		testOutputImplementation(t, descriptor.Outputs)
	})

	t.Run("SSL/TLS Feature Implementation", func(t *testing.T) {
		testSSLTLSImplementation(t)
	})

	t.Run("Connection Management Implementation", func(t *testing.T) {
		testConnectionManagementImplementation(t)
	})

	t.Run("Validation Implementation", func(t *testing.T) {
		testValidationImplementation(t)
	})
}

func testSettingsImplementation(t *testing.T, descriptorSettings []SettingDescriptor) {
	settingsType := reflect.TypeOf(Settings{})

	// Map descriptor field names to struct field names
	fieldMapping := map[string]string{
		"host":                 "Host",
		"port":                 "Port",
		"user":                 "User",
		"password":             "Password",
		"databaseName":         "DatabaseName",
		"sslMode":              "SSLMode",
		"tlsConfig":            "TLSConfig",
		"tlsMode":              "TLSMode",
		"cacert":               "Cacert",
		"clientcert":           "Clientcert",
		"clientkey":            "Clientkey",
		"connectionTimeout":    "ConnectionTimeout",
		"maxConnRetryAttempts": "MaxConnRetryAttempts",
		"connectionRetryDelay": "ConnectionRetryDelay",
	}

	for _, setting := range descriptorSettings {
		t.Run("Setting_"+setting.Name, func(t *testing.T) {
			// Check if setting is mapped to a struct field
			structFieldName, exists := fieldMapping[setting.Name]
			require.True(t, exists, "Setting '%s' not mapped to struct field", setting.Name)

			// Check if struct field exists
			field, exists := settingsType.FieldByName(structFieldName)
			require.True(t, exists, "Struct field '%s' not found for setting '%s'", structFieldName, setting.Name)

			// Verify field type compatibility
			expectedGoType := getGoTypeFromDescriptor(setting.Type)
			assert.Equal(t, expectedGoType, field.Type.String(),
				"Type mismatch for field '%s': expected %s, got %s",
				structFieldName, expectedGoType, field.Type.String())

			// Check metadata tag
			mdTag := field.Tag.Get("md")
			assert.Contains(t, mdTag, setting.Name,
				"Metadata tag should contain setting name '%s'", setting.Name)

			if setting.Required {
				assert.Contains(t, mdTag, "required",
					"Required setting '%s' should have 'required' in metadata tag", setting.Name)
			}
		})
	}
}

func testHandlerSettingsImplementation(t *testing.T, handlerSettings []SettingDescriptor) {
	handlerType := reflect.TypeOf(HandlerSettings{})

	fieldMapping := map[string]string{
		"channel": "Channel",
	}

	for _, setting := range handlerSettings {
		t.Run("HandlerSetting_"+setting.Name, func(t *testing.T) {
			structFieldName, exists := fieldMapping[setting.Name]
			require.True(t, exists, "Handler setting '%s' not mapped to struct field", setting.Name)

			field, exists := handlerType.FieldByName(structFieldName)
			require.True(t, exists, "Handler struct field '%s' not found", structFieldName)

			expectedGoType := getGoTypeFromDescriptor(setting.Type)
			assert.Equal(t, expectedGoType, field.Type.String(),
				"Type mismatch for handler field '%s'", structFieldName)

			mdTag := field.Tag.Get("md")
			assert.Contains(t, mdTag, setting.Name)

			if setting.Required {
				assert.Contains(t, mdTag, "required")
			}
		})
	}
}

func testOutputImplementation(t *testing.T, outputs []OutputDescriptor) {
	outputType := reflect.TypeOf(Output{})

	fieldMapping := map[string]string{
		"payload": "Payload",
	}

	for _, output := range outputs {
		t.Run("Output_"+output.Name, func(t *testing.T) {
			structFieldName, exists := fieldMapping[output.Name]
			require.True(t, exists, "Output '%s' not mapped to struct field", output.Name)

			field, exists := outputType.FieldByName(structFieldName)
			require.True(t, exists, "Output struct field '%s' not found", structFieldName)

			expectedGoType := getGoTypeFromDescriptor(output.Type)
			assert.Equal(t, expectedGoType, field.Type.String(),
				"Type mismatch for output field '%s'", structFieldName)

			mdTag := field.Tag.Get("md")
			assert.Contains(t, mdTag, output.Name)
		})
	}

	// Test Output methods exist
	outputValue := reflect.ValueOf(&Output{})

	toMapMethod := outputValue.MethodByName("ToMap")
	assert.True(t, toMapMethod.IsValid(), "Output.ToMap method not found")

	fromMapMethod := outputValue.MethodByName("FromMap")
	assert.True(t, fromMapMethod.IsValid(), "Output.FromMap method not found")
}

func testSSLTLSImplementation(t *testing.T) {
	// Test SSL/TLS features mentioned in descriptor
	settings := &Settings{
		Host:         "localhost",
		Port:         5432,
		User:         "postgres",
		Password:     "password",
		DatabaseName: "testdb",
		TLSConfig:    true,
		TLSMode:      "VerifyCA",
		Cacert:       "LS0tLS1CRUdJTi==", // base64 test data
		Clientcert:   "LS0tLS1CRUdJTi==",
		Clientkey:    "LS0tLS1CRUdJTi==",
	}

	// Test connection string building with TLS
	connStr, tempFiles, err := buildConnectionString(settings)
	assert.NoError(t, err)
	assert.Contains(t, connStr, "sslmode=verify-ca")

	// Clean up temp files
	for _, file := range tempFiles {
		os.Remove(file)
	}

	// Test VerifyFull mode
	settings.TLSMode = "VerifyFull"
	connStr, tempFiles, err = buildConnectionString(settings)
	assert.NoError(t, err)
	assert.Contains(t, connStr, "sslmode=verify-full")

	// Clean up temp files
	for _, file := range tempFiles {
		os.Remove(file)
	}
}

func testConnectionManagementImplementation(t *testing.T) {
	// Test connection timeout feature
	settings := &Settings{
		Host:              "localhost",
		Port:              5432,
		User:              "postgres",
		Password:          "password",
		DatabaseName:      "testdb",
		SSLMode:           "disable",
		ConnectionTimeout: 45,
	}

	connStr, _, err := buildConnectionString(settings)
	assert.NoError(t, err)
	assert.Contains(t, connStr, "connect_timeout=45")

	// Test retry configuration
	settings.MaxConnRetryAttempts = 5
	settings.ConnectionRetryDelay = 10

	trigger := &Trigger{settings: settings}
	err = trigger.validateSettings()
	assert.NoError(t, err)
}

func testValidationImplementation(t *testing.T) {
	// Test all validation rules mentioned in descriptor
	testCases := []struct {
		name        string
		settings    *Settings
		expectError bool
		errorType   string
	}{
		{
			name: "Valid minimal config",
			settings: &Settings{
				Host:         "localhost",
				Port:         5432,
				User:         "postgres",
				Password:     "password",
				DatabaseName: "testdb",
			},
			expectError: false,
		},
		{
			name: "Invalid port range - lower bound",
			settings: &Settings{
				Host:         "localhost",
				Port:         0,
				User:         "postgres",
				Password:     "password",
				DatabaseName: "testdb",
			},
			expectError: true,
			errorType:   "port validation",
		},
		{
			name: "Invalid port range - upper bound",
			settings: &Settings{
				Host:         "localhost",
				Port:         65536,
				User:         "postgres",
				Password:     "password",
				DatabaseName: "testdb",
			},
			expectError: true,
			errorType:   "port validation",
		},
		{
			name: "TLS config conflict",
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
			errorType:   "TLS configuration conflict",
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			trigger := &Trigger{settings: tc.settings}
			err := trigger.validateSettings()

			if tc.expectError {
				assert.Error(t, err, "Expected validation error for %s", tc.errorType)
			} else {
				assert.NoError(t, err, "Unexpected validation error")
			}
		})
	}
}

func getGoTypeFromDescriptor(descriptorType string) string {
	switch descriptorType {
	case "string":
		return "string"
	case "integer":
		return "int"
	case "boolean":
		return "bool"
	default:
		return descriptorType
	}
}

func TestDescriptorConsistency(t *testing.T) {
	// This test ensures the descriptor.json is internally consistent
	descriptorData, err := os.ReadFile("trigger.json")
	require.NoError(t, err)

	var descriptor TriggerDescriptor
	err = json.Unmarshal(descriptorData, &descriptor)
	require.NoError(t, err)

	// Test basic descriptor properties
	assert.Equal(t, "postgreslistener", descriptor.Name)
	assert.Equal(t, "flogo:trigger", descriptor.Type)
	assert.Equal(t, "PostgreSQL Listener", descriptor.Title)
	assert.NotEmpty(t, descriptor.Version)
	assert.NotEmpty(t, descriptor.Author)
	assert.NotEmpty(t, descriptor.Description)

	// Test settings have required fields
	for _, setting := range descriptor.Settings {
		assert.NotEmpty(t, setting.Name, "Setting name cannot be empty")
		assert.NotEmpty(t, setting.Type, "Setting type cannot be empty")
		assert.NotEmpty(t, setting.Display.Name, "Setting display name cannot be empty")
		assert.NotEmpty(t, setting.Display.Description, "Setting display description cannot be empty")
	}

	// Test handler settings
	assert.NotEmpty(t, descriptor.Handler.Settings, "Handler should have settings")
	for _, setting := range descriptor.Handler.Settings {
		assert.NotEmpty(t, setting.Name)
		assert.NotEmpty(t, setting.Type)
	}

	// Test outputs
	assert.NotEmpty(t, descriptor.Outputs, "Trigger should have outputs")
	for _, output := range descriptor.Outputs {
		assert.NotEmpty(t, output.Name)
		assert.NotEmpty(t, output.Type)
	}
}

func TestConditionalVisibilityRules(t *testing.T) {
	// Test that conditional visibility rules in descriptor are properly implemented
	descriptorData, err := os.ReadFile("trigger.json")
	require.NoError(t, err)

	var descriptor TriggerDescriptor
	err = json.Unmarshal(descriptorData, &descriptor)
	require.NoError(t, err)

	// Find TLS-related settings that should have conditional visibility
	tlsRelatedSettings := []string{"tlsMode", "cacert", "clientcert", "clientkey"}

	for _, setting := range descriptor.Settings {
		if contains(tlsRelatedSettings, setting.Name) {
			assert.Contains(t, setting.Display.Visible, "tlsConfig",
				"TLS-related setting '%s' should have conditional visibility based on tlsConfig", setting.Name)
			assert.Contains(t, setting.Display.Visible, "== true",
				"TLS-related setting '%s' should be visible when tlsConfig is true", setting.Name)
		}
	}
}

func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}

func TestAllowedValuesImplementation(t *testing.T) {
	// Test that allowed values in descriptor are properly validated
	descriptorData, err := os.ReadFile("trigger.json")
	require.NoError(t, err)

	var descriptor TriggerDescriptor
	err = json.Unmarshal(descriptorData, &descriptor)
	require.NoError(t, err)

	// Test SSL mode allowed values
	for _, setting := range descriptor.Settings {
		if setting.Name == "sslMode" {
			expectedValues := []string{"disable", "require", "verify-ca", "verify-full"}
			assert.Equal(t, expectedValues, setting.Allowed,
				"SSL mode should have correct allowed values")

			// Test that buildConnectionString respects these values
			for _, sslMode := range expectedValues {
				settings := &Settings{
					Host:         "localhost",
					Port:         5432,
					User:         "postgres",
					Password:     "password",
					DatabaseName: "testdb",
					SSLMode:      sslMode,
				}

				connStr, _, err := buildConnectionString(settings)
				assert.NoError(t, err)
				assert.Contains(t, connStr, "sslmode="+sslMode)
			}
		}

		if setting.Name == "tlsMode" {
			expectedValues := []string{"VerifyCA", "VerifyFull"}
			assert.Equal(t, expectedValues, setting.Allowed,
				"TLS mode should have correct allowed values")
		}
	}
}

func TestDefaultValuesConsistency(t *testing.T) {
	// Test that default values in descriptor match implementation defaults
	descriptorData, err := os.ReadFile("trigger.json")
	require.NoError(t, err)

	var descriptor TriggerDescriptor
	err = json.Unmarshal(descriptorData, &descriptor)
	require.NoError(t, err)

	defaultValueChecks := map[string]interface{}{
		"port":                 5432,
		"sslMode":              "disable",
		"tlsConfig":            false,
		"tlsMode":              "VerifyCA",
		"connectionTimeout":    30,
		"maxConnRetryAttempts": 3,
		"connectionRetryDelay": 5,
	}

	for _, setting := range descriptor.Settings {
		if expectedDefault, exists := defaultValueChecks[setting.Name]; exists {
			if setting.Value != nil {
				switch v := expectedDefault.(type) {
				case int:
					assert.Equal(t, float64(v), setting.Value,
						"Default value mismatch for %s", setting.Name)
				case bool:
					assert.Equal(t, v, setting.Value,
						"Default value mismatch for %s", setting.Name)
				case string:
					assert.Equal(t, v, setting.Value,
						"Default value mismatch for %s", setting.Name)
				}
			}
		}
	}
}
