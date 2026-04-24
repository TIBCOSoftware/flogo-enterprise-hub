package stringfn

import (
	"fmt"
	"strings"
	"unicode"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnIsBlank{})
	_ = function.Register(&fnIsNumeric{})
}

// --- string.isBlank ---

type fnIsBlank struct{}

func (fnIsBlank) Name() string        { return "isBlank" }
func (fnIsBlank) GetCategory() string { return "string" }

func (fnIsBlank) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString}, false
}

// Eval returns true if str is nil, empty, or contains only whitespace.
func (fnIsBlank) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("string.isBlank: params=%+v", params)
	if params[0] == nil {
		log.RootLogger().Debugf("string.isBlank: nil input, returning true")
		return true, nil
	}
	str, err := coerce.ToString(params[0])
	if err != nil {
		return nil, fmt.Errorf("string.isBlank: parameter must be a string, got %v", params[0])
	}
	result := strings.TrimSpace(str) == ""
	log.RootLogger().Debugf("string.isBlank: input=%q result=%v", str, result)
	return result, nil
}

// --- string.isNumeric ---

type fnIsNumeric struct{}

func (fnIsNumeric) Name() string        { return "isNumeric" }
func (fnIsNumeric) GetCategory() string { return "string" }

func (fnIsNumeric) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString}, false
}

// Eval returns true if str represents a valid decimal integer or float (may start with - or +).
// Does not accept hex, octal, or scientific notation.
func (fnIsNumeric) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("string.isNumeric: params=%+v", params)
	if params[0] == nil {
		return false, nil
	}
	str, err := coerce.ToString(params[0])
	if err != nil {
		return nil, fmt.Errorf("string.isNumeric: parameter must be a string, got %v", params[0])
	}
	s := strings.TrimSpace(str)
	if s == "" {
		return false, nil
	}
	// Optional leading sign
	start := 0
	if s[0] == '+' || s[0] == '-' {
		start = 1
	}
	dotSeen := false
	digits := 0
	for _, r := range s[start:] {
		if r == '.' {
			if dotSeen {
				log.RootLogger().Debugf("string.isNumeric: multiple dots in %q, not numeric", str)
				return false, nil
			}
			dotSeen = true
		} else if unicode.IsDigit(r) {
			digits++
		} else {
			log.RootLogger().Debugf("string.isNumeric: non-digit char %q in %q, not numeric", string(r), str)
			return false, nil
		}
	}
	result := digits > 0
	log.RootLogger().Debugf("string.isNumeric: input=%q result=%v", str, result)
	return result, nil
}
