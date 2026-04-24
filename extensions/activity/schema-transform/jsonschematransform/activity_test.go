package jsonschematransform

import (
	"strings"
	"testing"

	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestRegister(t *testing.T) {
	ref := activity.GetRef(&Activity{})
	act := activity.Get(ref)
	assert.NotNil(t, act)
}

func TestActivity_Eval(t *testing.T) {
	act := &Activity{}
	tc := test.NewActivityContext(act.Metadata())

	// Sample JSON Schema for testing
	jsonSchema := `{
		"type": "object",
		"properties": {
			"id": {"type": "integer"},
			"name": {"type": "string"},
			"email": {"type": "string", "format": "email"},
			"age": {"type": "integer", "minimum": 0, "maximum": 120},
			"active": {"type": "boolean", "default": true},
			"tags": {
				"type": "array",
				"items": {"type": "string"}
			},
			"status": {
				"type": "string",
				"enum": ["active", "inactive", "pending"]
			},
			"address": {
				"type": "object",
				"properties": {
					"street": {"type": "string"},
					"city": {"type": "string"},
					"zipcode": {"type": "string"}
				},
				"required": ["street", "city"]
			}
		},
		"required": ["id", "name", "age", "active", "tags", "address"]
	}`

	t.Run("Transform to Both Formats", func(t *testing.T) {
		tc.SetInput(ivJSONSchemaString, jsonSchema)
		tc.SetInput(ivOutputFormat, "both")
		tc.SetInput(ivRootElementName, "User")
		tc.SetInput(ivTargetNamespace, "http://example.com/user")
		tc.SetInput(ivAvroRecordName, "UserRecord")
		tc.SetInput(ivAvroNamespace, "com.example.user")

		done, err := act.Eval(tc)

		assert.True(t, done)
		assert.NoError(t, err)
		assert.False(t, tc.GetOutput(ovError).(bool))

		xsdString := tc.GetOutput(ovXSDString).(string)
		avroSchema := tc.GetOutput(ovAvroSchema).(string)

		assert.NotEmpty(t, xsdString)
		assert.NotEmpty(t, avroSchema)

		// Validate XSD contains expected elements
		assert.Contains(t, xsdString, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
		assert.Contains(t, xsdString, "xs:schema")
		assert.Contains(t, xsdString, "name=\"User\"")
		assert.Contains(t, xsdString, "targetNamespace=\"http://example.com/user\"")

		// Validate Avro contains expected elements
		assert.Contains(t, avroSchema, "\"type\": \"record\"")
		assert.Contains(t, avroSchema, "\"name\": \"UserRecord\"")
		assert.Contains(t, avroSchema, "\"namespace\": \"com.example.user\"")

		t.Logf("Generated XSD:\n%s", xsdString)
		t.Logf("Generated Avro:\n%s", avroSchema)
	})

	t.Run("Transform to XSD only", func(t *testing.T) {
		tc.SetInput(ivJSONSchemaString, jsonSchema)
		tc.SetInput(ivOutputFormat, "xsd")
		tc.SetInput(ivRootElementName, "User")

		done, err := act.Eval(tc)

		assert.True(t, done)
		assert.NoError(t, err)
		assert.False(t, tc.GetOutput(ovError).(bool))

		xsdString := tc.GetOutput(ovXSDString).(string)
		avroSchema := tc.GetOutput(ovAvroSchema).(string)

		assert.NotEmpty(t, xsdString)
		assert.Empty(t, avroSchema)
	})

	t.Run("Transform to Avro only", func(t *testing.T) {
		tc.SetInput(ivJSONSchemaString, jsonSchema)
		tc.SetInput(ivOutputFormat, "avro")
		tc.SetInput(ivAvroRecordName, "User")

		done, err := act.Eval(tc)

		assert.True(t, done)
		assert.NoError(t, err)
		assert.False(t, tc.GetOutput(ovError).(bool))

		xsdString := tc.GetOutput(ovXSDString).(string)
		avroSchema := tc.GetOutput(ovAvroSchema).(string)

		assert.Empty(t, xsdString)
		assert.NotEmpty(t, avroSchema)

		t.Logf("Generated Avro:\n%s", avroSchema)
	})

	t.Run("Default values", func(t *testing.T) {
		tc.SetInput(ivJSONSchemaString, jsonSchema)
		tc.SetInput(ivOutputFormat, "xsd")

		done, err := act.Eval(tc)

		assert.True(t, done)
		assert.NoError(t, err)
		assert.False(t, tc.GetOutput(ovError).(bool))

		xsdString := tc.GetOutput(ovXSDString).(string)

		// Verify default root element name is used
		assert.Contains(t, xsdString, "name=\"RootElement\"")
		// Verify no targetNamespace is set (should not contain targetNamespace attribute)
		assert.NotContains(t, xsdString, "targetNamespace=")

		t.Logf("Generated XSD:\n%s", xsdString)
	})

	t.Run("Invalid JSON Schema", func(t *testing.T) {
		tc.SetInput(ivJSONSchemaString, "invalid json")
		tc.SetInput(ivOutputFormat, "both")

		done, err := act.Eval(tc)

		assert.True(t, done)
		assert.NoError(t, err)
		assert.True(t, tc.GetOutput(ovError).(bool))

		errorMessage := tc.GetOutput(ovErrorMessage).(string)
		assert.Contains(t, errorMessage, "SCHEMA_PARSE_ERROR")
	})

	t.Run("Invalid Output Format", func(t *testing.T) {
		tc.SetInput(ivJSONSchemaString, jsonSchema)
		tc.SetInput(ivOutputFormat, "invalid")

		done, err := act.Eval(tc)

		assert.True(t, done)
		assert.NoError(t, err)
		assert.True(t, tc.GetOutput(ovError).(bool))

		errorMessage := tc.GetOutput(ovErrorMessage).(string)
		assert.Contains(t, errorMessage, "invalid outputFormat")
	})
}

func TestEvalWithDefaults(t *testing.T) {
	act := &Activity{}
	tc := test.NewActivityContext(act.Metadata())

	jsonSchema := `{
		"type": "object",
		"properties": {
			"name": {"type": "string"}
		}
	}`

	// Set only required input
	tc.SetInput(ivJSONSchemaString, jsonSchema)

	done, err := act.Eval(tc)
	assert.True(t, done)
	assert.NoError(t, err)

	// Check that defaults were applied
	xsdString := tc.GetOutput(ovXSDString).(string)
	avroSchema := tc.GetOutput(ovAvroSchema).(string)

	// Should contain default root element name
	assert.Contains(t, xsdString, `name="RootElement"`)
	// Should contain default Avro record name
	assert.Contains(t, avroSchema, `"name": "RootRecord"`)
	assert.Contains(t, avroSchema, `"namespace": "com.example"`)
}

// TestAdvancedFeatures tests complex JSON Schema features
func TestAdvancedFeatures(t *testing.T) {
	act := &Activity{}
	tc := test.NewActivityContext(act.Metadata())

	tests := []struct {
		name         string
		jsonSchema   string
		outputFormat string
		expectedXSD  []string
		expectedAvro []string
	}{
		{
			name: "Union Types (anyOf)",
			jsonSchema: `{
				"type": "object",
				"properties": {
					"value": {
						"anyOf": [
							{"type": "string"},
							{"type": "integer"}
						]
					}
				}
			}`,
			outputFormat: "both",
			expectedXSD:  []string{"xs:choice"},
			expectedAvro: []string{"\"type\": [\"string\", \"long\"]"},
		},
		{
			name: "String Constraints",
			jsonSchema: `{
				"type": "object",
				"properties": {
					"username": {
						"type": "string",
						"pattern": "^[a-zA-Z][a-zA-Z0-9]*$",
						"minLength": 3,
						"maxLength": 20
					}
				}
			}`,
			outputFormat: "xsd",
			expectedXSD: []string{
				"xs:pattern",
				"value=\"^[a-zA-Z][a-zA-Z0-9]*$\"",
				"xs:minLength",
				"value=\"3\"",
				"xs:maxLength",
				"value=\"20\"",
			},
		},
		{
			name: "Enum Values",
			jsonSchema: `{
				"type": "object",
				"properties": {
					"status": {
						"type": "string",
						"enum": ["active", "inactive", "pending"]
					}
				}
			}`,
			outputFormat: "both",
			expectedXSD: []string{
				"xs:enumeration",
				"value=\"active\"",
				"value=\"inactive\"",
				"value=\"pending\"",
			},
			expectedAvro: []string{
				"\"type\": \"enum\"",
				"\"symbols\": [\"active\", \"inactive\", \"pending\"]",
			},
		},
		{
			name: "Numeric Constraints",
			jsonSchema: `{
				"type": "object",
				"properties": {
					"age": {
						"type": "integer",
						"minimum": 0,
						"maximum": 120
					},
					"price": {
						"type": "number",
						"exclusiveMinimum": 0,
						"exclusiveMaximum": 1000
					}
				}
			}`,
			outputFormat: "xsd",
			expectedXSD: []string{
				"xs:minInclusive",
				"value=\"0\"",
				"xs:maxInclusive",
				"value=\"120\"",
				"xs:minExclusive",
				"xs:maxExclusive",
				"value=\"1000\"",
			},
		},
		{
			name: "Array Constraints",
			jsonSchema: `{
				"type": "object",
				"properties": {
					"tags": {
						"type": "array",
						"items": {"type": "string"},
						"minItems": 1,
						"maxItems": 5
					}
				}
			}`,
			outputFormat: "xsd",
			expectedXSD: []string{
				"minOccurs=\"1\"",
				"maxOccurs=\"5\"",
			},
		},
		{
			name: "Nested Objects",
			jsonSchema: `{
				"type": "object",
				"properties": {
					"user": {
						"type": "object",
						"properties": {
							"profile": {
								"type": "object",
								"properties": {
									"name": {"type": "string"}
								}
							}
						}
					}
				}
			}`,
			outputFormat: "avro",
			expectedAvro: []string{
				"\"type\": \"record\"",
				"\"name\": \"userRecord\"",
				"\"name\": \"profileRecord\"",
			},
		},
		{
			name: "AllOf Schema Merging",
			jsonSchema: `{
				"type": "object",
				"properties": {
					"entity": {
						"allOf": [
							{
								"type": "object",
								"properties": {
									"id": {"type": "string"}
								}
							},
							{
								"type": "object",
								"properties": {
									"name": {"type": "string"}
								}
							}
						]
					}
				}
			}`,
			outputFormat: "both",
			expectedXSD:  []string{"xs:sequence"},
			expectedAvro: []string{"\"type\": \"record\""},
		},
		{
			name: "Const Values",
			jsonSchema: `{
				"type": "object",
				"properties": {
					"version": {
						"const": "1.0.0"
					}
				}
			}`,
			outputFormat: "both",
			expectedXSD: []string{
				"xs:enumeration",
				"value=\"1.0.0\"",
			},
			expectedAvro: []string{
				"\"type\": \"enum\"",
				"\"symbols\": [\"1.0.0\"]",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tc.SetInput(ivJSONSchemaString, tt.jsonSchema)
			tc.SetInput(ivOutputFormat, tt.outputFormat)
			tc.SetInput(ivRootElementName, "TestElement")
			tc.SetInput(ivTargetNamespace, "http://test.example.com/")
			tc.SetInput(ivAvroRecordName, "TestRecord")
			tc.SetInput(ivAvroNamespace, "com.test")

			done, err := act.Eval(tc)

			assert.True(t, done)
			assert.NoError(t, err)
			assert.False(t, tc.GetOutput(ovError).(bool))

			if tt.outputFormat == "xsd" || tt.outputFormat == "both" {
				xsdString := tc.GetOutput(ovXSDString).(string)
				for _, expected := range tt.expectedXSD {
					assert.Contains(t, xsdString, expected, "Expected XSD to contain '%s'", expected)
				}
				t.Logf("Generated XSD:\n%s", xsdString)
			}

			if tt.outputFormat == "avro" || tt.outputFormat == "both" {
				avroSchema := tc.GetOutput(ovAvroSchema).(string)
				for _, expected := range tt.expectedAvro {
					assert.Contains(t, avroSchema, expected, "Expected Avro to contain '%s'", expected)
				}
				t.Logf("Generated Avro:\n%s", avroSchema)
			}
		})
	}
}

// TestErrorHandling tests various error scenarios
func TestErrorHandling(t *testing.T) {
	act := &Activity{}

	tests := []struct {
		name           string
		jsonSchema     string
		outputFormat   string
		expectError    bool
		expectedErrMsg string
	}{
		{
			name:           "Empty JSON Schema Input",
			jsonSchema:     "",
			outputFormat:   "both",
			expectError:    true,
			expectedErrMsg: "jsonSchemaString",
		},
		{
			name:           "Malformed JSON",
			jsonSchema:     `{"type": "object", "properties":`,
			outputFormat:   "both",
			expectError:    true,
			expectedErrMsg: "unexpected end of JSON input",
		},
		{
			name:           "Unsupported Schema Type",
			jsonSchema:     `{"type": "unsupported_type"}`,
			outputFormat:   "both",
			expectError:    true,
			expectedErrMsg: "unsupported",
		},
		{
			name:           "Array Without Items Definition",
			jsonSchema:     `{"type": "array"}`,
			outputFormat:   "both",
			expectError:    true,
			expectedErrMsg: "items",
		},
		{
			name:           "Invalid Output Format",
			jsonSchema:     `{"type": "string"}`,
			outputFormat:   "invalid",
			expectError:    true,
			expectedErrMsg: "invalid outputFormat",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tc := test.NewActivityContext(act.Metadata())

			tc.SetInput(ivJSONSchemaString, tt.jsonSchema)
			tc.SetInput(ivOutputFormat, tt.outputFormat)
			tc.SetInput(ivRootElementName, "Test")
			tc.SetInput(ivTargetNamespace, "")

			done, err := act.Eval(tc)

			if tt.expectError {
				assert.True(t, done)
				assert.NoError(t, err) // Activity should not return Go error, but set error outputs

				errorOutput := tc.GetOutput(ovError)
				assert.True(t, errorOutput.(bool))

				errorMsg := tc.GetOutput(ovErrorMessage)
				require.NotNil(t, errorMsg)
				assert.Contains(t, errorMsg.(string), tt.expectedErrMsg)
			} else {
				assert.True(t, done)
				assert.NoError(t, err)
				assert.False(t, tc.GetOutput(ovError).(bool))
			}
		})
	}
}

// TestComplexScenarios tests real-world complex schema scenarios
func TestComplexScenarios(t *testing.T) {
	act := &Activity{}
	tc := test.NewActivityContext(act.Metadata())

	complexSchema := `{
		"type": "object",
		"properties": {
			"id": {"type": "string", "pattern": "^PROD-[0-9]{6}$"},
			"name": {"type": "string", "minLength": 1, "maxLength": 100},
			"price": {"type": "number", "minimum": 0.01, "maximum": 999999.99},
			"category": {"type": "string", "enum": ["electronics", "clothing", "books"]},
			"tags": {
				"type": "array",
				"items": {"type": "string"},
				"minItems": 1,
				"maxItems": 10
			},
			"specifications": {
				"type": "object",
				"properties": {
					"weight": {"type": "number", "minimum": 0},
					"dimensions": {
						"type": "object",
						"properties": {
							"length": {"type": "number"},
							"width": {"type": "number"}, 
							"height": {"type": "number"}
						},
						"required": ["length", "width", "height"]
					}
				}
			},
			"availability": {
				"anyOf": [
					{"type": "boolean"},
					{
						"type": "object",
						"properties": {
							"inStock": {"type": "boolean"},
							"quantity": {"type": "integer", "minimum": 0}
						}
					}
				]
			}
		},
		"required": ["id", "name", "price", "category"]
	}`

	tc.SetInput(ivJSONSchemaString, complexSchema)
	tc.SetInput(ivOutputFormat, "both")
	tc.SetInput(ivRootElementName, "Product")
	tc.SetInput(ivTargetNamespace, "http://example.com/product")
	tc.SetInput(ivAvroRecordName, "ProductRecord")
	tc.SetInput(ivAvroNamespace, "com.example.product")

	done, err := act.Eval(tc)
	assert.True(t, done)
	assert.NoError(t, err)
	assert.False(t, tc.GetOutput(ovError).(bool))

	xsdString := tc.GetOutput(ovXSDString).(string)
	avroSchema := tc.GetOutput(ovAvroSchema).(string)

	// XSD validations
	xsdAssertions := []string{
		`targetNamespace="http://example.com/product"`,
		`<xs:pattern value="^PROD-[0-9]{6}$">`,
		`<xs:minLength value="1">`,
		`<xs:maxLength value="100">`,
		`<xs:minInclusive value="0.01">`,
		`<xs:enumeration value="electronics">`,
		`minOccurs="1" maxOccurs="10"`,
		`<xs:element name="length" type="xs:decimal">`,
		`xs:choice`,
	}

	for _, assertion := range xsdAssertions {
		assert.Contains(t, xsdString, assertion, "Expected XSD to contain: %s", assertion)
	}

	// Avro validations
	avroAssertions := []string{
		`"name": "ProductRecord"`,
		`"namespace": "com.example.product"`,
		`"type": "record"`,
		`"type": "enum"`,
		`"symbols": ["electronics", "clothing", "books"]`,
		`"type": "array"`,
		`"items": "string"`,
	}

	for _, assertion := range avroAssertions {
		assert.Contains(t, avroSchema, assertion, "Expected Avro to contain: %s", assertion)
	}

	t.Logf("Generated XSD:\n%s", xsdString)
	t.Logf("Generated Avro:\n%s", avroSchema)
}

// Benchmark tests
func BenchmarkEval(b *testing.B) {
	act := &Activity{}
	tc := test.NewActivityContext(act.Metadata())

	jsonSchema := `{
		"type": "object",
		"properties": {
			"name": {"type": "string"},
			"age": {"type": "integer"},
			"address": {
				"type": "object",
				"properties": {
					"street": {"type": "string"},
					"city": {"type": "string"},
					"zipcode": {"type": "string"}
				}
			},
			"hobbies": {
				"type": "array",
				"items": {"type": "string"}
			}
		},
		"required": ["name"]
	}`

	tc.SetInput(ivJSONSchemaString, jsonSchema)
	tc.SetInput(ivOutputFormat, "both")
	tc.SetInput(ivRootElementName, "Person")
	tc.SetInput(ivTargetNamespace, "http://example.com/person")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := act.Eval(tc)
		if err != nil {
			b.Fatal(err)
		}
	}
}

// Helper function to normalize strings for comparison
func normalizeString(s string) string {
	return strings.ReplaceAll(strings.ReplaceAll(s, "\n", ""), "\t", "")
}
