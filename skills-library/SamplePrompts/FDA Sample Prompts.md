# FDA Prompts

A collection of sample prompts for creating Flogo applications using the FDA CLI.

---

## Sample Prompt 1 — REST + SQL Server CRUD

**Prompt:**

> - Create a Flogo application based on the image `<path-of-image>`. Replace PostgreSQL with SQL Server and pass the database details.
> - Table name should be BookStore.
> - Don't update file manually, use fda only.

**Manual steps needed to run the app end to end:**

- Trigger handlers created via FDA CLI have an unnecessary `body:object` on GET/DELETE and a missing `schemas` block (causes nil pointer panic) -- click **Sync** on trigger handler in VS Code to fix both.
- SQL query activities with prepared parameters (e.g. `?BookId`) get collapsed into a JSON literal on `input.input` by `fda mm` (make-mapping) -- manually set the leaf-level parameter mapping in app.

---

## Sample Prompt 2 — REST + SQL Server with @foreach Mapper

**Prompt:**

> - Create a Flogo app `Rest_BookStore_ListAll` based on the image `<path-of-image>`.
> - Replace PostgreSQL with SQL Server database and pass the database details.
> - Table name should be BookStore.
> - Use a Mapper with `@foreach` to transform SQL result records into a response array.
> - Don't update file manually, use fda only.

**Manual steps needed to run the app end to end:**

- Trigger handlers created via FDA CLI have an unnecessary `body:object` on GET/DELETE and a missing `schemas` block (causes nil pointer panic) -- click **Sync** on trigger handler in VS Code to fix both.

---

## Sample Prompt 3 — App Properties + Trigger Port Binding

**Prompt:**

> - Create a simple Flogo application with multiple app properties of different data types (e.g., string, integer, boolean), each initialized with sample values. Then demonstrate using those properties within the app's flow.
> - Add `Port` as app property and pass value as `8765` and bind it in REST Trigger.

**Manual steps needed to run the app end to end:**

- Trigger handlers created via FDA CLI have an unnecessary `body:object` on GET/DELETE and a missing `schemas` block (causes nil pointer panic) -- click **Sync** on trigger handler in VS Code to fix both.

---

## Sample Prompt 4 — AWS SQS (Multi-Flow App)

### Prompt 4a — Send SQS Message

> - Create Flogo app named "SQS-App" and create AWS Connection using details as below.
> - Create Flow named "Send SQS Message to Queue".
> - In Flow, add REST trigger and use GET method and add Send SQS Message activity and use above created connection in it.
> - Create app property for Queue URL and pass `<queue-url>` and bind app property in activity.
> - Also, configure the activity to push a dummy message to the queue and include dummy message attributes.
> - Don't update file manually and use FDA only.

### Prompt 4b — Receive SQS Message

> - In same app, create another Flow named "Receive Message from Queue".
> - Add Receive SQS Message Trigger and bind available Connection.
> - In Queue URL dropdown, bind the app property available for it and also add message attributes that we added previously in activity.
> - Add Log message activity in flow and in message field map Message field from trigger flow output.
> - No direct file update.

**Manual steps needed to run the app end to end:**

- Trigger handlers created via FDA CLI have an unnecessary `body:object` on GET/DELETE and a missing `schemas` block (causes nil pointer panic) -- click **Sync** on trigger handler in VS Code to fix both.

---

## Sample Prompt 5 — REST API from OpenAPI Spec

**Prompt:**

> - Create Flogo REST API app using api spec file `<path-of-spec-file>`.
> - Add some dummy implementation in the newly created flows before the Configure HTTP Response based on the schema it is expecting.

**Manual steps needed to run the app end to end:**

- Just make changes in dummy implementation as per your requirements and run the app.

---

## Sample Prompt 6 — Request/Response Schema Binding

**Prompt:**

> - Create a Flogo app called "RestTrigger-RequestResponseSchema".
> - Add a REST trigger in flow and it should receive a POST request at `/rec1`.
> - Create a schema "project info" with below properties:
>   - `projectId`, `status`, `teams` (where each team has a `teamName`, `specialty`, and a list of `members` — each member has a required `id` as number and required `name` as string).
> - Bind this schema in REST Trigger Request and Response schema.
> - Also add Mapper, LogMessage, and Return activity in flow and link them in sequence.
> - Set the "project info" schema on the Mapper and map all request body fields through it.
> - Wire LogMessage and Return to use the Mapper output.

**Manual steps needed to run the app end to end:**

- In the REST trigger, click the **Sync** button on the Response Schema to populate flow output properties, then map the flow output data object to the trigger reply data.

---

## Sample Prompt 7 — Invoke REST Service + Log Response

**Prompt:**

> - Create a Flogo app "DemoRestApp" with a flow "GetPostFlow" and add a REST trigger (GET, path `/api/getpost`).
> - Add an Invoke REST Service activity that calls `https://jsonplaceholder.typicode.com/posts/1` using GET method with a response schema having fields: `userId` (integer), `id` (integer), `title` (string), `body` (string).
> - Add a Log Message activity to log the title from the response. Map the invoke response to the trigger reply.

**Manual steps needed to run the app end to end:**

- Trigger handlers created via FDA CLI have an unnecessary `body:object` on GET/DELETE and a missing `schemas` block (causes nil pointer panic) -- click **Sync** on trigger handler in VS Code to fix both.

---

## Sample Prompt 8 — Nested Array/Object Transformation

**Prompt:**

> - Create a Flogo app called "NestedArrayObjects" with a REST API that accepts a POST request on `/orders`. The request body contains an order with the following structure:
>   - `orderId` (string)
>   - `customer` (string)
>   - `lineItems` (array of objects), where each line item has:
>     - `productId` (string)
>     - `quantity` (number)
>     - `subItems` (array of objects), where each sub-item has:
>       - `subItemId` (string)
>       - `subItemName` (string)
> - Use a Mapper to transform the input into a different output structure with renamed fields. Return the mapped output as the API response with HTTP status 200.

**Manual steps needed to run the app end to end:**

- In the REST trigger, click the **Sync** button on the Response Schema to populate flow output properties, then map the flow output data object to the trigger reply data.

---

## Sample Prompt 9 — Multi-level JSON Structures

**Prompt:**

> Create a Flogo app called `test_multilevel.flogo` that tests resolving multi-level JSON structures in mappings. The app should have a timer-triggered flow with two mapper activities and a log activity:
>
> 1. **Source mapper** — produces a deeply nested JSON object (4 levels deep) representing an order: `orderId`, `total` (number), a `customer` with `name` and `email` who has an `address` with `street`, `city`, `state`, and `zip`, and a `payment` method that has a `card` with `last4` and `expiry`.
> 2. **Resolver mapper** — pulls fields from different nesting levels into a flat structure (e.g. `customerName`, `shippingCity`, `cardLast4`).

---

## Sample Prompt 10 — Dynamic Lookups with json.jq

**Prompt:**

> - Create a Flogo app with a timer-triggered flow that does dynamic lookups across a collection.
> - A Source mapper produces a catalog array of products, each with a `code`, `name`, and `price`, plus a `searchCode` field.
> - A Lookup mapper uses `json.jq` to find the product matching the search code from the catalog and extracts its name and price into flat output fields. Log the lookup result.

**Status:** Working fine end to end.

---

## Sample Prompt 11 — Inbuilt Functions

**Prompt:**

> - Create a Flogo app with a timer-triggered flow that transforms customer data.
> - A Source mapper provides a customer name, an email address, an order amount with decimals and a list of tags.
> - A Transform mapper should: uppercase the customer name and add a "CUSTOMER: " prefix, extract the username part before the `@` from the email, round the order amount to the nearest whole number, count how many tags there are, add the current date as a timestamp, and generate a unique transaction ID.
> - Log the transformed result.

---

## Sample Prompt 12 — MCP Server from OpenAPI Spec + Mock Server

### Prompt 12a — Create MCP Server App

> I have an OpenAPI spec file at `<path>/weather-forecast-api.json`.
> Create a Flogo MCP Server app from this spec.
> Set the API endpoint to `http://localhost:9999` and MCP port to `3040`.

### Prompt 12b — Create Mock REST Server

> I don't have a real Weather API. Create a dummy Flogo REST server using the same OpenAPI spec `<path>/weather-forecast-api.json` on port 9999 that returns sample data for all endpoints.
> Add a Mapper activity in each flow between Log and ConfigureHTTPResponse to set the dummy response data, then pass it to ConfigureHTTPResponse.

---

## Sample Prompt 13 — Insert Activity Between Existing Activities

### Prompt 13a — Create Base App

> Create a REST API app called OrderProcessor that receives a POST request at `/orders`. Log the incoming order details, then return a success response.

### Prompt 13b — Insert Mapper Activity

> Add a Mapper activity between the Log and Return activities to transform the order data before returning it.
