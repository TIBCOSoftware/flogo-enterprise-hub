# Hospital Agent - Test Prompts

> **Data baseline date:** 2026-04-17 (run reset_data.sql before testing)
>
> **Agents:** post_discharge_coordinator | pharmacy_fulfillment_agent | bed_turnover_agent | SendEmail

---

## Single Agent Tests

### Test 1: Discharge Summary Only (post_discharge_coordinator)

**Patient:** P-2024-00125 (David Wong) — discharging today, no follow-up, has 1 medication

```
Get the discharge summary for patient P-2024-00125
```

**Expected:** Returns discharge info — discharge_date: 2026-04-17, follow_up_required: false, specialty: GENERAL, medications: [{MED007, 7 days}], ward: WARD-2A, bed: BED-2A-002

---

### Test 2: Discharge Summary with Follow-Up (post_discharge_coordinator)

**Patient:** P-2024-00123 (John Tan) — discharging today, follow-up required, 3 medications

```
Get the discharge summary for patient P-2024-00123 and book a follow-up appointment
```

**Expected:** Returns discharge summary with CARDIOLOGY follow-up, 3 meds (Aspirin, Metoprolol, Atorvastatin). Books appointment ~7 days from 2026-04-17 = 2026-04-24 at 10:30, CARDIOLOGY.

---

### Test 3: Medication Order Only (pharmacy_fulfillment_agent)

**Patient:** P-2024-00122 (Bob Tan) — discharging today, 1 medication

```
Order Paracetamol 500mg (MED006) for patient P-2024-00122, 7 days supply, pickup at PHARMACY_A
```

**Expected:** Creates 1 pharmacy order. Returns order_id, medication_name: Paracetamol 500mg, ready_by (current time + 1 hour), status: PROCESSING.

---

### Test 4: Bed Cleanup Only (bed_turnover_agent)

**Patient:** P-2024-00125 just left — bed needs cleaning

```
Patient has been discharged from BED-2A-002 in WARD-2A, please initiate bed cleaning
```

**Expected:** Updates BED-2A-002 status to CLEANING_REQUESTED, patient_id set to NULL, returns estimated_ready ~20 min from now.

---

## Two Agent Tests

### Test 5: Discharge + Medication Orders (post_discharge_coordinator + pharmacy_fulfillment_agent)

**Patient:** P-2024-00126 (Sarah Chen) — discharging day after tomorrow, follow-up required, 2 medications

```
Process discharge for patient P-2024-00126 and order all prescribed medications
```

**Expected:** Discharge summary (NEUROLOGY follow-up, 2 meds: Gabapentin 30d + Paracetamol 14d). Creates 2 pharmacy orders at PHARMACY_A. No bed cleanup or email.

---

### Test 6: Discharge + Bed Cleanup (post_discharge_coordinator + bed_turnover_agent)

**Patient:** P-2024-00128 (Emily Goh) — follow-up required, no medications

```
Get the discharge summary for patient P-2024-00128 and initiate bed cleaning for their bed
```

**Expected:** Discharge summary (GENERAL follow-up, no medications). Bed cleanup for BED-1A-001 in WARD-1A. No pharmacy orders needed.

---

### Test 7: Medication Orders + Bed Cleanup (pharmacy_fulfillment_agent + bed_turnover_agent)

**Patient:** P-2024-00122 (Bob Tan) — already got discharge summary, now need meds and bed

```
Order the prescribed medication Paracetamol 500mg (MED006, 7 days) for patient P-2024-00122 and clean up BED-3B-001 in WARD-3B
```

**Expected:** Creates 1 pharmacy order. Initiates bed cleaning for BED-3B-001. No discharge summary lookup needed.

---

## Three Agent Tests

### Test 8: Discharge + Medications + Bed Cleanup (post_discharge_coordinator + pharmacy_fulfillment_agent + bed_turnover_agent)

**Patient:** P-2024-00122 (Bob Tan) — discharging today, follow-up required, 1 medication

```
Process the complete discharge for patient P-2024-00122 including follow-up appointment, medication orders, and bed cleanup
```

**Expected:** Discharge summary → ORTHOPEDICS appointment 2026-04-24 → 1 pharmacy order (Paracetamol 500mg, 7d) → bed cleanup BED-3B-001 in WARD-3B.

---

### Test 9: Discharge + Medications + Bed Cleanup — Multiple Meds

**Patient:** P-2024-00123 (John Tan) — discharging today, follow-up required, 3 medications

```
Complete the discharge process for patient P-2024-00123 with follow-up appointment, all medication orders, and bed cleanup
```

**Expected:** Discharge summary → CARDIOLOGY appointment 2026-04-24 → 3 pharmacy orders (Aspirin 30d, Metoprolol 30d, Atorvastatin 30d) → bed cleanup BED-4A-010 in WARD-4A.

---

## Full Workflow Tests (All Agents)

### Test 10: Full Workflow — Today's Discharge with Email

**Patient:** P-2024-00122 (Bob Tan) — bob.tan@email.com

```
Complete the full discharge process for patient P-2024-00122 including follow-up appointment, all medication orders, and bed cleanup and send appointment confirmation email at the end with all the details
```

**Expected:** Discharge summary → ORTHOPEDICS follow-up → 1 pharmacy order → bed cleanup BED-3B-001 → confirmation email to bob.tan@email.com with appointment date, medication details, and pickup info.

---

### Test 11: Full Workflow — Heavy Medication Load with Email

**Patient:** P-2024-00123 (John Tan) — john.tan@email.com

```
Complete the full discharge process for patient P-2024-00123 including follow-up appointment, all medication orders, and bed cleanup and send appointment confirmation email at the end with all the details
```

**Expected:** Discharge summary → CARDIOLOGY follow-up → 3 pharmacy orders (Aspirin, Metoprolol, Atorvastatin all 30d) → bed cleanup BED-4A-010 → email to john.tan@email.com.

---

### Test 12: Full Workflow — Tomorrow's Discharge with Email

**Patient:** P-2024-00124 (Mary Lim) — mary.lim@email.com

```
Complete the full discharge process for patient P-2024-00124 including follow-up appointment, all medication orders, and bed cleanup and send appointment confirmation email at the end with all the details
```

**Expected:** Discharge summary (2026-04-18) → ORTHOPEDICS follow-up 2026-04-25 → 2 pharmacy orders (Paracetamol 7d, Omeprazole 14d) → bed cleanup BED-3B-002 → email to mary.lim@email.com.

---

### Test 13: Full Workflow — Future Neurology Patient

**Patient:** P-2024-00126 (Sarah Chen) — sarah.chen@email.com

```
Complete the full discharge process for patient P-2024-00126 including follow-up appointment, all medication orders, and bed cleanup and send appointment confirmation email at the end with all the details
```

**Expected:** Discharge summary (2026-04-19) → NEUROLOGY follow-up 2026-04-26 → 2 pharmacy orders (Gabapentin 30d, Paracetamol 14d) → bed cleanup BED-5C-001 → email to sarah.chen@email.com.

---

## Edge Case Tests

### Test 14: No Follow-Up, Has Medication

**Patient:** P-2024-00125 (David Wong) — no follow-up, but has 1 medication

```
Complete the full discharge process for patient P-2024-00125 including any follow-up appointment if needed, medication orders, and bed cleanup
```

**Expected:** Discharge summary shows follow_up_required=false → NO appointment booked → 1 pharmacy order (Amoxicillin 7d) → bed cleanup BED-2A-002 in WARD-2A. Agent should clearly state no follow-up is needed.

---

### Test 15: Follow-Up Required, No Medications

**Patient:** P-2024-00128 (Emily Goh) — follow-up required, no medications

```
Complete the full discharge process for patient P-2024-00128 including follow-up, medications, and bed cleanup
```

**Expected:** Discharge summary → GENERAL follow-up 2026-04-29 → NO pharmacy orders (no medications prescribed) → bed cleanup BED-1A-001 in WARD-1A. Agent should state no medications to order.

---

### Test 16: No Follow-Up, No Medications

**Patient:** P-2024-00121 (Alice Ng) — discharged 3 days ago, no follow-up, no meds

```
Get the discharge summary for patient P-2024-00121
```

**Expected:** Returns discharge summary from 2026-04-14. follow_up_required=false, no medications. This is a past discharge — information retrieval only.

---

### Test 17: Patient Not Found

```
Get the discharge summary for patient P-2024-99999
```

**Expected:** Agent should handle gracefully — report that no discharge record was found for this patient ID.

---

### Test 18: Out of Scope — Medical Advice

```
What is the recommended dosage of Aspirin for heart patients?
```

**Expected:** Agent should politely decline — medical advice is outside scope. Should clarify it can only assist with discharge coordination, appointments, medication orders, and bed management.

---

### Test 19: Out of Scope — Billing

```
How much does patient P-2024-00123 owe for their hospital stay?
```

**Expected:** Agent should politely decline — billing inquiries are outside scope.

---

## Quick Reference — Agent Coverage Matrix

| Test | post_discharge | pharmacy | bed_turnover | SendEmail | Key Scenario |
|------|:-:|:-:|:-:|:-:|------|
| 1 | x | | | | Summary only (no follow-up) |
| 2 | x | | | | Summary + appointment |
| 3 | | x | | | Single med order |
| 4 | | | x | | Bed cleaning only |
| 5 | x | x | | | Discharge + 2 meds |
| 6 | x | | x | | Discharge + bed (no meds) |
| 7 | | x | x | | Meds + bed (no discharge lookup) |
| 8 | x | x | x | | Full minus email (1 med) |
| 9 | x | x | x | | Full minus email (3 meds) |
| 10 | x | x | x | x | Full workflow (1 med) |
| 11 | x | x | x | x | Full workflow (3 meds) |
| 12 | x | x | x | x | Full workflow (tomorrow, 2 meds) |
| 13 | x | x | x | x | Full workflow (future, 2 meds) |
| 14 | x | x | x | | No follow-up + has meds |
| 15 | x | | x | | Follow-up + no meds |
| 16 | x | | | | Past discharge, no follow-up, no meds |
| 17 | x | | | | Error handling |
| 18 | | | | | Scope boundary |
| 19 | | | | | Scope boundary |


Can you help me populate the dates in this sql file based on todays date 23rd April .... "C:\Work\VsCode\Agentic_AI\Hospital_AI-Agent_Use_Case\reset_data.sql"

So in patient_discharges table some patients have yesterday's discharge_date ....some patients have today's discharge date ...some patients have tomorrows discharge date, some have day after tomorrow discharge date  etc 

Update the appointments table scheduled_date accordingly,  pharmacy_orders table ready_by date accordingly , beds table updated_at date accordingly
