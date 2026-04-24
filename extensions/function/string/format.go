package stringfn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnFormat{})
}

type fnFormat struct{}

func (fnFormat) Name() string { return "format" }

func (fnFormat) GetCategory() string { return "string" }

func (fnFormat) Sig() (paramTypes []data.Type, isVariadic bool) {
	// template + variadic args
	return []data.Type{data.TypeString}, true
}

// Eval formats a template string using fmt.Sprintf-style verbs with the given arguments.
// The first argument is the format template; remaining arguments are substituted in order.
//
// Example:
//
//	string.format("Hello %s, you have %d messages", "Alice", 3) => "Hello Alice, you have 3 messages"
//	string.format("Price: %.2f", 9.5)                           => "Price: 9.50"
func (fnFormat) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("string.format: params=%+v", params)

	if len(params) == 0 {
		return nil, fmt.Errorf("string.format: requires at least one argument (the template)")
	}

	template, err := coerce.ToString(params[0])
	if err != nil {
		return nil, fmt.Errorf("string.format: template must be a string, got %v", params[0])
	}

	if len(params) == 1 {
		log.RootLogger().Debugf("string.format: no args, returning template as-is")
		return template, nil
	}

	args := params[1:]
	result := fmt.Sprintf(template, args...)
	log.RootLogger().Debugf("string.format: result=%q", result)
	return result, nil
}
