package pongo2

import (
	"testing"

	"github.com/flosch/pongo2/v6"
)

func TestPongo2Syntax(t *testing.T) {
	// Test different or syntaxes
	templates := []string{
		"{% if experience == 10 or experience == 15 %} test {% endif %}",
		"{% if experience == 10 || experience == 15 %} test {% endif %}",
		"{% if experience in \"10,15,20\" %} test {% endif %}",
	}

	for i, tmplStr := range templates {
		tmpl, err := pongo2.FromString(tmplStr)
		if err != nil {
			t.Logf("Template %d failed to parse: %v", i+1, err)
			continue
		}

		result, err := tmpl.Execute(pongo2.Context{"experience": 10})
		if err != nil {
			t.Logf("Template %d failed to execute: %v", i+1, err)
			continue
		}

		t.Logf("Template %d result: \"%s\"", i+1, result)
	}
}
