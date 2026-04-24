package arrayfn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnFirst{})
	_ = function.Register(&fnLast{})
}

// --- array.first ---

type fnFirst struct{}

func (fnFirst) Name() string        { return "first" }
func (fnFirst) GetCategory() string { return "array" }

func (fnFirst) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeAny}, false
}

// Eval returns the first element of the array, or nil for an empty array.
func (fnFirst) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("array.first: params=%+v", params)
	elems, err := toSlice(params[0])
	if err != nil {
		return nil, fmt.Errorf("array.first: %w", err)
	}
	if len(elems) == 0 {
		log.RootLogger().Debugf("array.first: empty array, returning nil")
		return nil, nil
	}
	result := elems[0]
	log.RootLogger().Debugf("array.first: result=%+v (array len=%d)", result, len(elems))
	return result, nil
}

// --- array.last ---

type fnLast struct{}

func (fnLast) Name() string        { return "last" }
func (fnLast) GetCategory() string { return "array" }

func (fnLast) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeAny}, false
}

// Eval returns the last element of the array, or nil for an empty array.
func (fnLast) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("array.last: params=%+v", params)
	elems, err := toSlice(params[0])
	if err != nil {
		return nil, fmt.Errorf("array.last: %w", err)
	}
	if len(elems) == 0 {
		log.RootLogger().Debugf("array.last: empty array, returning nil")
		return nil, nil
	}
	result := elems[len(elems)-1]
	log.RootLogger().Debugf("array.last: result=%+v (array len=%d)", result, len(elems))
	return result, nil
}
