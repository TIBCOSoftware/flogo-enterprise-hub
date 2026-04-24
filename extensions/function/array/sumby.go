package arrayfn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnSumBy{})
}

type fnSumBy struct{}

func (fnSumBy) Name() string        { return "sumBy" }
func (fnSumBy) GetCategory() string { return "array" }

func (fnSumBy) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeAny, data.TypeString}, false
}

// Eval sums the numeric value of a named field across an array of objects.
// array.sumBy([{"amount":10},{"amount":20}], "amount") => 30
func (fnSumBy) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("array.sumBy: params=%+v", params)
	elems, err := toSlice(params[0])
	if err != nil {
		return nil, fmt.Errorf("array.sumBy: first argument must be an array, %w", err)
	}
	field, err := coerce.ToString(params[1])
	if err != nil || field == "" {
		return nil, fmt.Errorf("array.sumBy: second argument must be a non-empty field name, got %v", params[1])
	}
	log.RootLogger().Debugf("array.sumBy: summing field=%q over %d elements", field, len(elems))

	var sum float64
	for i, elem := range elems {
		obj, err := coerce.ToObject(elem)
		if err != nil {
			return nil, fmt.Errorf("array.sumBy: element [%d] is not an object: %v", i, elem)
		}
		val, ok := obj[field]
		if !ok {
			log.RootLogger().Debugf("array.sumBy: element [%d] missing field %q, treating as 0", i, field)
			continue
		}
		num, err := coerce.ToFloat64(val)
		if err != nil {
			return nil, fmt.Errorf("array.sumBy: element [%d] field %q value %v cannot be coerced to number", i, field, val)
		}
		log.RootLogger().Debugf("array.sumBy: element [%d] field=%q value=%v running_sum=%v", i, field, num, sum+num)
		sum += num
	}
	log.RootLogger().Debugf("array.sumBy: final sum=%v", sum)
	return sum, nil
}
