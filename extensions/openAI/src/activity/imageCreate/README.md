# Create Image Activity

OpenAI image-generation activity for Flogo. Wraps `POST /images/generations`,
supporting the GPT image model family (`gpt-image-1`, `gpt-image-1-mini`,
`gpt-image-1.5`, `gpt-image-2`, `gpt-image-2-2026-04-21`).

> **Deprecation notice.** OpenAI deprecated `dall-e-2` and `dall-e-3` on
> **May 12, 2026** and replaced them with `gpt-image-1` and `gpt-image-1-mini`.
> This activity no longer accepts the DALL·E models — configurations that
> reference them will be rejected at validation time. Migrate any existing
> flows to a `gpt-image-*` model.

## Settings

| Name | Required | Description |
|------|----------|-------------|
| `endPointURL` | yes | OpenAI API base URL, e.g. `https://api.openai.com/v1` |
| `apiKey`      | yes | OpenAI API key |

## Inputs

`prompt` is required. All others are optional. The activity rejects invalid
combinations before calling the API.

| Input | Type | Notes |
|-------|------|-------|
| `prompt` | string | Max length 32 000 characters |
| `model` | string | A `gpt-image-*` model. Defaults to `gpt-image-1` |
| `numberOfImages` | integer | 1–10 |
| `size` | string | `1024x1024`, `1536x1024`, `1024x1536`, `auto`. `gpt-image-2` also accepts arbitrary `WxH` |
| `quality` | string | `low`, `medium`, `high`, or `auto` |
| `outputFormat` | string | `png`, `jpeg`, `webp` |
| `background` | string | `transparent`, `opaque`, or `auto`. `transparent` requires `outputFormat ∈ {png, webp}` |
| `outputCompression` | integer | 1–100. Only applies when `outputFormat ∈ {webp, jpeg}` |
| `moderation` | string | `low` or `auto` |
| `user` | string | End-user identifier |

## Outputs

| Output | Type | Notes |
|--------|------|-------|
| `created` | integer | Unix timestamp |
| `background` | string | Echoed background |
| `outputFormat` | string | Echoed output format |
| `quality` | string | Echoed quality |
| `size` | string | Echoed size |
| `data` | array | One entry per generated image: `{ b64_json, url, revised_prompt }` |
| `usage` | object | Token usage details |

## Limitations

- `stream` and `partial_images` are **not** supported. A separate streaming
  activity is required for SSE consumption.

## Tests

Unit tests for input validation run with no credentials:

```bash
go test ./activity/imageCreate/
```

Integration tests require a real key. Copy `.env.example` to `.env`, fill in
`OPENAI_API_KEY`, set `RUN_INTEGRATION=1`, then:

```bash
go test ./activity/imageCreate/ -run Integration -v
```

## Parameter dependencies

These rules are enforced at runtime by `validateInput()` in
[activity.go](activity.go).

### Tabs

| Tab           | Field                                                                                                              |
| ------------- | ------------------------------------------------------------------------------------------------------------------ |
| Configuration | `endPointURL`, `apiKey`, `model`, `numberOfImages`, `size`, `quality`, `outputFormat`, `background`, `outputCompression`, `moderation`, `user` |
| Input         | `prompt`                                                                                                           |

### Model families

| Family        | Models                                                       |
| ------------- | ------------------------------------------------------------ |
| `gpt-image`   | `gpt-image-1`, `gpt-image-1-mini`, `gpt-image-1.5` (also the default when `model` is empty) |
| `gpt-image-2` | `gpt-image-2`, `gpt-image-2-2026-04-21` (and other variants) |

### Per-parameter rules

#### `prompt` (input, required)

Maximum length: **32 000** characters.

#### `numberOfImages`

- Range: `1`–`10`.
- A value of `0` is treated as "not provided" and is omitted from the request.

#### `size`

| Family        | Allowed values                                                                                                          |
| ------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `gpt-image`   | `1024x1024`, `1536x1024`, `1024x1536`, `auto`                                                                           |
| `gpt-image-2` | The three sizes above, **plus** any `WxH` that is divisible by 16, has aspect ratio between 1:3 and 3:1, and ≤ 3840x2160 |

#### `quality`

Allowed values: `low`, `medium`, `high`, `auto` (or empty to omit).

#### `background`

- Allowed values: `transparent`, `opaque`, `auto`.
- `background=transparent` requires `outputFormat` to be `png` or `webp`
  (or empty so the API picks a compatible default).

#### `outputCompression`

- Range: `1`–`100`.
- Only takes effect when `outputFormat` is `webp` or `jpeg`.
- A value of `0` is treated as "not provided" and is omitted from the request
  (Flogo's metadata reflection cannot distinguish a missing `int` from `0`).

#### `moderation`

Allowed values: `low`, `auto`.

#### `user`

Free-form opaque identifier used by OpenAI for abuse detection.

### Quick compatibility matrix

| Field               | gpt-image | gpt-image-2 |
| ------------------- | :-------: | :---------: |
| `prompt`            | ✓         | ✓           |
| `numberOfImages`    | ✓         | ✓           |
| `size` standard     | ✓         | ✓           |
| `size=auto`         | ✓         | ✓           |
| `size` arbitrary    | –         | ✓           |
| `quality`           | ✓         | ✓           |
| `outputFormat`      | ✓         | ✓           |
| `background`        | ✓         | ✓           |
| `outputCompression` | ✓¹        | ✓¹          |
| `moderation`        | ✓         | ✓           |
| `user`              | ✓         | ✓           |

¹ Only effective when `outputFormat` is `webp` or `jpeg`.
