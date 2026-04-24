package arrayfn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/expression/function"
)

func init() {
	_ = function.Register(&fnIndexOf{})
}

type fnIndexOf struct{}

func (fnIndexOf) Name() string { return "indexOf" }

func (fnIndexOf) GetCategory() string { return "array" }

func (fnIndexOf) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeAny, data.TypeAny}, false
}

// Eval returns the zero-based index of the first occurrence of value in the array,
// or -1 if the value is not found. Comparison is done via string representation.
func (fnIndexOf) Eval(params ...interface{}) (interface{}, error) {
	elems, err := toSlice(params[0])
	if err != nil {
		return nil, fmt.Errorf("array.indexOf: %w", err)
	}
	target := fmt.Sprintf("%v", params[1])
	for i, el := range elems {
		if fmt.Sprintf("%v", el) == target {
			return i, nil
		}
	}
	return -1, nil
}
