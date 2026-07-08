# Telecom Invoice Chatbot -- Demo Prompts

Subscribers are identified by mobile number. The agent looks up the customer ID from the number, then uses it for all other tools. Currency is AED.

## 1. Bill Explanation (MCP Only)

```
Why is my bill so high this month? My number is +971-50-123-4567.
```
```
Can you break down my June invoice? My mobile is +971-50-123-4567.
```
```
What am I being charged for? +971-58-890-1234
```

---

## 2. Usage (MCP Only)

```
How much data have I used this month? My number is +971-55-345-6789.
```
```
Am I close to my data limit? +971-50-123-4567
```

---

## 3. Plans (MCP Only)

```
What plan am I on? My number is +971-56-456-7890.
```
```
What add-ons do I have? +971-50-123-4567
```

---

## 4. Payment History (MCP Only)

```
Show me my last 3 payments. My number is +971-52-567-8901.
```
```
When did I last pay my bill? +971-50-123-4567
```

---

## 5. Billing Dispute (MCP + A2A: billing_dispute_agent)

### Fatima Al Zaabi -- Roaming charged but never travelled (0 roaming days)
```
Prompt 1: I was charged for roaming in Europe but I never left the country. My number is +971-50-234-5678.
Prompt 2: Yes, please file a dispute.
```

### Generic dispute
```
There's a charge on my bill I don't recognise. My mobile is +971-50-234-5678. Can you dispute it?
```

---

## 6. Recharge (MCP + A2A: recharge_agent)

### Mohammed Hassan -- near data limit
```
Prompt 1: I'm almost out of data. My number is +971-55-345-6789.
Prompt 2: What recharge packs do you have?
Prompt 3: Get me the Data Booster 10GB pack.
```

### Direct recharge
```
Prompt 1: I need more data on +971-56-456-7890.
Prompt 2: Add the 5GB booster please.
```

---

## 7. Dispute Status (MCP Only: GetDisputes)

### Layla Ibrahim -- pre-seeded dispute DSP-2026-0001 (UNDER_REVIEW)
```
What's the status of my dispute? My number is +971-50-678-9012.
```

### Mohammed Hassan -- resolved dispute DSP-2026-0002
```
Did my dispute get resolved? +971-55-345-6789
```

---

## 8. Full Workflow with Email (All Agents)

```
Prompt 1: I was charged AED 120 for roaming in Europe but I didn't travel. My number is +971-50-234-5678.
Prompt 2: Yes, file the dispute and send me email confirmation.
Prompt 3: Can you email me a confirmation?
```

```
Prompt 1: I need more data. My number is +971-55-345-6789.
Prompt 2: Apply the Data Booster 10GB.
Prompt 3: Please send me a confirmation email.
```

---

## 9. Multi-Turn Conversation

```
Turn 1: Hi, my number is +971-50-123-4567. Why is my bill higher than usual?
Turn 2: Is the roaming charge correct?
Turn 3: What plan am I on again?
Turn 4: Show me my last 3 payments.
```

---

## 10. Edge Cases & Out of Scope

### Unknown subscriber
```
Why is my bill high? My number is +971-99-000-0000.
```

### Out of scope (agent should politely decline)
```
I want to swap my SIM card.
Can you port my number to another operator?
Is there a network outage in Dubai?
I want to buy a new iPhone.
My internet at home is down, can you fix it?
```
