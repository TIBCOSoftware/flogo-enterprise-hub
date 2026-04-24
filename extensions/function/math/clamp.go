package mathfn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnClamp{})
}

type fnClamp struct{}

func (fnClamp) Name() string        { return "clamp" }
func (fnClamp) GetCategory() string { return "math" }

func (fnClamp) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeFloat64, data.TypeFloat64, data.TypeFloat64}, false
}

// Eval clamps val to the inclusive range [min, max].
// Returns min if val < min, max if val > max, otherwise val.
func (fnClamp) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("math.clamp: params=%+v", params)
	val, err := coerce.ToFloat64(params[0])
	if err != nil {
		return nil, fmt.Errorf("math.clamp: first parameter (val) must be a number, got %v", params[0])
	}
	min, err := coerce.ToFloat64(params[1])
	if err != nil {
		return nil, fmt.Errorf("math.clamp: second parameter (min) must be a number, got %v", params[1])
	}
	max, err := coerce.ToFloat64(params[2])
	if err != nil {
		return nil, fmt.Errorf("math.clamp: third parameter (max) must be a number, got %v", params[2])
	}
	if min > max {
		return nil, fmt.Errorf("math.clamp: min (%v) must be <= max (%v)", min, max)
	}
	var result float64
	if val < min {
		result = min
	} else if val > max {
		result = max
	} else {
		result = val
	}
	log.RootLogger().Debugf("math.clamp: clamp(%v, %v, %v) = %v", val, min, max, result)
	return result, nil
}
