package arrayfn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/expression/function"
)

func init() {
	_ = function.Register(&fnUnique{})
}

type fnUnique struct{}

func (fnUnique) Name() string { return "unique" }

func (fnUnique) GetCategory() string { return "array" }

func (fnUnique) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeAny}, false
}

// Eval returns a new array with duplicate values removed, preserving original order.
// Elements are compared by their fmt.Sprintf("%v") string representation, which
// handles primitives and nested objects uniformly without panicking on unhashable types.
func (fnUnique) Eval(params ...interface{}) (interface{}, error) {
	elems, err := toSlice(params[0])
	if err != nil {
		return nil, fmt.Errorf("array.unique: %w", err)
	}
	seen := make(map[string]bool, len(elems))
	result := make([]interface{}, 0, len(elems))
	for _, el := range elems {
		key := fmt.Sprintf("%v", el)
		if !seen[key] {
			seen[key] = true
			result = append(result, el)
		}
	}
	return result, nil
}
