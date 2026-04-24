package stringfn

import (
	"fmt"
	"regexp"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnRegexExtract{})
}

type fnRegexExtract struct{}

func (fnRegexExtract) Name() string { return "regexExtract" }

func (fnRegexExtract) GetCategory() string { return "string" }

func (fnRegexExtract) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString, data.TypeString}, false
}

// Eval extracts the first match (or first capture group) of pattern from str.
// Returns empty string if there is no match.
// Unlike OOTB string.matchRegEx which only returns bool, this returns the actual matched text.
//
// Example:
//
//	string.regexExtract("order-12345-done", `\d+`) => "12345"
//	string.regexExtract("foo@example.com", `(\w+)@`) => "foo"
func (fnRegexExtract) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("string.regexExtract: params=%+v", params)

	str, err := coerce.ToString(params[0])
	if err != nil {
		return nil, fmt.Errorf("string.regexExtract: first arg must be string, got %v", params[0])
	}
	pattern, err := coerce.ToString(params[1])
	if err != nil {
		return nil, fmt.Errorf("string.regexExtract: pattern must be string, got %v", params[1])
	}

	re, err := regexp.Compile(pattern)
	if err != nil {
		return nil, fmt.Errorf("string.regexExtract: invalid pattern %q: %s", pattern, err)
	}

	matches := re.FindStringSubmatch(str)
	log.RootLogger().Debugf("string.regexExtract: pattern=%q matches=%v", pattern, matches)

	if len(matches) == 0 {
		return "", nil
	}
	// if there is a capture group, return group 1; otherwise return the full match (group 0)
	if len(matches) > 1 {
		return matches[1], nil
	}
	return matches[0], nil
}
