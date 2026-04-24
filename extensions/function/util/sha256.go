package utilfn

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
)

func init() {
	_ = function.Register(&fnSHA256{})
}

type fnSHA256 struct{}

func (fnSHA256) Name() string { return "sha256" }

func (fnSHA256) GetCategory() string { return "util" }

func (fnSHA256) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString}, false
}

// Eval returns the lowercase hex-encoded SHA-256 hash of the input string.
// Useful for generating idempotency keys, checksums, and ETag values.
//
// Example:
//
//	util.sha256("hello") => "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
func (fnSHA256) Eval(params ...interface{}) (interface{}, error) {
	s, err := coerce.ToString(params[0])
	if err != nil {
		return nil, fmt.Errorf("util.sha256: argument must be a string, got %v", params[0])
	}
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:]), nil
}
