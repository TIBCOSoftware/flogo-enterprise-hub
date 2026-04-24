package xsdschematransform

import (
	"encoding/json"
	"testing"

	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
)

func TestXSDSchemaTransformActivity(t *testing.T) {
	// Create activity instance
	act := &Activity{}
	tc := test.NewActivityContext(act.Metadata())

	// Sample XSD schema
	xsdSchema := `<?xml version="1.0" encoding="UTF-8"?>
<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
           targetNamespace="http://example.com/test"
           elementFormDefault="qualified">
    
    <xs:element name="person" type="PersonType"/>
    
    <xs:complexType name="PersonType">
        <xs:sequence>
            <xs:element name="name" type="xs:string"/>
            <xs:element name="age" type="xs:int"/>
            <xs:element name="email" type="xs:string" minOccurs="0"/>
        </xs:sequence>
        <xs:attribute name="id" type="xs:string" use="required"/>
    </xs:complexType>
</xs:schema>`

	// Set inputs
	tc.SetInput(ivXSDString, xsdSchema)
	tc.SetInput(ivOutputFormat, "both")
	tc.SetInput(ivValidateInput, true)
	tc.SetInput(ivJSONSchemaVersion, "2020-12")
	tc.SetInput(ivAvroRecordName, "Person")
	tc.SetInput(ivAvroNamespace, "com.example.test")
	tc.SetInput(ivIncludeAttributes, true)

	// Execute activity
	done, err := act.Eval(tc)

	// Assertions
	assert.True(t, done)
	assert.NoError(t, err)

	// Check that we didn't get an error in output
	errorOutput := tc.GetOutput(ovError)
	assert.False(t, errorOutput.(bool), "Activity should not have errored")

	// Check JSON Schema output
	jsonSchemaOutput := tc.GetOutput(ovJSONSchemaString)
	assert.NotEmpty(t, jsonSchemaOutput, "JSON Schema output should not be empty")

	// Verify JSON Schema is valid JSON
	var jsonSchema interface{}
	err = json.Unmarshal([]byte(jsonSchemaOutput.(string)), &jsonSchema)
	assert.NoError(t, err, "JSON Schema output should be valid JSON")

	// Check Avro Schema output
	avroSchemaOutput := tc.GetOutput(ovAvroSchemaString)
	assert.NotEmpty(t, avroSchemaOutput, "Avro Schema output should not be empty")

	// Verify Avro Schema is valid JSON
	var avroSchema interface{}
	err = json.Unmarshal([]byte(avroSchemaOutput.(string)), &avroSchema)
	assert.NoError(t, err, "Avro Schema output should be valid JSON")

	// Check validation result
	validationResult := tc.GetOutput(ovValidationResult)
	assert.NotEmpty(t, validationResult, "Validation result should not be empty")

	// Check conversion stats
	conversionStats := tc.GetOutput(ovConversionStats)
	assert.NotEmpty(t, conversionStats, "Conversion stats should not be empty")
}

func TestXSDSchemaTransformActivity_JSONSchemaOnly(t *testing.T) {
	// Create activity instance
	act := &Activity{}
	tc := test.NewActivityContext(act.Metadata())

	// Simple XSD schema
	xsdSchema := `<?xml version="1.0" encoding="UTF-8"?>
<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
    <xs:element name="message" type="xs:string"/>
</xs:schema>`

	// Set inputs for JSON Schema only
	tc.SetInput(ivXSDString, xsdSchema)
	tc.SetInput(ivOutputFormat, "jsonschema")
	tc.SetInput(ivJSONSchemaVersion, "draft-07")

	// Execute activity
	done, err := act.Eval(tc)

	// Assertions
	assert.True(t, done)
	assert.NoError(t, err)
	assert.False(t, tc.GetOutput(ovError).(bool))

	// JSON Schema should be generated
	jsonSchemaOutput := tc.GetOutput(ovJSONSchemaString)
	assert.NotEmpty(t, jsonSchemaOutput)

	// Avro Schema should be empty
	avroSchemaOutput := tc.GetOutput(ovAvroSchemaString)
	assert.Empty(t, avroSchemaOutput)
}

func TestXSDSchemaTransformActivity_AvroOnly(t *testing.T) {
	// Create activity instance
	act := &Activity{}
	tc := test.NewActivityContext(act.Metadata())

	// Simple XSD schema
	xsdSchema := `<?xml version="1.0" encoding="UTF-8"?>
<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
    <xs:element name="count" type="xs:int"/>
</xs:schema>`

	// Set inputs for Avro only
	tc.SetInput(ivXSDString, xsdSchema)
	tc.SetInput(ivOutputFormat, "avro")
	tc.SetInput(ivAvroLogicalTypes, true)

	// Execute activity
	done, err := act.Eval(tc)

	// Assertions
	assert.True(t, done)
	assert.NoError(t, err)
	assert.False(t, tc.GetOutput(ovError).(bool))

	// JSON Schema should be empty
	jsonSchemaOutput := tc.GetOutput(ovJSONSchemaString)
	assert.Empty(t, jsonSchemaOutput)

	// Avro Schema should be generated
	avroSchemaOutput := tc.GetOutput(ovAvroSchemaString)
	assert.NotEmpty(t, avroSchemaOutput)
}

func TestXSDSchemaTransformActivity_InvalidXSD(t *testing.T) {
	// Create activity instance
	act := &Activity{}
	tc := test.NewActivityContext(act.Metadata())

	// Invalid XSD schema
	xsdSchema := `<invalid-xml>`

	// Set inputs
	tc.SetInput(ivXSDString, xsdSchema)
	tc.SetInput(ivOutputFormat, "both")

	// Execute activity
	done, err := act.Eval(tc)

	// Assertions
	assert.True(t, done)
	assert.NoError(t, err) // Activity should handle errors gracefully

	// Should have error in output
	errorOutput := tc.GetOutput(ovError)
	assert.True(t, errorOutput.(bool), "Activity should have errored")

	// Error message should be present
	errorMessage := tc.GetOutput(ovErrorMessage)
	assert.NotEmpty(t, errorMessage, "Error message should be present")
}

func TestXSDSchemaTransformActivity_EmptyXSD(t *testing.T) {
	// Create activity instance
	act := &Activity{}
	tc := test.NewActivityContext(act.Metadata())

	// Set empty XSD
	tc.SetInput(ivXSDString, "")
	tc.SetInput(ivOutputFormat, "both")

	// Execute activity
	done, err := act.Eval(tc)

	// Assertions
	assert.True(t, done)
	assert.NoError(t, err)

	// Should have error in output due to empty input
	errorOutput := tc.GetOutput(ovError)
	assert.True(t, errorOutput.(bool), "Activity should have errored with empty XSD")
}
