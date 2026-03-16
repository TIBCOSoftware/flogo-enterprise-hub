package pongo2

import (
	"encoding/json"
	"regexp"
	"strings"
)

// SchemaProvider interface for dynamic schema generation
type SchemaProvider interface {
	GetInputSchema(settings map[string]interface{}) (map[string]interface{}, error)
}

// TemplateSchemaProvider generates schema based on template content
type TemplateSchemaProvider struct{}

// GetInputSchema generates schema for template variables based on template content
func (tsp *TemplateSchemaProvider) GetInputSchema(settings map[string]interface{}) (map[string]interface{}, error) {
	template, ok := settings["template"].(string)
	if !ok || template == "" {
		return nil, nil
	}

	variables := extractTemplateVariables(template)
	forLoopArrays := extractForLoopArrays(template)

	properties := make(map[string]interface{})
	for _, variable := range variables {
		if isArrayVariable(variable, forLoopArrays) {
			properties[variable] = map[string]interface{}{
				"type":        "array",
				"description": "Array variable used in for loop: {{ " + variable + " }}",
				"items": map[string]interface{}{
					"type":                 "object",
					"additionalProperties": true,
				},
			}
		} else {
			properties[variable] = map[string]interface{}{
				"type":        "string",
				"description": "Template variable: {{ " + variable + " }}",
			}
		}
	}

	schema := map[string]interface{}{
		"$schema":    "http://json-schema.org/draft-04/schema#",
		"type":       "object",
		"properties": properties,
	}

	return schema, nil
}

// extractTemplateVariables extracts variable names from pongo2 template using regex
func extractTemplateVariables(template string) []string {
	// Regex to match {{ variable_name|filter }} or {{ variable_name }} patterns
	// This captures everything inside {{ }} and then extracts the variable name before any filters
	re := regexp.MustCompile(`\{\{\s*([^}|]+)(?:\|[^}]*)?\s*\}\}`)
	matches := re.FindAllStringSubmatch(template, -1)

	var variables []string
	seen := make(map[string]bool)
	for _, match := range matches {
		if len(match) > 1 {
			varName := strings.TrimSpace(match[1])
			if varName != "" && !seen[varName] {
				variables = append(variables, varName)
				seen[varName] = true
			}
		}
	}
	return variables
}

// isLoopIterator checks if a variable name is a loop iterator
func isLoopIterator(varName string, template string) bool {
	pattern := `\{\%\s*for\s+` + regexp.QuoteMeta(varName) + `\s+in\s+`
	re := regexp.MustCompile(pattern)
	return re.MatchString(template)
}

// extractForLoopArrays finds arrays used in for loops
func extractForLoopArrays(template string) []string {
	re := regexp.MustCompile(`\{\%\s*for\s+\w+\s+in\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*\%\}`)
	matches := re.FindAllStringSubmatch(template, -1)

	var arrays []string
	for _, match := range matches {
		if len(match) > 1 {
			arrays = append(arrays, match[1])
		}
	}
	return arrays
}

// isArrayVariable checks if a variable is an array used in for loops
func isArrayVariable(variable string, forLoopArrays []string) bool {
	for _, array := range forLoopArrays {
		if variable == array {
			return true
		}
	}
	return false
}

// generateJSONSchemaForTemplate creates a JSON schema based on detected template variables
func generateJSONSchemaForTemplate(template string) string {
	variables := extractTemplateVariables(template)

	// Detect arrays used in for loops
	forLoopArrays := extractForLoopArrays(template)

	// Add for loop arrays to variables if not already detected
	for _, array := range forLoopArrays {
		found := false
		for _, variable := range variables {
			if variable == array {
				found = true
				break
			}
		}
		if !found {
			variables = append(variables, array)
		}
	}

	properties := make(map[string]interface{})
	for _, variable := range variables {
		// Check if this variable is used in a for loop
		if isArrayVariable(variable, forLoopArrays) {
			properties[variable] = map[string]interface{}{
				"type":        "array",
				"description": "Array variable used in for loop: {{ " + variable + " }}",
				"items": map[string]interface{}{
					"type":                 "object",
					"additionalProperties": true,
				},
			}
		} else {
			properties[variable] = map[string]interface{}{
				"type":        "string",
				"description": "Template variable: {{ " + variable + " }}",
			}
		}
	}

	schema := map[string]interface{}{
		"$schema":    "http://json-schema.org/draft-04/schema#",
		"type":       "object",
		"properties": properties,
	}

	schemaBytes, _ := json.Marshal(schema)
	return string(schemaBytes)
}

// GetTemplateSchemaAsJSON returns JSON schema as string for template variables
func GetTemplateSchemaAsJSON(template string) string {
	provider := &TemplateSchemaProvider{}
	settings := map[string]interface{}{
		"template": template,
	}

	schema, err := provider.GetInputSchema(settings)
	if err != nil || schema == nil {
		return "{}"
	}

	schemaBytes, err := json.Marshal(schema)
	if err != nil {
		return "{}"
	}

	return string(schemaBytes)
}

// ExtensionMetadata provides metadata for Flogo Web UI extensions
type ExtensionMetadata struct {
	Name           string                 `json:"name"`
	Type           string                 `json:"type"`
	Version        string                 `json:"version"`
	Title          string                 `json:"title"`
	Description    string                 `json:"description"`
	SchemaProvider SchemaProvider         `json:"-"`
	DynamicInputs  map[string]interface{} `json:"dynamicInputs,omitempty"`
}

// GetExtensionMetadata returns metadata for this activity extension
func GetExtensionMetadata() *ExtensionMetadata {
	return &ExtensionMetadata{
		Name:           "pongo2-prompt",
		Type:           "flogo:activity",
		Version:        "1.0.0",
		Title:          "Pongo2 AI Prompt Template",
		Description:    "Processes Pongo2/Django templates for AI prompts with dynamic variable mapping",
		SchemaProvider: &TemplateSchemaProvider{},
		DynamicInputs: map[string]interface{}{
			"templateVariables": map[string]interface{}{
				"dependsOn":       "template",
				"schemaGenerator": "template",
			},
		},
	}
}
