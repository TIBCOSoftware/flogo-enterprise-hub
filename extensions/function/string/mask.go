package stringfn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
)

func init() {
	_ = function.Register(&fnMask{})
}

type fnMask struct{}

func (fnMask) Name() string { return "mask" }

func (fnMask) GetCategory() string { return "string" }

func (fnMask) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString, data.TypeInt, data.TypeInt}, false
}

// Eval masks the middle portion of str with '*', preserving keepFirst characters
// at the start and keepLast characters at the end.
//
// Examples:
//
//	string.mask("4111-1111-1111-1234", 0, 4) => "***************1234"
//	string.mask("john.doe@acme.com",   1, 8) => "j*******@acme.com"
//	string.mask("secret",              0, 0) => "******"
//
// If keepFirst + keepLast >= len(str), the original string is returned unchanged.
func (fnMask) Eval(params ...interface{}) (interface{}, error) {
	str, err := coerce.ToString(params[0])
	if err != nil {
		return nil, fmt.Errorf("string.mask: first argument must be a string, got %v", params[0])
	}
	keepFirst, err := coerce.ToInt(params[1])
	if err != nil || keepFirst < 0 {
		return nil, fmt.Errorf("string.mask: keepFirst must be a non-negative integer, got %v", params[1])
	}
	keepLast, err := coerce.ToInt(params[2])
	if err != nil || keepLast < 0 {
		return nil, fmt.Errorf("string.mask: keepLast must be a non-negative integer, got %v", params[2])
	}

	runes := []rune(str)
	n := len(runes)
	if keepFirst+keepLast >= n {
		return str, nil
	}

	result := make([]rune, n)
	for i, r := range runes {
		if i < keepFirst || i >= n-keepLast {
			result[i] = r
		} else {
			result[i] = '*'
		}
	}
	return string(result), nil
}
