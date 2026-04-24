package numberfn

import (
	"crypto/rand"
	"fmt"
	"math/big"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnRandomInt{})
}

type fnRandomInt struct{}

func (fnRandomInt) Name() string { return "randomInt" }

func (fnRandomInt) GetCategory() string { return "number" }

func (fnRandomInt) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeInt, data.TypeInt}, false
}

// Eval returns a cryptographically random integer in the range [min, max] (inclusive).
// Unlike OOTB number.random(n) which is [0, n-1] and re-seeds on every call,
// this uses crypto/rand for quality randomness and supports arbitrary ranges.
//
// Example:
//
//	number.randomInt(1, 100) => 42   (some value between 1 and 100 inclusive)
func (fnRandomInt) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("number.randomInt: params=%+v", params)

	minVal, err := coerce.ToInt(params[0])
	if err != nil {
		return nil, fmt.Errorf("number.randomInt: min must be an integer, got %v", params[0])
	}
	maxVal, err := coerce.ToInt(params[1])
	if err != nil {
		return nil, fmt.Errorf("number.randomInt: max must be an integer, got %v", params[1])
	}
	if minVal > maxVal {
		return nil, fmt.Errorf("number.randomInt: min (%d) must be <= max (%d)", minVal, maxVal)
	}

	rangeSize := int64(maxVal-minVal) + 1
	n, err := rand.Int(rand.Reader, big.NewInt(rangeSize))
	if err != nil {
		return nil, fmt.Errorf("number.randomInt: failed to generate random number: %s", err)
	}

	result := int(n.Int64()) + minVal
	log.RootLogger().Debugf("number.randomInt: range=[%d,%d] result=%d", minVal, maxVal, result)
	return result, nil
}
