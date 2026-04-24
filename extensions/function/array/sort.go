package arrayfn

import (
	"fmt"
	"sort"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnSort{})
	_ = function.Register(&fnSortDesc{})
}

// --- array.sort (ascending) ---

type fnSort struct{}

func (fnSort) Name() string        { return "sort" }
func (fnSort) GetCategory() string { return "array" }

func (fnSort) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeAny}, false
}

// Eval returns a new array sorted ascending. Elements are coerced to float64;
// if any element cannot be coerced the original order is preserved with an error.
func (fnSort) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("array.sort: params=%+v", params)
	elems, err := toSlice(params[0])
	if err != nil {
		return nil, fmt.Errorf("array.sort: %w", err)
	}
	nums, err := toFloat64Slice(params[0])
	if err != nil {
		// Fall back to string sort for non-numeric arrays
		log.RootLogger().Debugf("array.sort: non-numeric array, falling back to string sort: %v", err)
		strs := make([]string, len(elems))
		for i, e := range elems {
			s, _ := coerce.ToString(e)
			strs[i] = s
		}
		sort.Strings(strs)
		result := make([]interface{}, len(strs))
		for i, s := range strs {
			result[i] = s
		}
		log.RootLogger().Debugf("array.sort: string sort result=%+v", result)
		return result, nil
	}
	sort.Float64s(nums)
	result := make([]interface{}, len(nums))
	for i, n := range nums {
		result[i] = n
	}
	log.RootLogger().Debugf("array.sort: numeric sort result=%+v", result)
	return result, nil
}

// --- array.sortDesc (descending) ---

type fnSortDesc struct{}

func (fnSortDesc) Name() string        { return "sortDesc" }
func (fnSortDesc) GetCategory() string { return "array" }

func (fnSortDesc) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeAny}, false
}

func (fnSortDesc) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("array.sortDesc: params=%+v", params)
	elems, err := toSlice(params[0])
	if err != nil {
		return nil, fmt.Errorf("array.sortDesc: %w", err)
	}
	nums, err := toFloat64Slice(params[0])
	if err != nil {
		log.RootLogger().Debugf("array.sortDesc: non-numeric array, falling back to string sort desc: %v", err)
		strs := make([]string, len(elems))
		for i, e := range elems {
			s, _ := coerce.ToString(e)
			strs[i] = s
		}
		sort.Sort(sort.Reverse(sort.StringSlice(strs)))
		result := make([]interface{}, len(strs))
		for i, s := range strs {
			result[i] = s
		}
		log.RootLogger().Debugf("array.sortDesc: string sort desc result=%+v", result)
		return result, nil
	}
	sort.Sort(sort.Reverse(sort.Float64Slice(nums)))
	result := make([]interface{}, len(nums))
	for i, n := range nums {
		result[i] = n
	}
	log.RootLogger().Debugf("array.sortDesc: numeric sort desc result=%+v", result)
	return result, nil
}
