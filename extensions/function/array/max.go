package arrayfn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/expression/function"
)

func init() {
	_ = function.Register(&fnMax{})
}

type fnMax struct{}

func (fnMax) Name() string { return "max" }

func (fnMax) GetCategory() string { return "array" }

func (fnMax) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeAny}, false
}

func (fnMax) Eval(params ...interface{}) (interface{}, error) {
	nums, err := toFloat64Slice(params[0])
	if err != nil {
		return nil, fmt.Errorf("array.max: %w", err)
	}
	max := nums[0]
	for _, n := range nums[1:] {
		if n > max {
			max = n
		}
	}
	return max, nil
}
