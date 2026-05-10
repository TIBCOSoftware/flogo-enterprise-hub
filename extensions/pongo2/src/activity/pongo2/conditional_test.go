package pongo2

import (
	"testing"
)

func TestConditionalLogicWithExperience(t *testing.T) {
	// Test the specific conditional logic issue reported by user
	initCtx := &MockInitContext{
		settings: map[string]interface{}{
			"template": `Hello {{ name }}! Welcome to {{ company }}.
Your role is {{ role }}{% if experience == 0 %} and welcome to your first professional role!{% elif experience > 0 %} and well done on your {{ experience|floatformat:0 }} years of experience!{% endif %}{% if experience == 10 or experience == 15 or experience == 20 %} We truly appreciate your significant contribution to the industry.{% endif %}`,
		},
	}

	act, err := New(initCtx)
	if err != nil {
		t.Fatalf("Failed to create activity: %v", err)
	}

	// Test Case 1: experience = 0
	t.Run("Experience Zero", func(t *testing.T) {
		evalCtx := &MockActivityContext{
			inputs: map[string]interface{}{
				"templateVariables": map[string]interface{}{
					"name":       "Shiv",
					"company":    "TIBCO",
					"role":       "Developer",
					"experience": 0,
				},
			},
			outputs: make(map[string]interface{}),
		}

		success, err := act.Eval(evalCtx)
		if err != nil || !success {
			t.Fatalf("Failed to evaluate activity: %v", err)
		}

		result := evalCtx.outputs["renderedPrompt"].(string)
		expected := "Hello Shiv! Welcome to TIBCO.\nYour role is Developer and welcome to your first professional role!"

		t.Logf("Expected: %s", expected)
		t.Logf("Got: %s", result)

		if !contains(result, "welcome to your first professional role!") {
			t.Errorf("Expected to contain 'welcome to your first professional role!' for experience=0")
		}
	})

	// Test Case 2: experience = 5
	t.Run("Experience Five", func(t *testing.T) {
		evalCtx := &MockActivityContext{
			inputs: map[string]interface{}{
				"templateVariables": map[string]interface{}{
					"name":       "Shiv",
					"company":    "TIBCO",
					"role":       "Developer",
					"experience": 5,
				},
			},
			outputs: make(map[string]interface{}),
		}

		success, err := act.Eval(evalCtx)
		if err != nil || !success {
			t.Fatalf("Failed to evaluate activity: %v", err)
		}

		result := evalCtx.outputs["renderedPrompt"].(string)
		t.Logf("Result for experience=5: %s", result)

		if !contains(result, "well done on your 5 years of experience!") {
			t.Errorf("Expected to contain 'well done on your 5 years of experience!' for experience=5, got: %s", result)
		}
		if contains(result, "5.000000") {
			t.Errorf("Should not contain decimal formatting '5.000000', got: %s", result)
		}
	})

	// Test Case 3: experience = 10 (milestone)
	t.Run("Experience Ten", func(t *testing.T) {
		evalCtx := &MockActivityContext{
			inputs: map[string]interface{}{
				"templateVariables": map[string]interface{}{
					"name":       "Shiv",
					"company":    "TIBCO",
					"role":       "Developer",
					"experience": 10,
				},
			},
			outputs: make(map[string]interface{}),
		}

		success, err := act.Eval(evalCtx)
		if err != nil || !success {
			t.Fatalf("Failed to evaluate activity: %v", err)
		}

		result := evalCtx.outputs["renderedPrompt"].(string)
		t.Logf("Result for experience=10: %s", result)

		if !contains(result, "well done on your 10 years of experience!") {
			t.Errorf("Expected to contain 'well done on your 10 years of experience!' for experience=10")
		}
		if !contains(result, "We truly appreciate your significant contribution to the industry.") {
			t.Errorf("Expected to contain appreciation message for experience=10")
		}
		if contains(result, "10.000000") {
			t.Errorf("Should not contain decimal formatting '10.000000', got: %s", result)
		}
	})
}

func TestSchemaProviderDataTypes(t *testing.T) {
	// Test that schema provider correctly identifies numeric vs string types
	provider := &TemplateSchemaProvider{}

	template := `Hello {{ name }}! You are {{ age }} years old and have {{ experience }} years of experience.`

	settings := map[string]interface{}{
		"template": template,
	}

	schema, err := provider.GetInputSchema(settings)
	if err != nil {
		t.Fatalf("Failed to get schema: %v", err)
	}

	t.Logf("Generated schema: %+v", schema)

	// Check that all variables are detected
	properties, ok := schema["properties"].(map[string]interface{})
	if !ok {
		t.Fatalf("Schema properties should be a map")
	}

	if _, exists := properties["name"]; !exists {
		t.Errorf("Schema should contain 'name' property")
	}
	if _, exists := properties["age"]; !exists {
		t.Errorf("Schema should contain 'age' property")
	}
	if _, exists := properties["experience"]; !exists {
		t.Errorf("Schema should contain 'experience' property")
	}
}
