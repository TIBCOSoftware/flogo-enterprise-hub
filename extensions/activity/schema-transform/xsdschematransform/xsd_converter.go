package xsdschematransform

import (
	"encoding/xml"
	"fmt"
	"strconv"
	"strings"
)

// convertXSDToUniversal converts XSD schema to universal schema representation
func convertXSDToUniversal(xsdData string, options ConversionOptions) (*UniversalSchema, error) {
	var xsdSchema XSDSchema

	// Parse XML
	if err := xml.Unmarshal([]byte(xsdData), &xsdSchema); err != nil {
		return nil, fmt.Errorf("failed to parse XSD: %w", err)
	}

	universal := &UniversalSchema{
		Type:        "object",
		Properties:  make(map[string]*UniversalProperty),
		Definitions: make(map[string]*UniversalSchema),
	}

	// Set schema metadata
	if xsdSchema.TargetNamespace != "" {
		universal.Namespace = xsdSchema.TargetNamespace
	}

	// Process global elements
	for _, element := range xsdSchema.Elements {
		prop, err := convertXSDElement(&element, &xsdSchema, options)
		if err != nil {
			if options.SkipUnsupported {
				continue
			}
			return nil, err
		}
		universal.Properties[element.Name] = prop
	}

	// Process global complex types
	for _, complexType := range xsdSchema.ComplexTypes {
		schema, err := convertXSDComplexTypeDef(&complexType, &xsdSchema, options)
		if err != nil {
			if options.SkipUnsupported {
				continue
			}
			return nil, err
		}
		universal.Definitions[complexType.Name] = schema
	}

	// Process global simple types
	for _, simpleType := range xsdSchema.SimpleTypes {
		schema, err := convertXSDSimpleTypeDef(&simpleType, &xsdSchema, options)
		if err != nil {
			if options.SkipUnsupported {
				continue
			}
			return nil, err
		}
		universal.Definitions[simpleType.Name] = schema
	}

	return universal, nil
}

// convertXSDElement converts an XSD element to universal property
func convertXSDElement(element *XSDElement, schema *XSDSchema, options ConversionOptions) (*UniversalProperty, error) {
	prop := &UniversalProperty{}

	// Handle occurrence constraints
	if element.MinOccurs != "" {
		if minOccurs, err := strconv.Atoi(element.MinOccurs); err == nil {
			prop.MinOccurs = &minOccurs
		}
	}

	if element.MaxOccurs != "" {
		if element.MaxOccurs == "unbounded" {
			unlimited := -1
			prop.MaxOccurs = &unlimited
		} else if maxOccurs, err := strconv.Atoi(element.MaxOccurs); err == nil {
			prop.MaxOccurs = &maxOccurs
		}
	}

	// Handle nillable
	if element.Nillable == "true" {
		prop.Nullable = true
	}

	// Handle default and fixed values
	if element.Default != "" {
		prop.Default = element.Default
	}
	if element.Fixed != "" {
		prop.Fixed = element.Fixed
	}

	// Handle documentation
	if element.Annotation != nil {
		for _, doc := range element.Annotation.Documentation {
			if prop.Description == "" {
				prop.Description = doc.Content
			} else {
				prop.Description += "\n" + doc.Content
			}
		}
	}

	// Determine type
	if element.Type != "" {
		// Reference to existing type
		universalType, err := mapXSDTypeToUniversal(element.Type, schema, options)
		if err != nil {
			return nil, err
		}
		prop.Type = universalType.Type
		prop.Format = universalType.Format
		prop.Constraints = universalType.Constraints
		prop.EnumValues = universalType.EnumValues

	} else if element.ComplexType != nil {
		// Inline complex type
		complexSchema, err := convertXSDComplexType(element.ComplexType, schema, options)
		if err != nil {
			return nil, err
		}
		prop.Type = complexSchema.Type
		prop.Properties = complexSchema.Properties
		prop.AdditionalProperties = complexSchema.AdditionalProperties

	} else if element.SimpleType != nil {
		// Inline simple type
		simpleSchema, err := convertXSDSimpleType(element.SimpleType, schema, options)
		if err != nil {
			return nil, err
		}
		prop.Type = simpleSchema.Type
		prop.Format = simpleSchema.Format
		prop.Constraints = simpleSchema.Constraints
		prop.EnumValues = simpleSchema.EnumValues

	} else {
		// Default to string if no type specified
		prop.Type = "string"
	}

	return prop, nil
}

// convertXSDComplexType converts XSD complex type to universal schema
func convertXSDComplexType(complexType *XSDComplexType, schema *XSDSchema, options ConversionOptions) (*UniversalSchema, error) {
	universal := &UniversalSchema{
		Type:       "object",
		Properties: make(map[string]*UniversalProperty),
	}

	// Handle mixed content
	if complexType.Mixed == "true" {
		universal.Mixed = true
	}

	// Handle documentation
	if complexType.Annotation != nil {
		for _, doc := range complexType.Annotation.Documentation {
			if universal.Description == "" {
				universal.Description = doc.Content
			} else {
				universal.Description += "\n" + doc.Content
			}
		}
	}

	// Process content model
	if complexType.Sequence != nil {
		err := processXSDSequence(complexType.Sequence, universal, schema, options)
		if err != nil {
			return nil, err
		}
	}

	if complexType.Choice != nil {
		err := processXSDChoice(complexType.Choice, universal, schema, options)
		if err != nil {
			return nil, err
		}
	}

	if complexType.All != nil {
		err := processXSDAll(complexType.All, universal, schema, options)
		if err != nil {
			return nil, err
		}
	}

	// Process attributes
	for _, attr := range complexType.Attributes {
		prop, err := convertXSDAttribute(&attr, schema, options)
		if err != nil {
			if options.SkipUnsupported {
				continue
			}
			return nil, err
		}
		universal.Properties[attr.Name] = prop
	}

	// Handle simple content
	if complexType.SimpleContent != nil {
		err := processXSDSimpleContent(complexType.SimpleContent, universal, schema, options)
		if err != nil {
			return nil, err
		}
	}

	// Handle complex content
	if complexType.ComplexContent != nil {
		err := processXSDComplexContent(complexType.ComplexContent, universal, schema, options)
		if err != nil {
			return nil, err
		}
	}

	return universal, nil
}

// convertXSDComplexTypeDef converts named XSD complex type to universal schema
func convertXSDComplexTypeDef(complexType *XSDComplexTypeDef, schema *XSDSchema, options ConversionOptions) (*UniversalSchema, error) {
	universal := &UniversalSchema{
		Type:       "object",
		Properties: make(map[string]*UniversalProperty),
	}

	// Handle mixed content
	if complexType.Mixed == "true" {
		universal.Mixed = true
	}

	// Handle documentation
	if complexType.Annotation != nil {
		for _, doc := range complexType.Annotation.Documentation {
			if universal.Description == "" {
				universal.Description = doc.Content
			} else {
				universal.Description += "\n" + doc.Content
			}
		}
	}

	// Process content model (same as inline complex type)
	if complexType.Sequence != nil {
		err := processXSDSequence(complexType.Sequence, universal, schema, options)
		if err != nil {
			return nil, err
		}
	}

	if complexType.Choice != nil {
		err := processXSDChoice(complexType.Choice, universal, schema, options)
		if err != nil {
			return nil, err
		}
	}

	if complexType.All != nil {
		err := processXSDAll(complexType.All, universal, schema, options)
		if err != nil {
			return nil, err
		}
	}

	// Process attributes
	for _, attr := range complexType.Attributes {
		prop, err := convertXSDAttribute(&attr, schema, options)
		if err != nil {
			if options.SkipUnsupported {
				continue
			}
			return nil, err
		}
		universal.Properties[attr.Name] = prop
	}

	// Handle simple content
	if complexType.SimpleContent != nil {
		err := processXSDSimpleContent(complexType.SimpleContent, universal, schema, options)
		if err != nil {
			return nil, err
		}
	}

	// Handle complex content
	if complexType.ComplexContent != nil {
		err := processXSDComplexContent(complexType.ComplexContent, universal, schema, options)
		if err != nil {
			return nil, err
		}
	}

	return universal, nil
}

// convertXSDSimpleType converts XSD simple type to universal schema
func convertXSDSimpleType(simpleType *XSDSimpleType, schema *XSDSchema, options ConversionOptions) (*UniversalSchema, error) {
	universal := &UniversalSchema{}

	// Handle documentation
	if simpleType.Annotation != nil {
		for _, doc := range simpleType.Annotation.Documentation {
			if universal.Description == "" {
				universal.Description = doc.Content
			} else {
				universal.Description += "\n" + doc.Content
			}
		}
	}

	if simpleType.Restriction != nil {
		err := processXSDRestriction(simpleType.Restriction, universal, schema, options)
		if err != nil {
			return nil, err
		}
	}

	if simpleType.List != nil {
		universal.Type = "array"
		if simpleType.List.ItemType != "" {
			itemSchema, err := mapXSDTypeToUniversal(simpleType.List.ItemType, schema, options)
			if err != nil {
				return nil, err
			}
			universal.Items = itemSchema
		}
	}

	if simpleType.Union != nil {
		universal.OneOf = []*UniversalSchema{}
		if simpleType.Union.MemberTypes != "" {
			memberTypes := strings.Fields(simpleType.Union.MemberTypes)
			for _, memberType := range memberTypes {
				memberSchema, err := mapXSDTypeToUniversal(memberType, schema, options)
				if err != nil {
					if options.SkipUnsupported {
						continue
					}
					return nil, err
				}
				universal.OneOf = append(universal.OneOf, memberSchema)
			}
		}
	}

	return universal, nil
}

// convertXSDSimpleTypeDef converts named XSD simple type to universal schema
func convertXSDSimpleTypeDef(simpleType *XSDSimpleTypeDef, schema *XSDSchema, options ConversionOptions) (*UniversalSchema, error) {
	universal := &UniversalSchema{}

	// Handle documentation
	if simpleType.Annotation != nil {
		for _, doc := range simpleType.Annotation.Documentation {
			if universal.Description == "" {
				universal.Description = doc.Content
			} else {
				universal.Description += "\n" + doc.Content
			}
		}
	}

	if simpleType.Restriction != nil {
		err := processXSDRestriction(simpleType.Restriction, universal, schema, options)
		if err != nil {
			return nil, err
		}
	}

	if simpleType.List != nil {
		universal.Type = "array"
		if simpleType.List.ItemType != "" {
			itemSchema, err := mapXSDTypeToUniversal(simpleType.List.ItemType, schema, options)
			if err != nil {
				return nil, err
			}
			universal.Items = itemSchema
		}
	}

	if simpleType.Union != nil {
		universal.OneOf = []*UniversalSchema{}
		if simpleType.Union.MemberTypes != "" {
			memberTypes := strings.Fields(simpleType.Union.MemberTypes)
			for _, memberType := range memberTypes {
				memberSchema, err := mapXSDTypeToUniversal(memberType, schema, options)
				if err != nil {
					if options.SkipUnsupported {
						continue
					}
					return nil, err
				}
				universal.OneOf = append(universal.OneOf, memberSchema)
			}
		}
	}

	return universal, nil
}

// convertXSDAttribute converts XSD attribute to universal property
func convertXSDAttribute(attr *XSDAttribute, schema *XSDSchema, options ConversionOptions) (*UniversalProperty, error) {
	prop := &UniversalProperty{}

	// Handle required
	if attr.Use == "required" {
		required := true
		prop.Required = &required
	}

	// Handle default and fixed values
	if attr.Default != "" {
		prop.Default = attr.Default
	}
	if attr.Fixed != "" {
		prop.Fixed = attr.Fixed
	}

	// Handle documentation
	if attr.Annotation != nil {
		for _, doc := range attr.Annotation.Documentation {
			if prop.Description == "" {
				prop.Description = doc.Content
			} else {
				prop.Description += "\n" + doc.Content
			}
		}
	}

	// Determine type
	if attr.Type != "" {
		universalType, err := mapXSDTypeToUniversal(attr.Type, schema, options)
		if err != nil {
			return nil, err
		}
		prop.Type = universalType.Type
		prop.Format = universalType.Format
		prop.Constraints = universalType.Constraints
		prop.EnumValues = universalType.EnumValues

	} else if attr.SimpleType != nil {
		simpleSchema, err := convertXSDSimpleType(attr.SimpleType, schema, options)
		if err != nil {
			return nil, err
		}
		prop.Type = simpleSchema.Type
		prop.Format = simpleSchema.Format
		prop.Constraints = simpleSchema.Constraints
		prop.EnumValues = simpleSchema.EnumValues

	} else {
		// Default to string for attributes
		prop.Type = "string"
	}

	return prop, nil
}

// processXSDSequence processes XSD sequence
func processXSDSequence(sequence *XSDSequence, universal *UniversalSchema, schema *XSDSchema, options ConversionOptions) error {
	for _, element := range sequence.Elements {
		prop, err := convertXSDElement(&element, schema, options)
		if err != nil {
			if options.SkipUnsupported {
				continue
			}
			return err
		}
		universal.Properties[element.Name] = prop
	}

	// Process nested sequences and choices
	for _, nestedChoice := range sequence.Choices {
		err := processXSDChoice(&nestedChoice, universal, schema, options)
		if err != nil {
			return err
		}
	}

	for _, nestedSequence := range sequence.Sequences {
		err := processXSDSequence(&nestedSequence, universal, schema, options)
		if err != nil {
			return err
		}
	}

	return nil
}

// processXSDChoice processes XSD choice
func processXSDChoice(choice *XSDChoice, universal *UniversalSchema, schema *XSDSchema, options ConversionOptions) error {
	// For choices, we create a oneOf structure
	if universal.OneOf == nil {
		universal.OneOf = []*UniversalSchema{}
	}

	for _, element := range choice.Elements {
		choiceSchema := &UniversalSchema{
			Type:       "object",
			Properties: make(map[string]*UniversalProperty),
		}

		prop, err := convertXSDElement(&element, schema, options)
		if err != nil {
			if options.SkipUnsupported {
				continue
			}
			return err
		}
		choiceSchema.Properties[element.Name] = prop
		universal.OneOf = append(universal.OneOf, choiceSchema)
	}

	return nil
}

// processXSDAll processes XSD all
func processXSDAll(all *XSDAll, universal *UniversalSchema, schema *XSDSchema, options ConversionOptions) error {
	// xs:all is similar to sequence but order doesn't matter
	for _, element := range all.Elements {
		prop, err := convertXSDElement(&element, schema, options)
		if err != nil {
			if options.SkipUnsupported {
				continue
			}
			return err
		}
		universal.Properties[element.Name] = prop
	}

	return nil
}

// processXSDRestriction processes XSD restriction facets
func processXSDRestriction(restriction *XSDRestriction, universal *UniversalSchema, schema *XSDSchema, options ConversionOptions) error {
	// Map base type
	baseSchema, err := mapXSDTypeToUniversal(restriction.Base, schema, options)
	if err != nil {
		return err
	}

	universal.Type = baseSchema.Type
	universal.Format = baseSchema.Format

	if universal.Constraints == nil {
		universal.Constraints = &UniversalConstraints{}
	}

	// Process facets
	if restriction.MinLength != nil {
		if minLen, err := strconv.Atoi(restriction.MinLength.Value); err == nil {
			universal.Constraints.MinLength = &minLen
		}
	}

	if restriction.MaxLength != nil {
		if maxLen, err := strconv.Atoi(restriction.MaxLength.Value); err == nil {
			universal.Constraints.MaxLength = &maxLen
		}
	}

	if restriction.Length != nil {
		if length, err := strconv.Atoi(restriction.Length.Value); err == nil {
			universal.Constraints.MinLength = &length
			universal.Constraints.MaxLength = &length
		}
	}

	if restriction.MinInclusive != nil {
		if minVal, err := strconv.ParseFloat(restriction.MinInclusive.Value, 64); err == nil {
			universal.Constraints.Minimum = &minVal
		}
	}

	if restriction.MaxInclusive != nil {
		if maxVal, err := strconv.ParseFloat(restriction.MaxInclusive.Value, 64); err == nil {
			universal.Constraints.Maximum = &maxVal
		}
	}

	if restriction.MinExclusive != nil {
		if minVal, err := strconv.ParseFloat(restriction.MinExclusive.Value, 64); err == nil {
			exclusive := true
			universal.Constraints.Minimum = &minVal
			universal.Constraints.ExclusiveMinimum = &exclusive
		}
	}

	if restriction.MaxExclusive != nil {
		if maxVal, err := strconv.ParseFloat(restriction.MaxExclusive.Value, 64); err == nil {
			exclusive := true
			universal.Constraints.Maximum = &maxVal
			universal.Constraints.ExclusiveMaximum = &exclusive
		}
	}

	if restriction.TotalDigits != nil {
		if totalDigits, err := strconv.Atoi(restriction.TotalDigits.Value); err == nil {
			universal.Constraints.TotalDigits = &totalDigits
		}
	}

	if restriction.FractionDigits != nil {
		if fractionDigits, err := strconv.Atoi(restriction.FractionDigits.Value); err == nil {
			universal.Constraints.FractionDigits = &fractionDigits
		}
	}

	// Handle patterns
	if len(restriction.Pattern) > 0 {
		patterns := make([]string, len(restriction.Pattern))
		for i, pattern := range restriction.Pattern {
			patterns[i] = pattern.Value
		}
		universal.Constraints.Pattern = patterns
	}

	// Handle enumerations
	if len(restriction.Enumerations) > 0 {
		enumValues := make([]interface{}, len(restriction.Enumerations))
		for i, enum := range restriction.Enumerations {
			enumValues[i] = enum.Value
		}
		universal.EnumValues = enumValues
	}

	return nil
}

// processXSDSimpleContent processes XSD simple content
func processXSDSimpleContent(simpleContent *XSDSimpleContent, universal *UniversalSchema, schema *XSDSchema, options ConversionOptions) error {
	if simpleContent.Extension != nil {
		// Base type becomes the content type
		baseSchema, err := mapXSDTypeToUniversal(simpleContent.Extension.Base, schema, options)
		if err != nil {
			return err
		}

		// Add content property
		universal.Properties["_content"] = &UniversalProperty{
			Type:   baseSchema.Type,
			Format: baseSchema.Format,
		}

		// Process attributes
		for _, attr := range simpleContent.Extension.Attributes {
			prop, err := convertXSDAttribute(&attr, schema, options)
			if err != nil {
				if options.SkipUnsupported {
					continue
				}
				return err
			}
			universal.Properties[attr.Name] = prop
		}
	}

	if simpleContent.Restriction != nil {
		// Similar to extension but with restrictions
		baseSchema, err := mapXSDTypeToUniversal(simpleContent.Restriction.Base, schema, options)
		if err != nil {
			return err
		}

		universal.Properties["_content"] = &UniversalProperty{
			Type:   baseSchema.Type,
			Format: baseSchema.Format,
		}

		// Apply restrictions to content
		if len(simpleContent.Restriction.Enumerations) > 0 {
			enumValues := make([]interface{}, len(simpleContent.Restriction.Enumerations))
			for i, enum := range simpleContent.Restriction.Enumerations {
				enumValues[i] = enum.Value
			}
			universal.Properties["_content"].EnumValues = enumValues
		}

		// Process attributes
		for _, attr := range simpleContent.Restriction.Attributes {
			prop, err := convertXSDAttribute(&attr, schema, options)
			if err != nil {
				if options.SkipUnsupported {
					continue
				}
				return err
			}
			universal.Properties[attr.Name] = prop
		}
	}

	return nil
}

// processXSDComplexContent processes XSD complex content
func processXSDComplexContent(complexContent *XSDComplexContent, universal *UniversalSchema, schema *XSDSchema, options ConversionOptions) error {
	if complexContent.Extension != nil {
		// Extend base type
		// This is a simplified implementation - in reality you'd need to resolve the base type
		// and merge its properties

		// Process new content
		if complexContent.Extension.Sequence != nil {
			err := processXSDSequence(complexContent.Extension.Sequence, universal, schema, options)
			if err != nil {
				return err
			}
		}

		if complexContent.Extension.Choice != nil {
			err := processXSDChoice(complexContent.Extension.Choice, universal, schema, options)
			if err != nil {
				return err
			}
		}

		// Process attributes
		for _, attr := range complexContent.Extension.Attributes {
			prop, err := convertXSDAttribute(&attr, schema, options)
			if err != nil {
				if options.SkipUnsupported {
					continue
				}
				return err
			}
			universal.Properties[attr.Name] = prop
		}
	}

	if complexContent.Restriction != nil {
		// Similar to extension but restricts base type
		if complexContent.Restriction.Sequence != nil {
			err := processXSDSequence(complexContent.Restriction.Sequence, universal, schema, options)
			if err != nil {
				return err
			}
		}

		if complexContent.Restriction.Choice != nil {
			err := processXSDChoice(complexContent.Restriction.Choice, universal, schema, options)
			if err != nil {
				return err
			}
		}

		// Process attributes
		for _, attr := range complexContent.Restriction.Attributes {
			prop, err := convertXSDAttribute(&attr, schema, options)
			if err != nil {
				if options.SkipUnsupported {
					continue
				}
				return err
			}
			universal.Properties[attr.Name] = prop
		}
	}

	return nil
}

// mapXSDTypeToUniversal maps XSD built-in types to universal schema types
func mapXSDTypeToUniversal(xsdType string, schema *XSDSchema, options ConversionOptions) (*UniversalSchema, error) {
	// Remove namespace prefix if present
	if colonIndex := strings.LastIndex(xsdType, ":"); colonIndex >= 0 {
		xsdType = xsdType[colonIndex+1:]
	}

	universal := &UniversalSchema{}

	switch xsdType {
	// String types
	case "string", "normalizedString", "token", "NMTOKEN", "NMTOKENS", "Name", "NCName", "ID", "IDREF", "IDREFS", "ENTITY", "ENTITIES", "language":
		universal.Type = "string"

	// Numeric types
	case "decimal":
		universal.Type = "number"
		universal.Format = "decimal"
	case "integer", "nonPositiveInteger", "negativeInteger", "long", "int", "short", "byte", "nonNegativeInteger", "unsignedLong", "unsignedInt", "unsignedShort", "unsignedByte", "positiveInteger":
		universal.Type = "integer"
	case "double":
		universal.Type = "number"
		universal.Format = "double"
	case "float":
		universal.Type = "number"
		universal.Format = "float"

	// Boolean type
	case "boolean":
		universal.Type = "boolean"

	// Date/time types
	case "dateTime":
		universal.Type = "string"
		universal.Format = "date-time"
	case "date":
		universal.Type = "string"
		universal.Format = "date"
	case "time":
		universal.Type = "string"
		universal.Format = "time"
	case "duration":
		universal.Type = "string"
		universal.Format = "duration"
	case "gYear":
		universal.Type = "string"
		universal.Format = "year"
	case "gMonth":
		universal.Type = "string"
		universal.Format = "month"
	case "gDay":
		universal.Type = "string"
		universal.Format = "day"
	case "gYearMonth":
		universal.Type = "string"
		universal.Format = "year-month"
	case "gMonthDay":
		universal.Type = "string"
		universal.Format = "month-day"

	// Binary types
	case "base64Binary":
		universal.Type = "string"
		universal.Format = "base64"
	case "hexBinary":
		universal.Type = "string"
		universal.Format = "hex"

	// URI type
	case "anyURI":
		universal.Type = "string"
		universal.Format = "uri"

	// QName type
	case "QName":
		universal.Type = "string"
		universal.Format = "qname"

	// NOTATION type
	case "NOTATION":
		universal.Type = "string"
		universal.Format = "notation"

	// anyType and anySimpleType
	case "anyType":
		// Leave type unspecified to allow any type
		return universal, nil
	case "anySimpleType":
		// Union of all simple types
		universal.OneOf = []*UniversalSchema{
			{Type: "string"},
			{Type: "number"},
			{Type: "integer"},
			{Type: "boolean"},
		}

	default:
		// Check if it's a user-defined type
		if options.SkipUnsupported {
			universal.Type = "string" // Default fallback
		} else {
			return nil, fmt.Errorf("unsupported XSD type: %s", xsdType)
		}
	}

	return universal, nil
}
