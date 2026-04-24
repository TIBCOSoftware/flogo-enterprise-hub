# PostgreSQL Listener Trigger

A Flogo trigger that listens for PostgreSQL NOTIFY messages on specified channels using PostgreSQL's LISTEN/NOTIFY mechanism.

## Overview

This trigger provides a robust solution for real-time PostgreSQL event listening with enterprise-grade features including SSL/TLS support, connection management, enhanced logging, and distributed tracing capabilities.

## Features

- **🔌 Direct Connection Configuration**: Configure PostgreSQL connection directly in trigger settings
- **📡 Multi-Channel Support**: Listen on multiple PostgreSQL channels simultaneously  
- **🔒 Full SSL/TLS Support**: Complete SSL/TLS configuration with certificate support
- **🔄 Connection Management**: Built-in connection retry logic with health monitoring
- **🛑 Graceful Shutdown**: Proper resource cleanup and graceful shutdown handling
- **📋 Enhanced Logging**: Efficient debugging with correlation IDs and structured logging
- **🌐 OpenTelemetry Integration**: Full distributed tracing support with rich PostgreSQL-specific metadata
- **⚡ Health Monitoring**: Periodic connection health checks with detailed metrics
- **🧠 Memory Tracking**: Runtime memory usage monitoring and resource statistics

## Configuration

### Trigger Settings

| Setting | Type | Required | Default | Description |
|---------|------|----------|---------|-------------|
| `host` | string | ✅ Yes | - | PostgreSQL server host |
| `port` | integer | ✅ Yes | `5432` | PostgreSQL server port |
| `user` | string | ✅ Yes | - | Database user |
| `password` | string | ✅ Yes | - | Database password |
| `databaseName` | string | ✅ Yes | - | Database name |
| `sslMode` | string | No | `disable` | SSL mode (`disable`, `require`, `verify-ca`, `verify-full`) |
| `tlsConfig` | boolean | No | `false` | Enable advanced TLS certificate configuration |
| `tlsMode` | string | No | `VerifyCA` | TLS verification mode (`VerifyCA`, `VerifyFull`) |
| `cacert` | string | No | - | CA certificate (base64 encoded) |
| `clientcert` | string | No | - | Client certificate (base64 encoded) |
| `clientkey` | string | No | - | Client key (base64 encoded) |
| `connectionTimeout` | integer | No | `30` | Connection timeout in seconds |
| `maxConnRetryAttempts` | integer | No | `3` | Maximum connection retry attempts |
| `connectionRetryDelay` | integer | No | `5` | Delay between connection retries in seconds |

### Handler Settings

| Setting | Type | Required | Description |
|---------|------|----------|-------------|
| `channel` | string | ✅ Yes | PostgreSQL channel name to listen on |

### Output

| Field | Type | Description |
|-------|------|-------------|
| `payload` | string | The payload string from the NOTIFY message |


## PostgreSQL Setup

### Enable Notifications

```sql
-- Create a function to send notifications
CREATE OR REPLACE FUNCTION notify_event()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('order_events', row_to_json(NEW)::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create a trigger that sends notifications
CREATE TRIGGER order_notification_trigger
    AFTER INSERT OR UPDATE ON orders
    FOR EACH ROW
    EXECUTE FUNCTION notify_event();
```

### Test Notifications

```sql
-- Send a test notification
SELECT pg_notify('order_events', '{"id": 123, "status": "created", "amount": 99.99}');

-- View active listeners (from another session)
SELECT * FROM pg_stat_activity WHERE state = 'idle in transaction';
```



**Example Log Output:**
```
[INITIALIZE] Starting PostgreSQL Listener Trigger initialization [corr_id=a1b2c3d4 trigger=postgres-listener-a1b2c3d4 op=INITIALIZE]
[PROCESS_NOTIFICATION] Flow execution completed successfully [corr_id=e5f6g7h8 processing_time=15.2ms total_processed=42]
[HEALTH_MONITOR] Periodic health summary [total_checks=10 uptime=5m0s metrics={healthy_listeners=3 memory_mb=45}]
```



## Error Handling

The trigger provides comprehensive error handling:

- **🔄 Connection Failures**: Automatic retry mechanisms with exponential backoff
- **⚠️ Invalid Configuration**: Detailed validation with actionable error messages
- **📡 Listener Reconnection**: Automatic reconnection on network issues
- **📝 Error Logging**: Comprehensive error logging with troubleshooting suggestions
- **🚨 Health Alerts**: Proactive monitoring with health check warnings

**Common Error Examples:**
```
[INITIALIZE] Settings validation failed [error=port must be between 1 and 65535 suggestion=Check trigger configuration]
[INITIALIZE] Initial database connection ping failed [error=connection refused suggestion=Check database server status]
[HEALTH_MONITOR] Health check detected issues [issues=[listener_orders: connection lost] suggestion=Monitor connection stability]
```


## Dependencies

- **[github.com/lib/pq](https://github.com/lib/pq)** v1.10.9 - PostgreSQL driver
- **[github.com/project-flogo/core](https://github.com/project-flogo/core)** v1.6.13 - Flogo core framework




## How It Works

1. **Initialization**: The trigger establishes a connection to PostgreSQL and validates the configuration
2. **Listening**: For each configured handler, it creates a `pq.Listener` that subscribes to the specified channel
3. **Processing**: When a NOTIFY message is received, it executes the associated Flogo flow with the payload
4. **Health Monitoring**: Periodic health checks ensure connections remain active
5. **Shutdown**: Graceful cleanup of all connections and resources

## Connection Management

- **Retry Logic**: Automatic retry on connection failures with configurable attempts and delays
- **Health Monitoring**: Periodic ping to detect connection issues
- **Resource Cleanup**: Automatic cleanup of temporary certificate files
- **Graceful Shutdown**: Proper closure of all database connections



## Support

For issues, questions, or contributions, please refer to the project's issue tracking system or documentation.
