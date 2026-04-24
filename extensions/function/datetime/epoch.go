package datetimefn

import (
	"fmt"
	"time"

	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = function.Register(&fnToEpoch{})
	_ = function.Register(&fnFromEpoch{})
}

// --- datetime.toEpoch ---

type fnToEpoch struct{}

func (fnToEpoch) Name() string        { return "toEpoch" }
func (fnToEpoch) GetCategory() string { return "datetime" }

func (fnToEpoch) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString}, false
}

// Eval converts a datetime string to Unix epoch milliseconds.
// datetime.toEpoch("2024-01-15T10:30:00Z") => 1705314600000
func (fnToEpoch) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("datetime.toEpoch: params=%+v", params)
	t, err := coerce.ToDateTime(params[0])
	if err != nil {
		return nil, fmt.Errorf("datetime.toEpoch: argument is not a valid datetime: %v", params[0])
	}
	millis := int(t.UnixMilli())
	log.RootLogger().Debugf("datetime.toEpoch: parsed=%v epoch_ms=%d", t, millis)
	return millis, nil
}

// --- datetime.fromEpoch ---

type fnFromEpoch struct{}

func (fnFromEpoch) Name() string        { return "fromEpoch" }
func (fnFromEpoch) GetCategory() string { return "datetime" }

func (fnFromEpoch) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeInt}, false
}

// Eval converts Unix epoch milliseconds to an RFC3339 UTC datetime string.
// datetime.fromEpoch(1705314600000) => "2024-01-15T10:30:00Z"
func (fnFromEpoch) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("datetime.fromEpoch: params=%+v", params)
	ms, err := coerce.ToInt(params[0])
	if err != nil {
		return nil, fmt.Errorf("datetime.fromEpoch: argument must be an integer (epoch milliseconds), got %v", params[0])
	}
	t := time.UnixMilli(int64(ms)).UTC()
	result := t.Format(time.RFC3339)
	log.RootLogger().Debugf("datetime.fromEpoch: epoch_ms=%d result=%q", ms, result)
	return result, nil
}
