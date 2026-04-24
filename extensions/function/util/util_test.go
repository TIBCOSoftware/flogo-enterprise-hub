package utilfn

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ─── coalesce ─────────────────────────────────────────────────────────────────

func TestCoalesce(t *testing.T) {
	fn := &fnCoalesce{}

	t.Run("returns first non-nil", func(t *testing.T) {
		out, err := fn.Eval(nil, nil, "hello")
		require.NoError(t, err)
		assert.Equal(t, "hello", out)
	})
	t.Run("skips empty string", func(t *testing.T) {
		out, err := fn.Eval("", "fallback")
		require.NoError(t, err)
		assert.Equal(t, "fallback", out)
	})
	t.Run("returns first non-empty", func(t *testing.T) {
		out, err := fn.Eval(nil, "", "first-valid", "second")
		require.NoError(t, err)
		assert.Equal(t, "first-valid", out)
	})
	t.Run("all nil returns nil", func(t *testing.T) {
		out, err := fn.Eval(nil, nil, nil)
		require.NoError(t, err)
		assert.Nil(t, out)
	})
	t.Run("non-string non-nil value", func(t *testing.T) {
		out, err := fn.Eval(nil, 42)
		require.NoError(t, err)
		assert.Equal(t, 42, out)
	})
	t.Run("single non-nil arg", func(t *testing.T) {
		out, err := fn.Eval("only")
		require.NoError(t, err)
		assert.Equal(t, "only", out)
	})
	t.Run("zero is valid (not skipped)", func(t *testing.T) {
		out, err := fn.Eval(nil, 0)
		require.NoError(t, err)
		assert.Equal(t, 0, out)
	})
}

// ─── sha256 ───────────────────────────────────────────────────────────────────

func TestSHA256(t *testing.T) {
	fn := &fnSHA256{}

	t.Run("well-known hash of 'hello'", func(t *testing.T) {
		out, err := fn.Eval("hello")
		require.NoError(t, err)
		assert.Equal(t, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", out)
	})
	t.Run("empty string", func(t *testing.T) {
		out, err := fn.Eval("")
		require.NoError(t, err)
		// SHA-256 of empty string
		assert.Equal(t, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", out)
	})
	t.Run("same input same output", func(t *testing.T) {
		out1, _ := fn.Eval("flogo")
		out2, _ := fn.Eval("flogo")
		assert.Equal(t, out1, out2)
	})
	t.Run("different inputs differ", func(t *testing.T) {
		out1, _ := fn.Eval("abc")
		out2, _ := fn.Eval("ABC")
		assert.NotEqual(t, out1, out2)
	})
	t.Run("output is 64 hex chars", func(t *testing.T) {
		out, err := fn.Eval("test")
		require.NoError(t, err)
		assert.Len(t, out, 64)
	})
}

// ─── hmacSha256 ───────────────────────────────────────────────────────────────

func TestHMACSHA256(t *testing.T) {
	fn := &fnHMACSHA256{}

	t.Run("known HMAC-SHA256 value", func(t *testing.T) {
		// echo -n "hello" | openssl dgst -sha256 -hmac "secret"
		out, err := fn.Eval("hello", "secret")
		require.NoError(t, err)
		assert.Equal(t, "88aab3ede8d3adf94d26ab90d3bafd4a2083070c3bcce9c014ee04a443847c0b", out)
	})
	t.Run("different keys produce different signatures", func(t *testing.T) {
		out1, _ := fn.Eval("payload", "key1")
		out2, _ := fn.Eval("payload", "key2")
		assert.NotEqual(t, out1, out2)
	})
	t.Run("different messages produce different signatures", func(t *testing.T) {
		out1, _ := fn.Eval("msg1", "key")
		out2, _ := fn.Eval("msg2", "key")
		assert.NotEqual(t, out1, out2)
	})
	t.Run("deterministic output", func(t *testing.T) {
		out1, _ := fn.Eval("body", "k")
		out2, _ := fn.Eval("body", "k")
		assert.Equal(t, out1, out2)
	})
	t.Run("output is 64 hex chars", func(t *testing.T) {
		out, err := fn.Eval("x", "y")
		require.NoError(t, err)
		assert.Len(t, out, 64)
	})
	t.Run("empty message", func(t *testing.T) {
		out, err := fn.Eval("", "secret")
		require.NoError(t, err)
		assert.NotEmpty(t, out)
	})
}

// ─── md5 ──────────────────────────────────────────────────────────────────────

func TestMD5(t *testing.T) {
	fn := &fnMD5{}

	t.Run("well-known MD5 of 'hello'", func(t *testing.T) {
		out, err := fn.Eval("hello")
		require.NoError(t, err)
		assert.Equal(t, "5d41402abc4b2a76b9719d911017c592", out)
	})
	t.Run("empty string", func(t *testing.T) {
		out, err := fn.Eval("")
		require.NoError(t, err)
		assert.Equal(t, "d41d8cd98f00b204e9800998ecf8427e", out)
	})
	t.Run("output is 32 hex chars", func(t *testing.T) {
		out, err := fn.Eval("anything")
		require.NoError(t, err)
		assert.Len(t, out, 32)
	})
	t.Run("deterministic", func(t *testing.T) {
		out1, _ := fn.Eval("flogo")
		out2, _ := fn.Eval("flogo")
		assert.Equal(t, out1, out2)
	})
}

// ─── base64UrlEncode ──────────────────────────────────────────────────────────

func TestBase64UrlEncode(t *testing.T) {
	fn := &fnBase64UrlEncode{}

	t.Run("basic encode", func(t *testing.T) {
		out, err := fn.Eval("Hello")
		require.NoError(t, err)
		assert.Equal(t, "SGVsbG8", out)
	})
	t.Run("no +/= in output", func(t *testing.T) {
		out, err := fn.Eval("Hello World!")
		require.NoError(t, err)
		s := out.(string)
		assert.NotContains(t, s, "+")
		assert.NotContains(t, s, "/")
		assert.NotContains(t, s, "=")
	})
	t.Run("empty string", func(t *testing.T) {
		out, err := fn.Eval("")
		require.NoError(t, err)
		assert.Equal(t, "", out)
	})
	t.Run("round-trips with decode", func(t *testing.T) {
		enc := &fnBase64UrlEncode{}
		dec := &fnBase64UrlDecode{}
		encoded, _ := enc.Eval("flogo custom functions")
		decoded, _ := dec.Eval(encoded)
		assert.Equal(t, "flogo custom functions", decoded)
	})
}

// ─── base64UrlDecode ──────────────────────────────────────────────────────────

func TestBase64UrlDecode(t *testing.T) {
	fn := &fnBase64UrlDecode{}

	t.Run("basic decode", func(t *testing.T) {
		out, err := fn.Eval("SGVsbG8")
		require.NoError(t, err)
		assert.Equal(t, "Hello", out)
	})
	t.Run("URL-safe chars accepted", func(t *testing.T) {
		// "Hello World!" encodes to "SGVsbG8gV29ybGQh" in raw URL-safe base64
		out, err := fn.Eval("SGVsbG8gV29ybGQh")
		require.NoError(t, err)
		assert.Equal(t, "Hello World!", out)
	})
	t.Run("invalid input returns error", func(t *testing.T) {
		_, err := fn.Eval("!!!invalid!!!")
		assert.Error(t, err)
	})
	t.Run("empty string", func(t *testing.T) {
		out, err := fn.Eval("")
		require.NoError(t, err)
		assert.Equal(t, "", out)
	})
}
