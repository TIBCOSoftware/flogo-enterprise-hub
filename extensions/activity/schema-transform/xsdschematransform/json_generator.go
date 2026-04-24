package xsdschematransform

import (
	"encoding/json"
	"fmt"
)

// generateJSONSchema converts universal schema to JSON Schema
func generateJSONSchema(universalSchema *UniversalSchema, input *Input) (string, error) {
	jsonSchema := &JSONSchema{}

	// Set JSON Schema metadata
	switch input.JSONSchemaVersion {
	case "draft-04":
		jsonSchema.Schema = "http://json-schema.org/draft-04/schema#"
	case "draft-07":
		jsonSchema.Schema = "http://json-schema.org/draft-07/schema#"
	case "2019-09":
		jsonSchema.Schema = "https://json-schema.org/draft/2019-09/schema"
	case "2020-12":
		jsonSchema.Schema = "https://json-schema.org/draft/2020-12/schema"
	default:
		jsonSchema.Schema = "https://json-schema.org/draft/2020-12/schema"
	}

	if input.JSONSchemaID != "" {
		jsonSchema.ID = input.JSONSchemaID
	}

	if input.JSONSchemaTitle != "" {
		jsonSchema.Title = input.JSONSchemaTitle
	}

	// Convert universal schema to JSON Schema format
	err := convertUniversalToJSONSchema(universalSchema, jsonSchema, input)
	if err != nil {
		return "", err
	}

	// Marshal to JSON string
	jsonBytes, err := json.MarshalIndent(jsonSchema, "", "  ")
	if err != nil {
		return "", fmt.Errorf("failed to marshal JSON Schema: %w", err)
	}

	return string(jsonBytes), nil
}

// convertUniversalToJSONSchema converts universal schema to JSON Schema structure
func convertUniversalToJSONSchema(universal *UniversalSchema, jsonSchema *JSONSchema, input *Input) error {
	// Set basic properties
	if universal.Type != "" {
		jsonSchema.Type = universal.Type
	}

	if universal.Description != "" {
		jsonSchema.Description = universal.Description
	}

	if universal.Title != "" {
		jsonSchema.Title = universal.Title
	}

	// Handle properties for objects
	if universal.Properties != nil && len(universal.Properties) > 0 {
		jsonSchema.Properties = make(map[string]*JSONSchema)
		var requiredFields []string

		for propName, prop := range universal.Properties {
			propSchema := &JSONSchema{}
			err := convertUniversalPropertyToJSONSchema(prop, propSchema, input)
			if err != nil {
				return err
			}
			jsonSchema.Properties[propName] = propSchema

			// Track required fields
			if prop.Required != nil && *prop.Required {
				requiredFields = append(requiredFields, propName)
			}
		}

		if len(requiredFields) > 0 {
			jsonSchema.Required = requiredFields
		}
	}

	// Handle array items
	if universal.Items != nil {
		itemSchema := &JSONSchema{}
		err := convertUniversalToJSONSchema(universal.Items, itemSchema, input)
		if err != nil {
			return err
		}
		jsonSchema.Items = itemSchema
	}

	// Handle enum values
	if universal.EnumValues != nil && len(universal.EnumValues) > 0 {
		jsonSchema.Enum = universal.EnumValues
	}

	// Handle oneOf/anyOf/allOf
	if universal.OneOf != nil && len(universal.OneOf) > 0 {
		jsonSchema.OneOf = make([]*JSONSchema, len(universal.OneOf))
		for i, schema := range universal.OneOf {
			oneOfSchema := &JSONSchema{}
			err := convertUniversalToJSONSchema(schema, oneOfSchema, input)
			if err != nil {
				return err
			}
			jsonSchema.OneOf[i] = oneOfSchema
		}
	}

	if universal.AnyOf != nil && len(universal.AnyOf) > 0 {
		jsonSchema.AnyOf = make([]*JSONSchema, len(universal.AnyOf))
		for i, schema := range universal.AnyOf {
			anyOfSchema := &JSONSchema{}
			err := convertUniversalToJSONSchema(schema, anyOfSchema, input)
			if err != nil {
				return err
			}
			jsonSchema.AnyOf[i] = anyOfSchema
		}
	}

	if universal.AllOf != nil && len(universal.AllOf) > 0 {
		jsonSchema.AllOf = make([]*JSONSchema, len(universal.AllOf))
		for i, schema := range universal.AllOf {
			allOfSchema := &JSONSchema{}
			err := convertUniversalToJSONSchema(schema, allOfSchema, input)
			if err != nil {
				return err
			}
			jsonSchema.AllOf[i] = allOfSchema
		}
	}

	// Handle constraints
	if universal.Constraints != nil {
		applyConstraintsToJSONSchema(universal.Constraints, jsonSchema)
	}

	// Handle format
	if universal.Format != "" {
		jsonSchema.Format = universal.Format
	}

	// Handle definitions
	if universal.Definitions != nil && len(universal.Definitions) > 0 {
		if input.JSONSchemaVersion == "draft-04" || input.JSONSchemaVersion == "draft-07" {
			jsonSchema.Definitions = make(map[string]*JSONSchema)
			for defName, defSchema := range universal.Definitions {
				defJSONSchema := &JSONSchema{}
				err := convertUniversalToJSONSchema(defSchema, defJSONSchema, input)
				if err != nil {
					return err
				}
				jsonSchema.Definitions[defName] = defJSONSchema
			}
		} else {
			// Use $defs for newer versions
			jsonSchema.Defs = make(map[string]*JSONSchema)
			for defName, defSchema := range universal.Definitions {
				defJSONSchema := &JSONSchema{}
				err := convertUniversalToJSONSchema(defSchema, defJSONSchema, input)
				if err != nil {
					return err
				}
				jsonSchema.Defs[defName] = defJSONSchema
			}
		}
	}

	return nil
}

// convertUniversalPropertyToJSONSchema converts universal property to JSON Schema
func convertUniversalPropertyToJSONSchema(prop *UniversalProperty, jsonSchema *JSONSchema, input *Input) error {
	// Set basic type
	if prop.Type != "" {
		jsonSchema.Type = prop.Type
	}

	// Set description
	if prop.Description != "" {
		jsonSchema.Description = prop.Description
	}

	// Set format
	if prop.Format != "" {
		jsonSchema.Format = prop.Format
	}

	// Handle default value
	if prop.Default != nil {
		jsonSchema.Default = prop.Default
	}

	// Handle enum values
	if prop.EnumValues != nil && len(prop.EnumValues) > 0 {
		jsonSchema.Enum = prop.EnumValues
	}

	// Handle nullable (for newer JSON Schema versions)
	if prop.Nullable && (input.JSONSchemaVersion == "2019-09" || input.JSONSchemaVersion == "2020-12") {
		// Make type nullable by using anyOf with null
		if jsonSchema.Type != nil {
			jsonSchema.AnyOf = []*JSONSchema{
				{Type: jsonSchema.Type},
				{Type: "null"},
			}
			jsonSchema.Type = nil
		}
	}

	// Handle object properties
	if prop.Properties != nil && len(prop.Properties) > 0 {
		jsonSchema.Properties = make(map[string]*JSONSchema)
		for propName, nestedProp := range prop.Properties {
			nestedSchema := &JSONSchema{}
			err := convertUniversalPropertyToJSONSchema(nestedProp, nestedSchema, input)
			if err != nil {
				return err
			}
			jsonSchema.Properties[propName] = nestedSchema
		}
	}

	// Handle constraints
	if prop.Constraints != nil {
		applyConstraintsToJSONSchema(prop.Constraints, jsonSchema)
	}

	return nil
}

// applyConstraintsToJSONSchema applies universal constraints to JSON Schema
func applyConstraintsToJSONSchema(constraints *UniversalConstraints, jsonSchema *JSONSchema) {
	// String constraints
	if constraints.MinLength != nil {
		jsonSchema.MinLength = constraints.MinLength
	}
	if constraints.MaxLength != nil {
		jsonSchema.MaxLength = constraints.MaxLength
	}
	if constraints.Pattern != nil && len(constraints.Pattern) > 0 {
		// Use the first pattern (JSON Schema supports only one pattern)
		jsonSchema.Pattern = constraints.Pattern[0]
	}

	// Numeric constraints
	if constraints.Minimum != nil {
		jsonSchema.Minimum = constraints.Minimum
	}
	if constraints.Maximum != nil {
		jsonSchema.Maximum = constraints.Maximum
	}
	if constraints.ExclusiveMinimum != nil {
		jsonSchema.ExclusiveMinimum = *constraints.ExclusiveMinimum
	}
	if constraints.ExclusiveMaximum != nil {
		jsonSchema.ExclusiveMaximum = *constraints.ExclusiveMaximum
	}
	if constraints.MultipleOf != nil {
		jsonSchema.MultipleOf = constraints.MultipleOf
	}

	// Array constraints
	if constraints.MinItems != nil {
		jsonSchema.MinItems = constraints.MinItems
	}
	if constraints.MaxItems != nil {
		jsonSchema.MaxItems = constraints.MaxItems
	}
	if constraints.UniqueItems != nil {
		jsonSchema.UniqueItems = constraints.UniqueItems
	}

	// Object constraints
	if constraints.MinProperties != nil {
		jsonSchema.MinProperties = constraints.MinProperties
	}
	if constraints.MaxProperties != nil {
		jsonSchema.MaxProperties = constraints.MaxProperties
	}

	// Const constraint
	if constraints.Const != nil {
		jsonSchema.Const = constraints.Const
	}

	// Default constraint
	if constraints.Default != nil {
		jsonSchema.Default = constraints.Default
	}
}
