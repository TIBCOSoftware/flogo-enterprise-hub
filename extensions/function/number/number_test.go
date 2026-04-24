package numberfn

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ─── randomInt ────────────────────────────────────────────────────────────────

func TestRandomInt(t *testing.T) {
	fn := &fnRandomInt{}

	t.Run("result within [min, max]", func(t *testing.T) {
		for i := 0; i < 50; i++ {
			out, err := fn.Eval(1, 10)
			require.NoError(t, err)
			v := out.(int)
			assert.GreaterOrEqual(t, v, 1)
			assert.LessOrEqual(t, v, 10)
		}
	})
	t.Run("single-value range always returns that value", func(t *testing.T) {
		out, err := fn.Eval(7, 7)
		require.NoError(t, err)
		assert.Equal(t, 7, out)
	})
	t.Run("negative range", func(t *testing.T) {
		for i := 0; i < 20; i++ {
			out, err := fn.Eval(-10, -1)
			require.NoError(t, err)
			v := out.(int)
			assert.GreaterOrEqual(t, v, -10)
			assert.LessOrEqual(t, v, -1)
		}
	})
	t.Run("zero-crossing range", func(t *testing.T) {
		for i := 0; i < 20; i++ {
			out, err := fn.Eval(-5, 5)
			require.NoError(t, err)
			v := out.(int)
			assert.GreaterOrEqual(t, v, -5)
			assert.LessOrEqual(t, v, 5)
		}
	})
	t.Run("min > max returns error", func(t *testing.T) {
		_, err := fn.Eval(10, 1)
		assert.Error(t, err)
	})
	t.Run("produces different values over multiple calls (randomness check)", func(t *testing.T) {
		seen := map[int]bool{}
		for i := 0; i < 100; i++ {
			out, _ := fn.Eval(0, 1000)
			seen[out.(int)] = true
		}
		// with range 0-1000 we should see at least a few distinct values in 100 tries
		assert.Greater(t, len(seen), 3)
	})
}
