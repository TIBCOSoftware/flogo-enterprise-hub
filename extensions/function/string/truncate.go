package stringfn

import (
	"fmt"
	"strings"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnTruncate{})
}

type fnTruncate struct{}

func (fnTruncate) Name() string        { return "truncate" }
func (fnTruncate) GetCategory() string { return "string" }

func (fnTruncate) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString, data.TypeInt}, false
}

// Eval truncates str to at most maxLen runes. If str was longer, "..." is appended
// so the total result length is maxLen (or 3 if maxLen < 3).
//
// Examples:
//
//	string.truncate("Hello, World!", 8) => "Hello..."
//	string.truncate("Hi", 10)           => "Hi"
func (fnTruncate) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("string.truncate: params=%+v", params)
	str, err := coerce.ToString(params[0])
	if err != nil {
		return nil, fmt.Errorf("string.truncate: first parameter must be a string, got %v", params[0])
	}
	maxLen, err := coerce.ToInt(params[1])
	if err != nil {
		return nil, fmt.Errorf("string.truncate: second parameter must be an integer, got %v", params[1])
	}
	if maxLen < 0 {
		return nil, fmt.Errorf("string.truncate: maxLen must be >= 0, got %d", maxLen)
	}
	runes := []rune(str)
	log.RootLogger().Debugf("string.truncate: input len=%d, maxLen=%d", len(runes), maxLen)
	if len(runes) <= maxLen {
		return str, nil
	}
	const ellipsis = "..."
	ellipsisLen := len([]rune(ellipsis))
	cutAt := maxLen - ellipsisLen
	if cutAt < 0 {
		cutAt = 0
	}
	result := string(runes[:cutAt]) + strings.Repeat(".", min3(ellipsisLen, maxLen))
	log.RootLogger().Debugf("string.truncate: result=%q", result)
	return result, nil
}

func min3(a, b int) int {
	if a < b {
		return a
	}
	return b
}
