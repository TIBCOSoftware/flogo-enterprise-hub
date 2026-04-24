package avroschematransform

import (
	"encoding/json"
	"testing"

	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
)

func TestActivity_Eval(t *testing.T) {
	act := &Activity{}
	tc := test.NewActivityContext(act.Metadata())

	// Sample Avro Schema for testing
	avroSchema := `{
		"type": "record",
		"name": "User",
		"namespace": "com.example",
		"fields": [
			{"name": "id", "type": "long"},
			{"name": "name", "type": "string"},
			{"name": "email", "type": ["null", "string"], "default": null},
			{"name": "age", "type": "int"},
			{"name": "active", "type": "boolean", "default": true},
			{"name": "tags", "type": {"type": "array", "items": "string"}},
			{"name": "address", "type": {
				"type": "record",
				"name": "Address",
				"fields": [
					{"name": "street", "type": "string"},
					{"name": "city", "type": "string"},
					{"name": "zipcode", "type": ["null", "string"], "default": null}
				]
			}}
		]
	}`

	t.Run("Transform to both JSON and XSD", func(t *testing.T) {
		tc.SetInput(ivAvroSchemaString, avroSchema)
		tc.SetInput(ivOutputFormat, "both")
		tc.SetInput(ivRootElementName, "User")
		tc.SetInput(ivTargetNamespace, "http://example.com/user")

		done, err := act.Eval(tc)

		assert.True(t, done)
		assert.Nil(t, err)
		assert.False(t, tc.GetOutput(ovError).(bool))

		jsonSchema := tc.GetOutput(ovJsonSchema).(string)
		xsdString := tc.GetOutput(ovXsdString).(string)

		assert.NotEmpty(t, jsonSchema)
		assert.NotEmpty(t, xsdString)

		// Validate JSON Schema is valid JSON
		var jsonObj map[string]interface{}
		err = json.Unmarshal([]byte(jsonSchema), &jsonObj)
		assert.Nil(t, err)
		assert.Equal(t, "https://json-schema.org/draft/2020-12/schema", jsonObj["$schema"])
		assert.Equal(t, "object", jsonObj["type"])

		// Validate XSD contains expected elements
		assert.Contains(t, xsdString, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
		assert.Contains(t, xsdString, "xs:schema")
		assert.Contains(t, xsdString, "name=\"User\"")
		assert.Contains(t, xsdString, "targetNamespace=\"http://example.com/user\"")
	})

	t.Run("Transform to JSON Schema only", func(t *testing.T) {
		tc.SetInput(ivAvroSchemaString, avroSchema)
		tc.SetInput(ivOutputFormat, "json")

		done, err := act.Eval(tc)

		assert.True(t, done)
		assert.Nil(t, err)
		assert.False(t, tc.GetOutput(ovError).(bool))

		jsonSchema := tc.GetOutput(ovJsonSchema).(string)
		xsdString := tc.GetOutput(ovXsdString).(string)

		assert.NotEmpty(t, jsonSchema)
		assert.Empty(t, xsdString)
	})

	t.Run("Transform to XSD only", func(t *testing.T) {
		tc.SetInput(ivAvroSchemaString, avroSchema)
		tc.SetInput(ivOutputFormat, "xsd")
		tc.SetInput(ivRootElementName, "User")

		done, err := act.Eval(tc)

		assert.True(t, done)
		assert.Nil(t, err)
		assert.False(t, tc.GetOutput(ovError).(bool))

		jsonSchema := tc.GetOutput(ovJsonSchema).(string)
		xsdString := tc.GetOutput(ovXsdString).(string)

		assert.Empty(t, jsonSchema)
		assert.NotEmpty(t, xsdString)
	})

	t.Run("Transform to XSD with default values", func(t *testing.T) {
		// Create a fresh test context to avoid input pollution from previous tests
		freshAct := &Activity{}
		freshTc := test.NewActivityContext(freshAct.Metadata())

		freshTc.SetInput(ivAvroSchemaString, avroSchema)
		freshTc.SetInput(ivOutputFormat, "xsd")
		// Intentionally NOT setting rootElementName or targetNamespace to test defaults

		done, err := freshAct.Eval(freshTc)

		assert.True(t, done)
		assert.Nil(t, err)
		assert.False(t, freshTc.GetOutput(ovError).(bool))

		jsonSchema := freshTc.GetOutput(ovJsonSchema).(string)
		xsdString := freshTc.GetOutput(ovXsdString).(string)

		assert.Empty(t, jsonSchema)
		assert.NotEmpty(t, xsdString)

		// Print the actual XSD for debugging
		t.Logf("Generated XSD:\n%s", xsdString)

		// Verify default root element name is used
		assert.Contains(t, xsdString, "name=\"root\"")
		// Verify no targetNamespace is set (should not contain targetNamespace attribute)
		assert.NotContains(t, xsdString, "targetNamespace=")
	})

	t.Run("Invalid Avro Schema", func(t *testing.T) {
		tc.SetInput(ivAvroSchemaString, "invalid json")
		tc.SetInput(ivOutputFormat, "both")

		done, err := act.Eval(tc)

		assert.True(t, done)
		assert.Nil(t, err)
		assert.True(t, tc.GetOutput(ovError).(bool))

		errorMessage := tc.GetOutput(ovErrorMessage).(string)
		assert.Contains(t, errorMessage, "SCHEMA_PARSE_ERROR")
	})

	t.Run("Invalid Output Format", func(t *testing.T) {
		tc.SetInput(ivAvroSchemaString, avroSchema)
		tc.SetInput(ivOutputFormat, "invalid")

		done, err := act.Eval(tc)

		assert.True(t, done)
		assert.Nil(t, err)
		assert.True(t, tc.GetOutput(ovError).(bool))

		errorMessage := tc.GetOutput(ovErrorMessage).(string)
		assert.Contains(t, errorMessage, "INVALID_INPUT")
		assert.Contains(t, errorMessage, "invalid outputFormat")
	})
}

func TestSimpleAvroTypes(t *testing.T) {
	act := &Activity{}
	tc := test.NewActivityContext(act.Metadata())

	// Test simple types
	simpleSchema := `{
		"type": "record",
		"name": "SimpleTypes",
		"fields": [
			{"name": "stringField", "type": "string"},
			{"name": "intField", "type": "int"},
			{"name": "longField", "type": "long"},
			{"name": "floatField", "type": "float"},
			{"name": "doubleField", "type": "double"},
			{"name": "booleanField", "type": "boolean"},
			{"name": "bytesField", "type": "bytes"},
			{"name": "enumField", "type": {
				"type": "enum",
				"name": "Color",
				"symbols": ["RED", "GREEN", "BLUE"]
			}}
		]
	}`

	tc.SetInput(ivAvroSchemaString, simpleSchema)
	tc.SetInput(ivOutputFormat, "json")

	done, err := act.Eval(tc)

	assert.True(t, done)
	assert.Nil(t, err)
	assert.False(t, tc.GetOutput(ovError).(bool))

	jsonSchema := tc.GetOutput(ovJsonSchema).(string)
	assert.NotEmpty(t, jsonSchema)

	var jsonObj map[string]interface{}
	err = json.Unmarshal([]byte(jsonSchema), &jsonObj)
	assert.Nil(t, err)

	properties := jsonObj["properties"].(map[string]interface{})

	// Check string type
	stringField := properties["stringField"].(map[string]interface{})
	assert.Equal(t, "string", stringField["type"])

	// Check integer type
	intField := properties["intField"].(map[string]interface{})
	assert.Equal(t, "integer", intField["type"])

	// Check enum type
	enumField := properties["enumField"].(map[string]interface{})
	assert.Equal(t, "string", enumField["type"])
	enumValues := enumField["enum"].([]interface{})
	assert.Contains(t, enumValues, "RED")
	assert.Contains(t, enumValues, "GREEN")
	assert.Contains(t, enumValues, "BLUE")
}
