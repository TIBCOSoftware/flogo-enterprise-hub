# Write Log Activity

![Write Log Activity](icons/log-file@2x.png)

This Flogo activity provides structured logging with OpenTracing/OpenTelemetry integration, ECS (Elastic Common Schema) compliance, field filtering, and sensitive data masking capabilities. It offers advanced formatting options.

## Features

### 🏢 ECS (Elastic Common Schema) Compliance
- **Standardized Fields**: Full ECS v8.11 compliance for enterprise log aggregation
- **Agent Metadata**: `agent.name`, `agent.type`, `agent.version`
- **Event Classification**: `event.category`, `event.kind`, `event.type`, `event.dataset`
- **Service Details**: `service.name`, `service.type`, `service.version`
- **Host Information**: `host.name` for infrastructure correlation

### 🔍 OpenTracing/OpenTelemetry Integration
- **Automatic Context Detection**: Detects active tracing contexts
- **Trace Correlation**: Adds `trace.id`, `span.id` for distributed tracing
- **Context-Aware Logging**: Leverages Flogo's context-aware logging capabilities

### 🔒 Sensitive Data Masking
- **Field-Level Masking**: Mask specific fields by name
- **Wildcard Pattern Support**: Support for wildcard patterns in field names (e.g., *_card, email_*)


### 🎯 Field Management
- **Include Filters**: Specify which fields to include in output
- **Exclude Filters**: Specify which fields to exclude from output
- **Nested Field Support**: Filter nested object fields using dot notation

### 🎨 Output Format Support
- **JSON**: Structured logs for modern log aggregation systems
- **KEY_VALUE**: Key-value pairs for traditional log parsing
- **LOGFMT**: Logfmt format for streamlined log processing
## Configuration

### Settings

| Setting | Type | Required | Description | Default |
|---------|------|----------|-------------|---------|
| logLevel | string | Yes | Default log level for this activity (can be overridden by input) | INFO |
| includeFlowInfo | boolean | No | Include ECS Standard Fields - If true, automatically merges standard fields like @timestamp, service.name, etc., into the log. User-provided data takes precedence | true |
| outputFormat | string | Yes | Default format for log output (can be overridden by input) | JSON |
| addFlowDetails | boolean | No | If true, appends flow instance ID, flow name, and activity name to log messages | false |

### Inputs

| Input | Type | Required | Description | Default |
|-------|------|----------|-------------|---------|
| logObject | object | No | Define a JSON schema or object here. The Flogo UI will create mappable fields based on its structure | {"$schema":"http://json-schema.org/draft-04/schema#","type":"object","properties":{"field1":{"type":"string"},"field2":{"type":"number"}}} |
| logLevel | string | No | Override default log level ('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL') | - |
| sensitiveFields | object | No | Configuration for field masking with properties: fieldNamesToHide (array), maskWith (string), maskLength (number) | {"$schema":"http://json-schema.org/draft-04/schema#","type":"object","properties":{"fieldNamesToHide":{"type":"array","items":{"type":"string"}},"maskWith":{"type":"string","default":"*****"},"maskLength":{"type":"number","default":0}}} |
| fieldFilters | object | No | Field filtering configuration with properties: include (array), exclude (array) | {"$schema":"http://json-schema.org/draft-04/schema#","type":"object","properties":{"include":{"type":"array","items":{"type":"string"}},"exclude":{"type":"array","items":{"type":"string"}}}} |

### Outputs

This activity does not return any outputs. It performs logging operations directly to the configured logging system.

**Note**: The activity intelligently processes inputs based on configuration. When Include ECS Standard Fields is enabled, additional enterprise metadata like ECS fields are automatically added. The activity supports inline flow formatting similar to the official Log activity when addFlowDetails is enabled.

## Usage Examples

### Example 1: Basic Logging

```json
{
  "id": "enterprise_log",
  "name": "Write Enterprise Log",
  "activity": {
    "ref": "github.com/milindpandav/activity/write-log",
    "settings": {
      "logLevel": "INFO",
      "outputFormat": "JSON",
      "includeFlowInfo": true,
      "addFlowDetails": true
    },
    "input": {
      "logObject": {
        "event": "user_login",
        "user_id": "12345",
        "session_id": "abc-def-ghi",
        "ip_address": "192.168.1.100"
      }
    }
  }
}
```

### Example 2: Sensitive Data Masking

```json
{
  "id": "secure_log",
  "name": "Log with Data Masking",
  "activity": {
    "ref": "github.com/milindpandav/activity/write-log",
    "settings": {
      "logLevel": "INFO",
      "outputFormat": "JSON",
      "includeFlowInfo": true
    },
    "input": {
      "logObject": {
        "transaction_id": "txn_12345",
        "user_email": "user@example.com",
        "credit_card": "1234-5678-9012-3456",
        "amount": 99.99
      },
      "sensitiveFields": {
        "fieldNamesToHide": ["user_email", "credit_card"],
        "maskWith": "****",
        "maskLength": 4
      }
    }
  }
}
```

### Example 3: Key-Value Format with Field Filtering

```json
{
  "id": "filtered_log",
  "name": "Filtered Key-Value Log",
  "activity": {
    "ref": "github.com/milindpandav/activity/write-log",
    "settings": {
      "outputFormat": "KEY_VALUE",
      "addFlowDetails": false,
      "includeFlowInfo": false
    },
    "input": {
      "logObject": {
        "request_id": "req_789",
        "method": "POST",
        "endpoint": "/api/users",
        "response_time": 156,
        "status_code": 200,
        "internal_debug": "sensitive_info"
      },
      "fieldFilters": {
        "include": ["request_id", "method", "endpoint", "response_time", "status_code"]
      }
    }
  }
}
```

### Example 4: LOGFMT Format with Log Level Override

```json
{
  "id": "error_log",
  "name": "Error Log with Context",
  "activity": {
    "ref": "github.com/milindpandav/activity/write-log",
    "settings": {
      "logLevel": "INFO",
      "outputFormat": "LOGFMT",
      "includeFlowInfo": true
    },
    "input": {
      "logLevel": "ERROR",
      "logObject": {
        "message": "Database connection failed",
        "error_code": "DB_CONN_001",
        "database": "user_db",
        "retry_count": 3,
        "last_error": "Connection timeout after 30s"
      }
    }
  }
}
```

## Supported Output Formats

### JSON Format (Default)
Structured JSON output with full metadata and ECS compliance:

```json
{
  "@timestamp": "2025-01-27T10:30:45.123Z",
  "ecs": {"version": "8.11.0"},
  "log": {
    "level": "INFO",
    "logger": "flogo.activity.write-log"
  },
  "event": {
    "category": ["application"],
    "kind": "event",
    "type": ["info"],
    "dataset": "flogo.application.log"
  },
  "user_data": {
    "event": "user_login",
    "user_id": "12345",
    "session_id": "abc-def-ghi"
  },
  "service": {
    "name": "my-flogo-app",
    "type": "flogo-application",
    "version": "1.0.0"
  },
  "trace": {
    "id": "1234567890abcdef",
    "span": {"id": "abcdef1234567890"}
  }
}
[Flow: MyFlow (instance: flow_123), Activity: enterprise_log]
```

### KEY_VALUE Format
Space-separated key=value pairs:

```
timestamp=2025-01-27T10:30:45.123Z level=INFO event.category=application user_data.event=user_login user_data.user_id=12345 service.name=my-flogo-app trace.id=1234567890abcdef [Flow: MyFlow (instance: flow_123), Activity: enterprise_log]
```

### LOGFMT Format
Logfmt-style structured logging:

```
ts=2025-01-27T10:30:45.123Z level=info event=user_login user_id=12345 session_id=abc-def-ghi service=my-flogo-app trace_id=1234567890abcdef [Flow: MyFlow (instance: flow_123), Activity: enterprise_log]
```

## Supported Log Levels

The activity supports the following log levels (configurable via settings or input override):

- `TRACE` - Most detailed logging level
- `DEBUG` - Detailed information for debugging
- `INFO` - General information messages
- `WARN` - Warning messages for potential issues
- `ERROR` - Error messages for failures
- `FATAL` - Critical errors that may cause application termination

## Field Management Features

### Sensitive Data Masking
The `sensitiveFields` input allows you to configure field masking:

```json
{
  "fieldNamesToHide": ["password", "credit_card", "ssn"],
  "maskWith": "****",
  "maskLength": 4
}
```

- **fieldNamesToHide**: Array of field names to mask in the output
- **maskWith**: String used for masking (default: "*****")
- **maskLength**: Number of characters to show before masking (default: 0)

### Field Filtering
The `fieldFilters` input supports include/exclude operations:

```json
{
  "include": ["user_id", "event_type", "timestamp"],
  "exclude": ["internal_debug", "temp_data"]
}
```

- **include**: Only these fields will be included in the output
- **exclude**: These fields will be excluded from the output
- **Nested Field Support**: Use dot notation like "user.profile.email"


## Error Handling

The activity provides comprehensive error handling:

- **INVALID_INPUT** - Invalid or missing required input parameters
- **SERIALIZATION_ERROR** - Error during JSON serialization
- **FORMATTING_ERROR** - Error during output formatting
- **TRACING_ERROR** - Error accessing tracing context (non-fatal)
- **ECS_ERROR** - Error adding ECS metadata (non-fatal)
- **MASKING_ERROR** - Error during field masking (non-fatal)

All errors are logged but do not stop activity execution to ensure logging reliability.

## Testing

Run the unit tests:

```bash
go test -v
```

Run specific test scenarios:

```bash
# Test basic functionality
go test -v -run TestBasicLogging

# Test output formats
go test -v -run TestOutputFormats

# Test field masking
go test -v -run TestSensitiveDataMasking

# Test field filtering
go test -v -run TestFieldFiltering

# Test ECS compliance
go test -v -run TestECSCompliance
```

## Dependencies

- `github.com/project-flogo/core` v1.6.13+ - Flogo core framework
- `github.com/stretchr/testify` v1.10.0+ - Testing framework

## Environment Variables

The activity respects the following environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `FLOGO_DYNAMICLOG_LOG_LEVEL` | Override default log level | - |
| `FLOGO_LOGACTIVITY_LOG_LEVEL` | Activity-specific log level override | - |
| `FLOGO_APP_NAME` | Application name for service metadata | "flogo-app" |
| `FLOGO_APP_VERSION` | Application version for service metadata | "1.0.0" |




## Sample Input/Output

### Sample Input Object

```json
{
  "user_id": "user_12345",
  "event_type": "purchase",
  "product": {
    "id": "prod_789",
    "name": "Enterprise License",
    "price": 299.99
  },
  "payment": {
    "method": "credit_card",
    "card_number": "4111-1111-1111-1111",
    "billing_address": {
      "street": "123 Main St",
      "city": "San Francisco",
      "state": "CA",
      "zip": "94105"
    }
  },
  "session": {
    "id": "sess_abc123",
    "ip_address": "192.168.1.100",
    "user_agent": "Mozilla/5.0..."
  }
}
```

### Generated JSON Output (with ECS & Masking)

```json
{
  "@timestamp": "2025-01-27T10:30:45.123456Z",
  "ecs": {
    "version": "8.11.0"
  },
  "log": {
    "level": "INFO",
    "logger": "flogo.activity.write-log"
  },
  "event": {
    "category": ["application"],
    "kind": "event",
    "type": ["info"],
    "dataset": "flogo.application.log"
  },
  "agent": {
    "name": "flogo-engine",
    "type": "flogo-application",
    "version": "1.6.13"
  },
  "service": {
    "name": "my-ecommerce-app",
    "type": "flogo-application",
    "version": "1.0.0"
  },
  "host": {
    "name": "app-server-01"
  },
  "process": {
    "name": "flogo-app"
  },
  "user_data": {
    "user_id": "user_12345",
    "event_type": "purchase",
    "product": {
      "id": "prod_789",
      "name": "Enterprise License",
      "price": 299.99
    },
    "payment": {
      "method": "credit_card",
      "card_number": "****-****-****-1111",
      "billing_address": {
        "street": "123 Main St",
        "city": "San Francisco",
        "state": "CA",
        "zip": "94105"
      }
    },
    "session": {
      "id": "sess_abc123",
      "ip_address": "192.168.1.100",
      "user_agent": "Mozilla/5.0..."
    }
  },
  "trace": {
    "id": "1a2b3c4d5e6f7890",
    "span": {
      "id": "9876543210abcdef"
    }
  }
} [Flow: PurchaseFlow (instance: flow_456789), Activity: log_purchase_event]
```

## Notes

- Flow details are appended as a human-readable suffix when `addFlowDetails` is enabled
- ECS metadata is automatically added when `includeFlowInfo` is enabled
- Tracing context is automatically detected and included when available
- All timestamps use RFC3339 format with microsecond precision
- Field masking applies to all output formats consistently
- The activity is designed to never fail - errors in non-critical features are logged but don't stop execution
- Icons are available in multiple resolutions for different display densities
- Compatible with all major logging infrastructures and observability platforms
