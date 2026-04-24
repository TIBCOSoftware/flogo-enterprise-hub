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
	_ = function.Register(&fnAddBusinessDays{})
	_ = function.Register(&fnStartOfDay{})
	_ = function.Register(&fnQuarter{})
}

// ─── addBusinessDays ──────────────────────────────────────────────────────────

type fnAddBusinessDays struct{}

func (fnAddBusinessDays) Name() string { return "addBusinessDays" }

func (fnAddBusinessDays) GetCategory() string { return "datetime" }

func (fnAddBusinessDays) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString, data.TypeInt}, false
}

// Eval adds n business days (Mon–Fri) to the given date string, skipping weekends.
// Negative n moves backward. Returns an RFC3339 string.
//
// Example:
//
//	datetime.addBusinessDays("2024-01-05T00:00:00Z", 3) => "2024-01-10T00:00:00Z"  (skips Sat/Sun)
func (fnAddBusinessDays) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("datetime.addBusinessDays: params=%+v", params)

	t, err := coerce.ToDateTime(params[0])
	if err != nil {
		return nil, fmt.Errorf("datetime.addBusinessDays: invalid date %v: %s", params[0], err)
	}
	days, err := coerce.ToInt(params[1])
	if err != nil {
		return nil, fmt.Errorf("datetime.addBusinessDays: days must be int, got %v", params[1])
	}

	step := 1
	if days < 0 {
		step = -1
		days = -days
	}

	added := 0
	for added < days {
		t = t.AddDate(0, 0, step)
		if t.Weekday() != time.Saturday && t.Weekday() != time.Sunday {
			added++
		}
	}

	result := t.UTC().Format(time.RFC3339)
	log.RootLogger().Debugf("datetime.addBusinessDays: result=%s", result)
	return result, nil
}

// ─── startOfDay ───────────────────────────────────────────────────────────────

type fnStartOfDay struct{}

func (fnStartOfDay) Name() string { return "startOfDay" }

func (fnStartOfDay) GetCategory() string { return "datetime" }

func (fnStartOfDay) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString}, false
}

// Eval returns the start of the day (00:00:00 UTC) for the given date string as RFC3339.
//
// Example:
//
//	datetime.startOfDay("2024-03-15T14:30:00Z") => "2024-03-15T00:00:00Z"
func (fnStartOfDay) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("datetime.startOfDay: params=%+v", params)

	t, err := coerce.ToDateTime(params[0])
	if err != nil {
		return nil, fmt.Errorf("datetime.startOfDay: invalid date %v: %s", params[0], err)
	}

	utc := t.UTC()
	start := time.Date(utc.Year(), utc.Month(), utc.Day(), 0, 0, 0, 0, time.UTC)
	result := start.Format(time.RFC3339)
	log.RootLogger().Debugf("datetime.startOfDay: result=%s", result)
	return result, nil
}

// ─── quarter ──────────────────────────────────────────────────────────────────

type fnQuarter struct{}

func (fnQuarter) Name() string { return "quarter" }

func (fnQuarter) GetCategory() string { return "datetime" }

func (fnQuarter) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString}, false
}

// Eval returns the calendar quarter (1–4) for the given date string.
//
// Example:
//
//	datetime.quarter("2024-07-15T00:00:00Z") => 3
func (fnQuarter) Eval(params ...interface{}) (interface{}, error) {
	log.RootLogger().Debugf("datetime.quarter: params=%+v", params)

	t, err := coerce.ToDateTime(params[0])
	if err != nil {
		return nil, fmt.Errorf("datetime.quarter: invalid date %v: %s", params[0], err)
	}

	q := (int(t.UTC().Month())-1)/3 + 1
	log.RootLogger().Debugf("datetime.quarter: month=%d quarter=%d", t.Month(), q)
	return q, nil
}
