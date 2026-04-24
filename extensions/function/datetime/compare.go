package datetimefn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnIsBefore{})
	_ = function.Register(&fnIsAfter{})
}

// --- datetime.isBefore ---

type fnIsBefore struct{}

func (fnIsBefore) Name() string        { return "isBefore" }
func (fnIsBefore) GetCategory() string { return "datetime" }

func (fnIsBefore) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString, data.TypeString}, false
}

// Eval returns true if d1 is strictly before d2.
// Both arguments are parsed using the standard Flogo coerce.ToDateTime which
// accepts RFC3339, "2006-01-02", "2006-01-02T15:04:05", and other common
// datetime formats supported by the araddon/dateparse library.
func (fnIsBefore) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("datetime.isBefore: params=%+v", params)
	d1, err := coerce.ToDateTime(params[0])
	if err != nil {
		return nil, fmt.Errorf("datetime.isBefore: first argument is not a valid datetime: %v", params[0])
	}
	d2, err := coerce.ToDateTime(params[1])
	if err != nil {
		return nil, fmt.Errorf("datetime.isBefore: second argument is not a valid datetime: %v", params[1])
	}
	result := d1.Before(d2)
	log.RootLogger().Debugf("datetime.isBefore: d1=%v d2=%v result=%v", d1, d2, result)
	return result, nil
}

// --- datetime.isAfter ---

type fnIsAfter struct{}

func (fnIsAfter) Name() string        { return "isAfter" }
func (fnIsAfter) GetCategory() string { return "datetime" }

func (fnIsAfter) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString, data.TypeString}, false
}

// Eval returns true if d1 is strictly after d2.
func (fnIsAfter) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("datetime.isAfter: params=%+v", params)
	d1, err := coerce.ToDateTime(params[0])
	if err != nil {
		return nil, fmt.Errorf("datetime.isAfter: first argument is not a valid datetime: %v", params[0])
	}
	d2, err := coerce.ToDateTime(params[1])
	if err != nil {
		return nil, fmt.Errorf("datetime.isAfter: second argument is not a valid datetime: %v", params[1])
	}
	result := d1.After(d2)
	log.RootLogger().Debugf("datetime.isAfter: d1=%v d2=%v result=%v", d1, d2, result)
	return result, nil
}
