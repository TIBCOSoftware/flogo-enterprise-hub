package pongo2

import (
	"github.com/project-flogo/core/data/coerce"
)

// Settings for the activity
type Settings struct {
	Template string `md:"template,required"`
}

// Input defines the input structure
type Input struct {
	TemplateVariables map[string]interface{} `md:"templateVariables"`
}

// ToMap converts the struct Input into a map
func (i *Input) ToMap() map[string]interface{} {
	return map[string]interface{}{

		"templateVariables": i.TemplateVariables,
	}
}

// FromMap converts the values from a map into the struct Input
func (i *Input) FromMap(values map[string]interface{}) error {
	var err error

	i.TemplateVariables, err = coerce.ToObject(values["templateVariables"])
	if err != nil {
		return err
	}

	return nil
}

// Output defines the output structure
type Output struct {
	RenderedPrompt string `md:"renderedPrompt"`
}

// ToMap converts the struct Output into a map
func (o *Output) ToMap() map[string]interface{} {
	return map[string]interface{}{
		"renderedPrompt": o.RenderedPrompt,
	}
}

// FromMap converts the values from a map into the struct Output
func (o *Output) FromMap(values map[string]interface{}) error {
	var err error

	o.RenderedPrompt, err = coerce.ToString(values["renderedPrompt"])
	if err != nil {
		return err
	}

	return nil
}
