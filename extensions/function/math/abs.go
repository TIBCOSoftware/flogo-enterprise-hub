package mathfn

import (
	"fmt"
	"math"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
)

func init() {
	_ = function.Register(&fnAbs{})
}

type fnAbs struct{}

func (fnAbs) Name() string { return "abs" }

func (fnAbs) GetCategory() string { return "math" }

func (fnAbs) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeFloat64}, false
}

func (fnAbs) Eval(params ...interface{}) (interface{}, error) {
	x, err := coerce.ToFloat64(params[0])
	if err != nil {
		return nil, fmt.Errorf("math.abs: parameter must be a number, got %v", params[0])
	}
	return math.Abs(x), nil
}
