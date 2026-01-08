package pongo2

import (
	"testing"

	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/mapper"
	"github.com/project-flogo/core/support/log"
	"github.com/project-flogo/core/support/trace"
)

func TestJinja2PromptActivity(t *testing.T) {
	// Test basic template rendering using template variables
	initCtx := &MockInitContext{
		settings: map[string]interface{}{
			"template": "Hello {{ name }}! You are {{ age }} years old.",
		},
	}

	act, err := New(initCtx)
	if err != nil {
		t.Fatalf("Failed to create activity: %v", err)
	}

	evalCtx := &MockActivityContext{
		inputs: map[string]interface{}{
			"templateVariables": map[string]interface{}{
				"name": "Alice",
				"age":  30,
			},
		},
		outputs: make(map[string]interface{}),
	}

	success, err := act.Eval(evalCtx)
	if err != nil || !success {
		t.Fatalf("Failed to evaluate activity: %v", err)
	}

	result := evalCtx.outputs["renderedPrompt"].(string)
	expected := "Hello Alice! You are 30 years old."

	if result != expected {
		t.Errorf("Expected '%s', got '%s'", expected, result)
	}
}

func TestJinja2PromptActivityWithVariablesMap(t *testing.T) {
	// Test using template variables input
	initCtx := &MockInitContext{
		settings: map[string]interface{}{
			"template": "Task: {{ task }}\nContext: {{ context }}\nPlease {{ instruction }}.",
		},
	}

	act, err := New(initCtx)
	if err != nil {
		t.Fatalf("Failed to create activity: %v", err)
	}

	evalCtx := &MockActivityContext{
		inputs: map[string]interface{}{
			"templateVariables": map[string]interface{}{
				"task":        "Analyze the sentiment",
				"context":     "customer feedback",
				"instruction": "provide a detailed analysis",
			},
		},
		outputs: make(map[string]interface{}),
	}

	success, err := act.Eval(evalCtx)
	if err != nil || !success {
		t.Fatalf("Failed to evaluate activity: %v", err)
	}

	result := evalCtx.outputs["renderedPrompt"].(string)
	expected := "Task: Analyze the sentiment\nContext: customer feedback\nPlease provide a detailed analysis."

	if result != expected {
		t.Errorf("Expected '%s', got '%s'", expected, result)
	}
}

func TestJinja2PromptActivityComplexTemplate(t *testing.T) {
	// Test complex AI prompt template
	template := `You are a {{ role }}.

Context:
{{ context }}

Task: {{ task }}

{% if examples -%}
Examples:
{{ examples }}
{% endif -%}

Please respond with {{ format }}.`

	initCtx := &MockInitContext{
		settings: map[string]interface{}{
			"template": template,
		},
	}

	act, err := New(initCtx)
	if err != nil {
		t.Fatalf("Failed to create activity: %v", err)
	}

	evalCtx := &MockActivityContext{
		inputs: map[string]interface{}{
			"template": template,
			"templateVariables": map[string]interface{}{
				"role":     "helpful AI assistant",
				"context":  "The user needs help with Go programming",
				"task":     "explain how to create a REST API",
				"examples": "Example 1: Use gin framework\nExample 2: Use standard library",
				"format":   "step-by-step instructions",
			},
		},
		outputs: make(map[string]interface{}),
	}

	success, err := act.Eval(evalCtx)
	if err != nil || !success {
		t.Fatalf("Failed to evaluate activity: %v", err)
	}

	result := evalCtx.outputs["renderedPrompt"].(string)

	// Check that template was processed (contains expected parts)
	if !contains(result, "You are a helpful AI assistant") {
		t.Errorf("Result should contain role replacement: %s", result)
	}
	if !contains(result, "The user needs help with Go programming") {
		t.Errorf("Result should contain context replacement: %s", result)
	}
	if !contains(result, "explain how to create a REST API") {
		t.Errorf("Result should contain task replacement: %s", result)
	}
}

func TestDataAnalysisTemplate(t *testing.T) {
	// Test the complex data analysis template (simplified for pongo2 compatibility)
	template := `You are a data analyst working with {{ dataset_type }} data.

**Analysis Objective:** {{ objective }}

**Dataset Overview:**
- Total records: {{ data_info.records }}
- Columns: {{ data_info.columns }}
- Missing data: {{ missing_percentage }}%
{% if missing_percentage > 10 %}
⚠️ High percentage of missing data detected!
{% endif %}

**Key Variables:**
{% for var in variables %}
- **{{ var.name }}** ({{ var.type }}){% if var.description %}: {{ var.description }}{% endif %}{% if var.unique_values %} - {{ var.unique_values }} unique values{% endif %}
{% endfor %}

{% if hypotheses %}
**Research Hypotheses:**
{% for hypothesis in hypotheses %}
H{{ forloop.Counter }}: {{ hypothesis }}
{% endfor %}
{% endif %}

**Analysis Tasks:**
{% for task in tasks %}
{{ forloop.Counter }}. {{ task }}
{% endfor %}

{% if constraints %}
**Constraints & Considerations:**
{% for constraint in constraints %}
- {{ constraint }}
{% endfor %}
{% endif %}

Please provide your analysis with clear methodology, findings, and actionable insights.`

	initCtx := &MockInitContext{
		settings: map[string]interface{}{
			"template": template,
		},
	}

	act, err := New(initCtx)
	if err != nil {
		t.Fatalf("Failed to create activity: %v", err)
	}

	// Create the complex data structure
	variables := []map[string]interface{}{
		{
			"name":          "customer_tenure",
			"type":          "numeric",
			"description":   "months since first purchase",
			"unique_values": nil,
		},
		{
			"name":          "subscription_type",
			"type":          "categorical",
			"description":   "premium, standard, or basic",
			"unique_values": 3,
		},
		{
			"name":          "support_tickets",
			"type":          "numeric",
			"description":   "number of support requests",
			"unique_values": nil,
		},
	}

	hypotheses := []string{
		"Customers with longer tenure have higher retention rates",
		"Premium subscribers are more likely to be retained",
		"High support ticket volume correlates with churn",
	}

	tasks := []string{
		"Perform exploratory data analysis",
		"Calculate retention rates by segment",
		"Build predictive model for churn",
		"Identify top retention factors",
	}

	constraints := []string{
		"Protect customer PII",
		"Use only last 2 years of data",
		"Model must be interpretable",
	}

	// Pre-calculate missing percentage
	missingPercentage := float64(12000) / float64(150000) * 100

	evalCtx := &MockActivityContext{
		inputs: map[string]interface{}{
			"templateVariables": map[string]interface{}{
				"dataset_type": "customer behavior",
				"objective":    "Identify factors influencing customer retention",
				"data_info": map[string]interface{}{
					"records": 150000,
					"columns": 23,
				},
				"missing_percentage": missingPercentage,
				"variables":          variables,
				"hypotheses":         hypotheses,
				"tasks":              tasks,
				"constraints":        constraints,
			},
		},
		outputs: make(map[string]interface{}),
	}

	success, err := act.Eval(evalCtx)
	if err != nil || !success {
		t.Fatalf("Failed to evaluate activity: %v", err)
	}

	result := evalCtx.outputs["renderedPrompt"].(string)

	// Print the result to see what we get
	t.Logf("Rendered template result:\n%s", result)

	// Check that some basic parts were processed correctly
	if !contains(result, "customer behavior data") {
		t.Errorf("Result should contain dataset_type: %s", result)
	}
	if !contains(result, "Identify factors influencing customer retention") {
		t.Errorf("Result should contain objective: %s", result)
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > len(substr) && (s[:len(substr)] == substr || s[len(s)-len(substr):] == substr || containsInMiddle(s, substr)))
}

func containsInMiddle(s, substr string) bool {
	for i := 1; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

// MockInitContext is a mock implementation of activity.InitContext for testing purposes.
type MockInitContext struct {
	settings map[string]interface{}
}

func (m *MockInitContext) Settings() map[string]interface{} {
	return m.settings
}

func (m *MockInitContext) MapperFactory() mapper.Factory {
	return nil
}

func (m *MockInitContext) Logger() log.Logger {
	return &MockLogger{}
}

func (m *MockInitContext) GetSetting(setting string) (value interface{}, exists bool) {
	val, exists := m.settings[setting]
	return val, exists
}

func (m *MockInitContext) HostName() string {
	return "test-host"
}

func (m *MockInitContext) Name() string {
	return "test-activity"
}

// MockActivityContext is a mock implementation of activity.Context for testing purposes.
type MockActivityContext struct {
	inputs  map[string]interface{}
	outputs map[string]interface{}
}

func (m *MockActivityContext) GetInput(name string) interface{} {
	return m.inputs[name]
}

func (m *MockActivityContext) GetInputs() map[string]interface{} {
	return m.inputs
}

func (m *MockActivityContext) SetOutput(name string, value interface{}) error {
	m.outputs[name] = value
	return nil
}

func (m *MockActivityContext) GetOutput(name string) interface{} {
	return m.outputs[name]
}

func (m *MockActivityContext) Logger() log.Logger {
	return &MockLogger{}
}

func (m *MockActivityContext) ActivityHost() activity.Host {
	return nil
}

func (m *MockActivityContext) Name() string {
	return "TestActivity"
}

func (m *MockActivityContext) GetSharedTempData() map[string]interface{} {
	return nil
}

func (m *MockActivityContext) GetInputObject(input data.StructValue) error {
	return nil
}

func (m *MockActivityContext) GetTracingContext() trace.TracingContext {
	return nil
}

func (m *MockActivityContext) SetOutputObject(output data.StructValue) error {
	return nil
}

// MockLogger is a mock implementation of log.Logger for testing purposes.
type MockLogger struct{}

func (l *MockLogger) Debug(args ...interface{})                   {}
func (l *MockLogger) Debugf(template string, args ...interface{}) {}
func (l *MockLogger) Info(args ...interface{})                    {}
func (l *MockLogger) Infof(template string, args ...interface{})  {}
func (l *MockLogger) Warn(args ...interface{})                    {}
func (l *MockLogger) Warnf(template string, args ...interface{})  {}
func (l *MockLogger) Error(args ...interface{})                   {}
func (l *MockLogger) Errorf(template string, args ...interface{}) {}
func (l *MockLogger) Fatal(args ...interface{})                   {}
func (l *MockLogger) Fatalf(template string, args ...interface{}) {}
func (l *MockLogger) DebugEnabled() bool                          { return false }
func (l *MockLogger) InfoEnabled() bool                           { return false }
func (l *MockLogger) WarnEnabled() bool                           { return false }
func (l *MockLogger) ErrorEnabled() bool                          { return false }
func (l *MockLogger) Structured() log.StructuredLogger            { return nil }
func (l *MockLogger) Trace(args ...interface{})                   {}
func (l *MockLogger) Tracef(template string, args ...interface{}) {}
func (l *MockLogger) TraceEnabled() bool                          { return false }

func TestTemplateVariablesInput(t *testing.T) {
	// Test the new templateVariables input approach (simulating Flogo Web UI individual fields)
	initCtx := &MockInitContext{
		settings: map[string]interface{}{
			"template": "Hello {{ name }}! You are a {{ role }} aged {{ age }}.",
		},
	}

	act, err := New(initCtx)
	if err != nil {
		t.Fatalf("Failed to create activity: %v", err)
	}

	// Simulate individual template variable inputs from Flogo Web UI
	evalCtx := &MockActivityContext{
		inputs: map[string]interface{}{
			"templateVariables": map[string]interface{}{
				"name": "Alice",
				"role": "developer",
				"age":  "30",
			},
		},
		outputs: make(map[string]interface{}),
	}

	success, err := act.Eval(evalCtx)
	if err != nil || !success {
		t.Fatalf("Failed to evaluate activity: %v", err)
	}

	result := evalCtx.outputs["renderedPrompt"].(string)
	expected := "Hello Alice! You are a developer aged 30."

	if result != expected {
		t.Errorf("Expected '%s', got '%s'", expected, result)
	}
}

func TestCombinedInputApproaches(t *testing.T) {
	// Test templateVariables input with multiple variables
	initCtx := &MockInitContext{
		settings: map[string]interface{}{
			"template": "Name: {{ name }}, Role: {{ role }}, Extra: {{ extra }}",
		},
	}

	act, err := New(initCtx)
	if err != nil {
		t.Fatalf("Failed to create activity: %v", err)
	}

	evalCtx := &MockActivityContext{
		inputs: map[string]interface{}{
			"templateVariables": map[string]interface{}{
				"name":  "Alice",
				"role":  "developer",
				"extra": "additional_data",
			},
		},
		outputs: make(map[string]interface{}),
	}

	success, err := act.Eval(evalCtx)
	if err != nil || !success {
		t.Fatalf("Failed to evaluate activity: %v", err)
	}

	result := evalCtx.outputs["renderedPrompt"].(string)
	expected := "Name: Alice, Role: developer, Extra: additional_data"

	if result != expected {
		t.Errorf("Expected '%s', got '%s'", expected, result)
	}
}

func TestJSONSchemaGeneration(t *testing.T) {
	// Test the JSON schema generation function
	template := "Hello {{ name }}! You are {{ age }} years old and work as a {{ role }}."

	schema := generateJSONSchemaForTemplate(template)

	// Basic validation that schema contains expected elements
	if !contains(schema, "name") {
		t.Errorf("Schema should contain 'name' property")
	}
	if !contains(schema, "age") {
		t.Errorf("Schema should contain 'age' property")
	}
	if !contains(schema, "role") {
		t.Errorf("Schema should contain 'role' property")
	}
	if !contains(schema, "$schema") {
		t.Errorf("Schema should contain '$schema' property")
	}

	t.Logf("Generated schema: %s", schema)
}
