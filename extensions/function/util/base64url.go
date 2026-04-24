package utilfn

import (
	"encoding/base64"
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnBase64UrlEncode{})
	_ = function.Register(&fnBase64UrlDecode{})
}

// ─── base64UrlEncode ──────────────────────────────────────────────────────────

type fnBase64UrlEncode struct{}

func (fnBase64UrlEncode) Name() string { return "base64UrlEncode" }

func (fnBase64UrlEncode) GetCategory() string { return "util" }

func (fnBase64UrlEncode) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString}, false
}

// Eval returns the URL-safe Base64 encoding (RFC 4648 §5) of the input string,
// without padding. Uses '-' and '_' instead of '+' and '/'.
// Required for JWTs, OAuth tokens, and URL-embedded hashes.
func (fnBase64UrlEncode) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("util.base64UrlEncode: params=%+v", params)

	s, err := coerce.ToString(params[0])
	if err != nil {
		return nil, fmt.Errorf("util.base64UrlEncode: argument must be a string, got %v", params[0])
	}

	result := base64.RawURLEncoding.EncodeToString([]byte(s))
	log.RootLogger().Debugf("util.base64UrlEncode: result=%s", result)
	return result, nil
}

// ─── base64UrlDecode ──────────────────────────────────────────────────────────

type fnBase64UrlDecode struct{}

func (fnBase64UrlDecode) Name() string { return "base64UrlDecode" }

func (fnBase64UrlDecode) GetCategory() string { return "util" }

func (fnBase64UrlDecode) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString}, false
}

// Eval decodes a URL-safe Base64 string (with or without padding) and returns the result as a string.
func (fnBase64UrlDecode) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("util.base64UrlDecode: params=%+v", params)

	s, err := coerce.ToString(params[0])
	if err != nil {
		return nil, fmt.Errorf("util.base64UrlDecode: argument must be a string, got %v", params[0])
	}

	decoded, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		// also try with padding in case the caller included it
		decoded, err = base64.URLEncoding.DecodeString(s)
		if err != nil {
			return nil, fmt.Errorf("util.base64UrlDecode: invalid base64url input: %s", err)
		}
	}

	result := string(decoded)
	log.RootLogger().Debugf("util.base64UrlDecode: result=%s", result)
	return result, nil
}
