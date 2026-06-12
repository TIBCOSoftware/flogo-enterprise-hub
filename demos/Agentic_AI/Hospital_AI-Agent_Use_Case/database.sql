-- =============================================
-- Hospital Agent POC - Database Schema
-- PostgreSQL DDL & DML
-- =============================================

-- =============================================
-- DDL: CREATE TABLES
-- =============================================

-- 1. Specialties (Reference Table)
DROP TABLE IF EXISTS specialties CASCADE;

CREATE TABLE specialties (
    specialty_code VARCHAR(20) PRIMARY KEY,
    specialty_name VARCHAR(100)
);

-- 2. Patients
DROP TABLE IF EXISTS patients CASCADE;

CREATE TABLE patients (
    patient_id VARCHAR(20) PRIMARY KEY,
    first_name VARCHAR(50),
    last_name VARCHAR(50),
    phone_number VARCHAR(20),
    email VARCHAR(100)
);

-- 3. Patient Discharges
DROP TABLE IF EXISTS patient_discharges CASCADE;

CREATE TABLE patient_discharges (
    discharge_id SERIAL PRIMARY KEY,
    patient_id VARCHAR(20),
    discharge_date VARCHAR(20),
    ward_id VARCHAR(20),
    bed_id VARCHAR(20),
    follow_up_required BOOLEAN DEFAULT FALSE,
    specialty_code VARCHAR(20)
);

-- 4. Discharge Medications
DROP TABLE IF EXISTS discharge_medications CASCADE;

CREATE TABLE discharge_medications (
    id SERIAL PRIMARY KEY,
    discharge_id INTEGER,
    medication_code VARCHAR(20),
    days_supply INTEGER
);

-- 5. Appointments
DROP TABLE IF EXISTS appointments CASCADE;

CREATE TABLE appointments (
    appointment_id SERIAL PRIMARY KEY,
    patient_id VARCHAR(50),
    specialty VARCHAR(50),
    scheduled_date VARCHAR(20),
    scheduled_time VARCHAR(10),
    status VARCHAR(20) DEFAULT 'CONFIRMED'
);

-- 6. Medication Catalog (Lookup)
DROP TABLE IF EXISTS medication_catalog CASCADE;

CREATE TABLE medication_catalog (
    medication_code VARCHAR(20) PRIMARY KEY,
    medication_name VARCHAR(100),
    ready_hours VARCHAR(10)
);

-- 7. Pharmacy Orders
DROP TABLE IF EXISTS pharmacy_orders CASCADE;

CREATE TABLE pharmacy_orders (
    order_id SERIAL PRIMARY KEY,
    patient_id VARCHAR(50),
    medication_code VARCHAR(20),
    medication_name VARCHAR(100),
    days_supply VARCHAR(10),
    pickup_location VARCHAR(20),
    ready_by VARCHAR(30),
    status VARCHAR(20) DEFAULT 'PROCESSING'
);

-- 8. Beds
DROP TABLE IF EXISTS beds CASCADE;

CREATE TABLE beds (
    id SERIAL PRIMARY KEY,
    bed_id VARCHAR(20),
    ward_id VARCHAR(20),
    patient_id VARCHAR(20),
    status VARCHAR(30) DEFAULT 'AVAILABLE',
    updated_at VARCHAR(30),
    estimated_ready VARCHAR(30)
);


-- =============================================
-- DML: INSERT SAMPLE DATA
-- =============================================

-- Specialties
INSERT INTO specialties (specialty_code, specialty_name) VALUES
('CARDIOLOGY', 'Cardiology'),
('NEUROLOGY', 'Neurology'),
('ORTHOPEDICS', 'Orthopedics'),
('GENERAL', 'General Medicine'),
('ONCOLOGY', 'Oncology');

-- Patients
INSERT INTO patients (patient_id, first_name, last_name, phone_number, email) VALUES
('P-2024-00123', 'John', 'Tan', '+65 9123 4567', 'john.tan@email.com'),
('P-2024-00124', 'Mary', 'Lim', '+65 9234 5678', 'mary.lim@email.com'),
('P-2024-00125', 'David', 'Wong', '+65 9345 6789', 'david.wong@email.com'),
('P-2024-00126', 'Sarah', 'Chen', '+65 9456 7890', 'sarah.chen@email.com'),
('P-2024-00127', 'Michael', 'Lee', '+65 9567 8901', 'michael.lee@email.com');

-- Patient Discharges
INSERT INTO patient_discharges (patient_id, discharge_date, ward_id, bed_id, follow_up_required, specialty_code) VALUES
('P-2024-00123', '2026-03-20', 'WARD-4A', 'BED-4A-010', TRUE, 'CARDIOLOGY'),
('P-2024-00124', '2026-03-20', 'WARD-3B', 'BED-3B-001', TRUE, 'ORTHOPEDICS'),
('P-2024-00125', '2026-03-19', 'WARD-2A', 'BED-2A-001', FALSE, NULL),
('P-2024-00126', '2026-03-20', 'WARD-5C', 'BED-5C-001', TRUE, 'NEUROLOGY'),
('P-2024-00127', '2026-03-18', 'WARD-4A', 'BED-4A-012', TRUE, 'CARDIOLOGY');

-- Discharge Medications
INSERT INTO discharge_medications (discharge_id, medication_code, days_supply) VALUES
(1, 'MED001', 30),
(1, 'MED002', 30),
(1, 'MED004', 30),
(2, 'MED006', 7),
(2, 'MED005', 14),
(3, 'MED007', 7),
(4, 'MED010', 30),
(4, 'MED006', 14),
(5, 'MED001', 30),
(5, 'MED002', 30);

-- Appointments (Sample existing)
INSERT INTO appointments (patient_id, specialty, scheduled_date, scheduled_time) VALUES
('P-2024-00127', 'CARDIOLOGY', '2026-03-22', '09:00'),
('P-2024-00124', 'ORTHOPEDICS', '2026-03-23', '14:00');

-- Medication Catalog
INSERT INTO medication_catalog (medication_code, medication_name, ready_hours) VALUES
('MED001', 'Aspirin 100mg', '4'),
('MED002', 'Metoprolol 50mg', '4'),
('MED003', 'Lisinopril 10mg', '4'),
('MED004', 'Atorvastatin 20mg', '4'),
('MED005', 'Omeprazole 20mg', '2'),
('MED006', 'Paracetamol 500mg', '1'),
('MED007', 'Amoxicillin 500mg', '2'),
('MED008', 'Metformin 500mg', '4'),
('MED009', 'Warfarin 5mg', '4'),
('MED010', 'Gabapentin 300mg', '3');

-- Pharmacy Orders (Sample existing)
INSERT INTO pharmacy_orders (patient_id, medication_code, medication_name, days_supply, pickup_location, ready_by, status) VALUES
('P-2024-00127', 'MED001', 'Aspirin 100mg', '30', 'PHARMACY_A', '2026-03-21 14:00', 'READY'),
('P-2024-00124', 'MED006', 'Paracetamol 500mg', '7', 'PHARMACY_B', '2026-03-21 16:00', 'PROCESSING');

-- Beds
INSERT INTO beds (bed_id, ward_id, patient_id, status, updated_at, estimated_ready) VALUES
('BED-4A-010', 'WARD-4A', 'P-2024-00123', 'OCCUPIED', '2026-03-20 08:00', NULL),
('BED-4A-011', 'WARD-4A', NULL, 'AVAILABLE', '2026-03-20 10:00', NULL),
('BED-4A-012', 'WARD-4A', 'P-2024-00127', 'OCCUPIED', '2026-03-20 09:00', NULL),
('BED-3B-001', 'WARD-3B', NULL, 'CLEANING_IN_PROGRESS', '2026-03-20 14:00', '2026-03-20 14:30'),
('BED-3B-002', 'WARD-3B', NULL, 'AVAILABLE', '2026-03-20 11:00', NULL),
('BED-5C-001', 'WARD-5C', 'P-2024-00126', 'OCCUPIED', '2026-03-20 07:00', NULL);


-- =============================================
-- API QUERIES REFERENCE
-- =============================================

-- API 1: GET /api/v1/patients/{patient_id}/discharge-summary
-- SELECT
--     p.patient_id,
--     pd.follow_up_required,
--     pd.specialty_code AS specialty,
--     pd.discharge_date,
--     pd.ward_id,
--     pd.bed_id,
--     COALESCE(
--         json_agg(
--             json_build_object(
--                 'medication_code', dm.medication_code,
--                 'days_supply', dm.days_supply
--             )
--         ) FILTER (WHERE dm.medication_code IS NOT NULL),
--         '[]'::json
--     ) AS medications
-- FROM patients p
-- JOIN patient_discharges pd ON p.patient_id = pd.patient_id
-- LEFT JOIN discharge_medications dm ON pd.discharge_id = dm.discharge_id
-- WHERE p.patient_id = 'P-2024-00123'
-- GROUP BY p.patient_id, pd.follow_up_required, pd.specialty_code, pd.discharge_date, pd.ward_id, pd.bed_id;

-- API 2: POST /api/v1/appointments
-- INSERT INTO appointments (patient_id, specialty, scheduled_date, scheduled_time)
-- VALUES ('P-2024-00123', 'CARDIOLOGY', '2026-01-28', '10:30')
-- RETURNING appointment_id, patient_id, scheduled_date, scheduled_time, status;

-- API 3: POST /api/v1/pharmacy/orders
-- Step 1: Get medication info
-- SELECT medication_name, ready_hours FROM medication_catalog WHERE medication_code = 'MED001';
-- Step 2: Insert order
-- INSERT INTO pharmacy_orders (patient_id, medication_code, medication_name, days_supply, pickup_location, ready_by)
-- VALUES ('P-2024-00123', 'MED001', 'Aspirin 100mg', '30', 'PHARMACY_A', '2026-01-21 14:00')
-- RETURNING order_id, patient_id, medication_name, ready_by, status;

-- API 4: POST /api/v1/beds/actions
-- UPDATE beds
-- SET status = 'CLEANING_REQUESTED',
--     patient_id = NULL,
--     updated_at = TO_CHAR(NOW(), 'YYYY-MM-DD HH24:MI'),
--     estimated_ready = TO_CHAR(NOW() + INTERVAL '20 minutes', 'YYYY-MM-DD HH24:MI')
-- WHERE bed_id = 'BED-4A-012'
-- RETURNING bed_id, ward_id, patient_id, status, updated_at, estimated_ready;

-- API 5: POST /api/v1/beds/update-status
-- UPDATE beds
-- SET status = 'AVAILABLE',
--     updated_at = TO_CHAR(NOW(), 'YYYY-MM-DD HH24:MI'),
--     estimated_ready = NULL
-- WHERE bed_id = 'BED-4A-012'
-- RETURNING bed_id, ward_id, patient_id, status, updated_at, estimated_ready;
