package utilfn

import (
	"crypto/hmac"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnHMACSHA256{})
	_ = function.Register(&fnMD5{})
}

// ─── HMAC-SHA256 ──────────────────────────────────────────────────────────────

type fnHMACSHA256 struct{}

func (fnHMACSHA256) Name() string { return "hmacSha256" }

func (fnHMACSHA256) GetCategory() string { return "util" }

func (fnHMACSHA256) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString, data.TypeString}, false
}

// Eval returns the lowercase hex-encoded HMAC-SHA256 signature of message using key.
// Used for webhook signature verification and API authentication headers.
func (fnHMACSHA256) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("util.hmacSha256: params=%+v", params)

	msg, err := coerce.ToString(params[0])
	if err != nil {
		return nil, fmt.Errorf("util.hmacSha256: message must be a string, got %v", params[0])
	}
	key, err := coerce.ToString(params[1])
	if err != nil {
		return nil, fmt.Errorf("util.hmacSha256: key must be a string, got %v", params[1])
	}

	mac := hmac.New(sha256.New, []byte(key))
	mac.Write([]byte(msg))
	result := hex.EncodeToString(mac.Sum(nil))

	log.RootLogger().Debugf("util.hmacSha256: result=%s", result)
	return result, nil
}

// ─── MD5 ──────────────────────────────────────────────────────────────────────

type fnMD5 struct{}

func (fnMD5) Name() string { return "md5" }

func (fnMD5) GetCategory() string { return "util" }

func (fnMD5) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString}, false
}

// Eval returns the lowercase hex-encoded MD5 hash of the input string.
// Used for ETags, content-MD5 headers, and legacy checksums.
func (fnMD5) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("util.md5: params=%+v", params)

	s, err := coerce.ToString(params[0])
	if err != nil {
		return nil, fmt.Errorf("util.md5: argument must be a string, got %v", params[0])
	}

	h := md5.Sum([]byte(s))
	result := hex.EncodeToString(h[:])

	log.RootLogger().Debugf("util.md5: result=%s", result)
	return result, nil
}
