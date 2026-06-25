---
name: flogo-unit-testing
description: Create and run unit tests for Flogo apps — test files, test cases with flow inputs, assertions on flow outputs, test suites, and test execution with result verification
user-invocable: true

---

## 0. Configuration

> **All environment-specific values are defined in [config.md](../config.md).**
> Read that file first for `FLOGO_APPS_DIR`, `FLOGOBUILD_PATH`, `FLOGOBUILD_CONTEXT_NAME`, etc.

This skill creates unit tests for Flogo applications, runs them, and verifies all assertions pass.
It uses `flogodesign-cli` to create test files, test cases, assertions, and test suites,
then uses `flogobuild test-app` to execute the tests.

---

## 1. Inputs

The user must provide:
- **Flogo app file path** — the `.flogo` file to test
- **Flows to test** — which flows need test cases (or test all flows)
- **Test data** — sample input values for each flow (or derive from the API spec / activity configs)

---

## 2. Build Sequence

### Step 1 — Analyze the app to identify flows and their inputs/outputs

```bash
flogodesign-cli.exe -f <AppName>.flogo describe-project
```

For each flow, determine:
- Flow name (e.g. `books_isbn_GET`, `books_POST`)
- Flow input types from `metadata.input` (pathParams, body, headers, etc.)
- Flow output types from `metadata.output` (code, data)
- What the Reply_to_API activity returns (the expected response data)

### Step 2 — Create the test file

```bash
cd <FLOGO_APPS_DIR>
flogodesign-cli.exe -f <AppName>.flogo create-test-file
```

This creates `<AppName>.flogotest` in the same directory as the flogo file.

### Step 3 — Create test cases for each flow

For each flow, create a test case with appropriate flow inputs.

```bash
flogodesign-cli.exe -f <AppName>.flogo create-test-case <TestCaseName> <FlowName> "<Description>" '<flowInputsJSON>'
```

**Parameters:**
- `<TestCaseName>` — A descriptive name (e.g. `TestGetBook`, `TestPostBook`)
- `<FlowName>` — The flow name from describe-project (e.g. `books_isbn_GET`)
- `<Description>` — Description of what the test validates
- `<flowInputsJSON>` — JSON object with the flow's input values

**IMPORTANT — Flow input structure:**
The CLI wraps the JSON input in a `body` key automatically. To get the correct structure
in the `.flogotest` file, you MUST edit the file after creation to fix the wrapping:

- For **GET** flows with path params: pass `{"pathParams":{"param":"value"}}`,
  then edit the flogotest to remove the extra `body` wrapper so `flowInputs` contains
  `{"pathParams":{"param":"value"}}` directly.

- For **POST** flows with request body: pass `{"body":{...data...}}`,
  then edit the flogotest to remove the double `body` wrapper so `flowInputs` contains
  `{"body":{...data...}}` directly.

**Examples:**

GET flow (path params):
```bash
flogodesign-cli.exe -f <AppName>.flogo create-test-case TestGetBook books_isbn_GET \
  "Test GET returns book by ISBN" '{"pathParams":{"isbn":"1451648537"}}'
```

POST flow (request body):
```bash
flogodesign-cli.exe -f <AppName>.flogo create-test-case TestPostBook books_POST \
  "Test POST adds a book" '{"body":{"isbn":"0385537859","name":"Inferno","authorName":"Dan Brown","price":"14.09"}}'
```

**After creating all test cases**, edit the `.flogotest` file to fix `flowInputs`:
- GET: Change `"flowInputs": {"body": {"pathParams": {...}}}` to `"flowInputs": {"pathParams": {...}}`
- POST: Change `"flowInputs": {"body": {"body": {...}}}` to `"flowInputs": {"body": {...}}`

### Step 4 — Add assertions to test cases

For each test case, add assertions that validate the flow output.

```bash
flogodesign-cli.exe -f <AppName>.flogo create-assertion <TestCaseName> flowOutputs ASSERT_ON_OP <AssertionName> '<expression>'
```

**Parameters:**
- `<TestCaseName>` — The test case **name** (e.g. `TestGetBook`), NOT the full key (e.g. NOT `flowName:TestGetBook`)
- `flowOutputs` — The assertion location (always `flowOutputs` for output assertions)
- `ASSERT_ON_OP` — The assertion type (always `ASSERT_ON_OP` for output assertions)
- `<AssertionName>` — A descriptive name for the assertion (e.g. `AssertOnISBN`)
- `<expression>` — The assertion expression using `$.` prefix for JSONPath

**Assertion expression syntax:**
- `$.code == 200` — Assert HTTP status code
- `$.data.fieldName == "value"` — Assert a specific field value
- `$.data.message == "Book added successfully"` — Assert response message

**IMPORTANT — CLI escapes `!` in `!=` assertions (bug):**
Both `==` and `!=` operators are supported by the assertion engine. However, `flogodesign-cli create-assertion`
has a bug that escapes `!` to `\!` when writing to the `.flogotest` file, causing `!=` assertions to fail
with "Failed to validate expression". **Workaround:** After using `create-assertion` with a `!=` expression,
edit the `.flogotest` file to replace `\\!` with `!` in the `valueAssertion` field.

**Common assertions for REST services:**

For GET endpoints:
```bash
# Assert response code
flogodesign-cli.exe -f <AppName>.flogo create-assertion TestGetBook flowOutputs ASSERT_ON_OP AssertOnCode '$.code == 200'
# Assert returned data field
flogodesign-cli.exe -f <AppName>.flogo create-assertion TestGetBook flowOutputs ASSERT_ON_OP AssertOnISBN '$.data.isbn == "1451648537"'
```

For POST endpoints:
```bash
# Assert response code
flogodesign-cli.exe -f <AppName>.flogo create-assertion TestPostBook flowOutputs ASSERT_ON_OP AssertOnCode '$.code == 201'
# Assert response message
flogodesign-cli.exe -f <AppName>.flogo create-assertion TestPostBook flowOutputs ASSERT_ON_OP AssertOnMessage '$.data.message == "Book added successfully"'
# Assert echoed field
flogodesign-cli.exe -f <AppName>.flogo create-assertion TestPostBook flowOutputs ASSERT_ON_OP AssertOnISBN '$.data.isbn == "0385537859"'
```

### Step 5 — Create a test suite

```bash
flogodesign-cli.exe -f <AppName>.flogo create-test-suite <TestSuiteName>
```

Example:
```bash
flogodesign-cli.exe -f <AppName>.flogo create-test-suite BookstoreTestSuite
```

### Step 6 — Add test cases to the test suite

```bash
flogodesign-cli.exe -f <AppName>.flogo add-test-case-to-suite <TestCaseName> <TestSuiteName>
```

Example:
```bash
flogodesign-cli.exe -f <AppName>.flogo add-test-case-to-suite TestGetBook BookstoreTestSuite
flogodesign-cli.exe -f <AppName>.flogo add-test-case-to-suite TestPostBook BookstoreTestSuite
```

### Step 7 — Verify the test file

```bash
flogodesign-cli.exe -f <AppName>.flogo describe-test-file
```

This prints the test suites, test cases, flow inputs, and assertions for verification.

### Step 8 — Run the test suite

```bash
"<FLOGOBUILD_PATH>" test-app \
  -c <FLOGOBUILD_CONTEXT_NAME> \
  -a <AppName>.flogo \
  -f <AppName>.flogotest \
  -t <TestSuiteName> \
  -d <OUTPUT_DIRECTORY> \
  -o <AppName>.testresult
```

**Parameters:**
- `-c` — Flogobuild context name
- `-a` — The Flogo application file
- `-f` — The test file (.flogotest)
- `-t` — Comma-separated list of test suites to run
- `-d` — Output directory for test results (**must be an absolute path** on Windows, e.g. `c:/Work/VsCode/FDA/test-results`)
- `-o` — Output filename for the test result (flogobuild appends `.testresult` extension automatically)

Example:
```bash
"<FLOGOBUILD_PATH>" test-app \
  -c flogo-vscode-2262236 \
  -a flogorestservice4.flogo \
  -f flogorestservice4.flogotest \
  -t BookstoreTestSuite \
  -d ../test-results \
  -o flogorestservice4.testresult
```

### Step 9 — Verify the test results

Read the test result file and verify:
- `result.failedSuites` is `0`
- Each `suiteResult.failedTests` is `0`
- Each assertion has `status: "pass"`
- Each `testResult.failedAssertions` is `0`

Print a summary table showing:
- Suite name, total tests, passed/failed
- Per test case: total assertions, passed/failed
- Any failed assertions with their expression and evaluated value

---

## 3. Test File Structure (`.flogotest`)

```json
{
  "suites": {
    "<SuiteName>": {
      "id": "<SuiteName>",
      "name": "<SuiteName>",
      "disabled": false,
      "tests": [
        "<flowName>:<TestCaseName>",
        "<flowName>:<TestCaseName>"
      ]
    }
  },
  "tests": {
    "<flowName>:<TestCaseName>": {
      "name": "<TestCaseName>",
      "flowId": "flow:<flowName>",
      "flowName": "<flowName>",
      "disabled": false,
      "description": "<description>",
      "flowInputs": {
        // For GET flows: {"pathParams": {"param": "value"}}
        // For POST flows: {"body": {<request body fields>}}
      },
      "flowOutputs": {
        "type": "ASSERT_ON_OP",
        "assertions": {
          "<AssertionName>": {
            "name": "<AssertionName>",
            "valueAssertion": "<expression>"
          }
        }
      }
    }
  },
  "type": "flogo:unittest",
  "model": "1.1.1",
  "app": {
    "name": "<AppName>",
    "version": "1.0.0"
  }
}
```

---

## 4. Test Result Structure (`.testresult`)

```json
{
  "report": {
    "suites": [
      {
        "suiteName": "<SuiteName>",
        "testCases": [
          {
            "testName": "<TestCaseName>",
            "flowName": "<flowName>",
            "activities": [
              {
                "name": "Flow Output",
                "assertionResult": [
                  {
                    "name": "<AssertionName>",
                    "status": "pass",
                    "message": "Comparison success",
                    "expression": "<expression>",
                    "expressionEvaluated": "<actual comparison>"
                  }
                ],
                "activityStatus": "pass",
                "type": "Assert On Outputs"
              }
            ],
            "testResult": {
              "totalAssertions": 2,
              "executedAssertions": 2,
              "failedAssertions": 0,
              "successAssertions": 2,
              "flowExecuted": true
            }
          }
        ],
        "suiteResult": {
          "totalTests": 2,
          "failedTests": 0
        }
      }
    ]
  },
  "result": {
    "totalSuites": 1,
    "failedSuites": 0
  }
}
```

---

## 5. Assertion Expression Reference

| Expression | What it checks |
|---|---|
| `$.code == 200` | Flow output HTTP status code equals 200 |
| `$.code == 201` | Flow output HTTP status code equals 201 |
| `$.code != 999` | Flow output HTTP status code is not 999 |
| `$.data.fieldName == "value"` | Specific field in response data |
| `$.data.fieldName != "wrongValue"` | Field does not equal a value |
| `$.data.message == "text"` | Response message field |
| `$.data.isbn == "1234"` | Specific field match |

- Use `$.` prefix for JSONPath into the flow output
- `$.code` — the HTTP response code from the reply activity
- `$.data.*` — fields from the reply activity's data mapping
- String values must be quoted with escaped quotes: `"value"` becomes `\"value\"` in JSON
- Numeric values are unquoted: `$.code == 200`
- Both `==` and `!=` are supported — but CLI escapes `!` to `\!` (fix manually after `create-assertion`)

---

## 6. Complete Workflow Summary

| Step | Tool | Action |
|------|------|--------|
| 1 | `fda` | Analyze app — identify flows, inputs, outputs |
| 2 | `fda` | Create test file (`create-test-file`) |
| 3 | `fda` | Create test cases with flow inputs (`create-test-case`) |
| 3.5 | Edit | Fix `flowInputs` wrapping in .flogotest file |
| 4 | `fda` | Add assertions to test cases (`create-assertion`) |
| 5 | `fda` | Create test suite (`create-test-suite`) |
| 6 | `fda` | Add test cases to suite (`add-test-case-to-suite`) |
| 7 | `fda` | Verify test file (`describe-test-file`) |
| 8 | `flogobuild` | Run tests (`test-app`) |
| 9 | Read | Verify all assertions pass in result file |

**Always complete all 9 steps.** Create tests, run them, and verify results every time.

**CRITICAL: ALWAYS create test cases for EVERY flow in the app.** Do not create tests for only a subset of flows. Each flow must have at least one test case that validates its business logic works correctly. Count the flows from `describe-project` output and ensure your test case count matches.
