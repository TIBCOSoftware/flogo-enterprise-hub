package arrayfn

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ─── min ──────────────────────────────────────────────────────────────────────

func TestMin(t *testing.T) {
	fn := &fnMin{}

	t.Run("integers", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{3, 1, 4, 1, 5, 9})
		require.NoError(t, err)
		assert.Equal(t, 1.0, out)
	})
	t.Run("floats", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{3.5, 1.1, 2.9})
		require.NoError(t, err)
		assert.Equal(t, 1.1, out)
	})
	t.Run("single element", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{42})
		require.NoError(t, err)
		assert.Equal(t, 42.0, out)
	})
	t.Run("negative values", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{-1, -5, -2})
		require.NoError(t, err)
		assert.Equal(t, -5.0, out)
	})
	t.Run("empty array", func(t *testing.T) {
		_, err := fn.Eval([]interface{}{})
		assert.Error(t, err)
	})
	t.Run("nil input", func(t *testing.T) {
		_, err := fn.Eval(nil)
		assert.Error(t, err)
	})
}

// ─── max ──────────────────────────────────────────────────────────────────────

func TestMax(t *testing.T) {
	fn := &fnMax{}

	t.Run("integers", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{3, 1, 4, 1, 5, 9})
		require.NoError(t, err)
		assert.Equal(t, 9.0, out)
	})
	t.Run("floats", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{3.5, 1.1, 2.9})
		require.NoError(t, err)
		assert.Equal(t, 3.5, out)
	})
	t.Run("negative values", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{-1, -5, -2})
		require.NoError(t, err)
		assert.Equal(t, -1.0, out)
	})
}

// ─── avg ──────────────────────────────────────────────────────────────────────

func TestAvg(t *testing.T) {
	fn := &fnAvg{}

	t.Run("integers", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{1, 2, 3, 4, 5})
		require.NoError(t, err)
		assert.Equal(t, 3.0, out)
	})
	t.Run("floats", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{1.0, 2.0, 3.0})
		require.NoError(t, err)
		assert.InDelta(t, 2.0, out, 1e-9)
	})
	t.Run("single element", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{7})
		require.NoError(t, err)
		assert.Equal(t, 7.0, out)
	})
}

// ─── unique ───────────────────────────────────────────────────────────────────

func TestUnique(t *testing.T) {
	fn := &fnUnique{}

	t.Run("removes duplicates", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{1, 2, 2, 3, 1})
		require.NoError(t, err)
		assert.Equal(t, []interface{}{1, 2, 3}, out)
	})
	t.Run("preserves order", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{"c", "a", "b", "a", "c"})
		require.NoError(t, err)
		assert.Equal(t, []interface{}{"c", "a", "b"}, out)
	})
	t.Run("no duplicates stays unchanged", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{10, 20, 30})
		require.NoError(t, err)
		assert.Equal(t, []interface{}{10, 20, 30}, out)
	})
	t.Run("all duplicates", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{"x", "x", "x"})
		require.NoError(t, err)
		assert.Equal(t, []interface{}{"x"}, out)
	})
	t.Run("empty array", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{})
		require.NoError(t, err)
		assert.Equal(t, []interface{}{}, out)
	})
}

// ─── indexOf ──────────────────────────────────────────────────────────────────

func TestIndexOf(t *testing.T) {
	fn := &fnIndexOf{}

	t.Run("found string", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{"a", "b", "c"}, "b")
		require.NoError(t, err)
		assert.Equal(t, 1, out)
	})
	t.Run("found integer", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{10, 20, 30}, 20)
		require.NoError(t, err)
		assert.Equal(t, 1, out)
	})
	t.Run("not found returns -1", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{"a", "b", "c"}, "z")
		require.NoError(t, err)
		assert.Equal(t, -1, out)
	})
	t.Run("first occurrence", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{"a", "b", "a", "c"}, "a")
		require.NoError(t, err)
		assert.Equal(t, 0, out)
	})
	t.Run("empty array", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{}, "x")
		require.NoError(t, err)
		assert.Equal(t, -1, out)
	})
}

// ─── sort / sortDesc ──────────────────────────────────────────────────────────

func TestSort(t *testing.T) {
	fn := &fnSort{}

	t.Run("numeric ascending", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{3.0, 1.0, 4.0, 1.0, 5.0})
		require.NoError(t, err)
		assert.Equal(t, []interface{}{1.0, 1.0, 3.0, 4.0, 5.0}, out)
	})
	t.Run("already sorted", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{1.0, 2.0, 3.0})
		require.NoError(t, err)
		assert.Equal(t, []interface{}{1.0, 2.0, 3.0}, out)
	})
	t.Run("string array", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{"banana", "apple", "cherry"})
		require.NoError(t, err)
		assert.Equal(t, []interface{}{"apple", "banana", "cherry"}, out)
	})
	t.Run("single element", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{42.0})
		require.NoError(t, err)
		assert.Equal(t, []interface{}{42.0}, out)
	})
	t.Run("nil input errors", func(t *testing.T) {
		_, err := fn.Eval(nil)
		assert.Error(t, err)
	})
}

func TestSortDesc(t *testing.T) {
	fn := &fnSortDesc{}

	t.Run("numeric descending", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{3.0, 1.0, 4.0, 1.0, 5.0})
		require.NoError(t, err)
		assert.Equal(t, []interface{}{5.0, 4.0, 3.0, 1.0, 1.0}, out)
	})
	t.Run("string descending", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{"banana", "apple", "cherry"})
		require.NoError(t, err)
		assert.Equal(t, []interface{}{"cherry", "banana", "apple"}, out)
	})
}

// ─── first / last ─────────────────────────────────────────────────────────────

func TestFirst(t *testing.T) {
	fn := &fnFirst{}

	t.Run("returns first element", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{10, 20, 30})
		require.NoError(t, err)
		assert.Equal(t, 10, out)
	})
	t.Run("single element", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{"only"})
		require.NoError(t, err)
		assert.Equal(t, "only", out)
	})
	t.Run("empty returns nil", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{})
		require.NoError(t, err)
		assert.Nil(t, out)
	})
	t.Run("nil input errors", func(t *testing.T) {
		_, err := fn.Eval(nil)
		assert.Error(t, err)
	})
}

func TestLast(t *testing.T) {
	fn := &fnLast{}

	t.Run("returns last element", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{10, 20, 30})
		require.NoError(t, err)
		assert.Equal(t, 30, out)
	})
	t.Run("single element", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{"only"})
		require.NoError(t, err)
		assert.Equal(t, "only", out)
	})
	t.Run("empty returns nil", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{})
		require.NoError(t, err)
		assert.Nil(t, out)
	})
}

// ─── sumBy ────────────────────────────────────────────────────────────────────

func TestSumBy(t *testing.T) {
	fn := &fnSumBy{}

	t.Run("sums named field", func(t *testing.T) {
		input := []interface{}{
			map[string]interface{}{"amount": 10.0, "name": "a"},
			map[string]interface{}{"amount": 20.0, "name": "b"},
			map[string]interface{}{"amount": 30.0, "name": "c"},
		}
		out, err := fn.Eval(input, "amount")
		require.NoError(t, err)
		assert.InDelta(t, 60.0, out, 1e-9)
	})
	t.Run("missing field treated as 0", func(t *testing.T) {
		input := []interface{}{
			map[string]interface{}{"amount": 10.0},
			map[string]interface{}{"other": 99.0},
		}
		out, err := fn.Eval(input, "amount")
		require.NoError(t, err)
		assert.InDelta(t, 10.0, out, 1e-9)
	})
	t.Run("empty array returns 0", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{}, "amount")
		require.NoError(t, err)
		assert.InDelta(t, 0.0, out, 1e-9)
	})
	t.Run("string number field coerced", func(t *testing.T) {
		input := []interface{}{
			map[string]interface{}{"price": "5.5"},
			map[string]interface{}{"price": "4.5"},
		}
		out, err := fn.Eval(input, "price")
		require.NoError(t, err)
		assert.InDelta(t, 10.0, out, 1e-9)
	})
	t.Run("non-object element errors", func(t *testing.T) {
		input := []interface{}{"not-an-object"}
		_, err := fn.Eval(input, "amount")
		assert.Error(t, err)
	})
	t.Run("empty field name errors", func(t *testing.T) {
		_, err := fn.Eval([]interface{}{}, "")
		assert.Error(t, err)
	})
}

// ─── filter ───────────────────────────────────────────────────────────────────

func TestFilter(t *testing.T) {
	fn := &fnFilter{}

	users := []interface{}{
		map[string]interface{}{"name": "Alice", "status": "active"},
		map[string]interface{}{"name": "Bob", "status": "inactive"},
		map[string]interface{}{"name": "Carol", "status": "active"},
	}

	t.Run("filters by string field", func(t *testing.T) {
		out, err := fn.Eval(users, "status", "active")
		require.NoError(t, err)
		result := out.([]interface{})
		assert.Len(t, result, 2)
		assert.Equal(t, "Alice", result[0].(map[string]interface{})["name"])
		assert.Equal(t, "Carol", result[1].(map[string]interface{})["name"])
	})
	t.Run("no match returns empty array", func(t *testing.T) {
		out, err := fn.Eval(users, "status", "pending")
		require.NoError(t, err)
		assert.Empty(t, out.([]interface{}))
	})
	t.Run("field absent in element skips it", func(t *testing.T) {
		mixed := []interface{}{
			map[string]interface{}{"name": "Dave"},
			map[string]interface{}{"name": "Eve", "status": "active"},
		}
		out, err := fn.Eval(mixed, "status", "active")
		require.NoError(t, err)
		result := out.([]interface{})
		assert.Len(t, result, 1)
	})
	t.Run("non-object elements are skipped", func(t *testing.T) {
		mixed := []interface{}{"string", 42, map[string]interface{}{"status": "active"}}
		out, err := fn.Eval(mixed, "status", "active")
		require.NoError(t, err)
		assert.Len(t, out.([]interface{}), 1)
	})
	t.Run("empty array returns empty", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{}, "status", "active")
		require.NoError(t, err)
		assert.Empty(t, out.([]interface{}))
	})
	t.Run("numeric field match", func(t *testing.T) {
		items := []interface{}{
			map[string]interface{}{"code": 1},
			map[string]interface{}{"code": 2},
		}
		out, err := fn.Eval(items, "code", 1)
		require.NoError(t, err)
		assert.Len(t, out.([]interface{}), 1)
	})
}

// ─── pluck ────────────────────────────────────────────────────────────────────

func TestPluck(t *testing.T) {
	fn := &fnPluck{}

	t.Run("extracts field from each object", func(t *testing.T) {
		input := []interface{}{
			map[string]interface{}{"email": "a@x.com", "name": "A"},
			map[string]interface{}{"email": "b@x.com", "name": "B"},
		}
		out, err := fn.Eval(input, "email")
		require.NoError(t, err)
		result := out.([]interface{})
		assert.Equal(t, []interface{}{"a@x.com", "b@x.com"}, result)
	})
	t.Run("missing field gives nil in position", func(t *testing.T) {
		input := []interface{}{
			map[string]interface{}{"a": 1},
			map[string]interface{}{"b": 2},
		}
		out, err := fn.Eval(input, "a")
		require.NoError(t, err)
		result := out.([]interface{})
		assert.Equal(t, 1, result[0])
		assert.Nil(t, result[1])
	})
	t.Run("non-object element gives nil in position", func(t *testing.T) {
		input := []interface{}{"not-an-object", map[string]interface{}{"x": "val"}}
		out, err := fn.Eval(input, "x")
		require.NoError(t, err)
		result := out.([]interface{})
		assert.Nil(t, result[0])
		assert.Equal(t, "val", result[1])
	})
	t.Run("empty array returns empty", func(t *testing.T) {
		out, err := fn.Eval([]interface{}{}, "field")
		require.NoError(t, err)
		assert.Empty(t, out.([]interface{}))
	})
}
