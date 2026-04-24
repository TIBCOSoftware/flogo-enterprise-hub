package avroschematransform

import (
	"bytes"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"strconv"
	"strings"

	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/data/coerce"
)

// Constants for identifying inputs and outputs
const (
	ivAvroSchemaString = "avroSchemaString"
	ivOutputFormat     = "outputFormat"    // "json", "xsd", or "both"
	ivRootElementName  = "rootElementName" // For XSD generation
	ivTargetNamespace  = "targetNamespace" // For XSD generation
	ovJsonSchema       = "jsonSchema"
	ovXsdString        = "xsdString"
	ovError            = "error"
	ovErrorMessage     = "errorMessage"
)

// Activity is the structure for the Avro schema transformation activity
type Activity struct{}

// Ensure the Flogo framework can discover and register this activity
func init() {
	_ = activity.Register(&Activity{}, New)
}

// Metadata returns the activity's metadata.
func (a *Activity) Metadata() *activity.Metadata {
	return activity.ToMetadata(&Input{}, &Output{})
}

// New creates a new instance of the Activity.
func New(ctx activity.InitContext) (activity.Activity, error) {
	ctx.Logger().Debugf("Creating New Avro Schema Transformer Activity")
	return &Activity{}, nil
}

// Eval executes the main logic of the Activity.
func (a *Activity) Eval(ctx activity.Context) (done bool, err error) {
	logger := ctx.Logger()
	logger.Debugf("Executing Avro Schema Transformer Eval")

	// --- 1. Get All Inputs ---
	input, err := coerceAndValidateInputs(ctx)
	if err != nil {
		setErrorOutputs(ctx, err.Error(), "INVALID_INPUT")
		return true, nil
	}

	// --- 2. Parse Avro Schema ---
	logger.Debug("Parsing Avro Schema")
	var avroSchema map[string]interface{}
	if err := json.Unmarshal([]byte(input.AvroSchemaString), &avroSchema); err != nil {
		logger.Errorf("Failed to parse Avro Schema: %v", err)
		setErrorOutputs(ctx, fmt.Sprintf("Invalid Avro Schema provided: %v", err), "SCHEMA_PARSE_ERROR")
		return true, nil
	}

	// --- 3. Perform Transformations Based on Output Format ---
	outputFormat := strings.ToLower(input.OutputFormat)

	var jsonSchemaString, xsdString string

	if outputFormat == "json" || outputFormat == "both" {
		logger.Debug("Converting Avro Schema to JSON Schema")
		jsonSchemaString, err = avroToJSONSchema(avroSchema)
		if err != nil {
			logger.Errorf("Failed to convert to JSON Schema: %v", err)
			setErrorOutputs(ctx, fmt.Sprintf("Could not convert to JSON Schema: %v", err), "JSON_CONVERSION_ERROR")
			return true, nil
		}
	}

	if outputFormat == "xsd" || outputFormat == "both" {
		logger.Debug("Converting Avro Schema to XSD")
		xsdString, err = avroToXSD(avroSchema, input.RootElementName, input.TargetNamespace)
		if err != nil {
			logger.Errorf("Failed to convert to XSD: %v", err)
			setErrorOutputs(ctx, fmt.Sprintf("Could not convert to XSD: %v", err), "XSD_CONVERSION_ERROR")
			return true, nil
		}
	}

	// --- 4. Set Success Outputs ---
	logger.Info("Successfully transformed Avro Schema")
	ctx.SetOutput(ovJsonSchema, jsonSchemaString)
	ctx.SetOutput(ovXsdString, xsdString)
	ctx.SetOutput(ovError, false)
	ctx.SetOutput(ovErrorMessage, "")

	return true, nil
}

// coerceAndValidateInputs reads all inputs from the context and validates them.
func coerceAndValidateInputs(ctx activity.Context) (*Input, error) {
	input := &Input{}
	var err error

	input.AvroSchemaString, err = coerce.ToString(ctx.GetInput(ivAvroSchemaString))
	if err != nil || strings.TrimSpace(input.AvroSchemaString) == "" {
		return nil, fmt.Errorf("input 'avroSchemaString' is required and cannot be empty")
	}

	// Get output format - Flogo will automatically use settings as fallback
	input.OutputFormat, err = coerce.ToString(ctx.GetInput(ivOutputFormat))
	if err != nil || strings.TrimSpace(input.OutputFormat) == "" {
		input.OutputFormat = "both" // Default to both formats if not provided
	}

	// Validate and normalize output format
	outputFormat := strings.ToLower(input.OutputFormat)
	if outputFormat != "json" && outputFormat != "xsd" && outputFormat != "both" {
		return nil, fmt.Errorf("invalid outputFormat: must be 'json', 'xsd', or 'both'")
	}
	input.OutputFormat = outputFormat

	// Only process XML-related fields if needed for XSD generation
	if outputFormat == "xsd" || outputFormat == "both" {
		// Get root element name - Flogo will use settings as fallback
		input.RootElementName, err = coerce.ToString(ctx.GetInput(ivRootElementName))
		if err != nil || strings.TrimSpace(input.RootElementName) == "" {
			input.RootElementName = "root" // Default root element name
		}

		// Get target namespace - optional field
		input.TargetNamespace, _ = coerce.ToString(ctx.GetInput(ivTargetNamespace))
	} else {
		// Clear XML-related fields when not needed for JSON-only output
		input.RootElementName = ""
		input.TargetNamespace = ""
	}

	return input, nil
}

// avroToJSONSchema converts an Avro schema to JSON Schema
func avroToJSONSchema(avroSchema map[string]interface{}) (string, error) {
	jsonSchema := make(map[string]interface{})
	jsonSchema["$schema"] = "https://json-schema.org/draft/2020-12/schema"

	// Convert the Avro schema
	converted, err := convertAvroTypeToJSONSchema(avroSchema)
	if err != nil {
		return "", err
	}

	// Merge the converted schema properties
	for k, v := range converted {
		jsonSchema[k] = v
	}

	jsonBytes, err := json.MarshalIndent(jsonSchema, "", "  ")
	if err != nil {
		return "", fmt.Errorf("failed to marshal JSON schema: %v", err)
	}

	return string(jsonBytes), nil
}

// convertAvroTypeToJSONSchema converts Avro types to JSON Schema types
func convertAvroTypeToJSONSchema(avroType interface{}) (map[string]interface{}, error) {
	result := make(map[string]interface{})

	switch t := avroType.(type) {
	case string:
		// Simple types
		switch t {
		case "null":
			result["type"] = "null"
		case "boolean":
			result["type"] = "boolean"
		case "int", "long":
			result["type"] = "integer"
		case "float", "double":
			result["type"] = "number"
		case "bytes", "string":
			result["type"] = "string"
		default:
			return nil, fmt.Errorf("unsupported Avro type: %s", t)
		}
	case map[string]interface{}:
		avroTypeStr, ok := t["type"].(string)
		if !ok {
			return nil, fmt.Errorf("missing or invalid 'type' field in Avro schema")
		}

		switch avroTypeStr {
		case "record":
			result["type"] = "object"
			properties := make(map[string]interface{})
			required := []string{}

			if fields, ok := t["fields"].([]interface{}); ok {
				for _, field := range fields {
					if fieldMap, ok := field.(map[string]interface{}); ok {
						fieldName, _ := fieldMap["name"].(string)
						fieldType := fieldMap["type"]

						fieldSchema, err := convertAvroTypeToJSONSchema(fieldType)
						if err != nil {
							return nil, err
						}
						properties[fieldName] = fieldSchema

						// Check if field has default value (if not, it's required)
						if _, hasDefault := fieldMap["default"]; !hasDefault {
							// Check if it's a union with null (optional field)
							if !isOptionalUnion(fieldType) {
								required = append(required, fieldName)
							}
						}
					}
				}
			}
			result["properties"] = properties
			if len(required) > 0 {
				result["required"] = required
			}

		case "array":
			result["type"] = "array"
			if items := t["items"]; items != nil {
				itemSchema, err := convertAvroTypeToJSONSchema(items)
				if err != nil {
					return nil, err
				}
				result["items"] = itemSchema
			}

		case "map":
			result["type"] = "object"
			if values := t["values"]; values != nil {
				valueSchema, err := convertAvroTypeToJSONSchema(values)
				if err != nil {
					return nil, err
				}
				result["additionalProperties"] = valueSchema
			}

		case "enum":
			result["type"] = "string"
			if symbols, ok := t["symbols"].([]interface{}); ok {
				enumValues := make([]string, len(symbols))
				for i, symbol := range symbols {
					enumValues[i] = fmt.Sprintf("%v", symbol)
				}
				result["enum"] = enumValues
			}

		case "fixed":
			result["type"] = "string"
			if size, ok := t["size"]; ok {
				if sizeInt, err := coerce.ToInt(size); err == nil {
					result["maxLength"] = sizeInt
					result["minLength"] = sizeInt
				}
			}

		default:
			return nil, fmt.Errorf("unsupported Avro record type: %s", avroTypeStr)
		}

	case []interface{}:
		// Union type
		if len(t) == 2 && containsNull(t) {
			// Optional field (union with null)
			for _, unionType := range t {
				if unionType != "null" {
					return convertAvroTypeToJSONSchema(unionType)
				}
			}
		} else {
			// Multiple types union - use anyOf
			anyOf := make([]map[string]interface{}, 0)
			for _, unionType := range t {
				typeSchema, err := convertAvroTypeToJSONSchema(unionType)
				if err != nil {
					return nil, err
				}
				anyOf = append(anyOf, typeSchema)
			}
			result["anyOf"] = anyOf
		}

	default:
		return nil, fmt.Errorf("unsupported Avro type format: %T", avroType)
	}

	return result, nil
}

// isOptionalUnion checks if a type is a union with null (optional field)
func isOptionalUnion(avroType interface{}) bool {
	if union, ok := avroType.([]interface{}); ok {
		return len(union) == 2 && containsNull(union)
	}
	return false
}

// containsNull checks if a union contains null type
func containsNull(union []interface{}) bool {
	for _, t := range union {
		if t == "null" {
			return true
		}
	}
	return false
}

// avroToXSD converts an Avro schema to XSD
func avroToXSD(avroSchema map[string]interface{}, rootElementName, targetNamespace string) (string, error) {
	rootElement, err := avroToXSDElement(rootElementName, avroSchema, true)
	if err != nil {
		return "", err
	}

	xsd := XSDSchema{
		ElementFormDefault: "qualified",
		TargetNamespace:    targetNamespace,
		XmlnsXs:            "http://www.w3.org/2001/XMLSchema",
		Elements:           []XSDElement{*rootElement},
	}

	var buf bytes.Buffer
	buf.WriteString(xml.Header)
	encoder := xml.NewEncoder(&buf)
	encoder.Indent("", "  ")
	if err := encoder.Encode(xsd); err != nil {
		return "", err
	}

	return buf.String(), nil
}

// avroToXSDElement converts Avro types to XSD elements
func avroToXSDElement(name string, avroType interface{}, _ bool) (*XSDElement, error) {
	element := &XSDElement{Name: name}

	switch t := avroType.(type) {
	case string:
		// Simple types
		switch t {
		case "null":
			element.Type = "xs:string"
			element.MinOccurs = "0"
		case "boolean":
			element.Type = "xs:boolean"
		case "int", "long":
			element.Type = "xs:integer"
		case "float", "double":
			element.Type = "xs:decimal"
		case "bytes":
			element.Type = "xs:base64Binary"
		case "string":
			element.Type = "xs:string"
		default:
			return nil, fmt.Errorf("unsupported Avro type: %s", t)
		}

	case map[string]interface{}:
		avroTypeStr, ok := t["type"].(string)
		if !ok {
			return nil, fmt.Errorf("missing or invalid 'type' field in Avro schema")
		}

		switch avroTypeStr {
		case "record":
			var childElements []XSDElement
			if fields, ok := t["fields"].([]interface{}); ok {
				for _, field := range fields {
					if fieldMap, ok := field.(map[string]interface{}); ok {
						fieldName, _ := fieldMap["name"].(string)
						fieldType := fieldMap["type"]

						child, err := avroToXSDElement(fieldName, fieldType, false)
						if err != nil {
							return nil, err
						}

						// Check if field has default value or is optional union
						if _, hasDefault := fieldMap["default"]; hasDefault || isOptionalUnion(fieldType) {
							child.MinOccurs = "0"
						}

						childElements = append(childElements, *child)
					}
				}
			}
			element.ComplexType = &XSDComplexType{
				Sequence: &XSDSequence{
					Elements: childElements,
				},
			}

		case "array":
			element.MaxOccurs = "unbounded"
			if items := t["items"]; items != nil {
				itemElement, err := avroToXSDElement(name, items, false)
				if err != nil {
					return nil, err
				}
				element.Type = itemElement.Type
				element.ComplexType = itemElement.ComplexType
			}

		case "map":
			// Maps are complex to represent in XSD, simplify as any type
			element.Type = "xs:anyType"

		case "enum":
			element.Type = "xs:string"
			// XSD doesn't have direct enum support in basic schema, would need restrictions

		case "fixed":
			element.Type = "xs:string"
			if size, ok := t["size"]; ok {
				// XSD restrictions would be needed for exact length
				_ = size // For now, just treat as string
			}

		default:
			return nil, fmt.Errorf("unsupported Avro record type: %s", avroTypeStr)
		}

	case []interface{}:
		// Union type
		if len(t) == 2 && containsNull(t) {
			// Optional field (union with null)
			element.MinOccurs = "0"
			for _, unionType := range t {
				if unionType != "null" {
					nonNullElement, err := avroToXSDElement(name, unionType, false)
					if err != nil {
						return nil, err
					}
					element.Type = nonNullElement.Type
					element.ComplexType = nonNullElement.ComplexType
					break
				}
			}
		} else {
			// Complex union - use xs:choice for multiple types
			var choiceElements []XSDElement
			for i, unionType := range t {
				choiceName := name + "_choice" + strconv.Itoa(i)
				choice, err := avroToXSDElement(choiceName, unionType, false)
				if err != nil {
					return nil, err
				}
				choiceElements = append(choiceElements, *choice)
			}
			element.ComplexType = &XSDComplexType{
				Choice: &XSDChoice{
					Elements: choiceElements,
				},
			}
		}

	default:
		return nil, fmt.Errorf("unsupported Avro type format: %T", avroType)
	}

	return element, nil
}

// setErrorOutputs is a helper function to set all error-related outputs at once.
func setErrorOutputs(ctx activity.Context, message, code string) {
	ctx.SetOutput(ovJsonSchema, "")
	ctx.SetOutput(ovXsdString, "")
	ctx.SetOutput(ovError, true)
	ctx.SetOutput(ovErrorMessage, fmt.Sprintf("[%s] %s", code, message))
}

// --- Supporting Structs ---

// Input struct holds all dynamic inputs
type Input struct {
	AvroSchemaString string `md:"avroSchemaString,required"`
	OutputFormat     string `md:"outputFormat"`
	RootElementName  string `md:"rootElementName"`
	TargetNamespace  string `md:"targetNamespace"`
}

// Output struct for the transformation results
type Output struct {
	JsonSchema   string `md:"jsonSchema"`
	XsdString    string `md:"xsdString"`
	Error        bool   `md:"error"`
	ErrorMessage string `md:"errorMessage"`
}

// --- XSD Generation Supporting Structs ---

// XSDElement represents an <xs:element>
type XSDElement struct {
	XMLName     xml.Name        `xml:"xs:element"`
	Name        string          `xml:"name,attr"`
	Type        string          `xml:"type,attr,omitempty"`
	MinOccurs   string          `xml:"minOccurs,attr,omitempty"`
	MaxOccurs   string          `xml:"maxOccurs,attr,omitempty"`
	ComplexType *XSDComplexType `xml:",omitempty"`
}

// XSDSequence represents an <xs:sequence>
type XSDSequence struct {
	XMLName  xml.Name     `xml:"xs:sequence"`
	Elements []XSDElement `xml:"xs:element"`
}

// XSDChoice represents an <xs:choice>
type XSDChoice struct {
	XMLName  xml.Name     `xml:"xs:choice"`
	Elements []XSDElement `xml:"xs:element"`
}

// XSDComplexType represents an <xs:complexType>
type XSDComplexType struct {
	XMLName  xml.Name     `xml:"xs:complexType"`
	Sequence *XSDSequence `xml:",omitempty"`
	Choice   *XSDChoice   `xml:",omitempty"`
}

// XSDSchema represents the root <xs:schema> element
type XSDSchema struct {
	XMLName            xml.Name     `xml:"xs:schema"`
	ElementFormDefault string       `xml:"elementFormDefault,attr"`
	TargetNamespace    string       `xml:"targetNamespace,attr,omitempty"`
	XmlnsXs            string       `xml:"xmlns:xs,attr"`
	Elements           []XSDElement `xml:"xs:element"`
}
