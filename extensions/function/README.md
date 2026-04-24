# Custom Flogo Functions

Custom Flogo expression functions extending the built-in set across 7 packages: math, array, string, util, datetime, number, and json.

## Functions

### `math` — Math helpers

| Function | Signature | Description |
|----------|-----------|-------------|
| `math.abs` | `abs(x float64) float64` | Absolute value |
| `math.pow` | `pow(base float64, exp float64) float64` | Raises `base` to the power of `exp` |
| `math.sqrt` | `sqrt(x float64) float64` | Square root; error if x < 0 |
| `math.log` | `log(x float64) float64` | Natural logarithm (base e); error if x ≤ 0 |
| `math.log2` | `log2(x float64) float64` | Base-2 logarithm; error if x ≤ 0 |
| `math.log10` | `log10(x float64) float64` | Base-10 logarithm; error if x ≤ 0 |
| `math.sign` | `sign(x float64) float64` | Returns -1, 0, or 1 |
| `math.clamp` | `clamp(val float64, min float64, max float64) float64` | Bounds val to [min, max] |

### `array` — Array helpers

| Function | Signature | Description |
|----------|-----------|-------------|
| `array.min` | `min(arr) float64` | Minimum numeric value in array |
| `array.max` | `max(arr) float64` | Maximum numeric value in array |
| `array.avg` | `avg(arr) float64` | Average (mean) of numeric values in array |
| `array.unique` | `unique(arr) []any` | Deduplicated array, original order preserved |
| `array.indexOf` | `indexOf(arr []any, value any) int` | Index of first occurrence; `-1` if not found |
| `array.sort` | `sort(arr) []any` | Sorted ascending (numeric or string) |
| `array.sortDesc` | `sortDesc(arr) []any` | Sorted descending |
| `array.first` | `first(arr) any` | First element; `nil` for empty array |
| `array.last` | `last(arr) any` | Last element; `nil` for empty array |
| `array.sumBy` | `sumBy(arr []any, field string) float64` | Sum a numeric field across an array of objects |
| `array.filter` | `filter(arr []any, field string, value any) []any` | Elements where `element[field] == value`; non-objects skipped |
| `array.pluck` | `pluck(arr []any, field string) []any` | Extract a single field value from every object in array |

### `string` — String helpers

| Function | Signature | Description |
|----------|-----------|-------------|
| `string.padLeft` | `padLeft(str string, size int, padChar string) string` | Left-pad to `size` characters |
| `string.padRight` | `padRight(str string, size int, padChar string) string` | Right-pad to `size` characters |
| `string.mask` | `mask(str string, keepFirst int, keepLast int) string` | Replace middle chars with `*` |
| `string.truncate` | `truncate(str string, maxLen int) string` | Truncate to `maxLen`, appending `...` if cut |
| `string.isBlank` | `isBlank(str string) bool` | True if nil, empty, or whitespace-only |
| `string.isNumeric` | `isNumeric(str string) bool` | True if the string is a valid decimal number |
| `string.camelCase` | `camelCase(str string) string` | Convert to lowerCamelCase |
| `string.snakeCase` | `snakeCase(str string) string` | Convert to snake_case |
| `string.regexExtract` | `regexExtract(str string, pattern string) string` | First match or first capture group; `""` if no match. OOTB `matchRegEx` only returns bool. |
| `string.format` | `format(template string, args ...any) string` | `fmt.Sprintf`-style substitution (`%s`, `%d`, `%.2f`, etc.) |

### `util` — Utility helpers

| Function | Signature | Description |
|----------|-----------|-------------|
| `util.coalesce` | `coalesce(vals ...any) any` | First non-nil, non-empty value |
| `util.sha256` | `sha256(str string) string` | SHA-256 hex digest (64-char lowercase) |
| `util.hmacSha256` | `hmacSha256(message string, key string) string` | HMAC-SHA256 hex digest — webhook signing, API auth headers |
| `util.md5` | `md5(str string) string` | MD5 hex digest (32-char lowercase) — ETags, content-MD5, legacy checksums |
| `util.base64UrlEncode` | `base64UrlEncode(str string) string` | URL-safe Base64 (RFC 4648 §5, no padding). Required for JWTs and OAuth tokens — OOTB base64 uses standard alphabet (`+`, `/`) |
| `util.base64UrlDecode` | `base64UrlDecode(base64url string) string` | Decode URL-safe Base64 (with or without padding) |

### `datetime` — Datetime helpers

All datetime functions accept any format supported by Flogo's `coerce.ToDateTime` (RFC3339, ISO 8601, `2006-01-02`, etc.).

| Function | Signature | Description |
|----------|-----------|-------------|
| `datetime.isBefore` | `isBefore(d1 string, d2 string) bool` | True if d1 is strictly before d2 |
| `datetime.isAfter` | `isAfter(d1 string, d2 string) bool` | True if d1 is strictly after d2 |
| `datetime.toEpoch` | `toEpoch(d string) int` | Datetime string → Unix epoch milliseconds |
| `datetime.fromEpoch` | `fromEpoch(ms int) string` | Unix epoch milliseconds → RFC3339 UTC string |
| `datetime.isWeekend` | `isWeekend(d string) bool` | True if date is Saturday or Sunday |
| `datetime.isWeekday` | `isWeekday(d string) bool` | True if date is Monday through Friday |
| `datetime.addBusinessDays` | `addBusinessDays(d string, n int) string` | Add `n` business days (Mon–Fri), skipping weekends. Negative `n` moves backward. Returns RFC3339. |
| `datetime.startOfDay` | `startOfDay(d string) string` | Start of day (00:00:00 UTC) as RFC3339. Normalises timestamps to midnight. |
| `datetime.quarter` | `quarter(d string) int` | Calendar quarter 1–4 (Jan–Mar=1, Apr–Jun=2, Jul–Sep=3, Oct–Dec=4) |

### `number` — Number helpers

| Function | Signature | Description |
|----------|-----------|-------------|
| `number.randomInt` | `randomInt(min int, max int) int` | Cryptographically random integer in `[min, max]` inclusive. OOTB `number.random(n)` is `[0, n-1]` with low-quality re-seeding. |

### `json` — JSON object helpers

| Function | Signature | Description |
|----------|-----------|-------------|
| `json.removeKey` | `removeKey(obj object, key string) object` | Copy of the object with `key` deleted. OOTB `json.set(obj,key,nil)` sets to null — it does not remove the key. |
| `json.merge` | `merge(base object, overlays ...object) object` | Shallow-merge two or more objects. Later-argument keys win. OOTB `array.merge` is array-concat only; `json.set` is one-key-at-a-time. |

---

## Debug Logging

All functions emit `Debugf` log lines via `log.RootLogger()` at key points:
- **Entry**: input parameters
- **Intermediate**: key computed values
- **Exit**: final result

Activate with `FLOGO_LOG_LEVEL=DEBUG`.

---

## Usage

Add the root package as a single import in your `.flogo` file:

```json
"imports": [
  "github.com/milindpandav/flogo-extensions/function"
]
```

The root `all.go` blank-imports all sub-packages, triggering their `init()` functions and registering every custom function.

Example expressions:

```
=util.hmacSha256($flow.payload, $flow.webhookSecret)
=util.base64UrlEncode($flow.jwtHeader)
=util.md5($flow.content)

=string.regexExtract($flow.ref, "refs/heads/(.+)")
=string.format("Order %s: %.2f %s", $flow.id, $flow.total, $flow.currency)

=array.filter($flow.users, "status", "active")
=array.pluck($flow.orders, "amount")

=number.randomInt(1000, 9999)

=datetime.addBusinessDays($flow.startDate, 5)
=datetime.startOfDay($flow.eventTime)
=datetime.quarter($flow.reportDate)

=json.removeKey($flow.payload, "internalToken")
=json.merge($flow.defaults, $flow.overrides)
```

---

## Module

```
module: github.com/milindpandav/flogo-extensions/function
go:     1.21
```

---

## Tests

```bash
cd function
go test ./...
```

291 unit tests across all packages — all passing.
