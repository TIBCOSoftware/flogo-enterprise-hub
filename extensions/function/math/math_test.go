package mathfn

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAbs(t *testing.T) {
	fn := &fnAbs{}

	t.Run("negative float", func(t *testing.T) {
		out, err := fn.Eval(-5.5)
		require.NoError(t, err)
		assert.Equal(t, 5.5, out)
	})
	t.Run("positive float", func(t *testing.T) {
		out, err := fn.Eval(3.14)
		require.NoError(t, err)
		assert.Equal(t, 3.14, out)
	})
	t.Run("zero", func(t *testing.T) {
		out, err := fn.Eval(0.0)
		require.NoError(t, err)
		assert.Equal(t, 0.0, out)
	})
	t.Run("integer input", func(t *testing.T) {
		out, err := fn.Eval(-7)
		require.NoError(t, err)
		assert.Equal(t, 7.0, out)
	})
	t.Run("string number input", func(t *testing.T) {
		out, err := fn.Eval("-3.0")
		require.NoError(t, err)
		assert.Equal(t, 3.0, out)
	})
	t.Run("invalid input", func(t *testing.T) {
		_, err := fn.Eval("not-a-number")
		assert.Error(t, err)
	})
}

func TestPow(t *testing.T) {
	fn := &fnPow{}

	t.Run("2 to the 10", func(t *testing.T) {
		out, err := fn.Eval(2.0, 10.0)
		require.NoError(t, err)
		assert.Equal(t, 1024.0, out)
	})
	t.Run("square root via fractional exp", func(t *testing.T) {
		out, err := fn.Eval(9.0, 0.5)
		require.NoError(t, err)
		assert.InDelta(t, 3.0, out, 1e-9)
	})
	t.Run("zero exponent", func(t *testing.T) {
		out, err := fn.Eval(5.0, 0.0)
		require.NoError(t, err)
		assert.Equal(t, 1.0, out)
	})
	t.Run("base zero", func(t *testing.T) {
		out, err := fn.Eval(0.0, 5.0)
		require.NoError(t, err)
		assert.Equal(t, 0.0, out)
	})
	t.Run("integer inputs", func(t *testing.T) {
		out, err := fn.Eval(3, 3)
		require.NoError(t, err)
		assert.Equal(t, 27.0, out)
	})
}

func TestSqrt(t *testing.T) {
	fn := &fnSqrt{}

	t.Run("perfect square", func(t *testing.T) {
		out, err := fn.Eval(9.0)
		require.NoError(t, err)
		assert.InDelta(t, 3.0, out, 1e-9)
	})
	t.Run("non-perfect square", func(t *testing.T) {
		out, err := fn.Eval(2.0)
		require.NoError(t, err)
		assert.InDelta(t, 1.4142135623, out, 1e-9)
	})
	t.Run("zero", func(t *testing.T) {
		out, err := fn.Eval(0.0)
		require.NoError(t, err)
		assert.Equal(t, 0.0, out)
	})
	t.Run("negative returns error", func(t *testing.T) {
		_, err := fn.Eval(-4.0)
		assert.Error(t, err)
	})
	t.Run("integer input", func(t *testing.T) {
		out, err := fn.Eval(16)
		require.NoError(t, err)
		assert.InDelta(t, 4.0, out, 1e-9)
	})
}

func TestLog(t *testing.T) {
	fn := &fnLog{}

	t.Run("ln(e) = 1", func(t *testing.T) {
		out, err := fn.Eval(2.718281828459045)
		require.NoError(t, err)
		assert.InDelta(t, 1.0, out, 1e-9)
	})
	t.Run("ln(1) = 0", func(t *testing.T) {
		out, err := fn.Eval(1.0)
		require.NoError(t, err)
		assert.InDelta(t, 0.0, out, 1e-9)
	})
	t.Run("negative returns error", func(t *testing.T) {
		_, err := fn.Eval(-1.0)
		assert.Error(t, err)
	})
	t.Run("zero returns error", func(t *testing.T) {
		_, err := fn.Eval(0.0)
		assert.Error(t, err)
	})
}

func TestLog2(t *testing.T) {
	fn := &fnLog2{}

	t.Run("log2(8) = 3", func(t *testing.T) {
		out, err := fn.Eval(8.0)
		require.NoError(t, err)
		assert.InDelta(t, 3.0, out, 1e-9)
	})
	t.Run("log2(1) = 0", func(t *testing.T) {
		out, err := fn.Eval(1.0)
		require.NoError(t, err)
		assert.InDelta(t, 0.0, out, 1e-9)
	})
	t.Run("zero returns error", func(t *testing.T) {
		_, err := fn.Eval(0.0)
		assert.Error(t, err)
	})
}

func TestLog10(t *testing.T) {
	fn := &fnLog10{}

	t.Run("log10(1000) = 3", func(t *testing.T) {
		out, err := fn.Eval(1000.0)
		require.NoError(t, err)
		assert.InDelta(t, 3.0, out, 1e-9)
	})
	t.Run("log10(1) = 0", func(t *testing.T) {
		out, err := fn.Eval(1.0)
		require.NoError(t, err)
		assert.InDelta(t, 0.0, out, 1e-9)
	})
	t.Run("zero returns error", func(t *testing.T) {
		_, err := fn.Eval(0.0)
		assert.Error(t, err)
	})
}

func TestSign(t *testing.T) {
	fn := &fnSign{}

	t.Run("negative", func(t *testing.T) {
		out, err := fn.Eval(-7.5)
		require.NoError(t, err)
		assert.Equal(t, -1.0, out)
	})
	t.Run("zero", func(t *testing.T) {
		out, err := fn.Eval(0.0)
		require.NoError(t, err)
		assert.Equal(t, 0.0, out)
	})
	t.Run("positive", func(t *testing.T) {
		out, err := fn.Eval(42.0)
		require.NoError(t, err)
		assert.Equal(t, 1.0, out)
	})
	t.Run("integer input", func(t *testing.T) {
		out, err := fn.Eval(-3)
		require.NoError(t, err)
		assert.Equal(t, -1.0, out)
	})
}

func TestClamp(t *testing.T) {
	fn := &fnClamp{}

	t.Run("below min", func(t *testing.T) {
		out, err := fn.Eval(-10.0, 0.0, 100.0)
		require.NoError(t, err)
		assert.Equal(t, 0.0, out)
	})
	t.Run("above max", func(t *testing.T) {
		out, err := fn.Eval(150.0, 0.0, 100.0)
		require.NoError(t, err)
		assert.Equal(t, 100.0, out)
	})
	t.Run("within range", func(t *testing.T) {
		out, err := fn.Eval(50.0, 0.0, 100.0)
		require.NoError(t, err)
		assert.Equal(t, 50.0, out)
	})
	t.Run("exactly min", func(t *testing.T) {
		out, err := fn.Eval(0.0, 0.0, 100.0)
		require.NoError(t, err)
		assert.Equal(t, 0.0, out)
	})
	t.Run("exactly max", func(t *testing.T) {
		out, err := fn.Eval(100.0, 0.0, 100.0)
		require.NoError(t, err)
		assert.Equal(t, 100.0, out)
	})
	t.Run("min greater than max returns error", func(t *testing.T) {
		_, err := fn.Eval(50.0, 100.0, 0.0)
		assert.Error(t, err)
	})
	t.Run("integer inputs", func(t *testing.T) {
		out, err := fn.Eval(5, 1, 10)
		require.NoError(t, err)
		assert.Equal(t, 5.0, out)
	})
}
