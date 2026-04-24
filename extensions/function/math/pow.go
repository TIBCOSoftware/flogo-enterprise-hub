package mathfn

import (
	"fmt"
	"math"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
)

func init() {
	_ = function.Register(&fnPow{})
}

type fnPow struct{}

func (fnPow) Name() string { return "pow" }

func (fnPow) GetCategory() string { return "math" }

func (fnPow) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeFloat64, data.TypeFloat64}, false
}

func (fnPow) Eval(params ...interface{}) (interface{}, error) {
	base, err := coerce.ToFloat64(params[0])
	if err != nil {
		return nil, fmt.Errorf("math.pow: base must be a number, got %v", params[0])
	}
	exp, err := coerce.ToFloat64(params[1])
	if err != nil {
		return nil, fmt.Errorf("math.pow: exponent must be a number, got %v", params[1])
	}
	return math.Pow(base, exp), nil
}
