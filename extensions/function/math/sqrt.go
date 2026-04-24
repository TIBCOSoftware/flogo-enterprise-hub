package mathfn

import (
	"fmt"
	"math"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnSqrt{})
}

type fnSqrt struct{}

func (fnSqrt) Name() string        { return "sqrt" }
func (fnSqrt) GetCategory() string { return "math" }

func (fnSqrt) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeFloat64}, false
}

// Eval returns the square root of x. Returns an error if x is negative.
func (fnSqrt) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("math.sqrt: params=%+v", params)
	x, err := coerce.ToFloat64(params[0])
	if err != nil {
		return nil, fmt.Errorf("math.sqrt: parameter must be a number, got %v", params[0])
	}
	if x < 0 {
		return nil, fmt.Errorf("math.sqrt: cannot take square root of negative number %v", x)
	}
	result := math.Sqrt(x)
	log.RootLogger().Debugf("math.sqrt: sqrt(%v) = %v", x, result)
	return result, nil
}
