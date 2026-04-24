package datetimefn

import (
	"fmt"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnIsWeekend{})
	_ = function.Register(&fnIsWeekday{})
}

// --- datetime.isWeekend ---

type fnIsWeekend struct{}

func (fnIsWeekend) Name() string        { return "isWeekend" }
func (fnIsWeekend) GetCategory() string { return "datetime" }

func (fnIsWeekend) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString}, false
}

// Eval returns true if the given datetime falls on a Saturday or Sunday.
func (fnIsWeekend) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("datetime.isWeekend: params=%+v", params)
	t, err := coerce.ToDateTime(params[0])
	if err != nil {
		return nil, fmt.Errorf("datetime.isWeekend: argument is not a valid datetime: %v", params[0])
	}
	wd := t.Weekday()
	result := wd == 0 || wd == 6 // Sunday=0, Saturday=6
	log.RootLogger().Debugf("datetime.isWeekend: date=%v weekday=%v result=%v", t.Format("2006-01-02"), wd, result)
	return result, nil
}

// --- datetime.isWeekday ---

type fnIsWeekday struct{}

func (fnIsWeekday) Name() string        { return "isWeekday" }
func (fnIsWeekday) GetCategory() string { return "datetime" }

func (fnIsWeekday) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString}, false
}

// Eval returns true if the given datetime falls on Monday through Friday.
func (fnIsWeekday) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("datetime.isWeekday: params=%+v", params)
	t, err := coerce.ToDateTime(params[0])
	if err != nil {
		return nil, fmt.Errorf("datetime.isWeekday: argument is not a valid datetime: %v", params[0])
	}
	wd := t.Weekday()
	result := wd >= 1 && wd <= 5
	log.RootLogger().Debugf("datetime.isWeekday: date=%v weekday=%v result=%v", t.Format("2006-01-02"), wd, result)
	return result, nil
}
