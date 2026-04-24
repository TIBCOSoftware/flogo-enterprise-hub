package jsonschematransform

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
	ivJSONSchemaString = "jsonSchemaString"
	ivOutputFormat     = "outputFormat"    // "xsd", "avro", or "both"
	ivRootElementName  = "rootElementName" // For XSD generation
	ivTargetNamespace  = "targetNamespace" // For XSD generation
	ivAvroRecordName   = "avroRecordName"  // For Avro generation
	ivAvroNamespace    = "avroNamespace"   // For Avro generation
	ovXSDString        = "xsdString"
	ovAvroSchema       = "avroSchema"
	ovError            = "error"
	ovErrorMessage     = "errorMessage"
)

// Activity is the structure for the JSON Schema transformation activity
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
	ctx.Logger().Debugf("Creating New JSON Schema Transformer Activity")
	return &Activity{}, nil
}

// Eval executes the main logic of the Activity.
func (a *Activity) Eval(ctx activity.Context) (done bool, err error) {
	logger := ctx.Logger()
	logger.Debugf("Executing JSON Schema Transformer Eval")

	// --- 1. Get All Inputs ---
	input, err := coerceAndValidateInputs(ctx)
	if err != nil {
		setErrorOutputs(ctx, err.Error(), "INVALID_INPUT")
		return true, nil
	}

	// --- 2. Parse JSON Schema ---
	logger.Debug("Parsing JSON Schema")
	var jsonSchema JSONSchema
	if err := json.Unmarshal([]byte(input.JSONSchemaString), &jsonSchema); err != nil {
		logger.Errorf("Failed to parse JSON Schema: %v", err)
		setErrorOutputs(ctx, fmt.Sprintf("Invalid JSON Schema provided: %v", err), "SCHEMA_PARSE_ERROR")
		return true, nil
	}

	// --- 3. Perform Transformations Based on Output Format ---
	outputFormat := strings.ToLower(input.OutputFormat)

	var xsdString, avroSchemaString string

	if outputFormat == "xsd" || outputFormat == "both" {
		logger.Debug("Converting JSON Schema to XSD")
		xsdString, err = jsonSchemaToXSD(&jsonSchema, input.RootElementName, input.TargetNamespace)
		if err != nil {
			logger.Errorf("Failed to convert to XSD: %v", err)
			setErrorOutputs(ctx, fmt.Sprintf("Could not convert to XSD: %v", err), "XSD_CONVERSION_ERROR")
			return true, nil
		}
	}

	if outputFormat == "avro" || outputFormat == "both" {
		logger.Debug("Converting JSON Schema to Avro")
		avroSchemaString, err = jsonSchemaToAvro(&jsonSchema, input.AvroRecordName, input.AvroNamespace)
		if err != nil {
			logger.Errorf("Failed to convert to Avro: %v", err)
			setErrorOutputs(ctx, fmt.Sprintf("Could not convert to Avro: %v", err), "AVRO_CONVERSION_ERROR")
			return true, nil
		}
	}

	// --- 4. Set Success Outputs ---
	logger.Info("Successfully transformed JSON Schema")
	ctx.SetOutput(ovXSDString, xsdString)
	ctx.SetOutput(ovAvroSchema, avroSchemaString)
	ctx.SetOutput(ovError, false)
	ctx.SetOutput(ovErrorMessage, "")

	return true, nil
}

// coerceAndValidateInputs reads all inputs from the context and validates them.
func coerceAndValidateInputs(ctx activity.Context) (*Input, error) {
	input := &Input{}
	var err error

	input.JSONSchemaString, err = coerce.ToString(ctx.GetInput(ivJSONSchemaString))
	if err != nil || strings.TrimSpace(input.JSONSchemaString) == "" {
		return nil, fmt.Errorf("input 'jsonSchemaString' is required and cannot be empty")
	}

	// Get output format with default fallback
	input.OutputFormat, err = coerce.ToString(ctx.GetInput(ivOutputFormat))
	if err != nil || strings.TrimSpace(input.OutputFormat) == "" {
		input.OutputFormat = "both" // Default output format
	}

	// Validate output format
	outputFormat := strings.ToLower(input.OutputFormat)
	if outputFormat != "xsd" && outputFormat != "avro" && outputFormat != "both" {
		return nil, fmt.Errorf("invalid outputFormat '%s'. Must be 'xsd', 'avro', or 'both'", input.OutputFormat)
	}

	// Process XSD-related inputs only when needed
	if outputFormat == "xsd" || outputFormat == "both" {
		input.RootElementName, err = coerce.ToString(ctx.GetInput(ivRootElementName))
		if err != nil || strings.TrimSpace(input.RootElementName) == "" {
			input.RootElementName = "RootElement" // Default root element name
		}

		input.TargetNamespace, _ = coerce.ToString(ctx.GetInput(ivTargetNamespace))
		// TargetNamespace can be empty - that's valid
	}

	// Process Avro-related inputs only when needed
	if outputFormat == "avro" || outputFormat == "both" {
		input.AvroRecordName, err = coerce.ToString(ctx.GetInput(ivAvroRecordName))
		if err != nil || strings.TrimSpace(input.AvroRecordName) == "" {
			input.AvroRecordName = "RootRecord" // Default record name
		}

		input.AvroNamespace, err = coerce.ToString(ctx.GetInput(ivAvroNamespace))
		if err != nil || strings.TrimSpace(input.AvroNamespace) == "" {
			input.AvroNamespace = "com.example" // Default namespace
		}
	}

	return input, nil
}

// --- JSON Schema Types ---

// JSONSchema represents a JSON Schema document with comprehensive support
type JSONSchema struct {
	Type                 string                 `json:"type"`
	Properties           map[string]*JSONSchema `json:"properties"`
	Items                *JSONSchema            `json:"items"`
	Required             []string               `json:"required"`
	Enum                 []interface{}          `json:"enum"`
	AnyOf                []*JSONSchema          `json:"anyOf"`
	OneOf                []*JSONSchema          `json:"oneOf"`
	AllOf                []*JSONSchema          `json:"allOf"`
	Pattern              string                 `json:"pattern"`
	MinLength            *int                   `json:"minLength"`
	MaxLength            *int                   `json:"maxLength"`
	Minimum              *float64               `json:"minimum"`
	Maximum              *float64               `json:"maximum"`
	ExclusiveMinimum     *float64               `json:"exclusiveMinimum"`
	ExclusiveMaximum     *float64               `json:"exclusiveMaximum"`
	MinItems             *int                   `json:"minItems"`
	MaxItems             *int                   `json:"maxItems"`
	Format               string                 `json:"format"`
	Title                string                 `json:"title"`
	Description          string                 `json:"description"`
	Ref                  string                 `json:"$ref"`
	Definitions          map[string]*JSONSchema `json:"definitions"`
	Defs                 map[string]*JSONSchema `json:"$defs"`
	If                   *JSONSchema            `json:"if"`
	Then                 *JSONSchema            `json:"then"`
	Else                 *JSONSchema            `json:"else"`
	Const                interface{}            `json:"const"`
	ID                   string                 `json:"$id"`
	Schema               string                 `json:"$schema"`
	Comment              string                 `json:"$comment"`
	Examples             []interface{}          `json:"examples"`
	Default              interface{}            `json:"default"`
	ReadOnly             bool                   `json:"readOnly"`
	WriteOnly            bool                   `json:"writeOnly"`
	Deprecated           bool                   `json:"deprecated"`
	ContentEncoding      string                 `json:"contentEncoding"`
	ContentMediaType     string                 `json:"contentMediaType"`
	Dependencies         map[string]interface{} `json:"dependencies"`
	MultipleOf           *float64               `json:"multipleOf"`
	Not                  *JSONSchema            `json:"not"`
	AdditionalProperties interface{}            `json:"additionalProperties"`
	PatternProperties    map[string]*JSONSchema `json:"patternProperties"`
	UniqueItems          *bool                  `json:"uniqueItems"`
	MinProperties        *int                   `json:"minProperties"`
	MaxProperties        *int                   `json:"maxProperties"`
	Contains             *JSONSchema            `json:"contains"`
	MinContains          *int                   `json:"minContains"`
	MaxContains          *int                   `json:"maxContains"`
	PropertyNames        *JSONSchema            `json:"propertyNames"`
	DependentRequired    map[string][]string    `json:"dependentRequired"`
	DependentSchemas     map[string]*JSONSchema `json:"dependentSchemas"`
}

// --- XSD Generation Types (Reusing from jsonschematoxsd) ---

// XSDElement represents an <xs:element>
type XSDElement struct {
	XMLName     xml.Name        `xml:"xs:element"`
	Name        string          `xml:"name,attr"`
	Type        string          `xml:"type,attr,omitempty"`
	MinOccurs   string          `xml:"minOccurs,attr,omitempty"`
	MaxOccurs   string          `xml:"maxOccurs,attr,omitempty"`
	Nillable    string          `xml:"nillable,attr,omitempty"`
	ComplexType *XSDComplexType `xml:",omitempty"`
	SimpleType  *XSDSimpleType  `xml:",omitempty"`
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

// XSDSimpleType represents an <xs:simpleType> with restrictions
type XSDSimpleType struct {
	XMLName     xml.Name        `xml:"xs:simpleType"`
	Restriction *XSDRestriction `xml:"xs:restriction,omitempty"`
}

// XSDRestriction represents XSD restrictions (xs:restriction element)
type XSDRestriction struct {
	XMLName      xml.Name         `xml:"xs:restriction"`
	Base         string           `xml:"base,attr"`
	Pattern      *XSDPattern      `xml:"xs:pattern,omitempty"`
	MinLength    *XSDFacet        `xml:"xs:minLength,omitempty"`
	MaxLength    *XSDFacet        `xml:"xs:maxLength,omitempty"`
	MinInclusive *XSDFacet        `xml:"xs:minInclusive,omitempty"`
	MaxInclusive *XSDFacet        `xml:"xs:maxInclusive,omitempty"`
	MinExclusive *XSDFacet        `xml:"xs:minExclusive,omitempty"`
	MaxExclusive *XSDFacet        `xml:"xs:maxExclusive,omitempty"`
	Enumerations []XSDEnumeration `xml:"xs:enumeration,omitempty"`
}

// XSDPattern represents xs:pattern facet
type XSDPattern struct {
	XMLName xml.Name `xml:"xs:pattern"`
	Value   string   `xml:"value,attr"`
}

// XSDEnumeration represents xs:enumeration facet
type XSDEnumeration struct {
	XMLName xml.Name `xml:"xs:enumeration"`
	Value   string   `xml:"value,attr"`
}

// XSDFacet represents generic XSD facets with a value attribute
type XSDFacet struct {
	Value string `xml:"value,attr"`
}

// XSDSchema represents the root <xs:schema> element
type XSDSchema struct {
	XMLName            xml.Name            `xml:"xs:schema"`
	ElementFormDefault string              `xml:"elementFormDefault,attr"`
	TargetNamespace    string              `xml:"targetNamespace,attr,omitempty"`
	XmlnsXs            string              `xml:"xmlns:xs,attr"`
	XmlnsXsi           string              `xml:"xmlns:xsi,attr,omitempty"`
	Elements           []XSDElement        `xml:"xs:element"`
	ComplexTypes       []XSDComplexTypeDef `xml:"xs:complexType,omitempty"`
}

// XSDComplexTypeDef represents named complex type definitions
type XSDComplexTypeDef struct {
	XMLName  xml.Name     `xml:"xs:complexType"`
	Name     string       `xml:"name,attr"`
	Sequence *XSDSequence `xml:",omitempty"`
	Choice   *XSDChoice   `xml:",omitempty"`
}

// --- Avro Generation Types ---

// AvroSchema represents an Avro schema
type AvroSchema struct {
	Type      interface{} `json:"type"`
	Name      string      `json:"name,omitempty"`
	Namespace string      `json:"namespace,omitempty"`
	Doc       string      `json:"doc,omitempty"`
	Fields    []AvroField `json:"fields,omitempty"`
	Items     interface{} `json:"items,omitempty"`
	Values    interface{} `json:"values,omitempty"`
	Symbols   []string    `json:"symbols,omitempty"`
	Default   interface{} `json:"default,omitempty"`
}

// AvroField represents a field in an Avro record
type AvroField struct {
	Name    string      `json:"name"`
	Type    interface{} `json:"type"`
	Doc     string      `json:"doc,omitempty"`
	Default interface{} `json:"default,omitempty"`
}

// --- Input/Output Structs ---

// Input struct holds all dynamic inputs
type Input struct {
	JSONSchemaString string `md:"jsonSchemaString,required"`
	OutputFormat     string `md:"outputFormat"`
	RootElementName  string `md:"rootElementName"` // For XSD generation
	TargetNamespace  string `md:"targetNamespace"` // For XSD generation
	AvroRecordName   string `md:"avroRecordName"`  // For Avro generation
	AvroNamespace    string `md:"avroNamespace"`   // For Avro generation
}

// Output struct for the transformation results
type Output struct {
	XSDString    string `md:"xsdString"`
	AvroSchema   string `md:"avroSchema"`
	Error        bool   `md:"error"`
	ErrorMessage string `md:"errorMessage"`
}

// --- XSD Conversion Logic ---

// jsonSchemaToXSD converts a JSON Schema to XSD string
func jsonSchemaToXSD(jsonSchema *JSONSchema, rootElementName, targetNamespace string) (string, error) {
	var rootElement *XSDElement
	var err error

	// Handle different root schema types
	switch jsonSchema.Type {
	case "object":
		rootElement, err = jsonSchemaToXSDElement(rootElementName, jsonSchema, jsonSchema.Required, true)
	case "array":
		rootElement, err = handleArrayRootSchema(rootElementName, jsonSchema)
	case "":
		// Handle schemas without explicit type but with union constructs
		if len(jsonSchema.AnyOf) > 0 || len(jsonSchema.OneOf) > 0 || len(jsonSchema.AllOf) > 0 {
			rootElement, err = jsonSchemaToXSDElement(rootElementName, jsonSchema, nil, true)
		} else {
			return "", fmt.Errorf("root schema must have a type or union construct")
		}
	default:
		// Handle primitive root schemas (string, integer, number, boolean)
		rootElement, err = handlePrimitiveRootSchema(rootElementName, jsonSchema)
	}

	if err != nil {
		return "", err
	}

	// Create XSD schema
	xsd := XSDSchema{
		ElementFormDefault: "qualified",
		TargetNamespace:    targetNamespace,
		XmlnsXs:            "http://www.w3.org/2001/XMLSchema",
		XmlnsXsi:           "http://www.w3.org/2001/XMLSchema-instance",
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

// jsonSchemaToXSDElement recursively converts a JSON schema property to an XSD element
func jsonSchemaToXSDElement(name string, schema *JSONSchema, requiredProps []string, isRoot bool) (*XSDElement, error) {
	element := &XSDElement{Name: name}

	// Handle optional elements
	if !isRoot {
		isOptional := true
		for _, req := range requiredProps {
			if req == name {
				isOptional = false
				break
			}
		}

		if isNullableSchema(schema) {
			element.Nillable = "true"
			if isOptional {
				element.MinOccurs = "0"
			}
		} else if isOptional {
			element.MinOccurs = "0"
		}
	}

	// Handle union types first
	if len(schema.AnyOf) > 0 {
		return handleUnionType(element, schema.AnyOf, name)
	}
	if len(schema.OneOf) > 0 {
		return handleUnionType(element, schema.OneOf, name)
	}
	if len(schema.AllOf) > 0 {
		return handleAllOfType(element, schema.AllOf)
	}

	// Handle const values
	if schema.Const != nil {
		return handleConstValue(element, schema.Const)
	}

	switch schema.Type {
	case "object":
		var childElements []XSDElement
		for propName, propSchema := range schema.Properties {
			child, err := jsonSchemaToXSDElement(propName, propSchema, schema.Required, false)
			if err != nil {
				return nil, err
			}
			childElements = append(childElements, *child)
		}
		element.ComplexType = &XSDComplexType{
			Sequence: &XSDSequence{
				Elements: childElements,
			},
		}

	case "array":
		element.MaxOccurs = "unbounded"
		if schema.Items == nil {
			return nil, fmt.Errorf("array '%s' must have an 'items' definition", name)
		}
		itemElement, err := jsonSchemaToXSDElement(name, schema.Items, nil, false)
		if err != nil {
			return nil, err
		}
		element.Type = itemElement.Type
		element.ComplexType = itemElement.ComplexType

		// Apply array constraints
		applyArrayConstraints(element, schema)

	case "string":
		element.Type = mapStringType(schema)
		applyStringConstraints(element, schema)
	case "number":
		element.Type = "xs:decimal"
		applyNumericConstraints(element, schema)
	case "integer":
		element.Type = "xs:integer"
		applyNumericConstraints(element, schema)
	case "boolean":
		element.Type = "xs:boolean"
	case "null":
		element.Type = "xs:string"
		element.Nillable = "true"
	default:
		if schema.Type == "" && len(schema.Enum) > 0 {
			element.Type = "xs:string"
			applyStringConstraints(element, schema)
		} else {
			return nil, fmt.Errorf("unsupported schema type: %s", schema.Type)
		}
	}

	return element, nil
}

// Helper functions for XSD conversion (simplified versions)
func isNullableSchema(schema *JSONSchema) bool {
	// Check if schema allows null values
	for _, anyOfSchema := range schema.AnyOf {
		if anyOfSchema.Type == "null" {
			return true
		}
	}
	for _, oneOfSchema := range schema.OneOf {
		if oneOfSchema.Type == "null" {
			return true
		}
	}
	return schema.Type == "null"
}

func handleUnionType(element *XSDElement, schemas []*JSONSchema, name string) (*XSDElement, error) {
	// Simplified union handling - use choice
	var choiceElements []XSDElement
	for i, unionSchema := range schemas {
		if unionSchema.Type == "null" {
			element.Nillable = "true"
			continue
		}
		choiceName := name + "_choice" + strconv.Itoa(i)
		choice, err := jsonSchemaToXSDElement(choiceName, unionSchema, nil, false)
		if err != nil {
			return nil, err
		}
		choiceElements = append(choiceElements, *choice)
	}

	if len(choiceElements) == 1 {
		// Single non-null type
		element.Type = choiceElements[0].Type
		element.ComplexType = choiceElements[0].ComplexType
	} else if len(choiceElements) > 1 {
		element.ComplexType = &XSDComplexType{
			Choice: &XSDChoice{
				Elements: choiceElements,
			},
		}
	}

	return element, nil
}

func handleAllOfType(element *XSDElement, schemas []*JSONSchema) (*XSDElement, error) {
	// Simplified allOf handling - merge properties
	mergedSchema := &JSONSchema{
		Type:       "object",
		Properties: make(map[string]*JSONSchema),
		Required:   []string{},
	}

	for _, schema := range schemas {
		if schema.Type == "object" {
			for propName, propSchema := range schema.Properties {
				mergedSchema.Properties[propName] = propSchema
			}
			mergedSchema.Required = append(mergedSchema.Required, schema.Required...)
		}
	}

	return jsonSchemaToXSDElement(element.Name, mergedSchema, mergedSchema.Required, false)
}

func handleConstValue(element *XSDElement, constValue interface{}) (*XSDElement, error) {
	element.Type = "xs:string"
	element.SimpleType = &XSDSimpleType{
		Restriction: &XSDRestriction{
			Base: "xs:string",
			Enumerations: []XSDEnumeration{
				{Value: fmt.Sprintf("%v", constValue)},
			},
		},
	}
	return element, nil
}

func handleArrayRootSchema(rootName string, schema *JSONSchema) (*XSDElement, error) {
	if schema.Items == nil {
		return nil, fmt.Errorf("array root schema must have an 'items' definition")
	}

	element := &XSDElement{
		Name:      rootName,
		MaxOccurs: "unbounded",
	}

	itemElement, err := jsonSchemaToXSDElement(rootName+"Item", schema.Items, nil, false)
	if err != nil {
		return nil, err
	}

	element.Type = itemElement.Type
	element.ComplexType = itemElement.ComplexType
	element.SimpleType = itemElement.SimpleType

	return element, nil
}

func handlePrimitiveRootSchema(rootName string, schema *JSONSchema) (*XSDElement, error) {
	element := &XSDElement{Name: rootName}

	switch schema.Type {
	case "string":
		element.Type = mapStringType(schema)
		applyStringConstraints(element, schema)
	case "number":
		element.Type = "xs:decimal"
		applyNumericConstraints(element, schema)
	case "integer":
		element.Type = "xs:integer"
		applyNumericConstraints(element, schema)
	case "boolean":
		element.Type = "xs:boolean"
	case "null":
		element.Type = "xs:string"
		element.Nillable = "true"
	default:
		return nil, fmt.Errorf("unsupported primitive root schema type: %s", schema.Type)
	}

	if len(schema.Enum) > 0 && element.SimpleType == nil {
		applyEnumConstraints(element, schema)
	}

	return element, nil
}

func mapStringType(schema *JSONSchema) string {
	switch schema.Format {
	case "date":
		return "xs:date"
	case "date-time":
		return "xs:dateTime"
	case "time":
		return "xs:time"
	case "uri":
		return "xs:anyURI"
	case "email":
		return "xs:string" // Will apply pattern constraint
	default:
		return "xs:string"
	}
}

func applyStringConstraints(element *XSDElement, schema *JSONSchema) {
	if schema.Pattern != "" || schema.MinLength != nil || schema.MaxLength != nil || len(schema.Enum) > 0 || schema.Format == "email" {
		restriction := &XSDRestriction{Base: element.Type}

		if schema.Pattern != "" {
			restriction.Pattern = &XSDPattern{Value: schema.Pattern}
		} else if schema.Format == "email" {
			restriction.Pattern = &XSDPattern{Value: "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$"}
		}

		if schema.MinLength != nil {
			restriction.MinLength = &XSDFacet{Value: strconv.Itoa(*schema.MinLength)}
		}

		if schema.MaxLength != nil {
			restriction.MaxLength = &XSDFacet{Value: strconv.Itoa(*schema.MaxLength)}
		}

		if len(schema.Enum) > 0 {
			for _, enumVal := range schema.Enum {
				restriction.Enumerations = append(restriction.Enumerations,
					XSDEnumeration{Value: fmt.Sprintf("%v", enumVal)})
			}
		}

		element.SimpleType = &XSDSimpleType{Restriction: restriction}
		element.Type = ""
	}
}

func applyNumericConstraints(element *XSDElement, schema *JSONSchema) {
	if schema.Minimum != nil || schema.Maximum != nil || schema.ExclusiveMinimum != nil || schema.ExclusiveMaximum != nil {
		restriction := &XSDRestriction{Base: element.Type}

		if schema.Minimum != nil {
			restriction.MinInclusive = &XSDFacet{Value: fmt.Sprintf("%g", *schema.Minimum)}
		}

		if schema.Maximum != nil {
			restriction.MaxInclusive = &XSDFacet{Value: fmt.Sprintf("%g", *schema.Maximum)}
		}

		if schema.ExclusiveMinimum != nil {
			restriction.MinExclusive = &XSDFacet{Value: fmt.Sprintf("%g", *schema.ExclusiveMinimum)}
		}

		if schema.ExclusiveMaximum != nil {
			restriction.MaxExclusive = &XSDFacet{Value: fmt.Sprintf("%g", *schema.ExclusiveMaximum)}
		}

		element.SimpleType = &XSDSimpleType{Restriction: restriction}
		element.Type = ""
	}
}

func applyArrayConstraints(element *XSDElement, schema *JSONSchema) {
	if schema.MinItems != nil {
		if *schema.MinItems == 0 {
			element.MinOccurs = "0"
		} else {
			element.MinOccurs = strconv.Itoa(*schema.MinItems)
		}
	}

	if schema.MaxItems != nil {
		element.MaxOccurs = strconv.Itoa(*schema.MaxItems)
	}
}

func applyEnumConstraints(element *XSDElement, schema *JSONSchema) {
	restriction := &XSDRestriction{Base: element.Type}

	for _, enumVal := range schema.Enum {
		restriction.Enumerations = append(restriction.Enumerations,
			XSDEnumeration{Value: fmt.Sprintf("%v", enumVal)})
	}

	element.SimpleType = &XSDSimpleType{Restriction: restriction}
	element.Type = ""
}

// --- Avro Conversion Logic ---

// jsonSchemaToAvro converts a JSON Schema to Avro schema string
func jsonSchemaToAvro(jsonSchema *JSONSchema, recordName, namespace string) (string, error) {
	avroSchema, err := convertJSONSchemaToAvro(jsonSchema, recordName, namespace)
	if err != nil {
		return "", err
	}

	avroBytes, err := json.MarshalIndent(avroSchema, "", "  ")
	if err != nil {
		return "", fmt.Errorf("failed to marshal Avro schema: %v", err)
	}

	return string(avroBytes), nil
}

// convertJSONSchemaToAvro converts a JSON Schema to Avro schema format
func convertJSONSchemaToAvro(jsonSchema *JSONSchema, recordName, namespace string) (*AvroSchema, error) {
	avroSchema := &AvroSchema{
		Name:      recordName,
		Namespace: namespace,
	}

	if jsonSchema.Description != "" {
		avroSchema.Doc = jsonSchema.Description
	}

	// Convert based on JSON Schema type
	switch jsonSchema.Type {
	case "object":
		return convertObjectToAvroRecord(jsonSchema, recordName, namespace)
	case "array":
		if jsonSchema.Items == nil {
			return nil, fmt.Errorf("array schema must have 'items' definition")
		}
		itemType, err := convertJSONSchemaTypeToAvro(jsonSchema.Items, "ArrayItem", namespace)
		if err != nil {
			return nil, err
		}
		avroSchema.Type = "array"
		avroSchema.Items = itemType
		return avroSchema, nil
	case "string":
		if len(jsonSchema.Enum) > 0 {
			symbols := make([]string, len(jsonSchema.Enum))
			for i, val := range jsonSchema.Enum {
				symbols[i] = fmt.Sprintf("%v", val)
			}
			avroSchema.Type = "enum"
			avroSchema.Symbols = symbols
			return avroSchema, nil
		}
		avroSchema.Type = "string"
		return avroSchema, nil
	case "integer":
		avroSchema.Type = "long"
		return avroSchema, nil
	case "number":
		avroSchema.Type = "double"
		return avroSchema, nil
	case "boolean":
		avroSchema.Type = "boolean"
		return avroSchema, nil
	case "null":
		avroSchema.Type = "null"
		return avroSchema, nil
	default:
		return nil, fmt.Errorf("unsupported JSON Schema type: %s", jsonSchema.Type)
	}
}

// convertObjectToAvroRecord converts a JSON Schema object to Avro record
func convertObjectToAvroRecord(jsonSchema *JSONSchema, recordName, namespace string) (*AvroSchema, error) {
	avroSchema := &AvroSchema{
		Type:      "record",
		Name:      recordName,
		Namespace: namespace,
		Fields:    []AvroField{},
	}

	if jsonSchema.Description != "" {
		avroSchema.Doc = jsonSchema.Description
	}

	// Convert properties to fields
	for propName, propSchema := range jsonSchema.Properties {
		fieldType, err := convertJSONSchemaTypeToAvro(propSchema, propName, namespace)
		if err != nil {
			return nil, fmt.Errorf("failed to convert property '%s': %v", propName, err)
		}

		field := AvroField{
			Name: propName,
			Type: fieldType,
		}

		if propSchema.Description != "" {
			field.Doc = propSchema.Description
		}

		// Check if field is optional
		isRequired := false
		for _, req := range jsonSchema.Required {
			if req == propName {
				isRequired = true
				break
			}
		}

		if !isRequired {
			// Make field optional by creating union with null
			field.Type = []interface{}{"null", fieldType}
			field.Default = nil
		}

		avroSchema.Fields = append(avroSchema.Fields, field)
	}

	return avroSchema, nil
}

// convertJSONSchemaTypeToAvro converts JSON Schema types to Avro types
func convertJSONSchemaTypeToAvro(jsonSchema *JSONSchema, fieldName, namespace string) (interface{}, error) {
	// Handle union types (anyOf, oneOf)
	if len(jsonSchema.AnyOf) > 0 || len(jsonSchema.OneOf) > 0 {
		unionSchemas := jsonSchema.AnyOf
		if len(jsonSchema.OneOf) > 0 {
			unionSchemas = jsonSchema.OneOf
		}

		var unionTypes []interface{}
		for _, unionSchema := range unionSchemas {
			unionType, err := convertJSONSchemaTypeToAvro(unionSchema, fieldName, namespace)
			if err != nil {
				return nil, err
			}
			unionTypes = append(unionTypes, unionType)
		}
		return unionTypes, nil
	}

	// Handle allOf by merging schemas
	if len(jsonSchema.AllOf) > 0 {
		mergedSchema := &JSONSchema{
			Type:       "object",
			Properties: make(map[string]*JSONSchema),
			Required:   []string{},
		}

		for _, schema := range jsonSchema.AllOf {
			if schema.Type == "object" {
				for propName, propSchema := range schema.Properties {
					mergedSchema.Properties[propName] = propSchema
				}
				mergedSchema.Required = append(mergedSchema.Required, schema.Required...)
			}
		}

		return convertJSONSchemaTypeToAvro(mergedSchema, fieldName, namespace)
	}

	// Handle const values
	if jsonSchema.Const != nil {
		return map[string]interface{}{
			"type":    "enum",
			"name":    fieldName + "Const",
			"symbols": []string{fmt.Sprintf("%v", jsonSchema.Const)},
		}, nil
	}

	switch jsonSchema.Type {
	case "string":
		if len(jsonSchema.Enum) > 0 {
			symbols := make([]string, len(jsonSchema.Enum))
			for i, val := range jsonSchema.Enum {
				symbols[i] = fmt.Sprintf("%v", val)
			}
			return map[string]interface{}{
				"type":    "enum",
				"name":    fieldName + "Enum",
				"symbols": symbols,
			}, nil
		}
		return "string", nil
	case "integer":
		return "long", nil
	case "number":
		return "double", nil
	case "boolean":
		return "boolean", nil
	case "null":
		return "null", nil
	case "array":
		if jsonSchema.Items == nil {
			return nil, fmt.Errorf("array must have 'items' definition")
		}
		itemType, err := convertJSONSchemaTypeToAvro(jsonSchema.Items, fieldName+"Item", namespace)
		if err != nil {
			return nil, err
		}
		return map[string]interface{}{
			"type":  "array",
			"items": itemType,
		}, nil
	case "object":
		if jsonSchema.AdditionalProperties != nil {
			// Map type
			if additionalPropsSchema, ok := jsonSchema.AdditionalProperties.(*JSONSchema); ok {
				valueType, err := convertJSONSchemaTypeToAvro(additionalPropsSchema, fieldName+"Value", namespace)
				if err != nil {
					return nil, err
				}
				return map[string]interface{}{
					"type":   "map",
					"values": valueType,
				}, nil
			} else if additionalProps, ok := jsonSchema.AdditionalProperties.(bool); ok && additionalProps {
				return map[string]interface{}{
					"type":   "map",
					"values": "string", // Default to string values
				}, nil
			}
		}
		// Nested record
		return convertObjectToAvroRecord(jsonSchema, fieldName+"Record", namespace)
	default:
		return nil, fmt.Errorf("unsupported JSON Schema type: %s", jsonSchema.Type)
	}
}

// setErrorOutputs is a helper function to set all error-related outputs at once.
func setErrorOutputs(ctx activity.Context, message, code string) {
	ctx.SetOutput(ovXSDString, "")
	ctx.SetOutput(ovAvroSchema, "")
	ctx.SetOutput(ovError, true)
	ctx.SetOutput(ovErrorMessage, fmt.Sprintf("%s: %s", code, message))
}
