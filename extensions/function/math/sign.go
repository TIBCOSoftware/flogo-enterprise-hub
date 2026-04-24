package mathfn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnSign{})
}

type fnSign struct{}

func (fnSign) Name() string        { return "sign" }
func (fnSign) GetCategory() string { return "math" }

func (fnSign) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeFloat64}, false
}

// Eval returns -1 if x < 0, 0 if x == 0, 1 if x > 0.
func (fnSign) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("math.sign: params=%+v", params)
	x, err := coerce.ToFloat64(params[0])
	if err != nil {
		return nil, fmt.Errorf("math.sign: parameter must be a number, got %v", params[0])
	}
	var result float64
	if x < 0 {
		result = -1
	} else if x > 0 {
		result = 1
	} else {
		result = 0
	}
	log.RootLogger().Debugf("math.sign: sign(%v) = %v", x, result)
	return result, nil
}
