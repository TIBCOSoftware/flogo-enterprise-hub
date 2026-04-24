package arrayfn

import (
	"fmt"
	"reflect"

	"github.com/project-flogo/core/data/coerce"
)

// toSlice converts any slice-like value to []interface{}.
func toSlice(v interface{}) ([]interface{}, error) {
	if v == nil {
		return nil, fmt.Errorf("array argument is nil")
	}
	rv := reflect.ValueOf(v)
	if rv.Kind() != reflect.Slice {
		return nil, fmt.Errorf("expected an array, got %T", v)
	}
	result := make([]interface{}, rv.Len())
	for i := 0; i < rv.Len(); i++ {
		result[i] = rv.Index(i).Interface()
	}
	return result, nil
}

// toFloat64Slice converts a slice to a []float64, returning an error if any
// element cannot be coerced to a number.
func toFloat64Slice(v interface{}) ([]float64, error) {
	elems, err := toSlice(v)
	if err != nil {
		return nil, err
	}
	if len(elems) == 0 {
		return nil, fmt.Errorf("array is empty")
	}
	out := make([]float64, len(elems))
	for i, el := range elems {
		f, err := coerce.ToFloat64(el)
		if err != nil {
			return nil, fmt.Errorf("element at index %d cannot be converted to a number: %v", i, el)
		}
		out[i] = f
	}
	return out, nil
}
