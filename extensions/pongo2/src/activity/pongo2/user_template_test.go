package pongo2

import (
	"testing"

	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
)

// TestUserProvidedTemplate tests the exact template the user provided
func TestUserProvidedTemplate(t *testing.T) {
	// Set up the exact template the user provided
	template := `You are a {{ role }} working with {{ domain }} data.

**Analysis Objective:** {{ objective }}

**Dataset Overview:**
- Total records: {{ total_records }}
- Columns: {{ num_columns }}
- Missing data: {{ missing_percentage }}%

{% for variable in key_variables %}
**Key Variables:**
- **{{ variable.name }}** ({{ variable.type }}): {{ variable.description }}
{% endfor %}

Please provide your analysis with clear methodology and insights.`

	// Initialize the activity with template in settings
	iCtx := test.NewActivityInitContext(map[string]interface{}{
		"template": template,
	}, nil)
	act, err := New(iCtx)
	assert.NoError(t, err)

	// Create test context
	tc := test.NewActivityContext(act.Metadata())

	// Set up template variables that match the detected schema
	templateVariables := map[string]interface{}{
		"role":               "senior data scientist",
		"domain":             "e-commerce",
		"objective":          "Analyze customer purchase patterns and predict churn risk",
		"total_records":      "250000",
		"num_columns":        "42",
		"missing_percentage": "4.7",
		"key_variables": []map[string]interface{}{
			{
				"name":        "customer_lifetime_value",
				"type":        "numeric",
				"description": "CLV calculated over 24 months",
			},
			{
				"name":        "last_purchase_days",
				"type":        "integer",
				"description": "days since last purchase",
			},
			{
				"name":        "product_category_preference",
				"type":        "categorical",
				"description": "most frequently purchased category",
			},
		},
	}

	// Set inputs
	tc.SetInput("templateVariables", templateVariables)

	// Execute the activity
	done, err := act.Eval(tc)
	assert.True(t, done)
	assert.NoError(t, err)

	// Get the result
	result := tc.GetOutput("renderedPrompt")
	assert.NotNil(t, result)

	renderedPrompt := result.(string)
	t.Logf("Rendered template result:\n%s", renderedPrompt)

	// Verify the template was rendered correctly
	assert.Contains(t, renderedPrompt, "senior data scientist")
	assert.Contains(t, renderedPrompt, "e-commerce")
	assert.Contains(t, renderedPrompt, "Analyze customer purchase patterns")
	assert.Contains(t, renderedPrompt, "250000")
	assert.Contains(t, renderedPrompt, "42")
	assert.Contains(t, renderedPrompt, "4.7%")

	// Verify the loop was processed
	assert.Contains(t, renderedPrompt, "customer_lifetime_value")
	assert.Contains(t, renderedPrompt, "CLV calculated over 24 months")
	assert.Contains(t, renderedPrompt, "last_purchase_days")
	assert.Contains(t, renderedPrompt, "product_category_preference")

	// Verify structure
	assert.Contains(t, renderedPrompt, "**Key Variables:**")
	assert.Contains(t, renderedPrompt, "**Analysis Objective:**")
	assert.Contains(t, renderedPrompt, "**Dataset Overview:**")
}
