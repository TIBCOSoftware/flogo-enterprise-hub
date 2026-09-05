# Conditional Mappings (if / else) — Flogo 3

## Overview

This sample demonstrates **conditional data mapping using if/else blocks** in the **TIBCO Flogo® 3** folder-based project format. A shared subflow creates a shopping order via a REST call, and two flows shape the response differently depending on run-time conditions — showing how to include or drop JSON attributes based on field values and on whether a field is defined.

| Building block | Activity / Trigger | What it shows |
|---|---|---|
| **REST** | `#rest` trigger | Two `POST` endpoints (`/orderdetails`, `/removeJsonTag`) on port `9999` |
| **Invoke REST Service** | `#rest` activity | Subflow posts the order and returns the created object |
| **Subflow** | `#subflow` activity | Reuse of `post_orderDetails` from both flows |
| **Mapper (if/else)** | `#mapper` activity | Conditional output mapping — include/omit attributes based on if/else |
| **Log Message** | `#log` activity | Prints flow progress to the terminal |
| **Return** | `#actreturn` activity | Returns the shaped order details in the HTTP response |

- **display_orderDetails** — includes the `Feedback` link only when `Status` is `delivered` or `completed`; the else branch simply does not map `Feedback`, so it is absent from the output (unlike a ternary, which would leave a null/empty value).
- **removeJsonAttributes_orderDetails** — uses an `isdefined()` if condition on the incoming `Item` array; if `Item` is not present in the POST body, the `Item`, `Shipment`, and `Feedback` attributes are omitted from the output.

## Architecture

```
  Client (curl / Postman)
      |
      |  POST /orderdetails      POST /removeJsonTag
      v                          v
 +----------------------------------------------------------------------+
 |  conditional_mappings_ifelse  (Flogo 3 app)                        |
 |                                                                      |
 |  REST Trigger (ReceiveHTTPMessage, port 9999)                        |
 |        |                                  |                          |
 |        v                                  v                          |
 |  display_orderDetails             removeJsonAttributes_orderDetails  |
 |    subflow -> mapper(if/else)       subflow -> mapper(if/else)       |
 |      -> log -> return                 -> log -> return               |
 |        |                                  |                          |
 |        +----------> post_orderDetails <---+                          |
 |                    (InvokeRestService POST -> Return)                |
 +----------------------------------------------------------------------+
```

Both entry flows call the shared **post_orderDetails** subflow, which POSTs the order to an external JSON service and returns the created object. Each flow then applies its own if/else mapping before returning the response.

## Files in This Sample

The Flogo 3 app is a folder-based project (not a single `.flogo` file):

| Path | Description |
|---|---|
| `conditional_mappings_ifelse/app.fgmd` | App metadata (`flogoVersion: 3.0.0`, name, version) |
| `conditional_mappings_ifelse/app.fgprops` | App properties file (no properties defined) |
| `conditional_mappings_ifelse/triggers/ReceiveHTTPMessage.fgtrigger` | REST trigger on port `9999` |
| `conditional_mappings_ifelse/flows/display_orderDetails.fgflow` | `POST /orderdetails` → include `Feedback` only when status is delivered/completed |
| `conditional_mappings_ifelse/flows/removeJsonAttributes_orderDetails.fgflow` | `POST /removeJsonTag` → drop `Item`/`Shipment`/`Feedback` when `Item` is undefined |
| `conditional_mappings_ifelse/flows/post_orderDetails.fgflow` | Subflow — InvokeRestService POST then Return the created order |
| `conditional_mappings_ifelse/schemas/order.json` | Shared shopping-order schema |

## Prerequisites

- **TIBCO Flogo® 3 extension for Visual Studio Code** installed. See the [TIBCO Flogo Extension for Visual Studio Code documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest).
- Outbound internet access — the `post_orderDetails` subflow calls an external test REST endpoint (`https://my-json-server.typicode.com/...`).

## Setup & Run

### Step 1 — Open the app in VS Code

Open this sample folder in VS Code with the Flogo 3 extension. The extension detects the `conditional_mappings_ifelse` project (the folder containing `app.fgmd`).

### Step 2 — Configure App Properties

Open the `app.fgprops` file for App Properties. This sample defines no app properties, so no changes are required (see the [App Properties Reference](#app-properties-reference) below).

### Step 3 — Create & select the Local Runtime

Click the **Flogo 3** icon in the VS Code menu bar → in **RUNTIME EXPLORER**, add a new runtime with the **+** button → give it a name → Save. This is a pure-Go sample, so no special build environment is required.

### Step 4 — Build and Run

In the **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. On success the binary is produced in the `bin` folder and execution logs appear in the integrated terminal. The REST trigger starts listening on port **9999**.

### Step 5 — Invoke the endpoint

**First flow** — `POST /orderdetails`. Try `Status` as `pending` (feedback omitted) or `delivered`/`completed` (feedback included):

```bash
curl -X POST "http://localhost:9999/orderdetails" \
  -H "Content-Type: application/json" \
  -d '{
    "ShoppingCartOrder": {
      "Order": "D01-8127020-6200600",
      "PlacedOn": "2017-10-21",
      "Feedback": "https://3err.bitly.com/feed",
      "Status": "delivered",
      "Item": [
        { "Description": "A Product for Everyone", "Code": "D01-8127020-6200600-1-1", "Price": 13.69, "Quantity": 1 }
      ],
      "Shipment": [
        { "Arriving": "2017-10-23",
          "DeliveryAddress": { "City": "Swindon", "County": "Wiltshire", "Line1": "76 Godwin Road", "Line2": "Stratton", "PostCode": "SN34XG" } }
      ]
    }
  }'
```

With `Status` = `delivered` or `completed` the response includes the `Feedback` link; with any other status the `Feedback` attribute is omitted.

**Second flow** — `POST /removeJsonTag`. Send a body with no `Item` array:

```bash
curl -X POST "http://localhost:9999/removeJsonTag" \
  -H "Content-Type: application/json" \
  -d '{
    "ShoppingCartOrder": {
      "Order": "D01-8127020-6200600",
      "PlacedOn": "2017-10-21",
      "Feedback": "https://3err.bitly.com/feed",
      "Status": "delivered",
      "Shipment": [
        { "Arriving": "2017-10-23",
          "DeliveryAddress": { "City": "Swindon", "County": "Wiltshire", "Line1": "76 Godwin Road", "Line2": "Stratton", "PostCode": "SN34XG" } }
      ]
    }
  }'
```

Because `Item` is not present in the POST body, the `Item`, `Shipment`, and `Feedback` attributes are omitted from the returned JSON.

## App Properties Reference

This sample defines no app properties — `app.fgprops` contains an empty properties list. Endpoint behavior is driven entirely by the request body and the if/else mappings in each flow.

| Property | Default | Description |
|---|---|---|
| *(none)* | — | No app properties are defined for this sample |

## Troubleshooting

- **`address already in use` on startup** — port `9999` is taken by another process; stop it or change the trigger port in `ReceiveHTTPMessage.fgtrigger`.
- **Subflow / order creation errors** — the `post_orderDetails` subflow calls an external test service; verify outbound internet access and that the endpoint is reachable.
- **`Feedback` still appears / attributes not dropped** — check the request body: the first flow keys off `Status` (`delivered`/`completed`), and the second keys off whether `Item` is present. An empty `Item: []` still counts as defined.
- **404 on request** — ensure you are calling the correct path (`/orderdetails` or `/removeJsonTag`) with the `POST` method.

## Help

For additional information, visit the [TIBCO Flogo® Extension for Visual Studio Code documentation — Conditional Mapping (Data Mappings)](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#flogo-all-vsc/conditional-mapping.htm?TocPath=User%2520Guide%257CApp%2520Development%257CData%2520Mappings%257C_____8).
