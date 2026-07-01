-- =============================================
-- Hospital Agent POC - Reset & Fresh Test Data
-- Run this script to reset all tables to baseline
-- =============================================

-- =============================================
-- TRUNCATE ALL TABLES
-- =============================================

TRUNCATE TABLE discharge_medications RESTART IDENTITY CASCADE;
TRUNCATE TABLE patient_discharges RESTART IDENTITY CASCADE;
TRUNCATE TABLE appointments RESTART IDENTITY CASCADE;
TRUNCATE TABLE pharmacy_orders RESTART IDENTITY CASCADE;
TRUNCATE TABLE beds RESTART IDENTITY CASCADE;
TRUNCATE TABLE patients RESTART IDENTITY CASCADE;
TRUNCATE TABLE medication_catalog RESTART IDENTITY CASCADE;
TRUNCATE TABLE specialties RESTART IDENTITY CASCADE;

-- =============================================
-- SPECIALTIES (5 entries)
-- =============================================

INSERT INTO specialties (specialty_code, specialty_name) VALUES
('CARDIOLOGY', 'Cardiology'),
('NEUROLOGY', 'Neurology'),
('ORTHOPEDICS', 'Orthopedics'),
('GENERAL', 'General Medicine'),
('ONCOLOGY', 'Oncology');

-- =============================================
-- MEDICATION CATALOG (10 entries)
-- =============================================

INSERT INTO medication_catalog (medication_code, medication_name, ready_hours) VALUES
('MED001', 'Aspirin 100mg', '4'),
('MED002', 'Metoprolol 50mg', '4'),
('MED003', 'Lisinopril 10mg', '4'),
('MED004', 'Atorvastatin 20mg', '4'),
('MED005', 'Omeprazole 20mg', '2'),
('MED006', 'Paracetamol 500mg', '1'),
('MED007', 'Amoxicillin 500mg', '2'),
('MED008', 'Metformin 500mg', '4'),
('MED009', 'Warfarin 5mg', '3'),
('MED010', 'Gabapentin 300mg', '3');

-- =============================================
-- PATIENTS (10 entries)
-- =============================================

INSERT INTO patients (patient_id, first_name, last_name, phone_number, email) VALUES
('P-2024-00121', 'Alice', 'Ng', '+1 (415) 555-0121', 'alice.ng@email.com'),
('P-2024-00122', 'Bob', 'Tan', '+1 (212) 555-0122', 'bob.tan@email.com'),
('P-2024-00123', 'John', 'Tan', '+1 (310) 555-0123', 'john.tan@email.com'),
('P-2024-00124', 'Mary', 'Lim', '+1 (312) 555-0124', 'mary.lim@email.com'),
('P-2024-00125', 'David', 'Wong', '+1 (617) 555-0125', 'david.wong@email.com'),
('P-2024-00126', 'Sarah', 'Chen', '+1 (206) 555-0126', 'sarah.chen@email.com'),
('P-2024-00127', 'Michael', 'Lee', '+1 (512) 555-0127', 'michael.lee@email.com'),
('P-2024-00128', 'Emily', 'Goh', '+1 (305) 555-0128', 'emily.goh@email.com'),
('P-2024-00129', 'James', 'Koh', '+1 (503) 555-0129', 'james.koh@email.com'),
('P-2024-00130', 'Sophie', 'Yeo', '+1 (404) 555-0130', 'sophie.yeo@email.com');

-- =============================================
-- PATIENT DISCHARGES (10 entries)
-- =============================================

INSERT INTO patient_discharges (patient_id, discharge_date, ward_id, bed_id, follow_up_required, specialty_code) VALUES
('P-2024-00121', '2026-06-27', 'WARD-2A', 'BED-2A-001', FALSE, 'GENERAL'),         -- 3 days ago (past)
('P-2024-00122', '2026-06-30', 'WARD-3B', 'BED-3B-001', TRUE, 'ORTHOPEDICS'),      -- today
('P-2024-00123', '2026-06-30', 'WARD-4A', 'BED-4A-010', TRUE, 'CARDIOLOGY'),       -- today
('P-2024-00124', '2026-07-01', 'WARD-3B', 'BED-3B-002', TRUE, 'ORTHOPEDICS'),      -- tomorrow
('P-2024-00125', '2026-06-30', 'WARD-2A', 'BED-2A-002', FALSE, 'GENERAL'),         -- today
('P-2024-00126', '2026-07-02', 'WARD-5C', 'BED-5C-001', TRUE, 'NEUROLOGY'),        -- day after tomorrow
('P-2024-00127', '2026-07-04', 'WARD-4A', 'BED-4A-012', TRUE, 'CARDIOLOGY'),       -- 4 days from now
('P-2024-00128', '2026-07-05', 'WARD-1A', 'BED-1A-001', TRUE, 'GENERAL'),          -- 5 days from now
('P-2024-00129', '2026-06-28', 'WARD-6B', 'BED-6B-001', TRUE, 'ONCOLOGY'),         -- 2 days ago (past)
('P-2024-00130', '2026-06-29', 'WARD-4A', 'BED-4A-011', FALSE, 'GENERAL');         -- yesterday (past)

-- =============================================
-- DISCHARGE MEDICATIONS (10 entries)
-- =============================================

INSERT INTO discharge_medications (discharge_id, medication_code, days_supply) VALUES
(2, 'MED006', 7),
(3, 'MED001', 30),
(3, 'MED002', 30),
(3, 'MED004', 30),
(4, 'MED006', 7),
(4, 'MED005', 14),
(5, 'MED007', 7),
(6, 'MED010', 30),
(6, 'MED006', 14),
(7, 'MED001', 30);

-- =============================================
-- APPOINTMENTS (5 entries - only past-discharged patients have follow-ups)
-- Test patients (122, 123, 125, 126) left clean for agent workflow testing
-- =============================================

INSERT INTO appointments (patient_id, specialty, scheduled_date, scheduled_time, status) VALUES
('P-2024-00129', 'ONCOLOGY', '2026-07-05', '10:30', 'CONFIRMED'),      -- follow-up 7d after 06-28 discharge
('P-2024-00121', 'GENERAL', '2026-07-11', '09:00', 'CONFIRMED'),       -- routine visit (not from discharge)
('P-2024-00130', 'GENERAL', '2026-07-08', '14:00', 'CONFIRMED'),       -- routine visit
('P-2024-00127', 'CARDIOLOGY', '2026-06-27', '14:00', 'CONFIRMED'),    -- past visit (before admission)
('P-2024-00128', 'GENERAL', '2026-06-23', '10:00', 'CONFIRMED');       -- past visit (before admission)

-- =============================================
-- PHARMACY ORDERS (4 entries - historical only, all completed)
-- Test patients (122, 123, 125, 126) left clean for agent workflow testing
-- =============================================

INSERT INTO pharmacy_orders (patient_id, medication_code, medication_name, days_supply, pickup_location, ready_by, status) VALUES
('P-2024-00121', 'MED001', 'Aspirin 100mg', '30', 'PHARMACY_A', '2026-06-18 10:00', 'DISPENSED'),       -- past prescription
('P-2024-00121', 'MED008', 'Metformin 500mg', '30', 'PHARMACY_A', '2026-06-23 14:00', 'DISPENSED'),      -- past prescription
('P-2024-00129', 'MED003', 'Lisinopril 10mg', '30', 'PHARMACY_A', '2026-06-25 16:00', 'DISPENSED'),      -- past prescription
('P-2024-00130', 'MED007', 'Amoxicillin 500mg', '7', 'PHARMACY_B', '2026-06-27 11:00', 'DISPENSED');     -- past prescription

-- =============================================
-- BEDS (10 entries)
-- =============================================

INSERT INTO beds (bed_id, ward_id, patient_id, status, updated_at, estimated_ready) VALUES
('BED-1A-001', 'WARD-1A', 'P-2024-00128', 'OCCUPIED', '2026-06-27 08:00', NULL),              -- P-128 discharge 07-05 (future)
('BED-2A-001', 'WARD-2A', NULL, 'AVAILABLE', '2026-06-27 15:00', NULL),                        -- P-121 discharged 06-27, bed cleaned
('BED-2A-002', 'WARD-2A', 'P-2024-00125', 'OCCUPIED', '2026-06-28 09:00', NULL),              -- P-125 discharging today
('BED-3B-001', 'WARD-3B', 'P-2024-00122', 'OCCUPIED', '2026-06-26 10:00', NULL),              -- P-122 discharging today
('BED-3B-002', 'WARD-3B', 'P-2024-00124', 'OCCUPIED', '2026-06-27 11:00', NULL),              -- P-124 discharge tomorrow
('BED-4A-010', 'WARD-4A', 'P-2024-00123', 'OCCUPIED', '2026-06-25 07:00', NULL),              -- P-123 discharging today
('BED-4A-011', 'WARD-4A', NULL, 'AVAILABLE', '2026-06-29 16:00', NULL),                        -- P-130 discharged yesterday, bed cleaned
('BED-4A-012', 'WARD-4A', 'P-2024-00127', 'OCCUPIED', '2026-06-27 07:00', NULL),              -- P-127 discharge 07-04 (future)
('BED-5C-001', 'WARD-5C', 'P-2024-00126', 'OCCUPIED', '2026-06-28 08:30', NULL),              -- P-126 discharge 07-02 (future)
('BED-6B-001', 'WARD-6B', NULL, 'AVAILABLE', '2026-06-29 09:30', NULL);                        -- P-129 discharged 06-28, bed cleaned

-- =============================================
-- VERIFY DATA
-- =============================================

SELECT 'specialties' AS table_name, COUNT(*) AS row_count FROM specialties
UNION ALL
SELECT 'medication_catalog', COUNT(*) FROM medication_catalog
UNION ALL
SELECT 'patients', COUNT(*) FROM patients
UNION ALL
SELECT 'patient_discharges', COUNT(*) FROM patient_discharges
UNION ALL
SELECT 'discharge_medications', COUNT(*) FROM discharge_medications
UNION ALL
SELECT 'appointments', COUNT(*) FROM appointments
UNION ALL
SELECT 'pharmacy_orders', COUNT(*) FROM pharmacy_orders
UNION ALL
SELECT 'beds', COUNT(*) FROM beds;
