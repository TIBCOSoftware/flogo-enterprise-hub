package pongo2

import (
	"fmt"
	"strings"

	"github.com/flosch/pongo2/v6"
	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/data/metadata"
)

// activityMd holds the metadata for this activity
var activityMd = activity.ToMetadata(&Settings{}, &Input{}, &Output{})

// Activity represents the pongo2-prompt activity
type Activity struct {
	template string
}

func init() {
	_ = activity.Register(&Activity{}, New)
}

// Metadata returns the activity's metadata.
func (a *Activity) Metadata() *activity.Metadata {
	return activityMd
}

// New creates a new instance of the Activity.
func New(ctx activity.InitContext) (activity.Activity, error) {
	// No initialization needed since template is now an input
	s := &Settings{}
	err := metadata.MapToStruct(ctx.Settings(), s, true)
	if err != nil {
		return nil, err
	}
	ctx.Logger().Info("Pongo2-prompt activity initialized - template will be processed at runtime")
	return &Activity{template: s.Template}, nil
}

// Eval executes the activity
func (a *Activity) Eval(ctx activity.Context) (bool, error) {
	if ctx == nil {
		return false, fmt.Errorf("activity context is nil")
	}

	// Get the template from input
	templateInput := a.template

	if templateInput == "" {
		return false, fmt.Errorf("template cannot be empty")
	}

	// Log template analysis for debugging
	variables := extractTemplateVariables(templateInput)
	if len(variables) > 0 {
		ctx.Logger().Infof("Template variables detected: %v", variables)
		schema := generateJSONSchemaForTemplate(templateInput)
		ctx.Logger().Debugf("Generated JSON schema: %s", schema)
	}

	// Create a context for template variables
	templateVars := pongo2.Context{}

	// Get template variables from the schema-based input
	if templateVariablesInput := ctx.GetInput("templateVariables"); templateVariablesInput != nil {
		if tvMap, ok := templateVariablesInput.(map[string]interface{}); ok {
			for key, value := range tvMap {
				if value != nil { // Only include non-nil values
					templateVars[key] = value
				}
			}
			ctx.Logger().Debugf("Loaded %d template variables from input fields", len(templateVars))
		}
	}

	if len(templateVars) == 0 {
		ctx.Logger().Info("No variables provided to template")
	} else {
		ctx.Logger().Debugf("Template context prepared with %d variables", len(templateVars))
	}

	// Extract expected variables for validation and user feedback
	expectedVars := extractTemplateVariables(templateInput)
	if len(expectedVars) > 0 {
		// Check for missing variables and warn
		var missingVars []string
		for _, expectedVar := range expectedVars {
			if _, exists := templateVars[expectedVar]; !exists {
				missingVars = append(missingVars, expectedVar)
			}
		}
		if len(missingVars) > 0 {
			ctx.Logger().Warnf("Template expects variables that are not provided: %v", missingVars)
			ctx.Logger().Info("Provide missing variables through the template variables input fields")
		}
	}

	// Parse and render the template
	template, err := pongo2.FromString(templateInput)
	if err != nil {
		return false, fmt.Errorf("failed to parse template: %w", err)
	}

	renderedPrompt, err := template.Execute(templateVars)
	if err != nil {
		return false, fmt.Errorf("failed to render template: %w", err)
	}

	trimmedOutput := strings.TrimSpace(renderedPrompt)
	ctx.Logger().Debugf("Template rendered successfully, original output length: %d characters", len(renderedPrompt))
	ctx.Logger().Debugf("After trimming, output length: %d characters", len(trimmedOutput))

	// Check if output is empty and log detailed information
	if len(trimmedOutput) == 0 {
		ctx.Logger().Warnf("WARNING: Rendered output is empty!")
		ctx.Logger().Warnf("Original template: '%s'", templateInput)
		ctx.Logger().Warnf("Template variables provided: %v", templateVars)
		ctx.Logger().Warnf("Raw rendered output: '%s'", renderedPrompt)
	} else {
		ctx.Logger().Infof("Setting output 'renderedPrompt' with %d characters", len(trimmedOutput))
	}

	// Set the output
	ctx.SetOutput("renderedPrompt", trimmedOutput)
	ctx.Logger().Debugf("Output 'renderedPrompt' has been set successfully")

	return true, nil
}
