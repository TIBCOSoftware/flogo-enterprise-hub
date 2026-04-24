package datetimefn

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ─── isBefore ─────────────────────────────────────────────────────────────────

func TestIsBefore(t *testing.T) {
	fn := &fnIsBefore{}

	t.Run("d1 before d2", func(t *testing.T) {
		out, err := fn.Eval("2024-01-01", "2024-06-01")
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("d1 after d2", func(t *testing.T) {
		out, err := fn.Eval("2024-06-01", "2024-01-01")
		require.NoError(t, err)
		assert.Equal(t, false, out)
	})
	t.Run("same date", func(t *testing.T) {
		out, err := fn.Eval("2024-01-01", "2024-01-01")
		require.NoError(t, err)
		assert.Equal(t, false, out)
	})
	t.Run("RFC3339 timestamps", func(t *testing.T) {
		out, err := fn.Eval("2024-01-15T08:00:00Z", "2024-01-15T10:00:00Z")
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("invalid first arg errors", func(t *testing.T) {
		_, err := fn.Eval("not-a-date", "2024-01-01")
		assert.Error(t, err)
	})
	t.Run("invalid second arg errors", func(t *testing.T) {
		_, err := fn.Eval("2024-01-01", "not-a-date")
		assert.Error(t, err)
	})
}

// ─── isAfter ──────────────────────────────────────────────────────────────────

func TestIsAfter(t *testing.T) {
	fn := &fnIsAfter{}

	t.Run("d1 after d2", func(t *testing.T) {
		out, err := fn.Eval("2024-06-01", "2024-01-01")
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("d1 before d2", func(t *testing.T) {
		out, err := fn.Eval("2024-01-01", "2024-06-01")
		require.NoError(t, err)
		assert.Equal(t, false, out)
	})
	t.Run("same date", func(t *testing.T) {
		out, err := fn.Eval("2024-06-01", "2024-06-01")
		require.NoError(t, err)
		assert.Equal(t, false, out)
	})
	t.Run("RFC3339 timestamps", func(t *testing.T) {
		out, err := fn.Eval("2024-01-15T10:00:00Z", "2024-01-15T08:00:00Z")
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("invalid arg errors", func(t *testing.T) {
		_, err := fn.Eval("not-a-date", "2024-01-01")
		assert.Error(t, err)
	})
}

// ─── toEpoch ──────────────────────────────────────────────────────────────────

func TestToEpoch(t *testing.T) {
	fn := &fnToEpoch{}

	t.Run("RFC3339 UTC", func(t *testing.T) {
		out, err := fn.Eval("2024-01-15T10:30:00Z")
		require.NoError(t, err)
		// 2024-01-15T10:30:00Z = 1705314600 seconds = 1705314600000 ms
		assert.Equal(t, int(1705314600000), out)
	})
	t.Run("returns int", func(t *testing.T) {
		out, err := fn.Eval("2020-01-01T00:00:00Z")
		require.NoError(t, err)
		_, ok := out.(int)
		assert.True(t, ok, "expected int, got %T", out)
	})
	t.Run("invalid datetime errors", func(t *testing.T) {
		_, err := fn.Eval("not-a-date")
		assert.Error(t, err)
	})
}

// ─── fromEpoch ────────────────────────────────────────────────────────────────

func TestFromEpoch(t *testing.T) {
	fn := &fnFromEpoch{}

	t.Run("known epoch to RFC3339", func(t *testing.T) {
		out, err := fn.Eval(int(1705314600000))
		require.NoError(t, err)
		assert.Equal(t, "2024-01-15T10:30:00Z", out)
	})
	t.Run("zero epoch = Unix epoch", func(t *testing.T) {
		out, err := fn.Eval(int(0))
		require.NoError(t, err)
		assert.Equal(t, "1970-01-01T00:00:00Z", out)
	})
	t.Run("string integer input coerced", func(t *testing.T) {
		out, err := fn.Eval("1705314600000")
		require.NoError(t, err)
		assert.Equal(t, "2024-01-15T10:30:00Z", out)
	})
	t.Run("invalid input errors", func(t *testing.T) {
		_, err := fn.Eval("not-a-number")
		assert.Error(t, err)
	})
}

// ─── isWeekend ────────────────────────────────────────────────────────────────

func TestIsWeekend(t *testing.T) {
	fn := &fnIsWeekend{}

	t.Run("Saturday", func(t *testing.T) {
		out, err := fn.Eval("2024-01-06") // Saturday
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("Sunday", func(t *testing.T) {
		out, err := fn.Eval("2024-01-07") // Sunday
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("Monday", func(t *testing.T) {
		out, err := fn.Eval("2024-01-08") // Monday
		require.NoError(t, err)
		assert.Equal(t, false, out)
	})
	t.Run("Friday", func(t *testing.T) {
		out, err := fn.Eval("2024-01-05") // Friday
		require.NoError(t, err)
		assert.Equal(t, false, out)
	})
	t.Run("RFC3339 Saturday", func(t *testing.T) {
		out, err := fn.Eval("2024-01-06T14:30:00Z")
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("invalid arg errors", func(t *testing.T) {
		_, err := fn.Eval("not-a-date")
		assert.Error(t, err)
	})
}

// ─── isWeekday ────────────────────────────────────────────────────────────────

func TestIsWeekday(t *testing.T) {
	fn := &fnIsWeekday{}

	t.Run("Monday", func(t *testing.T) {
		out, err := fn.Eval("2024-01-08") // Monday
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("Friday", func(t *testing.T) {
		out, err := fn.Eval("2024-01-05") // Friday
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("Saturday", func(t *testing.T) {
		out, err := fn.Eval("2024-01-06") // Saturday
		require.NoError(t, err)
		assert.Equal(t, false, out)
	})
	t.Run("Sunday", func(t *testing.T) {
		out, err := fn.Eval("2024-01-07") // Sunday
		require.NoError(t, err)
		assert.Equal(t, false, out)
	})
	t.Run("invalid arg errors", func(t *testing.T) {
		_, err := fn.Eval("not-a-date")
		assert.Error(t, err)
	})
}

// ─── addBusinessDays ──────────────────────────────────────────────────────────

func TestAddBusinessDays(t *testing.T) {
	fn := &fnAddBusinessDays{}

	t.Run("add 3 days mid-week lands on Thursday", func(t *testing.T) {
		// 2024-01-08 is Monday, +3 = Thursday 2024-01-11
		out, err := fn.Eval("2024-01-08T00:00:00Z", 3)
		require.NoError(t, err)
		assert.Equal(t, "2024-01-11T00:00:00Z", out)
	})
	t.Run("skips weekend", func(t *testing.T) {
		// 2024-01-05 is Friday, +1 business day = Monday 2024-01-08
		out, err := fn.Eval("2024-01-05T00:00:00Z", 1)
		require.NoError(t, err)
		assert.Equal(t, "2024-01-08T00:00:00Z", out)
	})
	t.Run("add 5 days skips a full weekend", func(t *testing.T) {
		// 2024-01-08 Monday +5 = 2024-01-15 Monday (skips Sat-Sun)
		out, err := fn.Eval("2024-01-08T00:00:00Z", 5)
		require.NoError(t, err)
		assert.Equal(t, "2024-01-15T00:00:00Z", out)
	})
	t.Run("negative days moves backward", func(t *testing.T) {
		// 2024-01-08 Monday -1 = 2024-01-05 Friday
		out, err := fn.Eval("2024-01-08T00:00:00Z", -1)
		require.NoError(t, err)
		assert.Equal(t, "2024-01-05T00:00:00Z", out)
	})
	t.Run("zero days returns same day", func(t *testing.T) {
		out, err := fn.Eval("2024-01-08T00:00:00Z", 0)
		require.NoError(t, err)
		assert.Equal(t, "2024-01-08T00:00:00Z", out)
	})
	t.Run("invalid date errors", func(t *testing.T) {
		_, err := fn.Eval("not-a-date", 1)
		assert.Error(t, err)
	})
}

// ─── startOfDay ───────────────────────────────────────────────────────────────

func TestStartOfDay(t *testing.T) {
	fn := &fnStartOfDay{}

	t.Run("strips time component", func(t *testing.T) {
		out, err := fn.Eval("2024-03-15T14:30:45Z")
		require.NoError(t, err)
		assert.Equal(t, "2024-03-15T00:00:00Z", out)
	})
	t.Run("already midnight unchanged", func(t *testing.T) {
		out, err := fn.Eval("2024-03-15T00:00:00Z")
		require.NoError(t, err)
		assert.Equal(t, "2024-03-15T00:00:00Z", out)
	})
	t.Run("end of day normalised to midnight", func(t *testing.T) {
		out, err := fn.Eval("2024-03-15T23:59:59Z")
		require.NoError(t, err)
		assert.Equal(t, "2024-03-15T00:00:00Z", out)
	})
	t.Run("invalid date errors", func(t *testing.T) {
		_, err := fn.Eval("not-a-date")
		assert.Error(t, err)
	})
}

// ─── quarter ──────────────────────────────────────────────────────────────────

func TestQuarter(t *testing.T) {
	fn := &fnQuarter{}

	t.Run("January => Q1", func(t *testing.T) {
		out, err := fn.Eval("2024-01-15T00:00:00Z")
		require.NoError(t, err)
		assert.Equal(t, 1, out)
	})
	t.Run("March => Q1", func(t *testing.T) {
		out, err := fn.Eval("2024-03-31T00:00:00Z")
		require.NoError(t, err)
		assert.Equal(t, 1, out)
	})
	t.Run("April => Q2", func(t *testing.T) {
		out, err := fn.Eval("2024-04-01T00:00:00Z")
		require.NoError(t, err)
		assert.Equal(t, 2, out)
	})
	t.Run("July => Q3", func(t *testing.T) {
		out, err := fn.Eval("2024-07-15T00:00:00Z")
		require.NoError(t, err)
		assert.Equal(t, 3, out)
	})
	t.Run("October => Q4", func(t *testing.T) {
		out, err := fn.Eval("2024-10-01T00:00:00Z")
		require.NoError(t, err)
		assert.Equal(t, 4, out)
	})
	t.Run("December => Q4", func(t *testing.T) {
		out, err := fn.Eval("2024-12-31T00:00:00Z")
		require.NoError(t, err)
		assert.Equal(t, 4, out)
	})
	t.Run("invalid date errors", func(t *testing.T) {
		_, err := fn.Eval("not-a-date")
		assert.Error(t, err)
	})
}
