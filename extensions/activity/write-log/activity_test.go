package writelog

import (
	"encoding/json"
	"fmt"
	"os"
	"testing"

	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
)

func TestActivity_Register(t *testing.T) {
	ref := activity.GetRef(&Activity{})
	act := activity.Get(ref)
	assert.NotNil(t, act)
}

func TestActivity_New(t *testing.T) {
	settings := map[string]interface{}{
		"logLevel":        "INFO",
		"includeFlowInfo": true,
		"outputFormat":    "JSON",
		"addFlowDetails":  false,
		"fieldFilters":    nil,
	}

	ctx := test.NewActivityInitContext(settings, nil)
	act, err := New(ctx)

	assert.NoError(t, err)
	assert.NotNil(t, act)
}

func TestActivity_Eval_Basic(t *testing.T) {
	settings := map[string]interface{}{
		"logLevel":        "INFO",
		"includeFlowInfo": true,
		"outputFormat":    "JSON",
		"addFlowDetails":  false,
		"fieldFilters":    nil,
	}

	ctx := test.NewActivityInitContext(settings, nil)
	act, err := New(ctx)
	assert.NoError(t, err)

	tc := test.NewActivityContext(act.Metadata())
	tc.SetInput("logObject", map[string]interface{}{"message": "test message"})
	tc.SetInput("logLevel", "INFO")

	done, err := act.Eval(tc)
	assert.NoError(t, err)
	assert.True(t, done)
}

func TestActivity_LogLevelProcessing(t *testing.T) {
	settings := map[string]interface{}{
		"logLevel":        "WARN", // Default level
		"includeFlowInfo": true,
		"outputFormat":    "JSON",
		"addFlowDetails":  false,
		"fieldFilters":    nil,
	}

	ctx := test.NewActivityInitContext(settings, nil)
	act, err := New(ctx)
	assert.NoError(t, err)

	// Test 1: No input level - should use settings level
	tc1 := test.NewActivityContext(act.Metadata())
	tc1.SetInput("logObject", "Test message without level override")

	done, err := act.Eval(tc1)
	assert.NoError(t, err)
	assert.True(t, done)

	// Test 2: Input level overrides settings level
	tc2 := test.NewActivityContext(act.Metadata())
	tc2.SetInput("logObject", "Test message with ERROR level")
	tc2.SetInput("logLevel", "ERROR")

	done, err = act.Eval(tc2)
	assert.NoError(t, err)
	assert.True(t, done)

	// Test 3: Test different log object types
	tc3 := test.NewActivityContext(act.Metadata())
	tc3.SetInput("logObject", map[string]interface{}{
		"message": "Structured log message",
		"user":    "testuser",
		"action":  "login",
	})
	tc3.SetInput("logLevel", "DEBUG")

	done, err = act.Eval(tc3)
	assert.NoError(t, err)
	assert.True(t, done)
}

func TestActivity_DetermineLogLevel(t *testing.T) {
	settings := map[string]interface{}{
		"logLevel":        "WARN",
		"includeFlowInfo": true,
		"outputFormat":    "JSON",
		"addFlowDetails":  false,
		"fieldFilters":    nil,
	}

	ctx := test.NewActivityInitContext(settings, nil)
	act, err := New(ctx)
	assert.NoError(t, err)

	activity := act.(*Activity)

	// Test cases for log level determination
	tests := []struct {
		name     string
		input    interface{}
		expected string
	}{
		{"Nil input uses settings", nil, "WARN"},
		{"Empty string uses settings", "", "WARN"},
		{"Valid input overrides settings", "ERROR", "ERROR"},
		{"Lowercase input normalized", "debug", "DEBUG"},
		{"Non-string input uses settings", 123, "WARN"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := activity.determineLogLevel(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestActivity_FormatBasicMessage(t *testing.T) {
	settings := map[string]interface{}{
		"logLevel":        "INFO",
		"includeFlowInfo": true,
		"outputFormat":    "JSON",
		"addFlowDetails":  false,
		"fieldFilters":    nil,
	}

	ctx := test.NewActivityInitContext(settings, nil)
	act, err := New(ctx)
	assert.NoError(t, err)

	activity := act.(*Activity)

	// Test cases for message formatting
	tests := []struct {
		name     string
		input    interface{}
		expected string
	}{
		{"Nil input", nil, ""},
		{"String input", "hello world", "hello world"},
		{"Map with message field", map[string]interface{}{"message": "test", "other": "data"}, "test"},
		{"Map without message field", map[string]interface{}{"user": "john", "action": "login"}, `{"action":"login","user":"john"}`},
		{"Integer input", 42, "42"},
		{"Boolean input", true, "true"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := activity.formatBasicMessage(tt.input)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestActivity_OutputFormats(t *testing.T) {
	// Test all three output formats
	formats := []struct {
		name   string
		format string
	}{
		{"JSON format", "JSON"},
		{"KEY_VALUE format", "KEY_VALUE"},
		{"LOGFMT format", "LOGFMT"},
	}

	for _, format := range formats {
		t.Run(format.name, func(t *testing.T) {
			settings := map[string]interface{}{
				"logLevel":        "INFO",
				"includeFlowInfo": true,
				"outputFormat":    format.format,
				"addFlowDetails":  false,
				"fieldFilters":    nil,
			}

			ctx := test.NewActivityInitContext(settings, nil)
			act, err := New(ctx)
			assert.NoError(t, err)

			tc := test.NewActivityContext(act.Metadata())
			tc.SetInput("logObject", map[string]interface{}{
				"message": "Test message",
				"user":    "testuser",
				"action":  "login",
			})
			tc.SetInput("logLevel", "INFO")

			done, err := act.Eval(tc)
			assert.NoError(t, err)
			assert.True(t, done)
		})
	}
}

func TestActivity_FormatLogEntry_JSON(t *testing.T) {
	settings := map[string]interface{}{
		"logLevel":        "INFO",
		"includeFlowInfo": true,
		"outputFormat":    "JSON",
		"addFlowDetails":  false,
		"fieldFilters":    nil,
	}

	ctx := test.NewActivityInitContext(settings, nil)
	act, err := New(ctx)
	assert.NoError(t, err)

	activity := act.(*Activity)

	// Test JSON formatting
	logObject := map[string]interface{}{
		"message": "Test message",
		"user":    "john",
		"action":  "login",
	}

	tc := test.NewActivityContext(act.Metadata())
	result := activity.formatLogEntry(tc, logObject, "INFO", nil, nil)

	// Should be valid JSON containing our fields
	assert.Contains(t, result, `"message":"Test message"`)
	assert.Contains(t, result, `"user":"john"`)
	assert.Contains(t, result, `"action":"login"`)
	assert.Contains(t, result, `"level":"INFO"`)
	assert.Contains(t, result, `"@timestamp"`)

	// Verify it's valid JSON
	var parsed map[string]interface{}
	err = json.Unmarshal([]byte(result), &parsed)
	assert.NoError(t, err)
}

func TestActivity_FormatLogEntry_KeyValue(t *testing.T) {
	settings := map[string]interface{}{
		"logLevel":        "INFO",
		"includeFlowInfo": true,
		"outputFormat":    "KEY_VALUE",
		"addFlowDetails":  false,
		"fieldFilters":    nil,
	}

	ctx := test.NewActivityInitContext(settings, nil)
	act, err := New(ctx)
	assert.NoError(t, err)

	activity := act.(*Activity)

	// Test KEY_VALUE formatting
	logObject := map[string]interface{}{
		"message": "Test message",
		"user":    "john",
	}

	tc := test.NewActivityContext(act.Metadata())
	result := activity.formatLogEntry(tc, logObject, "INFO", nil, nil)

	// Should contain key=value pairs
	assert.Contains(t, result, `message="Test message"`)
	assert.Contains(t, result, "user=john")
	assert.Contains(t, result, "level=INFO")
	assert.Contains(t, result, "@timestamp=")
}

func TestActivity_FormatLogEntry_Logfmt(t *testing.T) {
	settings := map[string]interface{}{
		"logLevel":        "INFO",
		"includeFlowInfo": true,
		"outputFormat":    "LOGFMT",
		"addFlowDetails":  false,
		"fieldFilters":    nil,
	}

	ctx := test.NewActivityInitContext(settings, nil)
	act, err := New(ctx)
	assert.NoError(t, err)

	activity := act.(*Activity)

	// Test LOGFMT formatting
	logObject := map[string]interface{}{
		"message": "Test message",
		"user":    "john",
	}

	tc := test.NewActivityContext(act.Metadata())
	result := activity.formatLogEntry(tc, logObject, "INFO", nil, nil)

	// Should contain logfmt style key=value pairs
	assert.Contains(t, result, `message="Test message"`)
	assert.Contains(t, result, "user=john")
	assert.Contains(t, result, "level=INFO")
	assert.Contains(t, result, "@timestamp=")
}

func TestActivity_FlowInfoIntegration(t *testing.T) {
	// Test includeFlowInfo setting
	t.Run("IncludeFlowInfo enabled", func(t *testing.T) {
		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": true, // Enable ECS fields
			"outputFormat":    "JSON",
			"addFlowDetails":  false,
			"fieldFilters":    nil,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		tc := test.NewActivityContext(act.Metadata())
		tc.SetInput("logObject", map[string]interface{}{
			"message": "Test with ECS fields",
			"user":    "testuser",
		})

		done, err := act.Eval(tc)
		assert.NoError(t, err)
		assert.True(t, done)
	})

	// Test addFlowDetails setting
	t.Run("AddFlowDetails enabled", func(t *testing.T) {
		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": false,
			"outputFormat":    "JSON",
			"addFlowDetails":  true, // Enable flow details
			"fieldFilters":    nil,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		tc := test.NewActivityContext(act.Metadata())
		tc.SetInput("logObject", "Test with flow details")

		done, err := act.Eval(tc)
		assert.NoError(t, err)
		assert.True(t, done)
	})

	// Test both settings enabled
	t.Run("Both ECS and Flow details enabled", func(t *testing.T) {
		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": true, // Enable ECS fields
			"outputFormat":    "JSON",
			"addFlowDetails":  true, // Enable flow details
			"fieldFilters":    nil,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		tc := test.NewActivityContext(act.Metadata())
		tc.SetInput("logObject", map[string]interface{}{
			"message": "Complete flow info test",
			"action":  "test_action",
		})

		done, err := act.Eval(tc)
		assert.NoError(t, err)
		assert.True(t, done)
	})
}

func TestActivity_FieldFiltering(t *testing.T) {
	// Test include filtering
	t.Run("Include filtering", func(t *testing.T) {
		fieldFilters := map[string]interface{}{
			"include": []string{"message", "user", "action"},
		}

		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": false,
			"outputFormat":    "JSON",
			"addFlowDetails":  false,
			"fieldFilters":    fieldFilters,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		tc := test.NewActivityContext(act.Metadata())
		tc.SetInput("logObject", map[string]interface{}{
			"message":    "Test message",
			"user":       "testuser",
			"action":     "login",
			"password":   "secret123", // Should be filtered out
			"session_id": "abc123",    // Should be filtered out
		})

		done, err := act.Eval(tc)
		assert.NoError(t, err)
		assert.True(t, done)
	})

	// Test exclude filtering
	t.Run("Exclude filtering", func(t *testing.T) {
		fieldFilters := map[string]interface{}{
			"exclude": []string{"password", "secret", "token"},
		}

		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": false,
			"outputFormat":    "JSON",
			"addFlowDetails":  false,
			"fieldFilters":    fieldFilters,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		tc := test.NewActivityContext(act.Metadata())
		tc.SetInput("logObject", map[string]interface{}{
			"message":  "Test message",
			"user":     "testuser",
			"password": "secret123", // Should be excluded
			"token":    "xyz789",    // Should be excluded
		})

		done, err := act.Eval(tc)
		assert.NoError(t, err)
		assert.True(t, done)
	})

	// Test wildcard filtering
	t.Run("Wildcard filtering", func(t *testing.T) {
		fieldFilters := map[string]interface{}{
			"include": []string{"message", "user*"},
			"exclude": []string{"*secret*", "*password*"},
		}

		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": false,
			"outputFormat":    "JSON",
			"addFlowDetails":  false,
			"fieldFilters":    fieldFilters,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		tc := test.NewActivityContext(act.Metadata())
		tc.SetInput("logObject", map[string]interface{}{
			"message":       "Test message",
			"user_id":       "123",       // Should be included (matches user*)
			"user_name":     "testuser",  // Should be included (matches user*)
			"api_secret":    "secret123", // Should be excluded (matches *secret*)
			"user_password": "pass123",   // Should be excluded (matches *password*)
			"session_token": "xyz789",    // Should be excluded (not in include list)
		})

		done, err := act.Eval(tc)
		assert.NoError(t, err)
		assert.True(t, done)
	})

	// Test JSON string configuration
	t.Run("JSON string configuration", func(t *testing.T) {
		fieldFiltersJSON := `{"include": ["message", "user"], "exclude": ["password"]}`

		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": false,
			"outputFormat":    "JSON",
			"addFlowDetails":  false,
			"fieldFilters":    fieldFiltersJSON,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		tc := test.NewActivityContext(act.Metadata())
		tc.SetInput("logObject", map[string]interface{}{
			"message":  "Test message",
			"user":     "testuser",
			"password": "secret123",
		})

		done, err := act.Eval(tc)
		assert.NoError(t, err)
		assert.True(t, done)
	})
}

func TestActivity_ParseFieldFilters(t *testing.T) {
	// Test with map input
	t.Run("Parse map configuration", func(t *testing.T) {
		fieldFilters := map[string]interface{}{
			"include": []string{"field1", "field2"},
			"exclude": []string{"field3"},
		}

		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": false,
			"outputFormat":    "JSON",
			"addFlowDetails":  false,
			"fieldFilters":    fieldFilters,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		activity := act.(*Activity)
		filter, err := activity.parseFieldFilters()

		assert.NoError(t, err)
		assert.NotNil(t, filter)
		assert.Equal(t, []string{"field1", "field2"}, filter.Include)
		assert.Equal(t, []string{"field3"}, filter.Exclude)
	})

	// Test with JSON string input
	t.Run("Parse JSON string configuration", func(t *testing.T) {
		fieldFiltersJSON := `{"include": ["field1"], "exclude": ["field2", "field3"]}`

		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": false,
			"outputFormat":    "JSON",
			"addFlowDetails":  false,
			"fieldFilters":    fieldFiltersJSON,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		activity := act.(*Activity)
		filter, err := activity.parseFieldFilters()

		assert.NoError(t, err)
		assert.NotNil(t, filter)
		assert.Equal(t, []string{"field1"}, filter.Include)
		assert.Equal(t, []string{"field2", "field3"}, filter.Exclude)
	})

	// Test with nil input
	t.Run("Parse nil configuration", func(t *testing.T) {
		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": false,
			"outputFormat":    "JSON",
			"addFlowDetails":  false,
			"fieldFilters":    nil,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		activity := act.(*Activity)
		filter, err := activity.parseFieldFilters()

		assert.NoError(t, err)
		assert.Nil(t, filter)
	})
}

func TestActivity_WildcardMatching(t *testing.T) {
	settings := map[string]interface{}{
		"logLevel":        "INFO",
		"includeFlowInfo": false,
		"outputFormat":    "JSON",
		"addFlowDetails":  false,
		"fieldFilters":    nil,
	}

	ctx := test.NewActivityInitContext(settings, nil)
	act, err := New(ctx)
	assert.NoError(t, err)

	activity := act.(*Activity)

	// Test wildcard pattern matching
	tests := []struct {
		str     string
		pattern string
		match   bool
	}{
		{"user_id", "user*", true},
		{"user_name", "user*", true},
		{"password", "user*", false},
		{"api_secret", "*secret*", true},
		{"my_secret_key", "*secret*", true},
		{"public_key", "*secret*", false},
		{"anything", "*", true},
		{"exact_match", "exact_match", true},
		{"no_match", "different", false},
	}

	for _, tt := range tests {
		t.Run(fmt.Sprintf("%s matches %s", tt.str, tt.pattern), func(t *testing.T) {
			result := activity.matchWildcardPattern(tt.str, tt.pattern)
			assert.Equal(t, tt.match, result)
		})
	}
}

// TestActivity_SensitiveFieldMasking tests sensitive field masking functionality
func TestActivity_SensitiveFieldMasking(t *testing.T) {
	settings := map[string]interface{}{
		"logLevel":        "INFO",
		"includeFlowInfo": false,
		"outputFormat":    "JSON",
		"addFlowDetails":  false,
	}

	ctx := test.NewActivityInitContext(settings, nil)
	act, err := New(ctx)
	assert.NoError(t, err)

	activity := act.(*Activity)

	// Test data with sensitive information
	logData := map[string]interface{}{
		"message":     "User login",
		"username":    "john.doe",
		"password":    "secret123",
		"email":       "john@example.com",
		"ssn":         "123-45-6789",
		"credit_card": "4111-1111-1111-1111",
		"api_key":     "sk_test_123456789",
		"user_id":     "12345",
	}

	t.Run("Basic field masking with field list", func(t *testing.T) {
		// Create a copy of logData for this test
		testData := make(map[string]interface{})
		for k, v := range logData {
			testData[k] = v
		}

		sensitiveFields := map[string]interface{}{
			"fields": []string{"password", "ssn", "credit_card"},
		}

		result := activity.applySensitiveFieldMasking(testData, sensitiveFields)

		assert.Equal(t, "***", result["password"])
		assert.Equal(t, "***", result["ssn"])
		assert.Equal(t, "***", result["credit_card"])
		// Non-sensitive fields should remain unchanged
		assert.Equal(t, "john.doe", result["username"])
		assert.Equal(t, "john@example.com", result["email"])
	})

	t.Run("Custom mask string", func(t *testing.T) {
		// Create a copy of logData for this test
		testData := make(map[string]interface{})
		for k, v := range logData {
			testData[k] = v
		}

		sensitiveFields := map[string]interface{}{
			"fields":   []string{"password"},
			"maskWith": "[REDACTED]",
		}

		result := activity.applySensitiveFieldMasking(testData, sensitiveFields)

		assert.Equal(t, "[REDACTED]", result["password"])
		assert.Equal(t, "john.doe", result["username"]) // Unchanged
	})

	t.Run("Partial masking with mask length", func(t *testing.T) {
		// Create a copy of logData for this test
		testData := make(map[string]interface{})
		for k, v := range logData {
			testData[k] = v
		}

		sensitiveFields := map[string]interface{}{
			"fields":     []string{"credit_card", "api_key"},
			"maskWith":   "XXX",
			"maskLength": 4,
		}

		result := activity.applySensitiveFieldMasking(testData, sensitiveFields)

		// Should keep first 3 chars (limited) and mask the rest
		assert.Equal(t, "411XXX", result["credit_card"])
		assert.Equal(t, "sk_XXX", result["api_key"])
	})

	t.Run("Wildcard field matching", func(t *testing.T) {
		// Create a copy of logData for this test
		testData := make(map[string]interface{})
		for k, v := range logData {
			testData[k] = v
		}

		sensitiveFields := map[string]interface{}{
			"fields": []string{"*card*", "*key*", "pass*"},
		}

		result := activity.applySensitiveFieldMasking(testData, sensitiveFields)

		assert.Equal(t, "***", result["credit_card"]) // matches *card*
		assert.Equal(t, "***", result["api_key"])     // matches *key*
		assert.Equal(t, "***", result["password"])    // matches pass*
		// Non-matching fields should remain unchanged
		assert.Equal(t, "john.doe", result["username"])
		assert.Equal(t, "john@example.com", result["email"])
	})

	t.Run("Simple array of field names", func(t *testing.T) {
		// Create a copy of logData for this test
		testData := make(map[string]interface{})
		for k, v := range logData {
			testData[k] = v
		}

		sensitiveFields := []string{"password", "ssn"}

		result := activity.applySensitiveFieldMasking(testData, sensitiveFields)

		assert.Equal(t, "***", result["password"])
		assert.Equal(t, "***", result["ssn"])
		assert.Equal(t, "john.doe", result["username"]) // Unchanged
	})

	t.Run("JSON string configuration", func(t *testing.T) {
		// Create a copy of logData for this test
		testData := make(map[string]interface{})
		for k, v := range logData {
			testData[k] = v
		}

		sensitiveFields := `{"fields": ["password", "ssn"], "maskWith": "[MASKED]"}`

		result := activity.applySensitiveFieldMasking(testData, sensitiveFields)

		assert.Equal(t, "[MASKED]", result["password"])
		assert.Equal(t, "[MASKED]", result["ssn"])
		assert.Equal(t, "john.doe", result["username"]) // Unchanged
	})

	t.Run("Empty sensitive fields", func(t *testing.T) {
		// Create a copy of logData for this test
		testData := make(map[string]interface{})
		for k, v := range logData {
			testData[k] = v
		}

		result := activity.applySensitiveFieldMasking(testData, nil)

		// Should return original data unchanged
		assert.Equal(t, testData, result)
	})

	t.Run("Non-existent fields", func(t *testing.T) {
		// Create a copy of logData for this test
		testData := make(map[string]interface{})
		for k, v := range logData {
			testData[k] = v
		}

		sensitiveFields := map[string]interface{}{
			"fields": []string{"nonexistent", "missing"},
		}

		result := activity.applySensitiveFieldMasking(testData, sensitiveFields)

		// Should return original data unchanged since fields don't exist
		assert.Equal(t, testData, result)
	})

	t.Run("Nil values", func(t *testing.T) {
		dataWithNil := map[string]interface{}{
			"message":  "test",
			"password": nil,
			"username": "john",
		}

		sensitiveFields := map[string]interface{}{
			"fields": []string{"password"},
		}

		result := activity.applySensitiveFieldMasking(dataWithNil, sensitiveFields)

		// Nil values should remain nil
		assert.Nil(t, result["password"])
		assert.Equal(t, "john", result["username"])
	})
}

// TestActivity_SensitiveFieldMaskingIntegration tests sensitive field masking in full context
func TestActivity_SensitiveFieldMaskingIntegration(t *testing.T) {
	settings := map[string]interface{}{
		"logLevel":        "INFO",
		"includeFlowInfo": false,
		"outputFormat":    "JSON",
		"addFlowDetails":  false,
	}

	ctx := test.NewActivityInitContext(settings, nil)
	act, err := New(ctx)
	assert.NoError(t, err)

	t.Run("Full integration with sensitive field masking", func(t *testing.T) {
		tc := test.NewActivityContext(act.Metadata())
		tc.SetInput("logObject", map[string]interface{}{
			"message":    "User authentication",
			"username":   "testuser",
			"password":   "secret123",
			"api_token":  "sk_live_123456789",
			"user_email": "test@example.com",
		})
		tc.SetInput("sensitiveFields", map[string]interface{}{
			"fields":   []string{"password", "*token*"},
			"maskWith": "[HIDDEN]",
		})

		done, err := act.Eval(tc)
		assert.NoError(t, err)
		assert.True(t, done)
	})

	t.Run("Integration with field filtering and masking", func(t *testing.T) {
		// Create activity with field filtering
		settingsWithFilters := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": false,
			"outputFormat":    "JSON",
			"addFlowDetails":  false,
			"fieldFilters": map[string]interface{}{
				"include": []string{"message", "username", "action"},
			},
		}

		ctx := test.NewActivityInitContext(settingsWithFilters, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		tc := test.NewActivityContext(act.Metadata())
		tc.SetInput("logObject", map[string]interface{}{
			"message":    "User action",
			"username":   "testuser",
			"password":   "secret123", // Should be filtered out anyway
			"action":     "login",
			"session_id": "sess_123", // Should be filtered out
		})
		tc.SetInput("sensitiveFields", map[string]interface{}{
			"fields": []string{"username"}, // This will mask username but it should still be included
		})

		done, err := act.Eval(tc)
		assert.NoError(t, err)
		assert.True(t, done)
	})

	t.Run("Masking with different output formats", func(t *testing.T) {
		formats := []string{"JSON", "KEY_VALUE", "LOGFMT"}

		for _, format := range formats {
			t.Run(format, func(t *testing.T) {
				settingsWithFormat := map[string]interface{}{
					"logLevel":        "INFO",
					"includeFlowInfo": false,
					"outputFormat":    format,
					"addFlowDetails":  false,
				}

				ctx := test.NewActivityInitContext(settingsWithFormat, nil)
				act, err := New(ctx)
				assert.NoError(t, err)

				tc := test.NewActivityContext(act.Metadata())
				tc.SetInput("logObject", map[string]interface{}{
					"message":  "Test message",
					"password": "secret123",
					"username": "testuser",
				})
				tc.SetInput("sensitiveFields", map[string]interface{}{
					"fields": []string{"password"},
				})

				done, err := act.Eval(tc)
				assert.NoError(t, err)
				assert.True(t, done)
			})
		}
	})
}

// TestActivity_EnterpriseFeatures tests the new enterprise features
func TestActivity_EnterpriseFeatures(t *testing.T) {
	t.Run("Engine metadata integration", func(t *testing.T) {
		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": true,
			"outputFormat":    "JSON",
			"addFlowDetails":  true,
			"fieldFilters":    nil,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		tc := test.NewActivityContext(act.Metadata())
		tc.SetInput("logObject", map[string]interface{}{
			"message": "Testing enterprise features",
			"action":  "demo",
		})

		done, err := act.Eval(tc)
		assert.NoError(t, err)
		assert.True(t, done)
	})

	t.Run("Environment variable override", func(t *testing.T) {
		// Set environment variable
		os.Setenv("FLOGO_LOG_LEVEL", "DEBUG")
		defer os.Unsetenv("FLOGO_LOG_LEVEL")

		settings := map[string]interface{}{
			"logLevel":        "INFO", // This should be overridden by env var
			"includeFlowInfo": false,
			"outputFormat":    "JSON",
			"addFlowDetails":  false,
			"fieldFilters":    nil,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		tc := test.NewActivityContext(act.Metadata())
		tc.SetInput("logObject", "Debug level test message")

		done, err := act.Eval(tc)
		assert.NoError(t, err)
		assert.True(t, done)
	})

	t.Run("Environment variable priority order", func(t *testing.T) {
		// Set multiple environment variables to test priority
		os.Setenv("FLOGO_LOG_LEVEL", "ERROR")
		os.Setenv("FLOGO_DYNAMICLOG_LOG_LEVEL", "DEBUG")
		os.Setenv("FLOGO_LOGACTIVITY_LOG_LEVEL", "WARN")
		defer func() {
			os.Unsetenv("FLOGO_LOG_LEVEL")
			os.Unsetenv("FLOGO_DYNAMICLOG_LOG_LEVEL")
			os.Unsetenv("FLOGO_LOGACTIVITY_LOG_LEVEL")
		}()

		settings := map[string]interface{}{
			"logLevel":        "INFO", // Should be overridden by FLOGO_LOG_LEVEL (ERROR)
			"includeFlowInfo": false,
			"outputFormat":    "JSON",
			"addFlowDetails":  false,
			"fieldFilters":    nil,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		tc := test.NewActivityContext(act.Metadata())
		tc.SetInput("logObject", "Priority test - should use ERROR level from FLOGO_LOG_LEVEL")

		done, err := act.Eval(tc)
		assert.NoError(t, err)
		assert.True(t, done)
	})

	t.Run("Tracing context awareness", func(t *testing.T) {
		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": true,
			"outputFormat":    "JSON",
			"addFlowDetails":  true,
			"fieldFilters":    nil,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		tc := test.NewActivityContext(act.Metadata())
		tc.SetInput("logObject", map[string]interface{}{
			"message":     "Tracing enabled test",
			"operation":   "test_trace",
			"trace_ready": true,
		})

		done, err := act.Eval(tc)
		assert.NoError(t, err)
		assert.True(t, done)
	})
}

// TestActivity_ECSCompliance tests ECS (Elastic Common Schema) compliance
func TestActivity_ECSCompliance(t *testing.T) {
	t.Run("ECS required fields", func(t *testing.T) {
		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": true, // Enable ECS fields
			"outputFormat":    "JSON",
			"addFlowDetails":  false,
			"fieldFilters":    nil,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		activity := act.(*Activity)

		// Test the ECS fields are properly structured
		tc := test.NewActivityContext(act.Metadata())
		result := activity.formatLogEntry(tc, map[string]interface{}{
			"message": "ECS compliance test",
			"user_id": "test123",
		}, "INFO", nil, nil)

		// Parse the JSON result to verify ECS compliance
		var logEntry map[string]interface{}
		err = json.Unmarshal([]byte(result), &logEntry)
		assert.NoError(t, err)

		// Check ECS version field
		assert.Contains(t, logEntry, "ecs")
		ecsInfo := logEntry["ecs"].(map[string]interface{})
		assert.Equal(t, "8.11", ecsInfo["version"])

		// Check @timestamp (ECS core field)
		assert.Contains(t, logEntry, "@timestamp")

		// Check log field (ECS logging fields)
		assert.Contains(t, logEntry, "log")
		logInfo := logEntry["log"].(map[string]interface{})
		assert.Equal(t, "INFO", logInfo["level"])
		assert.Equal(t, "flogo.dynamic-log", logInfo["logger"])

		// Check service field (ECS service fields)
		assert.Contains(t, logEntry, "service")
		serviceInfo := logEntry["service"].(map[string]interface{})
		assert.Equal(t, "application", serviceInfo["type"])
		assert.Contains(t, serviceInfo, "name")

		// Check agent field (ECS agent fields)
		assert.Contains(t, logEntry, "agent")
		agentInfo := logEntry["agent"].(map[string]interface{})
		assert.Equal(t, "flogo-dynamic-log", agentInfo["name"])
		assert.Equal(t, "logging", agentInfo["type"])
		assert.Equal(t, "1.0.0", agentInfo["version"])

		// Check host field (ECS host fields)
		assert.Contains(t, logEntry, "host")
		hostInfo := logEntry["host"].(map[string]interface{})
		assert.Contains(t, hostInfo, "name")

		// Check process field (ECS process fields)
		assert.Contains(t, logEntry, "process")
		processInfo := logEntry["process"].(map[string]interface{})
		assert.Equal(t, "flogo", processInfo["name"])
		assert.Contains(t, processInfo, "pid")

		// Check event field (ECS event fields)
		assert.Contains(t, logEntry, "event")
		eventInfo := logEntry["event"].(map[string]interface{})
		assert.Equal(t, "event", eventInfo["kind"])
		assert.Equal(t, []interface{}{"process"}, eventInfo["category"])
		assert.Equal(t, []interface{}{"info"}, eventInfo["type"])
		assert.Equal(t, "flogo.application.logs", eventInfo["dataset"])
		assert.Equal(t, "flogo", eventInfo["module"])
		assert.Equal(t, "log", eventInfo["action"])
		assert.Equal(t, "success", eventInfo["outcome"])

		// Check labels field (ECS base fields)
		assert.Contains(t, logEntry, "labels")
		labelsInfo := logEntry["labels"].(map[string]interface{})
		assert.Equal(t, "flogo", labelsInfo["framework"])
		assert.Equal(t, "dynamic-log", labelsInfo["activity"])

		fmt.Printf("ECS compliant log entry: %s\n", result)
	})

	t.Run("ECS event type mapping", func(t *testing.T) {
		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": true,
			"outputFormat":    "JSON",
			"addFlowDetails":  false,
			"fieldFilters":    nil,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		activity := act.(*Activity)

		// Test different log levels map to appropriate ECS event types
		testCases := []struct {
			level           string
			expectedType    string
			expectedOutcome string
		}{
			{"INFO", "info", "success"},
			{"DEBUG", "info", "success"},
			{"WARN", "info", "unknown"},
			{"ERROR", "error", "failure"},
			{"FATAL", "error", "failure"},
		}

		for _, tc := range testCases {
			t.Run(fmt.Sprintf("Level_%s", tc.level), func(t *testing.T) {
				result := activity.formatLogEntry(test.NewActivityContext(act.Metadata()),
					map[string]interface{}{"message": "test"}, tc.level, nil, nil)

				var logEntry map[string]interface{}
				err := json.Unmarshal([]byte(result), &logEntry)
				assert.NoError(t, err)

				eventInfo := logEntry["event"].(map[string]interface{})
				assert.Equal(t, []interface{}{tc.expectedType}, eventInfo["type"])
				assert.Equal(t, tc.expectedOutcome, eventInfo["outcome"])
			})
		}
	})

	t.Run("ECS environment variable integration", func(t *testing.T) {
		// Set test environment variables
		os.Setenv("SERVICE_NAME", "test-service")
		os.Setenv("SERVICE_VERSION", "2.1.0")
		os.Setenv("ENVIRONMENT", "test")
		defer func() {
			os.Unsetenv("SERVICE_NAME")
			os.Unsetenv("SERVICE_VERSION")
			os.Unsetenv("ENVIRONMENT")
		}()

		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": true,
			"outputFormat":    "JSON",
			"addFlowDetails":  false,
			"fieldFilters":    nil,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		activity := act.(*Activity)

		result := activity.formatLogEntry(test.NewActivityContext(act.Metadata()),
			map[string]interface{}{"message": "env test"}, "INFO", nil, nil)

		var logEntry map[string]interface{}
		err = json.Unmarshal([]byte(result), &logEntry)
		assert.NoError(t, err)

		// Verify environment variables are picked up
		serviceInfo := logEntry["service"].(map[string]interface{})
		assert.Equal(t, "test-service", serviceInfo["name"])
		assert.Equal(t, "2.1.0", serviceInfo["version"])
		assert.Equal(t, "test", serviceInfo["environment"])
	})
}

// TestActivity_InlineFlowFormatting tests the new inline flow formatting (like official Log activity)
func TestActivity_InlineFlowFormatting(t *testing.T) {
	t.Run("Flow details as inline suffix", func(t *testing.T) {
		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": false, // No ECS fields, just clean JSON
			"outputFormat":    "JSON",
			"addFlowDetails":  true, // Enable inline flow suffix
			"fieldFilters":    nil,
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		activity := act.(*Activity)

		// Test the appendFlowSuffix method directly
		tc := test.NewActivityContext(act.Metadata())
		mainContent := `{"fname":"milind","lname":"pandav","level":"INFO","password":"±±±±±±±"}`

		result := activity.appendFlowSuffix(tc, mainContent)

		// Should have the main content followed by flow information as suffix
		assert.Contains(t, result, mainContent)
		assert.Contains(t, result, ". ")

		// The result should NOT contain nested JSON objects like {"flogo":{"flow":"..."}
		assert.NotContains(t, result, `"flogo":`)
		assert.NotContains(t, result, `"instance_id":`)

		fmt.Printf("Inline format result: %s\n", result)
	})

	t.Run("Demo configuration simulation", func(t *testing.T) {
		// Exactly match the demo.flogo configuration
		settings := map[string]interface{}{
			"logLevel":        "INFO",
			"includeFlowInfo": false, // ECS disabled in demo
			"outputFormat":    "JSON",
			"addFlowDetails":  true, // Flow details enabled in demo
		}

		ctx := test.NewActivityInitContext(settings, nil)
		act, err := New(ctx)
		assert.NoError(t, err)

		tc := test.NewActivityContext(act.Metadata())
		tc.SetInput("logObject", map[string]interface{}{
			"fname":    "milind",
			"lname":    "pandav",
			"password": "milind",
			"username": "milind",
		})
		tc.SetInput("sensitiveFields", map[string]interface{}{
			"fieldNamesToHide": []string{"password"},
			"maskWith":         "±±±±±±±",
			"maskLength":       0,
		})
		tc.SetInput("fieldFilters", map[string]interface{}{
			"include": []string{"fname", "lname", "password"},
			"exclude": []string{"username"},
		})

		done, err := act.Eval(tc)
		assert.NoError(t, err)
		assert.True(t, done)

		// The output should now be inline format like:
		// {"fname":"milind","lname":"pandav","level":"INFO","password":"±±±±±±±"}. FlowInstanceID [...], Flow [...].
		// Instead of:
		// {"flogo":{"flow":"...","instance_id":"..."},"fname":"milind","lname":"pandav","level":"INFO","password":"±±±±±±±"}
	})

	t.Run("Compare output formats", func(t *testing.T) {
		formats := []string{"JSON", "KEY_VALUE", "LOGFMT"}

		for _, format := range formats {
			t.Run(format+" with inline flow details", func(t *testing.T) {
				settings := map[string]interface{}{
					"logLevel":        "INFO",
					"includeFlowInfo": false,
					"outputFormat":    format,
					"addFlowDetails":  true,
				}

				ctx := test.NewActivityInitContext(settings, nil)
				act, err := New(ctx)
				assert.NoError(t, err)

				tc := test.NewActivityContext(act.Metadata())
				tc.SetInput("logObject", map[string]interface{}{
					"message": "Test message",
					"user":    "testuser",
				})

				done, err := act.Eval(tc)
				assert.NoError(t, err)
				assert.True(t, done)
			})
		}
	})
}
