# Predictive Maintenance — Demo Test Prompts

## Single Agent Tests

### 1. Sensor data retrieval
```
Show me the latest sensor readings for pump PUMP-W47-TX
```

### 2. Read-only query (MCP tools)
```
List all assets and their current status
```

### 3. Work order creation
```
Create a HIGH priority work order for COMP-W12-OK — compressor overheating, assign to Field Tech Team B, schedule for 2026-04-19
```

### 4. Alert only
```
Send a CRITICAL alert for PUMP-E14-TX — multiple sensor failures detected, immediate shutdown recommended
```

---

## Multi-Agent Tests

### 5. Analyze + Predict
```
Analyze the sensor readings for PUMP-W47-TX and generate a health prediction
```

### 6. Full health check — CRITICAL asset
```
Run a full health check on COMP-W12-OK — analyze sensors, store prediction, create work order if critical, and send alert
```

### 7. Full health check — WARNING asset
```
Run a full health check on PUMP-B21-ND
```

### 8. Full health check — NORMAL asset (no work order or alert expected)
```
Run a full health check on VALVE-W03-NM
```

### 9. Full health check — CRITICAL pump
```
Run a full health check on PUMP-E14-TX — analyze sensors, predict failure, create work order, and alert if needed
```

---

## Read-Only Queries (MCP Tools)

### 10. List predictions
```
Show me all predictions stored so far
```

### 11. List work orders
```
What work orders are currently open or in progress?
```

### 12. Well site query
```
List all well sites and their locations
```

### 13. Alert history
```
Show me the alert history
```

### 14. Sensor history
```
Show me the sensor reading trends for PUMP-W47-TX
```

---

## Edge Cases

### 15. Unknown asset
```
Analyze sensor readings for PUMP-X99-UNKNOWN
```

### 16. Out of scope
```
What is the current oil price per barrel?
```

### 17. Multi-asset scan
```
Which assets are in WARNING or CRITICAL condition right now?
```

---

## Suggested Demo Flow

1. Start with **Prompt 2** — list all assets (shows MCP read-only tools working)
2. Run **Prompt 1** — show sensor data retrieval for a WARNING asset
3. Run **Prompt 6** — full health check on CRITICAL asset COMP-W12-OK (showcases all 4 sub-agents)
4. Run **Prompt 8** — full health check on NORMAL asset (shows AI correctly skips work order + alert)
5. Run **Prompt 10** — show the predictions stored by the agent
6. Run **Prompt 11** — show the work orders created
7. Run **Prompt 16** — show out-of-scope handling
