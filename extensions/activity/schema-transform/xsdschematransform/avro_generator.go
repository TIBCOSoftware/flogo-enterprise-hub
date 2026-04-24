package xsdschematransform

import (
	"encoding/json"
	"fmt"
	"strings"
)

// generateAvroSchema converts universal schema to Avro Schema
func generateAvroSchema(universalSchema *UniversalSchema, input *Input) (string, error) {
	avroSchema := &AvroSchema{}

	// Set Avro schema metadata
	avroSchema.Type = "record"
	avroSchema.Name = input.AvroRecordName
	avroSchema.Namespace = input.AvroNamespace

	if universalSchema.Description != "" {
		avroSchema.Doc = universalSchema.Description
	}

	// Convert universal schema to Avro format
	err := convertUniversalToAvroSchema(universalSchema, avroSchema, input)
	if err != nil {
		return "", err
	}

	// Marshal to JSON string
	avroBytes, err := json.MarshalIndent(avroSchema, "", "  ")
	if err != nil {
		return "", fmt.Errorf("failed to marshal Avro Schema: %w", err)
	}

	return string(avroBytes), nil
}

// convertUniversalToAvroSchema converts universal schema to Avro Schema structure
func convertUniversalToAvroSchema(universal *UniversalSchema, avroSchema *AvroSchema, input *Input) error {
	// Handle properties for records
	if universal.Properties != nil && len(universal.Properties) > 0 {
		avroSchema.Fields = make([]AvroField, 0, len(universal.Properties))

		for propName, prop := range universal.Properties {
			field := AvroField{
				Name: propName,
			}

			if prop.Description != "" {
				field.Doc = prop.Description
			}

			// Convert property type to Avro type
			avroType, err := convertUniversalPropertyToAvroType(prop, input)
			if err != nil {
				return err
			}
			field.Type = avroType

			// Handle default values
			if prop.Default != nil {
				field.Default = prop.Default
			}

			avroSchema.Fields = append(avroSchema.Fields, field)
		}
	}

	// Handle array types
	if universal.Type == "array" && universal.Items != nil {
		avroSchema.Type = "array"
		itemType, err := convertUniversalToAvroType(universal.Items, input)
		if err != nil {
			return err
		}
		avroSchema.Items = itemType
	}

	// Handle enum types
	if universal.EnumValues != nil && len(universal.EnumValues) > 0 {
		avroSchema.Type = "enum"
		avroSchema.Symbols = make([]string, len(universal.EnumValues))
		for i, enumValue := range universal.EnumValues {
			avroSchema.Symbols[i] = fmt.Sprintf("%v", enumValue)
		}
	}

	// Handle union types (oneOf/anyOf)
	if universal.OneOf != nil && len(universal.OneOf) > 0 {
		unionTypes := make([]interface{}, len(universal.OneOf))
		for i, schema := range universal.OneOf {
			unionType, err := convertUniversalToAvroType(schema, input)
			if err != nil {
				return err
			}
			unionTypes[i] = unionType
		}
		avroSchema.Type = unionTypes
	}

	return nil
}

// convertUniversalToAvroType converts universal schema to Avro type
func convertUniversalToAvroType(universal *UniversalSchema, input *Input) (interface{}, error) {
	// Handle primitive types
	switch universal.Type {
	case "string":
		return convertStringTypeToAvro(universal, input)
	case "integer":
		return convertIntegerTypeToAvro(universal, input)
	case "number":
		return convertNumberTypeToAvro(universal, input)
	case "boolean":
		return "boolean", nil
	case "array":
		if universal.Items != nil {
			itemType, err := convertUniversalToAvroType(universal.Items, input)
			if err != nil {
				return nil, err
			}
			return map[string]interface{}{
				"type":  "array",
				"items": itemType,
			}, nil
		}
		return map[string]interface{}{
			"type":  "array",
			"items": "string", // Default item type
		}, nil
	case "object":
		return convertObjectTypeToAvro(universal, input)
	}

	// Handle enums
	if universal.EnumValues != nil && len(universal.EnumValues) > 0 {
		symbols := make([]string, len(universal.EnumValues))
		for i, enumValue := range universal.EnumValues {
			symbols[i] = fmt.Sprintf("%v", enumValue)
		}
		return map[string]interface{}{
			"type":    "enum",
			"name":    "EnumType",
			"symbols": symbols,
		}, nil
	}

	// Handle unions (oneOf/anyOf)
	if universal.OneOf != nil && len(universal.OneOf) > 0 {
		unionTypes := make([]interface{}, len(universal.OneOf))
		for i, schema := range universal.OneOf {
			unionType, err := convertUniversalToAvroType(schema, input)
			if err != nil {
				return nil, err
			}
			unionTypes[i] = unionType
		}
		return unionTypes, nil
	}

	// Default to string if type is unknown
	return "string", nil
}

// convertUniversalPropertyToAvroType converts universal property to Avro type
func convertUniversalPropertyToAvroType(prop *UniversalProperty, input *Input) (interface{}, error) {
	baseType, err := getAvroTypeFromUniversalProperty(prop, input)
	if err != nil {
		return nil, err
	}

	// Handle nullable properties
	if prop.Nullable || (prop.Required != nil && !*prop.Required) {
		switch input.AvroUnionMode {
		case "nullable":
			// Create union with null
			return []interface{}{"null", baseType}, nil
		case "strict":
			// Return base type as-is (no null union)
			return baseType, nil
		case "permissive":
			// Create union with null and handle optional fields
			return []interface{}{"null", baseType}, nil
		default:
			return []interface{}{"null", baseType}, nil
		}
	}

	return baseType, nil
}

// getAvroTypeFromUniversalProperty gets Avro type from universal property
func getAvroTypeFromUniversalProperty(prop *UniversalProperty, input *Input) (interface{}, error) {
	switch prop.Type {
	case "string":
		return convertStringPropertyToAvro(prop, input)
	case "integer":
		return convertIntegerPropertyToAvro(prop, input)
	case "number":
		return convertNumberPropertyToAvro(prop, input)
	case "boolean":
		return "boolean", nil
	case "array":
		// Handle array properties
		return map[string]interface{}{
			"type":  "array",
			"items": "string", // Default, could be enhanced
		}, nil
	case "object":
		return convertObjectPropertyToAvro(prop, input)
	}

	// Handle enums
	if prop.EnumValues != nil && len(prop.EnumValues) > 0 {
		symbols := make([]string, len(prop.EnumValues))
		for i, enumValue := range prop.EnumValues {
			symbols[i] = fmt.Sprintf("%v", enumValue)
		}
		return map[string]interface{}{
			"type":    "enum",
			"name":    "PropertyEnum",
			"symbols": symbols,
		}, nil
	}

	// Default to string
	return "string", nil
}

// convertStringTypeToAvro converts string type with logical types if enabled
func convertStringTypeToAvro(universal *UniversalSchema, input *Input) (interface{}, error) {
	if input.AvroLogicalTypes {
		switch universal.Format {
		case "date":
			return map[string]interface{}{
				"type":        "int",
				"logicalType": "date",
			}, nil
		case "time":
			return map[string]interface{}{
				"type":        "int",
				"logicalType": "time-millis",
			}, nil
		case "date-time":
			return map[string]interface{}{
				"type":        "long",
				"logicalType": "timestamp-millis",
			}, nil
		case "uuid":
			return map[string]interface{}{
				"type":        "string",
				"logicalType": "uuid",
			}, nil
		}
	}
	return "string", nil
}

// convertStringPropertyToAvro converts string property with logical types
func convertStringPropertyToAvro(prop *UniversalProperty, input *Input) (interface{}, error) {
	if input.AvroLogicalTypes {
		switch prop.Format {
		case "date":
			return map[string]interface{}{
				"type":        "int",
				"logicalType": "date",
			}, nil
		case "time":
			return map[string]interface{}{
				"type":        "int",
				"logicalType": "time-millis",
			}, nil
		case "date-time":
			return map[string]interface{}{
				"type":        "long",
				"logicalType": "timestamp-millis",
			}, nil
		case "uuid":
			return map[string]interface{}{
				"type":        "string",
				"logicalType": "uuid",
			}, nil
		}
	}
	return "string", nil
}

// convertIntegerTypeToAvro converts integer types
func convertIntegerTypeToAvro(universal *UniversalSchema, input *Input) (interface{}, error) {
	// Determine appropriate Avro integer type based on constraints
	if universal.Constraints != nil {
		if universal.Constraints.Maximum != nil {
			maxVal := *universal.Constraints.Maximum
			if maxVal <= 127 {
				return "int", nil // Could be byte but Avro doesn't have byte
			} else if maxVal <= 32767 {
				return "int", nil // Could be short but Avro doesn't have short
			} else if maxVal <= 2147483647 {
				return "int", nil
			} else {
				return "long", nil
			}
		}
	}
	return "int", nil // Default to int
}

// convertIntegerPropertyToAvro converts integer property
func convertIntegerPropertyToAvro(prop *UniversalProperty, input *Input) (interface{}, error) {
	if prop.Constraints != nil {
		if prop.Constraints.Maximum != nil {
			maxVal := *prop.Constraints.Maximum
			if maxVal <= 2147483647 {
				return "int", nil
			} else {
				return "long", nil
			}
		}
	}
	return "int", nil
}

// convertNumberTypeToAvro converts number types
func convertNumberTypeToAvro(universal *UniversalSchema, input *Input) (interface{}, error) {
	if input.AvroLogicalTypes {
		// Check if it's a decimal type with precision/scale
		if universal.Constraints != nil {
			if universal.Constraints.TotalDigits != nil {
				precision := *universal.Constraints.TotalDigits
				scale := 0
				if universal.Constraints.FractionDigits != nil {
					scale = *universal.Constraints.FractionDigits
				}

				return map[string]interface{}{
					"type":        "bytes",
					"logicalType": "decimal",
					"precision":   precision,
					"scale":       scale,
				}, nil
			}
		}
	}

	switch universal.Format {
	case "float":
		return "float", nil
	case "double":
		return "double", nil
	default:
		return "double", nil // Default to double for numbers
	}
}

// convertNumberPropertyToAvro converts number property
func convertNumberPropertyToAvro(prop *UniversalProperty, input *Input) (interface{}, error) {
	if input.AvroLogicalTypes {
		if prop.Constraints != nil {
			if prop.Constraints.TotalDigits != nil {
				precision := *prop.Constraints.TotalDigits
				scale := 0
				if prop.Constraints.FractionDigits != nil {
					scale = *prop.Constraints.FractionDigits
				}

				return map[string]interface{}{
					"type":        "bytes",
					"logicalType": "decimal",
					"precision":   precision,
					"scale":       scale,
				}, nil
			}
		}
	}

	switch prop.Format {
	case "float":
		return "float", nil
	case "double":
		return "double", nil
	default:
		return "double", nil
	}
}

// convertObjectTypeToAvro converts object types to Avro records
func convertObjectTypeToAvro(universal *UniversalSchema, input *Input) (interface{}, error) {
	record := map[string]interface{}{
		"type": "record",
		"name": "ObjectType",
	}

	if universal.Description != "" {
		record["doc"] = universal.Description
	}

	if universal.Properties != nil && len(universal.Properties) > 0 {
		fields := make([]map[string]interface{}, 0, len(universal.Properties))

		for propName, prop := range universal.Properties {
			field := map[string]interface{}{
				"name": propName,
			}

			if prop.Description != "" {
				field["doc"] = prop.Description
			}

			fieldType, err := convertUniversalPropertyToAvroType(prop, input)
			if err != nil {
				return nil, err
			}
			field["type"] = fieldType

			if prop.Default != nil {
				field["default"] = prop.Default
			}

			fields = append(fields, field)
		}

		record["fields"] = fields
	} else {
		record["fields"] = []map[string]interface{}{}
	}

	return record, nil
}

// convertObjectPropertyToAvro converts object property to Avro record
func convertObjectPropertyToAvro(prop *UniversalProperty, input *Input) (interface{}, error) {
	record := map[string]interface{}{
		"type": "record",
		"name": "PropertyRecord",
	}

	if prop.Description != "" {
		record["doc"] = prop.Description
	}

	if prop.Properties != nil && len(prop.Properties) > 0 {
		fields := make([]map[string]interface{}, 0, len(prop.Properties))

		for propName, nestedProp := range prop.Properties {
			field := map[string]interface{}{
				"name": propName,
			}

			if nestedProp.Description != "" {
				field["doc"] = nestedProp.Description
			}

			fieldType, err := convertUniversalPropertyToAvroType(nestedProp, input)
			if err != nil {
				return nil, err
			}
			field["type"] = fieldType

			if nestedProp.Default != nil {
				field["default"] = nestedProp.Default
			}

			fields = append(fields, field)
		}

		record["fields"] = fields
	} else {
		record["fields"] = []map[string]interface{}{}
	}

	return record, nil
}

// sanitizeAvroName sanitizes names for Avro compatibility
func sanitizeAvroName(name string) string {
	// Avro names must start with [A-Za-z_] and contain only [A-Za-z0-9_]
	sanitized := strings.ReplaceAll(name, "-", "_")
	sanitized = strings.ReplaceAll(sanitized, ":", "_")
	sanitized = strings.ReplaceAll(sanitized, ".", "_")

	// Ensure it starts with a letter or underscore
	if len(sanitized) > 0 && !((sanitized[0] >= 'A' && sanitized[0] <= 'Z') ||
		(sanitized[0] >= 'a' && sanitized[0] <= 'z') || sanitized[0] == '_') {
		sanitized = "_" + sanitized
	}

	return sanitized
}
