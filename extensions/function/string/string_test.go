package stringfn

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ─── padLeft ──────────────────────────────────────────────────────────────────

func TestPadLeft(t *testing.T) {
	fn := &fnPadLeft{}

	t.Run("zero-pad number", func(t *testing.T) {
		out, err := fn.Eval("7", 3, "0")
		require.NoError(t, err)
		assert.Equal(t, "007", out)
	})
	t.Run("space pad", func(t *testing.T) {
		out, err := fn.Eval("hi", 5, " ")
		require.NoError(t, err)
		assert.Equal(t, "   hi", out)
	})
	t.Run("already at size", func(t *testing.T) {
		out, err := fn.Eval("abc", 3, "0")
		require.NoError(t, err)
		assert.Equal(t, "abc", out)
	})
	t.Run("longer than size returns unchanged", func(t *testing.T) {
		out, err := fn.Eval("abcde", 3, "0")
		require.NoError(t, err)
		assert.Equal(t, "abcde", out)
	})
	t.Run("empty padChar defaults to space", func(t *testing.T) {
		out, err := fn.Eval("x", 3, "")
		require.NoError(t, err)
		assert.Equal(t, "  x", out)
	})
	t.Run("unicode string", func(t *testing.T) {
		out, err := fn.Eval("日本", 4, "_")
		require.NoError(t, err)
		assert.Equal(t, "__日本", out)
	})
}

// ─── padRight ─────────────────────────────────────────────────────────────────

func TestPadRight(t *testing.T) {
	fn := &fnPadRight{}

	t.Run("dash pad", func(t *testing.T) {
		out, err := fn.Eval("hi", 5, "-")
		require.NoError(t, err)
		assert.Equal(t, "hi---", out)
	})
	t.Run("already at size", func(t *testing.T) {
		out, err := fn.Eval("abc", 3, "x")
		require.NoError(t, err)
		assert.Equal(t, "abc", out)
	})
	t.Run("longer than size returns unchanged", func(t *testing.T) {
		out, err := fn.Eval("toolong", 3, "0")
		require.NoError(t, err)
		assert.Equal(t, "toolong", out)
	})
	t.Run("empty padChar defaults to space", func(t *testing.T) {
		out, err := fn.Eval("ok", 5, "")
		require.NoError(t, err)
		assert.Equal(t, "ok   ", out)
	})
}

// ─── mask ─────────────────────────────────────────────────────────────────────

func TestMask(t *testing.T) {
	fn := &fnMask{}

	t.Run("credit card - keep last 4", func(t *testing.T) {
		out, err := fn.Eval("4111-1111-1111-1234", 0, 4)
		require.NoError(t, err)
		assert.Equal(t, "***************1234", out)
	})
	t.Run("email - keep first 1 last 9", func(t *testing.T) {
		// "@acme.com" is 9 chars; keepLast=9 preserves the domain including @
		out, err := fn.Eval("john.doe@acme.com", 1, 9)
		require.NoError(t, err)
		assert.Equal(t, "j*******@acme.com", out)
	})
	t.Run("mask all", func(t *testing.T) {
		out, err := fn.Eval("secret", 0, 0)
		require.NoError(t, err)
		assert.Equal(t, "******", out)
	})
	t.Run("keepFirst+keepLast >= len returns unchanged", func(t *testing.T) {
		out, err := fn.Eval("abc", 2, 2)
		require.NoError(t, err)
		assert.Equal(t, "abc", out)
	})
	t.Run("keep first only", func(t *testing.T) {
		out, err := fn.Eval("password", 2, 0)
		require.NoError(t, err)
		assert.Equal(t, "pa******", out)
	})
	t.Run("keep last only", func(t *testing.T) {
		out, err := fn.Eval("password", 0, 3)
		require.NoError(t, err)
		assert.Equal(t, "*****ord", out)
	})
	t.Run("negative keepFirst", func(t *testing.T) {
		_, err := fn.Eval("abc", -1, 0)
		assert.Error(t, err)
	})
}

// ─── truncate ─────────────────────────────────────────────────────────────────

func TestTruncate(t *testing.T) {
	fn := &fnTruncate{}

	t.Run("longer than maxLen", func(t *testing.T) {
		out, err := fn.Eval("Hello, World!", 8)
		require.NoError(t, err)
		assert.Equal(t, "Hello...", out)
	})
	t.Run("exactly maxLen — no truncation", func(t *testing.T) {
		out, err := fn.Eval("Hello", 5)
		require.NoError(t, err)
		assert.Equal(t, "Hello", out)
	})
	t.Run("shorter than maxLen — unchanged", func(t *testing.T) {
		out, err := fn.Eval("Hi", 10)
		require.NoError(t, err)
		assert.Equal(t, "Hi", out)
	})
	t.Run("maxLen = 3 exactly fits ellipsis", func(t *testing.T) {
		out, err := fn.Eval("LongString", 3)
		require.NoError(t, err)
		assert.Equal(t, "...", out)
	})
	t.Run("maxLen = 0", func(t *testing.T) {
		out, err := fn.Eval("abc", 0)
		require.NoError(t, err)
		assert.Equal(t, "", out)
	})
	t.Run("empty string", func(t *testing.T) {
		out, err := fn.Eval("", 5)
		require.NoError(t, err)
		assert.Equal(t, "", out)
	})
	t.Run("negative maxLen errors", func(t *testing.T) {
		_, err := fn.Eval("abc", -1)
		assert.Error(t, err)
	})
}

// ─── isBlank ──────────────────────────────────────────────────────────────────

func TestIsBlank(t *testing.T) {
	fn := &fnIsBlank{}

	t.Run("empty string", func(t *testing.T) {
		out, err := fn.Eval("")
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("whitespace only", func(t *testing.T) {
		out, err := fn.Eval("   \t\n")
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("nil", func(t *testing.T) {
		out, err := fn.Eval(nil)
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("non-empty", func(t *testing.T) {
		out, err := fn.Eval("hello")
		require.NoError(t, err)
		assert.Equal(t, false, out)
	})
	t.Run("space-padded content", func(t *testing.T) {
		out, err := fn.Eval("  x  ")
		require.NoError(t, err)
		assert.Equal(t, false, out)
	})
}

// ─── isNumeric ────────────────────────────────────────────────────────────────

func TestIsNumeric(t *testing.T) {
	fn := &fnIsNumeric{}

	t.Run("integer", func(t *testing.T) {
		out, err := fn.Eval("42")
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("float", func(t *testing.T) {
		out, err := fn.Eval("3.14")
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("negative float", func(t *testing.T) {
		out, err := fn.Eval("-2.5")
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("positive sign", func(t *testing.T) {
		out, err := fn.Eval("+10")
		require.NoError(t, err)
		assert.Equal(t, true, out)
	})
	t.Run("alpha string", func(t *testing.T) {
		out, err := fn.Eval("abc")
		require.NoError(t, err)
		assert.Equal(t, false, out)
	})
	t.Run("mixed alphanumeric", func(t *testing.T) {
		out, err := fn.Eval("12px")
		require.NoError(t, err)
		assert.Equal(t, false, out)
	})
	t.Run("empty string", func(t *testing.T) {
		out, err := fn.Eval("")
		require.NoError(t, err)
		assert.Equal(t, false, out)
	})
	t.Run("nil", func(t *testing.T) {
		out, err := fn.Eval(nil)
		require.NoError(t, err)
		assert.Equal(t, false, out)
	})
}

// ─── camelCase ────────────────────────────────────────────────────────────────

func TestCamelCase(t *testing.T) {
	fn := &fnCamelCase{}

	t.Run("snake_case input", func(t *testing.T) {
		out, err := fn.Eval("user_first_name")
		require.NoError(t, err)
		assert.Equal(t, "userFirstName", out)
	})
	t.Run("space separated", func(t *testing.T) {
		out, err := fn.Eval("hello world")
		require.NoError(t, err)
		assert.Equal(t, "helloWorld", out)
	})
	t.Run("hyphen separated", func(t *testing.T) {
		out, err := fn.Eval("my-field-name")
		require.NoError(t, err)
		assert.Equal(t, "myFieldName", out)
	})
	t.Run("already camel", func(t *testing.T) {
		out, err := fn.Eval("helloWorld")
		require.NoError(t, err)
		assert.Equal(t, "helloWorld", out)
	})
	t.Run("all upper", func(t *testing.T) {
		out, err := fn.Eval("FOO BAR")
		require.NoError(t, err)
		assert.Equal(t, "fooBar", out)
	})
	t.Run("empty string", func(t *testing.T) {
		out, err := fn.Eval("")
		require.NoError(t, err)
		assert.Equal(t, "", out)
	})
}

// ─── snakeCase ────────────────────────────────────────────────────────────────

func TestSnakeCase(t *testing.T) {
	fn := &fnSnakeCase{}

	t.Run("camelCase input", func(t *testing.T) {
		out, err := fn.Eval("userFirstName")
		require.NoError(t, err)
		assert.Equal(t, "user_first_name", out)
	})
	t.Run("space separated", func(t *testing.T) {
		out, err := fn.Eval("Hello World")
		require.NoError(t, err)
		assert.Equal(t, "hello_world", out)
	})
	t.Run("hyphen separated", func(t *testing.T) {
		out, err := fn.Eval("FOO-BAR")
		require.NoError(t, err)
		assert.Equal(t, "foo_bar", out)
	})
	t.Run("already snake", func(t *testing.T) {
		out, err := fn.Eval("hello_world")
		require.NoError(t, err)
		assert.Equal(t, "hello_world", out)
	})
	t.Run("empty string", func(t *testing.T) {
		out, err := fn.Eval("")
		require.NoError(t, err)
		assert.Equal(t, "", out)
	})
}

// ─── regexExtract ─────────────────────────────────────────────────────────────

func TestRegexExtract(t *testing.T) {
	fn := &fnRegexExtract{}

	t.Run("extract digits (no capture group)", func(t *testing.T) {
		out, err := fn.Eval("order-12345-done", `\d+`)
		require.NoError(t, err)
		assert.Equal(t, "12345", out)
	})
	t.Run("extract with capture group returns group 1", func(t *testing.T) {
		out, err := fn.Eval("foo@example.com", `(\w+)@`)
		require.NoError(t, err)
		assert.Equal(t, "foo", out)
	})
	t.Run("no match returns empty string", func(t *testing.T) {
		out, err := fn.Eval("hello world", `\d+`)
		require.NoError(t, err)
		assert.Equal(t, "", out)
	})
	t.Run("invalid pattern returns error", func(t *testing.T) {
		_, err := fn.Eval("test", `[invalid`)
		assert.Error(t, err)
	})
	t.Run("first match only", func(t *testing.T) {
		out, err := fn.Eval("abc 123 def 456", `\d+`)
		require.NoError(t, err)
		assert.Equal(t, "123", out)
	})
	t.Run("email domain capture", func(t *testing.T) {
		out, err := fn.Eval("user@tibco.com", `@(.+)$`)
		require.NoError(t, err)
		assert.Equal(t, "tibco.com", out)
	})
}

// ─── format ───────────────────────────────────────────────────────────────────

func TestFormat(t *testing.T) {
	fn := &fnFormat{}

	t.Run("string substitution", func(t *testing.T) {
		out, err := fn.Eval("Hello %s!", "World")
		require.NoError(t, err)
		assert.Equal(t, "Hello World!", out)
	})
	t.Run("integer substitution", func(t *testing.T) {
		out, err := fn.Eval("You have %d messages", 5)
		require.NoError(t, err)
		assert.Equal(t, "You have 5 messages", out)
	})
	t.Run("float with precision", func(t *testing.T) {
		out, err := fn.Eval("Price: %.2f", 9.5)
		require.NoError(t, err)
		assert.Equal(t, "Price: 9.50", out)
	})
	t.Run("multiple args", func(t *testing.T) {
		out, err := fn.Eval("%s is %d years old", "Alice", 30)
		require.NoError(t, err)
		assert.Equal(t, "Alice is 30 years old", out)
	})
	t.Run("no args returns template unchanged", func(t *testing.T) {
		out, err := fn.Eval("static text")
		require.NoError(t, err)
		assert.Equal(t, "static text", out)
	})
	t.Run("no template returns error", func(t *testing.T) {
		_, err := fn.Eval()
		assert.Error(t, err)
	})
}
