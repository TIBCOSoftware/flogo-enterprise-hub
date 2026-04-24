package utilfn

import (
	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/expression/function"
)

func init() {
	_ = function.Register(&fnCoalesce{})
}

type fnCoalesce struct{}

func (fnCoalesce) Name() string { return "coalesce" }

func (fnCoalesce) GetCategory() string { return "util" }

func (fnCoalesce) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeAny}, true
}

// Eval returns the first argument that is non-nil and non-empty-string.
// Accepts any number of arguments. Returns nil if all arguments are nil or empty.
//
// Examples:
//
//	util.coalesce(nil, "", "hello")     => "hello"
//	util.coalesce($flow.optional, "default") => value of optional if set, else "default"
func (fnCoalesce) Eval(params ...interface{}) (interface{}, error) {
	for _, p := range params {
		if p == nil {
			continue
		}
		if s, ok := p.(string); ok && s == "" {
			continue
		}
		return p, nil
	}
	return nil, nil
}
