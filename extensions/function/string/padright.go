package stringfn

import (
	"fmt"
	"strings"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
)

func init() {
	_ = function.Register(&fnPadRight{})
}

type fnPadRight struct{}

func (fnPadRight) Name() string { return "padRight" }

func (fnPadRight) GetCategory() string { return "string" }

func (fnPadRight) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString, data.TypeInt, data.TypeString}, false
}

// Eval pads str on the right with padChar until the total rune-length reaches size.
// If str is already >= size, it is returned unchanged.
// Only the first rune of padChar is used; defaults to " " if empty.
func (fnPadRight) Eval(params ...interface{}) (interface{}, error) {
	str, err := coerce.ToString(params[0])
	if err != nil {
		return nil, fmt.Errorf("string.padRight: first argument must be a string, got %v", params[0])
	}
	size, err := coerce.ToInt(params[1])
	if err != nil {
		return nil, fmt.Errorf("string.padRight: size must be an integer, got %v", params[1])
	}
	padChar, err := coerce.ToString(params[2])
	if err != nil || padChar == "" {
		padChar = " "
	}

	padRune := []rune(padChar)[0]
	runes := []rune(str)
	needed := size - len(runes)
	if needed <= 0 {
		return str, nil
	}
	return str + strings.Repeat(string(padRune), needed), nil
}
