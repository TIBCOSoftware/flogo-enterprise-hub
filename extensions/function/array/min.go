package arrayfn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/expression/function"
)

func init() {
	_ = function.Register(&fnMin{})
}

type fnMin struct{}

func (fnMin) Name() string { return "min" }

func (fnMin) GetCategory() string { return "array" }

func (fnMin) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeAny}, false
}

func (fnMin) Eval(params ...interface{}) (interface{}, error) {
	nums, err := toFloat64Slice(params[0])
	if err != nil {
		return nil, fmt.Errorf("array.min: %w", err)
	}
	min := nums[0]
	for _, n := range nums[1:] {
		if n < min {
			min = n
		}
	}
	return min, nil
}
