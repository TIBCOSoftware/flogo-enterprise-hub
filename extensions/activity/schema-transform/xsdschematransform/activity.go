package xsdschematransform

import (
	"encoding/json"
	"encoding/xml"
	"fmt"
	"regexp"
	"strings"

	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/data/coerce"
)

// Constants for identifying inputs and outputs
const (
	ivXSDString      = "xsdString"      // XSD schema input
	ivOutputFormat   = "outputFormat"   // "jsonschema", "avro", or "both"
	ivValidateInput  = "validateInput"  // Validate XSD before conversion
	ivPreserveOrder  = "preserveOrder"  // Preserve element order when possible
	ivOptimizeOutput = "optimizeOutput" // Optimize output schema structure

	// JSON Schema options
	ivJSONSchemaVersion = "jsonSchemaVersion" // "draft-04", "draft-07", "2019-09", "2020-12"
	ivJSONSchemaTitle   = "jsonSchemaTitle"   // Schema title
	ivJSONSchemaID      = "jsonSchemaId"      // Schema $id
	ivAddExamples       = "addExamples"       // Add example values from XSD

	// Avro options
	ivAvroRecordName   = "avroRecordName"   // For Avro generation
	ivAvroNamespace    = "avroNamespace"    // For Avro generation
	ivAvroLogicalTypes = "avroLogicalTypes" // Enable logical types (date, time, etc.)
	ivAvroUnionMode    = "avroUnionMode"    // "nullable", "strict", "permissive"

	// Advanced options
	ivHandleAny         = "handleAny"         // How to handle xs:any elements
	ivHandleChoice      = "handleChoice"      // How to handle xs:choice - "union", "oneof", "anyof"
	ivIncludeAttributes = "includeAttributes" // Include attributes in conversion
	ivNamespaceHandling = "namespaceHandling" // "ignore", "prefix", "separate"
	ivComplexTypeMode   = "complexTypeMode"   // "inline", "definitions", "refs"

	// Output parameters
	ovJSONSchemaString = "jsonSchemaString"
	ovAvroSchemaString = "avroSchemaString"
	ovValidationResult = "validationResult"
	ovConversionStats  = "conversionStats"
	ovError            = "error"
	ovErrorMessage     = "errorMessage"
)

// Activity is the structure for the XSD Schema transformation activity
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
	ctx.Logger().Debugf("Creating New XSD Schema Transform Activity")
	return &Activity{}, nil
}

// Eval executes the main logic of the Activity.
func (a *Activity) Eval(ctx activity.Context) (done bool, err error) {
	logger := ctx.Logger()
	logger.Debugf("Executing XSD Schema Transform Eval")

	// --- 1. Get and validate all inputs ---
	input, err := coerceAndValidateInputs(ctx)
	if err != nil {
		setErrorOutputs(ctx, err.Error(), "INVALID_INPUT")
		return true, nil
	}

	// --- 2. Parse XSD Schema ---
	logger.Debug("Parsing XSD Schema")
	xsdSchema, err := parseXSDSchema(input.XSDString)
	if err != nil {
		logger.Errorf("Failed to parse XSD Schema: %v", err)
		setErrorOutputs(ctx, fmt.Sprintf("Invalid XSD Schema provided: %v", err), "XSD_PARSE_ERROR")
		return true, nil
	}

	// --- 3. Validate XSD if requested ---
	var validationResult *ValidationResult
	if input.ValidateInput {
		logger.Debug("Validating XSD Schema")
		validationResult = validateXSDSchema(xsdSchema)
		if !validationResult.IsValid {
			logger.Warnf("XSD validation failed: %v", validationResult.Errors)
		}
	}

	// --- 4. Convert XSD to universal format ---
	logger.Debug("Converting XSD to universal format")

	// Convert Input to ConversionOptions
	options := ConversionOptions{
		OutputFormat:      input.OutputFormat,
		ValidateInput:     input.ValidateInput,
		PreserveOrder:     input.PreserveOrder,
		OptimizeOutput:    input.OptimizeOutput,
		JSONSchemaVersion: input.JSONSchemaVersion,
		JSONSchemaTitle:   input.JSONSchemaTitle,
		JSONSchemaID:      input.JSONSchemaID,
		AddExamples:       input.AddExamples,
		AvroRecordName:    input.AvroRecordName,
		AvroNamespace:     input.AvroNamespace,
		AvroLogicalTypes:  input.AvroLogicalTypes,
		AvroUnionMode:     input.AvroUnionMode,
		HandleAny:         input.HandleAny,
		HandleChoice:      input.HandleChoice,
		IncludeAttributes: input.IncludeAttributes,
		NamespaceHandling: input.NamespaceHandling,
		ComplexTypeMode:   input.ComplexTypeMode,
		SkipUnsupported:   true, // Always skip unsupported for now
	}

	universalSchema, err := convertXSDToUniversal(input.XSDString, options)
	if err != nil {
		logger.Errorf("Failed to convert XSD to universal format: %v", err)
		setErrorOutputs(ctx, fmt.Sprintf("XSD conversion failed: %v", err), "XSD_CONVERSION_ERROR")
		return true, nil
	}

	// Create conversion stats
	conversionStats := &ConversionStats{
		ElementsProcessed:   countElements(universalSchema),
		AttributesProcessed: countAttributes(universalSchema),
		ComplexTypesFound:   countComplexTypes(universalSchema),
		SimpleTypesFound:    countSimpleTypes(universalSchema),
		TypeMapping:         make(map[string]string),
		Warnings:            []string{},
	}

	// --- 5. Generate output schemas ---
	outputFormat := strings.ToLower(input.OutputFormat)
	var jsonSchemaString, avroSchemaString string

	if outputFormat == "jsonschema" || outputFormat == "both" {
		logger.Debug("Generating JSON Schema")
		jsonSchemaString, err = generateJSONSchema(universalSchema, input)
		if err != nil {
			logger.Errorf("Failed to generate JSON Schema: %v", err)
			setErrorOutputs(ctx, fmt.Sprintf("JSON Schema generation failed: %v", err), "JSONSCHEMA_GENERATION_ERROR")
			return true, nil
		}
	}

	if outputFormat == "avro" || outputFormat == "both" {
		logger.Debug("Generating Avro Schema")
		avroSchemaString, err = generateAvroSchema(universalSchema, input)
		if err != nil {
			logger.Errorf("Failed to generate Avro Schema: %v", err)
			setErrorOutputs(ctx, fmt.Sprintf("Avro Schema generation failed: %v", err), "AVRO_GENERATION_ERROR")
			return true, nil
		}
	}

	// --- 6. Set success outputs ---
	logger.Info("Successfully transformed XSD Schema")
	ctx.SetOutput(ovJSONSchemaString, jsonSchemaString)
	ctx.SetOutput(ovAvroSchemaString, avroSchemaString)

	if validationResult != nil {
		validationJSON, _ := json.Marshal(validationResult)
		ctx.SetOutput(ovValidationResult, string(validationJSON))
	}

	statsJSON, _ := json.Marshal(conversionStats)
	ctx.SetOutput(ovConversionStats, string(statsJSON))
	ctx.SetOutput(ovError, false)
	ctx.SetOutput(ovErrorMessage, "")

	return true, nil
}

// --- Input/Output Structs ---

// Input struct holds all configuration parameters
type Input struct {
	XSDString      string `md:"xsdString,required"`
	OutputFormat   string `md:"outputFormat"`
	ValidateInput  bool   `md:"validateInput"`
	PreserveOrder  bool   `md:"preserveOrder"`
	OptimizeOutput bool   `md:"optimizeOutput"`

	// JSON Schema options
	JSONSchemaVersion string `md:"jsonSchemaVersion"`
	JSONSchemaTitle   string `md:"jsonSchemaTitle"`
	JSONSchemaID      string `md:"jsonSchemaId"`
	AddExamples       bool   `md:"addExamples"`

	// Avro options
	AvroRecordName   string `md:"avroRecordName"`
	AvroNamespace    string `md:"avroNamespace"`
	AvroLogicalTypes bool   `md:"avroLogicalTypes"`
	AvroUnionMode    string `md:"avroUnionMode"`

	// Advanced options
	HandleAny         string `md:"handleAny"`
	HandleChoice      string `md:"handleChoice"`
	IncludeAttributes bool   `md:"includeAttributes"`
	NamespaceHandling string `md:"namespaceHandling"`
	ComplexTypeMode   string `md:"complexTypeMode"`
}

// Output struct for transformation results
type Output struct {
	JSONSchemaString string `md:"jsonSchemaString"`
	AvroSchemaString string `md:"avroSchemaString"`
	ValidationResult string `md:"validationResult"`
	ConversionStats  string `md:"conversionStats"`
	Error            bool   `md:"error"`
	ErrorMessage     string `md:"errorMessage"`
}

// --- Universal Schema Types ---

// UniversalSchema represents a schema in our internal universal format
type UniversalSchema struct {
	Type                 string                        `json:"type"`
	Name                 string                        `json:"name,omitempty"`
	Namespace            string                        `json:"namespace,omitempty"`
	Title                string                        `json:"title,omitempty"`
	Description          string                        `json:"description,omitempty"`
	Properties           map[string]*UniversalProperty `json:"properties,omitempty"`
	Items                *UniversalSchema              `json:"items,omitempty"`
	Required             []string                      `json:"required,omitempty"`
	EnumValues           []interface{}                 `json:"enum,omitempty"`
	OneOf                []*UniversalSchema            `json:"oneOf,omitempty"`
	AnyOf                []*UniversalSchema            `json:"anyOf,omitempty"`
	AllOf                []*UniversalSchema            `json:"allOf,omitempty"`
	Constraints          *UniversalConstraints         `json:"constraints,omitempty"`
	Annotations          map[string]interface{}        `json:"annotations,omitempty"`
	Order                int                           `json:"order,omitempty"`
	OriginalType         string                        `json:"originalType,omitempty"`
	Attributes           map[string]*UniversalProperty `json:"attributes,omitempty"`
	Format               string                        `json:"format,omitempty"`
	Definitions          map[string]*UniversalSchema   `json:"definitions,omitempty"`
	AdditionalProperties interface{}                   `json:"additionalProperties,omitempty"`
	Mixed                bool                          `json:"mixed,omitempty"`
}

// UniversalProperty represents a property in the universal schema format
type UniversalProperty struct {
	Type                 string                        `json:"type"`
	Format               string                        `json:"format,omitempty"`
	Description          string                        `json:"description,omitempty"`
	Required             *bool                         `json:"required,omitempty"`
	Nullable             bool                          `json:"nullable,omitempty"`
	Default              interface{}                   `json:"default,omitempty"`
	Fixed                interface{}                   `json:"fixed,omitempty"`
	EnumValues           []interface{}                 `json:"enum,omitempty"`
	MinOccurs            *int                          `json:"minOccurs,omitempty"`
	MaxOccurs            *int                          `json:"maxOccurs,omitempty"`
	Constraints          *UniversalConstraints         `json:"constraints,omitempty"`
	Properties           map[string]*UniversalProperty `json:"properties,omitempty"`
	AdditionalProperties interface{}                   `json:"additionalProperties,omitempty"`
}

// UniversalConstraints holds validation constraints
type UniversalConstraints struct {
	// String constraints
	MinLength *int     `json:"minLength,omitempty"`
	MaxLength *int     `json:"maxLength,omitempty"`
	Pattern   []string `json:"pattern,omitempty"`

	// Numeric constraints
	Minimum          *float64 `json:"minimum,omitempty"`
	Maximum          *float64 `json:"maximum,omitempty"`
	ExclusiveMinimum *bool    `json:"exclusiveMinimum,omitempty"`
	ExclusiveMaximum *bool    `json:"exclusiveMaximum,omitempty"`
	MultipleOf       *float64 `json:"multipleOf,omitempty"`
	TotalDigits      *int     `json:"totalDigits,omitempty"`
	FractionDigits   *int     `json:"fractionDigits,omitempty"`

	// Array constraints
	MinItems    *int  `json:"minItems,omitempty"`
	MaxItems    *int  `json:"maxItems,omitempty"`
	UniqueItems *bool `json:"uniqueItems,omitempty"`

	// Object constraints
	MinProperties *int `json:"minProperties,omitempty"`
	MaxProperties *int `json:"maxProperties,omitempty"`

	// Other constraints
	Const   interface{} `json:"const,omitempty"`
	Default interface{} `json:"default,omitempty"`
}

// ConversionOptions holds configuration for conversion
type ConversionOptions struct {
	OutputFormat      string
	ValidateInput     bool
	PreserveOrder     bool
	OptimizeOutput    bool
	JSONSchemaVersion string
	JSONSchemaTitle   string
	JSONSchemaID      string
	AddExamples       bool
	AvroRecordName    string
	AvroNamespace     string
	AvroLogicalTypes  bool
	AvroUnionMode     string
	HandleAny         string
	HandleChoice      string
	IncludeAttributes bool
	NamespaceHandling string
	ComplexTypeMode   string
	SkipUnsupported   bool
}

// ValidationResult holds schema validation results
type ValidationResult struct {
	IsValid  bool     `json:"isValid"`
	Errors   []string `json:"errors,omitempty"`
	Warnings []string `json:"warnings,omitempty"`
}

// ConversionStats holds conversion statistics
type ConversionStats struct {
	ElementsProcessed   int               `json:"elementsProcessed"`
	AttributesProcessed int               `json:"attributesProcessed"`
	ComplexTypesFound   int               `json:"complexTypesFound"`
	SimpleTypesFound    int               `json:"simpleTypesFound"`
	ChoicesFound        int               `json:"choicesFound"`
	UnionsCreated       int               `json:"unionsCreated"`
	ConstraintsApplied  int               `json:"constraintsApplied"`
	NamespacesFound     []string          `json:"namespacesFound"`
	TypeMapping         map[string]string `json:"typeMapping"`
	Warnings            []string          `json:"warnings"`
}

// --- Input Validation ---

// coerceAndValidateInputs reads all inputs from the context and validates them.
func coerceAndValidateInputs(ctx activity.Context) (*Input, error) {
	input := &Input{}
	var err error

	// Required inputs
	input.XSDString, err = coerce.ToString(ctx.GetInput(ivXSDString))
	if err != nil || strings.TrimSpace(input.XSDString) == "" {
		return nil, fmt.Errorf("input 'xsdString' is required and cannot be empty")
	}

	// Optional inputs with defaults
	input.OutputFormat, err = coerce.ToString(ctx.GetInput(ivOutputFormat))
	if err != nil || strings.TrimSpace(input.OutputFormat) == "" {
		input.OutputFormat = "both" // Default output format
	}

	// Validate output format
	outputFormat := strings.ToLower(input.OutputFormat)
	if outputFormat != "jsonschema" && outputFormat != "avro" && outputFormat != "both" {
		return nil, fmt.Errorf("invalid outputFormat '%s'. Must be 'jsonschema', 'avro', or 'both'", input.OutputFormat)
	}
	input.OutputFormat = outputFormat

	// Boolean options
	input.ValidateInput, _ = coerce.ToBool(ctx.GetInput(ivValidateInput))
	input.PreserveOrder, _ = coerce.ToBool(ctx.GetInput(ivPreserveOrder))
	input.OptimizeOutput, _ = coerce.ToBool(ctx.GetInput(ivOptimizeOutput))
	input.AddExamples, _ = coerce.ToBool(ctx.GetInput(ivAddExamples))
	input.AvroLogicalTypes, _ = coerce.ToBool(ctx.GetInput(ivAvroLogicalTypes))
	input.IncludeAttributes, _ = coerce.ToBool(ctx.GetInput(ivIncludeAttributes))

	// JSON Schema options
	input.JSONSchemaVersion, _ = coerce.ToString(ctx.GetInput(ivJSONSchemaVersion))
	if input.JSONSchemaVersion == "" {
		input.JSONSchemaVersion = "2020-12"
	}

	input.JSONSchemaTitle, _ = coerce.ToString(ctx.GetInput(ivJSONSchemaTitle))
	input.JSONSchemaID, _ = coerce.ToString(ctx.GetInput(ivJSONSchemaID))

	// Avro options
	input.AvroRecordName, _ = coerce.ToString(ctx.GetInput(ivAvroRecordName))
	if input.AvroRecordName == "" {
		input.AvroRecordName = "RootRecord"
	}

	input.AvroNamespace, _ = coerce.ToString(ctx.GetInput(ivAvroNamespace))
	if input.AvroNamespace == "" {
		input.AvroNamespace = "com.example"
	}

	input.AvroUnionMode, _ = coerce.ToString(ctx.GetInput(ivAvroUnionMode))
	if input.AvroUnionMode == "" {
		input.AvroUnionMode = "nullable"
	}

	// Advanced options
	input.HandleAny, _ = coerce.ToString(ctx.GetInput(ivHandleAny))
	if input.HandleAny == "" {
		input.HandleAny = "object"
	}

	input.HandleChoice, _ = coerce.ToString(ctx.GetInput(ivHandleChoice))
	if input.HandleChoice == "" {
		input.HandleChoice = "union"
	}

	input.NamespaceHandling, _ = coerce.ToString(ctx.GetInput(ivNamespaceHandling))
	if input.NamespaceHandling == "" {
		input.NamespaceHandling = "ignore"
	}

	input.ComplexTypeMode, _ = coerce.ToString(ctx.GetInput(ivComplexTypeMode))
	if input.ComplexTypeMode == "" {
		input.ComplexTypeMode = "inline"
	}

	return input, nil
}

// --- XSD Schema Parsing ---

// parseXSDSchema parses XSD schema string
func parseXSDSchema(schemaString string) (*XSDSchema, error) {
	var xsdSchema XSDSchema
	if err := xml.Unmarshal([]byte(schemaString), &xsdSchema); err != nil {
		return nil, fmt.Errorf("failed to parse XSD schema: %v", err)
	}
	return &xsdSchema, nil
}

// --- XSD Validation ---

// validateXSDSchema validates XSD schema structure
func validateXSDSchema(schema *XSDSchema) *ValidationResult {
	result := &ValidationResult{
		IsValid:  true,
		Errors:   []string{},
		Warnings: []string{},
	}

	// Basic structure validation
	if len(schema.Elements) == 0 && len(schema.ComplexTypes) == 0 && len(schema.SimpleTypes) == 0 {
		result.Errors = append(result.Errors, "XSD schema must have at least one element, complex type, or simple type")
	}

	// Validate target namespace format
	if schema.TargetNamespace != "" {
		if !isValidURI(schema.TargetNamespace) {
			result.Warnings = append(result.Warnings, "Target namespace should be a valid URI")
		}
	}

	// Validate elements
	for _, element := range schema.Elements {
		if element.Name == "" && element.Ref == "" {
			result.Errors = append(result.Errors, "XSD element must have either a name or ref attribute")
		}

		// Check for conflicting type definitions
		if element.Type != "" && (element.ComplexType != nil || element.SimpleType != nil) {
			result.Warnings = append(result.Warnings, fmt.Sprintf("Element '%s' has both type attribute and inline type definition", element.Name))
		}
	}

	// Validate complex types
	for _, complexType := range schema.ComplexTypes {
		if complexType.Name == "" {
			result.Errors = append(result.Errors, "Named complex type must have a name")
		}
	}

	result.IsValid = len(result.Errors) == 0
	return result
}

// isValidURI validates URI format
func isValidURI(uri string) bool {
	return regexp.MustCompile(`^https?://`).MatchString(uri) ||
		regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9+.-]*:`).MatchString(uri)
}

// setErrorOutputs is a helper function to set all error-related outputs at once.
func setErrorOutputs(ctx activity.Context, message, code string) {
	ctx.SetOutput(ovJSONSchemaString, "")
	ctx.SetOutput(ovAvroSchemaString, "")
	ctx.SetOutput(ovValidationResult, "")
	ctx.SetOutput(ovConversionStats, "")
	ctx.SetOutput(ovError, true)
	ctx.SetOutput(ovErrorMessage, fmt.Sprintf("%s: %s", code, message))
}

// --- Helper functions for counting schema elements ---

// countElements counts the number of elements in the universal schema
func countElements(schema *UniversalSchema) int {
	count := 0
	if schema.Properties != nil {
		count += len(schema.Properties)
		for _, prop := range schema.Properties {
			if prop.Properties != nil {
				count += countElementsInProperty(prop)
			}
		}
	}
	if schema.Definitions != nil {
		for _, def := range schema.Definitions {
			count += countElements(def)
		}
	}
	return count
}

// countElementsInProperty counts elements in a universal property
func countElementsInProperty(prop *UniversalProperty) int {
	count := 0
	if prop.Properties != nil {
		count += len(prop.Properties)
		for _, nestedProp := range prop.Properties {
			count += countElementsInProperty(nestedProp)
		}
	}
	return count
}

// countAttributes counts the number of attributes in the universal schema
func countAttributes(schema *UniversalSchema) int {
	count := 0
	if schema.Attributes != nil {
		count += len(schema.Attributes)
	}
	if schema.Properties != nil {
		for _, prop := range schema.Properties {
			count += countAttributesInProperty(prop)
		}
	}
	if schema.Definitions != nil {
		for _, def := range schema.Definitions {
			count += countAttributes(def)
		}
	}
	return count
}

// countAttributesInProperty counts attributes in a universal property
func countAttributesInProperty(prop *UniversalProperty) int {
	count := 0
	if prop.Properties != nil {
		for _, nestedProp := range prop.Properties {
			count += countAttributesInProperty(nestedProp)
		}
	}
	return count
}

// countComplexTypes counts the number of complex types in the universal schema
func countComplexTypes(schema *UniversalSchema) int {
	count := 0
	if schema.Type == "object" {
		count++
	}
	if schema.Properties != nil {
		for _, prop := range schema.Properties {
			count += countComplexTypesInProperty(prop)
		}
	}
	if schema.Definitions != nil {
		for _, def := range schema.Definitions {
			count += countComplexTypes(def)
		}
	}
	return count
}

// countComplexTypesInProperty counts complex types in a universal property
func countComplexTypesInProperty(prop *UniversalProperty) int {
	count := 0
	if prop.Type == "object" {
		count++
	}
	if prop.Properties != nil {
		for _, nestedProp := range prop.Properties {
			count += countComplexTypesInProperty(nestedProp)
		}
	}
	return count
}

// countSimpleTypes counts the number of simple types in the universal schema
func countSimpleTypes(schema *UniversalSchema) int {
	count := 0
	if schema.Type != "object" && schema.Type != "" {
		count++
	}
	if schema.Properties != nil {
		for _, prop := range schema.Properties {
			count += countSimpleTypesInProperty(prop)
		}
	}
	if schema.Definitions != nil {
		for _, def := range schema.Definitions {
			count += countSimpleTypes(def)
		}
	}
	return count
}

// countSimpleTypesInProperty counts simple types in a universal property
func countSimpleTypesInProperty(prop *UniversalProperty) int {
	count := 0
	if prop.Type != "object" && prop.Type != "" {
		count++
	}
	if prop.Properties != nil {
		for _, nestedProp := range prop.Properties {
			count += countSimpleTypesInProperty(nestedProp)
		}
	}
	return count
}

// --- Continue with conversion functions in separate files ---

// Note: Implementation functions are in separate files:
// - xsd_types.go: XSD type definitions
// - xsd_converter.go: XSD to Universal conversion
// - json_generator.go: JSON Schema generation
// - avro_generator.go: Avro Schema generation
