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
	_ = function.Register(&fnCamelCase{})
	_ = function.Register(&fnSnakeCase{})
}

// --- string.camelCase ---

type fnCamelCase struct{}

func (fnCamelCase) Name() string        { return "camelCase" }
func (fnCamelCase) GetCategory() string { return "string" }

func (fnCamelCase) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString}, false
}

// Eval converts str to lowerCamelCase. Words are split on spaces, hyphens,
// underscores, and transitions between lower→upper letters.
//
// Examples:
//
//	string.camelCase("hello world")    => "helloWorld"
//	string.camelCase("user_first_name") => "userFirstName"
//	string.camelCase("FOO BAR")         => "fooBar"
func (fnCamelCase) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("string.camelCase: params=%+v", params)
	str, err := coerce.ToString(params[0])
	if err != nil {
		return nil, fmt.Errorf("string.camelCase: parameter must be a string, got %v", params[0])
	}
	words := splitWords(str)
	log.RootLogger().Debugf("string.camelCase: words=%v", words)
	if len(words) == 0 {
		return "", nil
	}
	var sb strings.Builder
	for i, w := range words {
		if w == "" {
			continue
		}
		lower := strings.ToLower(w)
		if i == 0 {
			sb.WriteString(lower)
		} else {
			runes := []rune(lower)
			sb.WriteRune(unicode.ToUpper(runes[0]))
			sb.WriteString(string(runes[1:]))
		}
	}
	result := sb.String()
	log.RootLogger().Debugf("string.camelCase: input=%q result=%q", str, result)
	return result, nil
}

// --- string.snakeCase ---

type fnSnakeCase struct{}

func (fnSnakeCase) Name() string        { return "snakeCase" }
func (fnSnakeCase) GetCategory() string { return "string" }

func (fnSnakeCase) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString}, false
}

// Eval converts str to snake_case. All words are lower-cased and joined with "_".
//
// Examples:
//
//	string.snakeCase("Hello World")    => "hello_world"
//	string.snakeCase("userFirstName")  => "user_first_name"
//	string.snakeCase("FOO-BAR")        => "foo_bar"
func (fnSnakeCase) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("string.snakeCase: params=%+v", params)
	str, err := coerce.ToString(params[0])
	if err != nil {
		return nil, fmt.Errorf("string.snakeCase: parameter must be a string, got %v", params[0])
	}
	words := splitWords(str)
	log.RootLogger().Debugf("string.snakeCase: words=%v", words)
	lower := make([]string, 0, len(words))
	for _, w := range words {
		if w != "" {
			lower = append(lower, strings.ToLower(w))
		}
	}
	result := strings.Join(lower, "_")
	log.RootLogger().Debugf("string.snakeCase: input=%q result=%q", str, result)
	return result, nil
}

// splitWords splits a string into words on spaces, hyphens, underscores,
// and camelCase transition boundaries (lower→upper or digit→upper).
func splitWords(s string) []string {
	runes := []rune(s)
	var words []string
	var cur strings.Builder
	for i, r := range runes {
		if r == ' ' || r == '-' || r == '_' {
			if cur.Len() > 0 {
				words = append(words, cur.String())
				cur.Reset()
			}
			continue
		}
		// Start a new word on upper-case letter that follows a lower-case or digit
		if i > 0 && unicode.IsUpper(r) {
			prev := runes[i-1]
			if unicode.IsLower(prev) || unicode.IsDigit(prev) {
				if cur.Len() > 0 {
					words = append(words, cur.String())
					cur.Reset()
				}
			}
		}
		cur.WriteRune(r)
	}
	if cur.Len() > 0 {
		words = append(words, cur.String())
	}
	return words
}
