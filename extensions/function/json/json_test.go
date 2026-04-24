package jsonfn

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ─── removeKey ────────────────────────────────────────────────────────────────

func TestRemoveKey(t *testing.T) {
	fn := &fnRemoveKey{}

	t.Run("removes existing key", func(t *testing.T) {
		input := map[string]interface{}{"a": 1, "b": 2, "c": 3}
		out, err := fn.Eval(input, "b")
		require.NoError(t, err)
		result := out.(map[string]interface{})
		assert.NotContains(t, result, "b")
		assert.Equal(t, 1, result["a"])
		assert.Equal(t, 3, result["c"])
	})
	t.Run("absent key returns object unchanged", func(t *testing.T) {
		input := map[string]interface{}{"x": 1}
		out, err := fn.Eval(input, "y")
		require.NoError(t, err)
		result := out.(map[string]interface{})
		assert.Equal(t, 1, result["x"])
		assert.Len(t, result, 1)
	})
	t.Run("does not mutate original", func(t *testing.T) {
		input := map[string]interface{}{"a": 1, "b": 2}
		_, err := fn.Eval(input, "a")
		require.NoError(t, err)
		// original unchanged
		assert.Contains(t, input, "a")
	})
	t.Run("empty object returns empty", func(t *testing.T) {
		out, err := fn.Eval(map[string]interface{}{}, "key")
		require.NoError(t, err)
		assert.Empty(t, out.(map[string]interface{}))
	})
	t.Run("non-object first arg errors", func(t *testing.T) {
		_, err := fn.Eval("not-an-object", "key")
		assert.Error(t, err)
	})
}

// ─── merge ────────────────────────────────────────────────────────────────────

func TestMerge(t *testing.T) {
	fn := &fnMerge{}

	t.Run("merges two objects", func(t *testing.T) {
		a := map[string]interface{}{"a": 1, "b": 2}
		b := map[string]interface{}{"b": 99, "c": 3}
		out, err := fn.Eval(a, b)
		require.NoError(t, err)
		result := out.(map[string]interface{})
		assert.Equal(t, 1, result["a"])
		assert.Equal(t, 99, result["b"]) // overwritten
		assert.Equal(t, 3, result["c"])
	})
	t.Run("later arg wins on key conflict", func(t *testing.T) {
		a := map[string]interface{}{"k": "first"}
		b := map[string]interface{}{"k": "second"}
		out, err := fn.Eval(a, b)
		require.NoError(t, err)
		assert.Equal(t, "second", out.(map[string]interface{})["k"])
	})
	t.Run("merges three objects", func(t *testing.T) {
		a := map[string]interface{}{"x": 1}
		b := map[string]interface{}{"y": 2}
		c := map[string]interface{}{"z": 3}
		out, err := fn.Eval(a, b, c)
		require.NoError(t, err)
		result := out.(map[string]interface{})
		assert.Equal(t, 1, result["x"])
		assert.Equal(t, 2, result["y"])
		assert.Equal(t, 3, result["z"])
	})
	t.Run("does not mutate base object", func(t *testing.T) {
		base := map[string]interface{}{"a": 1}
		overlay := map[string]interface{}{"b": 2}
		_, err := fn.Eval(base, overlay)
		require.NoError(t, err)
		assert.NotContains(t, base, "b")
	})
	t.Run("empty overlay returns copy of base", func(t *testing.T) {
		base := map[string]interface{}{"a": 1}
		out, err := fn.Eval(base, map[string]interface{}{})
		require.NoError(t, err)
		assert.Equal(t, 1, out.(map[string]interface{})["a"])
	})
	t.Run("fewer than 2 args errors", func(t *testing.T) {
		_, err := fn.Eval(map[string]interface{}{"a": 1})
		assert.Error(t, err)
	})
	t.Run("non-object arg errors", func(t *testing.T) {
		_, err := fn.Eval(map[string]interface{}{"a": 1}, "not-an-object")
		assert.Error(t, err)
	})
}
