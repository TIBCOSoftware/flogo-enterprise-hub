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
	_ = function.Register(&fnLog{})
	_ = function.Register(&fnLog2{})
	_ = function.Register(&fnLog10{})
}

// --- math.log (natural log) ---

type fnLog struct{}

func (fnLog) Name() string        { return "log" }
func (fnLog) GetCategory() string { return "math" }

func (fnLog) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeFloat64}, false
}

func (fnLog) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("math.log: params=%+v", params)
	x, err := coerce.ToFloat64(params[0])
	if err != nil {
		return nil, fmt.Errorf("math.log: parameter must be a number, got %v", params[0])
	}
	if x <= 0 {
		return nil, fmt.Errorf("math.log: argument must be positive, got %v", x)
	}
	result := math.Log(x)
	log.RootLogger().Debugf("math.log: ln(%v) = %v", x, result)
	return result, nil
}

// --- math.log2 ---

type fnLog2 struct{}

func (fnLog2) Name() string        { return "log2" }
func (fnLog2) GetCategory() string { return "math" }

func (fnLog2) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeFloat64}, false
}

func (fnLog2) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("math.log2: params=%+v", params)
	x, err := coerce.ToFloat64(params[0])
	if err != nil {
		return nil, fmt.Errorf("math.log2: parameter must be a number, got %v", params[0])
	}
	if x <= 0 {
		return nil, fmt.Errorf("math.log2: argument must be positive, got %v", x)
	}
	result := math.Log2(x)
	log.RootLogger().Debugf("math.log2: log2(%v) = %v", x, result)
	return result, nil
}

// --- math.log10 ---

type fnLog10 struct{}

func (fnLog10) Name() string        { return "log10" }
func (fnLog10) GetCategory() string { return "math" }

func (fnLog10) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeFloat64}, false
}

func (fnLog10) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("math.log10: params=%+v", params)
	x, err := coerce.ToFloat64(params[0])
	if err != nil {
		return nil, fmt.Errorf("math.log10: parameter must be a number, got %v", params[0])
	}
	if x <= 0 {
		return nil, fmt.Errorf("math.log10: argument must be positive, got %v", x)
	}
	result := math.Log10(x)
	log.RootLogger().Debugf("math.log10: log10(%v) = %v", x, result)
	return result, nil
}
