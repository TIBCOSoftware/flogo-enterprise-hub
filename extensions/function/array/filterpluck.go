package arrayfn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnFilter{})
	_ = function.Register(&fnPluck{})
}

// ─── filter ───────────────────────────────────────────────────────────────────

type fnFilter struct{}

func (fnFilter) Name() string { return "filter" }

func (fnFilter) GetCategory() string { return "array" }

func (fnFilter) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeAny, data.TypeString, data.TypeAny}, false
}

// Eval returns a new array containing only the elements (objects) where element[field] == value.
// Elements that are not maps or do not contain the field are skipped.
//
// Example:
//
//	array.filter($flow.items, "status", "active") => [{...active items...}]
func (fnFilter) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("array.filter: params=%+v", params)

	arr, err := coerce.ToArray(params[0])
	if err != nil {
		return nil, fmt.Errorf("array.filter: first arg must be an array, got %T", params[0])
	}
	field, err := coerce.ToString(params[1])
	if err != nil {
		return nil, fmt.Errorf("array.filter: field must be a string, got %v", params[1])
	}
	needle := params[2]

	needleStr, needleIsStr := needle.(string)

	result := make([]interface{}, 0)
	for i, elem := range arr {
		m, ok := elem.(map[string]interface{})
		if !ok {
			log.RootLogger().Debugf("array.filter: element[%d] is not an object, skipping", i)
			continue
		}
		val, exists := m[field]
		if !exists {
			continue
		}
		// compare as strings when both sides can be compared that way, otherwise use deep equality
		valStr, valIsStr := val.(string)
		if needleIsStr && valIsStr {
			if valStr == needleStr {
				result = append(result, elem)
			}
		} else {
			valCoerced, _ := coerce.ToString(val)
			needleCoerced, _ := coerce.ToString(needle)
			if valCoerced == needleCoerced {
				result = append(result, elem)
			}
		}
	}

	log.RootLogger().Debugf("array.filter: field=%q value=%v matched %d/%d elements", field, needle, len(result), len(arr))
	return result, nil
}

// ─── pluck ────────────────────────────────────────────────────────────────────

type fnPluck struct{}

func (fnPluck) Name() string { return "pluck" }

func (fnPluck) GetCategory() string { return "array" }

func (fnPluck) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeAny, data.TypeString}, false
}

// Eval extracts the value of field from each object element and returns them as a flat array.
// Elements that are not maps or do not contain the field contribute a nil to the result.
//
// Example:
//
//	array.pluck($flow.users, "email") => ["a@x.com", "b@x.com"]
func (fnPluck) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("array.pluck: params=%+v", params)

	arr, err := coerce.ToArray(params[0])
	if err != nil {
		return nil, fmt.Errorf("array.pluck: first arg must be an array, got %T", params[0])
	}
	field, err := coerce.ToString(params[1])
	if err != nil {
		return nil, fmt.Errorf("array.pluck: field must be a string, got %v", params[1])
	}

	result := make([]interface{}, len(arr))
	for i, elem := range arr {
		if m, ok := elem.(map[string]interface{}); ok {
			result[i] = m[field]
		} else {
			result[i] = nil
		}
	}

	log.RootLogger().Debugf("array.pluck: field=%q extracted %d values", field, len(result))
	return result, nil
}
