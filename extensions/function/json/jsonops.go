package jsonfn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnRemoveKey{})
	_ = function.Register(&fnMerge{})
}

// ─── removeKey ────────────────────────────────────────────────────────────────

type fnRemoveKey struct{}

func (fnRemoveKey) Name() string { return "removeKey" }

func (fnRemoveKey) GetCategory() string { return "json" }

func (fnRemoveKey) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeObject, data.TypeString}, false
}

// Eval returns a copy of the object with the specified top-level key removed.
// If the key does not exist the original object is returned unchanged.
// Unlike OOTB json.set which sets keys to null (not the same as deletion),
// this actually removes the key from the returned object.
//
// Example:
//
//	json.removeKey({"a":1,"b":2}, "b") => {"a":1}
func (fnRemoveKey) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("json.removeKey: params=%+v", params)

	obj, err := coerce.ToObject(params[0])
	if err != nil {
		return nil, fmt.Errorf("json.removeKey: first arg must be an object, got %T", params[0])
	}
	key, err := coerce.ToString(params[1])
	if err != nil {
		return nil, fmt.Errorf("json.removeKey: key must be a string, got %v", params[1])
	}

	// shallow copy so we don't mutate the input
	result := make(map[string]interface{}, len(obj))
	for k, v := range obj {
		if k != key {
			result[k] = v
		}
	}

	log.RootLogger().Debugf("json.removeKey: removed key=%q from object with %d keys", key, len(obj))
	return result, nil
}

// ─── merge ────────────────────────────────────────────────────────────────────

type fnMerge struct{}

func (fnMerge) Name() string { return "merge" }

func (fnMerge) GetCategory() string { return "json" }

func (fnMerge) Sig() (paramTypes []data.Type, isVariadic bool) {
	// base object + one or more override objects
	return []data.Type{data.TypeObject, data.TypeObject}, true
}

// Eval performs a shallow merge of one or more objects into a copy of the first object.
// Keys from later arguments overwrite keys from earlier ones.
// Unlike OOTB json.set (top-level only, one key at a time) and array.merge (array concat),
// this merges multiple JSON objects in a single expression.
//
// Example:
//
//	json.merge({"a":1,"b":2}, {"b":99,"c":3}) => {"a":1,"b":99,"c":3}
func (fnMerge) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("json.merge: merging %d objects", len(params))

	if len(params) < 2 {
		return nil, fmt.Errorf("json.merge: requires at least 2 arguments")
	}

	base, err := coerce.ToObject(params[0])
	if err != nil {
		return nil, fmt.Errorf("json.merge: first arg must be an object, got %T", params[0])
	}

	// shallow copy of base
	result := make(map[string]interface{}, len(base))
	for k, v := range base {
		result[k] = v
	}

	for i := 1; i < len(params); i++ {
		overlay, err := coerce.ToObject(params[i])
		if err != nil {
			return nil, fmt.Errorf("json.merge: arg[%d] must be an object, got %T", i, params[i])
		}
		for k, v := range overlay {
			log.RootLogger().Debugf("json.merge: setting key=%q from arg[%d]", k, i)
			result[k] = v
		}
	}

	log.RootLogger().Debugf("json.merge: result has %d keys", len(result))
	return result, nil
}
