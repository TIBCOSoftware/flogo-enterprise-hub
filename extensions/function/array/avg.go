package arrayfn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/expression/function"
)

func init() {
	_ = function.Register(&fnAvg{})
}

type fnAvg struct{}

func (fnAvg) Name() string { return "avg" }

func (fnAvg) GetCategory() string { return "array" }

func (fnAvg) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeAny}, false
}

func (fnAvg) Eval(params ...interface{}) (interface{}, error) {
	nums, err := toFloat64Slice(params[0])
	if err != nil {
		return nil, fmt.Errorf("array.avg: %w", err)
	}
	var total float64
	for _, n := range nums {
		total += n
	}
	return total / float64(len(nums)), nil
}
