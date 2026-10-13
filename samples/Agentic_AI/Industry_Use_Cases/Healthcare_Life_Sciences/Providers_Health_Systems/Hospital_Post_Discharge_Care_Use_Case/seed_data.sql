-- Demo data for Bellmont Regional Medical Center - Hospital Post-Discharge Care (governed). Fictional hospital, patients,
-- staff and numbers (555-01xx range, example.com emails, no real addresses). Every volatile date is relative to
-- CURRENT_DATE / now(), so the demo never goes stale. Clinic days skip weekends (add_business_days).
-- Included by database.sql and reset_data.sql via \ir - do not load on its own.

ALTER SEQUENCE rx_seq RESTART WITH 101;
ALTER SEQUENCE bed_seq RESTART WITH 101;

-- ---------------------------------------------------------------------
-- Reference data and routing
-- ---------------------------------------------------------------------
INSERT INTO wards (ward_id, ward_name) VALUES ('4A', 'Cardiac Step-Down'), ('3B', 'Orthopedics');

INSERT INTO specialties (specialty_code, specialty_name) VALUES
 ('CARDIOLOGY',  'Cardiology'),
 ('ANTICOAG',    'Anticoagulation Clinic'),
 ('ORTHOPEDICS', 'Orthopedics'),
 ('GENERAL',     'General Medicine');

INSERT INTO medication_catalog (medication_code, generic_name, strength, form, also_known_as, high_alert, prep_minutes) VALUES
 ('MED-101', 'aspirin',              '81 mg',        'tablet',     'baby aspirin, low-dose aspirin', FALSE, 30),
 ('MED-102', 'metoprolol succinate', '25 mg',        'ER tablet',  NULL,                             FALSE, 30),
 ('MED-103', 'atorvastatin',         '40 mg',        'tablet',     NULL,                             FALSE, 30),
 ('MED-104', 'lisinopril',           '10 mg',        'tablet',     NULL,                             FALSE, 30),
 ('MED-105', 'warfarin',             '5 mg',         'tablet',     NULL,                             TRUE,  60),
 ('MED-106', 'omeprazole',           '20 mg',        'capsule',    NULL,                             FALSE, 20),
 ('MED-107', 'oxycodone',            '5 mg',         'tablet',     NULL,                             TRUE,  60),
 ('MED-108', 'acetaminophen',        '500 mg',       'tablet',     'paracetamol',                    FALSE, 15),
 ('MED-109', 'amoxicillin',          '500 mg',       'capsule',    NULL,                             FALSE, 20),
 ('MED-110', 'furosemide',           '40 mg',        'tablet',     'water pill',                     FALSE, 20),
 ('MED-111', 'insulin glargine',     '100 units/mL', 'pen',        NULL,                             TRUE,  45),
 ('MED-112', 'enoxaparin',           '40 mg/0.4 mL', 'syringe',    NULL,                             TRUE,  45);

-- ---------------------------------------------------------------------
-- Agent reference tables (read-only for the A2A agents via ref_* functions; no patient or staff data)
-- ---------------------------------------------------------------------
-- discharge_instructions_agent -> ref_plain_language()
INSERT INTO plain_language_guide (section, term, meaning) VALUES
 ('PRESCRIPTION_WORD', 'by mouth',                    'swallow it'),
 ('PRESCRIPTION_WORD', 'once daily',                  'one time each day'),
 ('PRESCRIPTION_WORD', 'twice daily',                 'two times each day, about 12 hours apart'),
 ('PRESCRIPTION_WORD', 'three times daily',           'morning, afternoon and evening'),
 ('PRESCRIPTION_WORD', 'every morning',               'one time each morning'),
 ('PRESCRIPTION_WORD', 'every 8 hours',               'about three times a day, 8 hours apart'),
 ('PRESCRIPTION_WORD', 'at bedtime',                  'just before you go to sleep'),
 ('PRESCRIPTION_WORD', 'before breakfast',            'before you eat breakfast'),
 ('PRESCRIPTION_WORD', 'as needed',                   'only when you need it, not on a schedule'),
 ('PRESCRIPTION_WORD', 'every 6 hours as needed',     'no more often than every 6 hours'),
 ('PRESCRIPTION_WORD', 'max N tablets a day',         'never more than that many tablets in 24 hours'),
 ('PRESCRIPTION_WORD', 'swallow whole, do not crush', 'do not break, crush or chew it'),
 ('PRESCRIPTION_WORD', 'until finished',              'take every dose until the bottle is empty, even if you feel better'),
 ('PRESCRIPTION_WORD', 'dose per INR result',         'the clinic tells you the dose after your blood test'),
 ('PRESCRIPTION_WORD', 'injection under the skin',    'a small shot just under the skin, not into a vein'),
 ('PRESCRIPTION_WORD', 'ER tablet',                   'extended-release tablet'),
 ('PICKUP',            'Meds-to-Beds bedside delivery',            'the pharmacy brings the medicines to the patient''s room before they leave'),
 ('PICKUP',            'Bellmont Outpatient Pharmacy, Main Lobby', 'pick up at the pharmacy counter in the main lobby'),
 ('APPOINTMENT_TYPE',  'Follow-up visit',             'a check-up with the doctor or clinic after leaving the hospital'),
 ('APPOINTMENT_TYPE',  'Echocardiogram',              'an ultrasound picture of the heart (a test, not a visit with the doctor)'),
 ('PENDING',           'pharmacist still reviewing',  'say the care team will tell the patient when it is ready'),
 ('READING_LEVEL',     'sentences',                   'short sentences, one idea each'),
 ('READING_LEVEL',     'words',                       'everyday words; explain a medical word in plain words the first time it is used'),
 ('READING_LEVEL',     'target',                      'about a 6th-grade reading level'),
 ('SAFETY_NET',        'safety-net sentence (always end with it)',
                       'If you have questions about your medicines, call the Bellmont Pharmacy at (555) 010-4400. If you feel very unwell, call your care team; in an emergency, call 911.');

-- med_reconciliation_agent -> ref_med_rec()  (+ HIGH_ALERT rows from medication_catalog.high_alert)
INSERT INTO med_rec_reference (section, term, meaning) VALUES
 ('COMMON_NAME', 'baby aspirin',             'aspirin 81 mg (antiplatelet)'),
 ('COMMON_NAME', 'low-dose aspirin',         'aspirin 81 mg (antiplatelet)'),
 ('COMMON_NAME', 'water pill',               'a diuretic such as furosemide'),
 ('COMMON_NAME', 'blood thinner',            'an anticoagulant such as warfarin or enoxaparin, or sometimes an antiplatelet such as aspirin - flag as UNCLEAR unless named'),
 ('COMMON_NAME', 'paracetamol',              'acetaminophen'),
 ('COMMON_NAME', 'fish oil',                 'omega-3 supplement'),
 ('COMMON_NAME', 'my heart pill',            'UNCLEAR unless the medicine is named'),
 ('COMMON_NAME', 'my blood pressure pill',   'UNCLEAR unless the medicine is named'),
 ('DRUG_CLASS',  'aspirin',                  'antiplatelet; also an NSAID'),
 ('DRUG_CLASS',  'ibuprofen',                'NSAID (anti-inflammatory pain reliever)'),
 ('DRUG_CLASS',  'naproxen',                 'NSAID (anti-inflammatory pain reliever)'),
 ('DRUG_CLASS',  'acetaminophen',            'pain and fever reliever (not an NSAID); has a daily maximum'),
 ('DRUG_CLASS',  'warfarin',                 'anticoagulant (blood thinner)'),
 ('DRUG_CLASS',  'enoxaparin',               'anticoagulant (blood thinner), given by injection'),
 ('DRUG_CLASS',  'metoprolol',               'beta blocker (blood pressure medicine)'),
 ('DRUG_CLASS',  'lisinopril',               'ACE inhibitor (blood pressure medicine)'),
 ('DRUG_CLASS',  'atorvastatin',             'statin (cholesterol medicine)'),
 ('DRUG_CLASS',  'omeprazole',               'proton pump inhibitor (stomach acid medicine)'),
 ('DRUG_CLASS',  'furosemide',               'loop diuretic (water pill)'),
 ('DRUG_CLASS',  'amoxicillin',              'penicillin antibiotic'),
 ('DRUG_CLASS',  'oxycodone',                'opioid pain reliever'),
 ('DRUG_CLASS',  'insulin glargine',         'long-acting insulin'),
 ('DRUG_CLASS',  'omega-3 supplement',       'dietary supplement; can add to bleeding risk with an anticoagulant'),
 ('FLAG_TYPE',   'DUPLICATE',                'the same ingredient or the same drug class appears twice (home + discharge)'),
 ('FLAG_TYPE',   'INTERACTION',              'a home medicine and a discharge medicine that a pharmacist always reviews together'),
 ('FLAG_TYPE',   'OMISSION',                 'a home medicine that is not on the discharge list (continue or stop is unclear)'),
 ('FLAG_TYPE',   'UNCLEAR',                  'a home medicine that cannot be identified from the description'),
 ('ALWAYS_FLAG', 'anticoagulant + aspirin',  'bleeding risk - always flag for the pharmacist'),
 ('ALWAYS_FLAG', 'anticoagulant + NSAID',    'bleeding risk - always flag for the pharmacist'),
 ('ALWAYS_FLAG', 'anticoagulant + fish oil', 'bleeding risk - always flag for the pharmacist'),
 ('ALWAYS_FLAG', 'same ingredient twice',    'two medicines with the same ingredient - always flag'),
 ('ALWAYS_FLAG', 'two blood pressure medicines of the same class', 'always flag for the pharmacist'),
 ('ALWAYS_FLAG', 'acetaminophen from more than one source', 'daily maximum - always flag for the pharmacist'),
 ('RULE',        'who decides',              'flags are for the pharmacist to review; the pharmacist decides - never recommend stopping or changing anything');

-- followup_slot_agent -> ref_slot_guide()
INSERT INTO slot_ranking_guide (section, term, meaning) VALUES
 ('PART_OF_DAY',    'morning',                    'starts before 12:00'),
 ('PART_OF_DAY',    'afternoon',                  'starts 12:00 to 16:59'),
 ('PART_OF_DAY',    'evening',                    'starts 17:00 or later'),
 ('ACCESS_CODE',    'wheelchair_accessible yes',  'the clinic room and entrance are step-free'),
 ('ACCESS_CODE',    'wheelchair_accessible no',   'the clinic room or entrance has steps'),
 ('TRANSPORT_CODE', 'transport_available yes',    'Bellmont''s patient transport (a wheelchair-accessible van) can bring the patient to that slot'),
 ('TRANSPORT_CODE', 'transport_available no',     'no Bellmont transport for that slot - the patient needs their own ride'),
 ('CONSTRAINT',     'needs wheelchair transport', 'the slot must have BOTH wheelchair_accessible yes AND transport_available yes'),
 ('CONSTRAINT',     'no mornings',                'never rank a slot that starts before 12:00'),
 ('SEQUENCE',       'after a test',               'the slot starts on a later calendar day than that test - the same day is not enough, because results are reviewed the next day'),
 ('SEQUENCE',       'before a test',              'the slot starts on an earlier calendar day than that test'),
 ('RANKING',        'earliest first',             'when several slots meet every constraint, prefer the earliest'),
 ('RANKING',        'only listed slots',          'never suggest a slot that is not in the list you were given'),
 ('RANKING',        'excluded',                   'list every slot that breaks a stated constraint, with the reason');

INSERT INTO case_routing (request_type, label, team, sla_hours, sla_text, coordinator_openable) VALUES
 ('high_alert_med',      'high-alert medicine review',       'Pharmacy',            2, 'A pharmacist reviews high-alert medicines within 2 hours.', FALSE),
 ('med_rec_review',      'medication reconciliation review', 'Pharmacy',            4, 'A pharmacist reviews the reconciliation flags within 4 hours.', TRUE),
 ('bed_override',        'early bed turnover',               'Nursing Operations',  1, 'The charge nurse decides early bed turnovers within 1 hour.', TRUE),
 ('clinical_question',   'clinical or dosage question',      'Hospitalist Service', 2, 'The attending physician answers clinical and dosage questions within 2 hours.', TRUE),
 ('prescription_change', 'prescription change',              'Hospitalist Service', 4, 'The attending physician reviews prescription changes within 4 hours.', TRUE),
 ('discharge_decision',  'discharge decision',               'Hospitalist Service', 4, 'The attending physician decides discharge questions within 4 hours.', TRUE);

-- ---------------------------------------------------------------------
-- Staff (login: staff ID + one-time code)
-- ---------------------------------------------------------------------
INSERT INTO coordinators (staff_id, display_name, ward_id, one_time_code) VALUES
 ('BMC-4101', 'Rachel Moore',  '4A', '4826'),
 ('BMC-3201', 'Daniel Brooks', '3B', '7391');

INSERT INTO reviewers (reviewer_id, display_name, team, one_time_code, approval_limit) VALUES
 ('BMC-7701', 'Priya Raman, PharmD',  'Pharmacy',            '3141', 30),     -- clinical pharmacist: up to a 30-day high-alert supply
 ('BMC-7702', 'Owen Fischer, PharmD', 'Pharmacy',            '2718', 7),      -- pharmacy resident: 7-day limit (OVER_AUTHORITY demo)
 ('BMC-5501', 'Maya Kim, RN',         'Nursing Operations',  '1618', NULL),   -- charge nurse
 ('BMC-6601', 'Dr. Elena Torres',     'Hospitalist Service', '5772', NULL);   -- attending physician

-- ---------------------------------------------------------------------
-- Patients (fictional) and beds
-- ---------------------------------------------------------------------
INSERT INTO patients (patient_id, first_name, last_name, date_of_birth, phone, email, home_address, insurance_id) VALUES
 ('MRN-4012', 'John',     'Harper',  '1956-04-11', '(555) 010-1012', 'john.harper@example.com',     '41 Alder Lane, Bellmont',      'INS-55104012'),
 ('MRN-4015', 'Margaret', 'Ellis',   '1948-09-02', '(555) 010-1015', 'margaret.ellis@example.com',  '9 Quarry Road, Bellmont',      'INS-55104015'),
 ('MRN-4018', 'Robert',   'Nguyen',  '1961-01-23', '(555) 010-1018', 'robert.nguyen@example.com',   '220 Mill Street, Bellmont',    'INS-55104018'),
 ('MRN-4021', 'Dorothy',  'Evans',   '1939-06-30', '(555) 010-1021', 'dorothy.evans@example.com',   '7 Linden Court, Bellmont',     'INS-55104021'),
 ('MRN-4009', 'William',  'Foster',  '1970-11-15', '(555) 010-1009', 'william.foster@example.com',  '58 Ridge Avenue, Bellmont',    'INS-55104009'),
 ('MRN-3204', 'Thomas',   'Reed',    '1965-03-08', '(555) 010-3204', 'thomas.reed@example.com',     '312 Harbor View, Bellmont',    'INS-55103204'),
 ('MRN-3207', 'Angela',   'Morris',  '1952-12-19', '(555) 010-3207', 'angela.morris@example.com',   '15 Orchard Way, Bellmont',     'INS-55103207'),
 ('MRN-3211', 'Kevin',    'Shaw',    '1983-07-04', '(555) 010-3211', 'kevin.shaw@example.com',      '88 Station Road, Bellmont',    'INS-55103211');

INSERT INTO beds (bed_id, ward_id, patient_id, status, updated_at, estimated_ready) VALUES
 ('4A-09', '4A', NULL,       'AVAILABLE',            now() - INTERVAL '20 hours', NULL),
 ('4A-10', '4A', 'MRN-4012', 'OCCUPIED',             now() - INTERVAL '4 days',   NULL),   -- John left this morning; bed not turned over yet
 ('4A-11', '4A', 'MRN-4015', 'OCCUPIED',             now() - INTERVAL '3 days',   NULL),
 ('4A-12', '4A', 'MRN-4018', 'OCCUPIED',             now() - INTERVAL '5 days',   NULL),   -- Robert leaves tomorrow
 ('4A-14', '4A', 'MRN-4021', 'OCCUPIED',             now() - INTERVAL '6 days',   NULL),
 ('4A-15', '4A', NULL,       'CLEANING_IN_PROGRESS', now() - INTERVAL '25 minutes', date_trunc('minute', now()::timestamp) + INTERVAL '20 minutes'),
 ('4A-16', '4A', NULL,       'AVAILABLE',            now() - INTERVAL '2 hours',  NULL),
 ('3B-02', '3B', NULL,       'AVAILABLE',            now() - INTERVAL '3 hours',  NULL),
 ('3B-04', '3B', 'MRN-3204', 'OCCUPIED',             now() - INTERVAL '4 days',   NULL),   -- Thomas left today (contact isolation)
 ('3B-07', '3B', 'MRN-3207', 'OCCUPIED',             now() - INTERVAL '3 days',   NULL),   -- Angela is in the discharge lounge
 ('3B-11', '3B', 'MRN-3211', 'OCCUPIED',             now() - INTERVAL '2 days',   NULL);

-- ---------------------------------------------------------------------
-- Discharges and discharge medicines
-- ---------------------------------------------------------------------
INSERT INTO discharges (patient_id, ward_id, bed_id, service, attending, status, planned_date, discharge_date, discharged_at,
                        followup_required, followup_specialty, followup_min_days, followup_max_days, isolation) VALUES
 ('MRN-4012', '4A', '4A-10', 'Cardiology',       'Dr. Samuel Okoro',     'DISCHARGED', current_date,     current_date,     date_trunc('minute', now()::timestamp - INTERVAL '90 minutes'), TRUE,  'CARDIOLOGY',  7, 14, FALSE),
 ('MRN-4015', '4A', '4A-11', 'Cardiology',       'Dr. Samuel Okoro',     'ORDERED',    current_date,     NULL,             NULL,                                                           TRUE,  'ANTICOAG',    3,  7, FALSE),
 ('MRN-4018', '4A', '4A-12', 'Cardiology',       'Dr. Samuel Okoro',     'ORDERED',    current_date + 1, NULL,             NULL,                                                           TRUE,  'CARDIOLOGY',  7, 14, FALSE),
 ('MRN-4021', '4A', '4A-14', 'General Medicine', 'Dr. Elena Torres',     'PENDING',    NULL,             NULL,             NULL,                                                           TRUE,  'GENERAL',     7, 14, FALSE),
 ('MRN-4009', '4A', '4A-09', 'Cardiology',       'Dr. Samuel Okoro',     'DISCHARGED', current_date - 1, current_date - 1, (current_date - 1) + TIME '14:10',                              FALSE, NULL,       NULL, NULL, FALSE),
 ('MRN-3204', '3B', '3B-04', 'Orthopedics',      'Dr. Hannah Lindqvist', 'DISCHARGED', current_date,     current_date,     date_trunc('minute', now()::timestamp - INTERVAL '2 hours'),    TRUE,  'ORTHOPEDICS', 10, 14, TRUE),
 ('MRN-3207', '3B', '3B-07', 'Orthopedics',      'Dr. Hannah Lindqvist', 'ORDERED',    current_date,     NULL,             NULL,                                                           TRUE,  'ORTHOPEDICS', 10, 14, FALSE),
 ('MRN-3211', '3B', '3B-11', 'Orthopedics',      'Dr. Hannah Lindqvist', 'PENDING',    NULL,             NULL,             NULL,                                                           FALSE, NULL,       NULL, NULL, FALSE);

INSERT INTO discharge_medications (discharge_id, medication_code, instructions, days_supply, indication)
SELECT x.discharge_id, v.code, v.instr, v.days, v.ind
  FROM (VALUES
   ('MRN-4012', 'MED-101', '1 tablet by mouth once daily',                                     30, 'coronary artery disease'),
   ('MRN-4012', 'MED-102', '1 tablet by mouth once daily; swallow whole, do not crush',        30, 'heart rate and blood pressure'),
   ('MRN-4012', 'MED-103', '1 tablet by mouth at bedtime',                                     30, 'cholesterol'),
   ('MRN-4015', 'MED-105', '1 tablet by mouth once daily at 5 PM; dose per INR result',        30, 'new atrial fibrillation (stroke prevention)'),
   ('MRN-4015', 'MED-102', '1 tablet by mouth once daily; swallow whole, do not crush',        30, 'heart rate control'),
   ('MRN-4015', 'MED-106', '1 capsule by mouth before breakfast',                              30, 'stomach protection'),
   ('MRN-4018', 'MED-104', '1 tablet by mouth once daily',                                     30, 'blood pressure'),
   ('MRN-4018', 'MED-110', '1 tablet by mouth every morning',                                  14, 'fluid control'),
   ('MRN-4021', 'MED-109', '1 capsule by mouth three times daily until finished',               7, 'pneumonia'),
   ('MRN-4021', 'MED-108', '1-2 tablets by mouth every 6 hours as needed; max 6 tablets a day', 10, 'pain or fever'),
   ('MRN-4009', 'MED-109', '1 capsule by mouth three times daily until finished',               7, 'skin infection'),
   ('MRN-3204', 'MED-107', '1 tablet by mouth every 6 hours as needed for severe pain',        10, 'pain after hip replacement'),
   ('MRN-3204', 'MED-108', '2 tablets by mouth every 8 hours',                                 14, 'pain after hip replacement'),
   ('MRN-3204', 'MED-112', '1 injection under the skin once daily',                            14, 'blood clot prevention after hip replacement'),
   ('MRN-3207', 'MED-108', '2 tablets by mouth every 8 hours as needed',                       14, 'pain after knee surgery'),
   ('MRN-3207', 'MED-104', '1 tablet by mouth once daily',                                     30, 'blood pressure'),
   ('MRN-3211', 'MED-108', '2 tablets by mouth every 8 hours as needed',                        7, 'pain')
  ) AS v (mrn, code, instr, days, ind)
  JOIN discharges x ON x.patient_id = v.mrn
 ORDER BY x.discharge_id, v.code;

-- ---------------------------------------------------------------------
-- Clinic slots (weekdays only) and existing appointments
-- John: echo on business day 7 at 09:30 -> "after the echo" means business day 8 or later.
-- ---------------------------------------------------------------------
INSERT INTO clinic_slots (slot_id, specialty_code, clinician, starts_at, location, wheelchair_accessible, transport_available, status) VALUES
 ('SLOT-C101', 'CARDIOLOGY',  'Dr. Alan Pierce',      add_business_days(current_date, 6)  + TIME '09:00', 'Heart Center, Main Campus',      TRUE,  TRUE,  'OPEN'),
 ('SLOT-C102', 'CARDIOLOGY',  'Dr. Grace Liu',        add_business_days(current_date, 6)  + TIME '14:30', 'Westside Cardiology Clinic',     FALSE, FALSE, 'OPEN'),
 ('SLOT-C103', 'CARDIOLOGY',  'Dr. Alan Pierce',      add_business_days(current_date, 8)  + TIME '08:30', 'Heart Center, Main Campus',      TRUE,  TRUE,  'OPEN'),
 ('SLOT-C104', 'CARDIOLOGY',  'Dr. Grace Liu',        add_business_days(current_date, 8)  + TIME '15:00', 'Westside Cardiology Clinic',     TRUE,  FALSE, 'OPEN'),
 ('SLOT-C105', 'CARDIOLOGY',  'Dr. Alan Pierce',      add_business_days(current_date, 8)  + TIME '13:30', 'Heart Center, Main Campus',      TRUE,  TRUE,  'OPEN'),
 ('SLOT-C106', 'CARDIOLOGY',  'Dr. Alan Pierce',      add_business_days(current_date, 9)  + TIME '16:00', 'Heart Center, Main Campus',      TRUE,  TRUE,  'OPEN'),
 ('SLOT-C107', 'CARDIOLOGY',  'Dr. Alan Pierce',      add_business_days(current_date, 10) + TIME '10:00', 'Heart Center, Main Campus',      TRUE,  TRUE,  'OPEN'),
 ('SLOT-C108', 'CARDIOLOGY',  'Dr. Alan Pierce',      add_business_days(current_date, 13) + TIME '14:00', 'Heart Center, Main Campus',      TRUE,  TRUE,  'OPEN'),   -- outside the window
 ('SLOT-C109', 'CARDIOLOGY',  'Dr. Alan Pierce',      add_business_days(current_date, 9)  + TIME '13:00', 'Heart Center, Main Campus',      TRUE,  TRUE,  'BOOKED'), -- taken
 ('SLOT-C110', 'CARDIOLOGY',  'Dr. Grace Liu',        add_business_days(current_date, 7)  + TIME '11:00', 'Westside Cardiology Clinic',     TRUE,  FALSE, 'BOOKED'), -- Robert's follow-up
 ('SLOT-A301', 'ANTICOAG',    'Leah Ortiz, NP',       add_business_days(current_date, 3)  + TIME '10:00', 'Anticoagulation Clinic, Main Campus', TRUE, TRUE, 'OPEN'),
 ('SLOT-A302', 'ANTICOAG',    'Leah Ortiz, NP',       add_business_days(current_date, 4)  + TIME '14:00', 'Anticoagulation Clinic, Main Campus', TRUE, TRUE, 'OPEN'),
 ('SLOT-O201', 'ORTHOPEDICS', 'Dr. Hannah Lindqvist', add_business_days(current_date, 8)  + TIME '13:00', 'Orthopedic Clinic, Main Campus', TRUE,  TRUE,  'OPEN'),
 ('SLOT-O202', 'ORTHOPEDICS', 'Dr. Hannah Lindqvist', add_business_days(current_date, 9)  + TIME '09:30', 'Orthopedic Clinic, Main Campus', TRUE,  TRUE,  'OPEN'),
 ('SLOT-G401', 'GENERAL',     'Dr. Elena Torres',     add_business_days(current_date, 6)  + TIME '10:00', 'Internal Medicine Clinic, Main Campus', TRUE, TRUE, 'OPEN');

INSERT INTO appointments (appointment_id, patient_id, appt_type, specialty_code, slot_id, starts_at, location, clinician, status, source) VALUES
 ('APT-0001', 'MRN-4012', 'Echocardiogram',  'CARDIOLOGY', NULL,        add_business_days(current_date, 7) + TIME '09:30', 'Heart Center, Main Campus',  'Echo Lab',      'SCHEDULED', 'SEED'),
 ('APT-0002', 'MRN-4018', 'Follow-up visit', 'CARDIOLOGY', 'SLOT-C110', add_business_days(current_date, 7) + TIME '11:00', 'Westside Cardiology Clinic', 'Dr. Grace Liu', 'SCHEDULED', 'SEED');

-- William's antibiotic was ordered and picked up yesterday.
INSERT INTO pharmacy_orders (order_id, dm_id, patient_id, medication_code, days_supply, pickup_location, ready_by, status, ordered_by, created_at)
SELECT 'RX-000011', dm.dm_id, 'MRN-4009', 'MED-109', 7, 'Bellmont Outpatient Pharmacy, Main Lobby', (current_date - 1) + TIME '14:40',
       'PICKED_UP', 'BMC-4101', (current_date - 1) + TIME '14:15'
  FROM discharge_medications dm JOIN discharges x ON x.discharge_id = dm.discharge_id
 WHERE x.patient_id = 'MRN-4009' AND dm.medication_code = 'MED-109';

-- ---------------------------------------------------------------------
-- Already-open cases, so every reviewer queue has work (one per team)
-- ---------------------------------------------------------------------
INSERT INTO service_cases (case_no, case_id, patient_id, ward_id, opened_by, request_type, summary, reference_id, requested_amount,
                           parked_action, agent_brief, sla_due_at, created_at)
SELECT 1, 'BMC-CASE-000001', 'MRN-3204', '3B', 'BMC-3201', 'high_alert_med',
       'High-alert medicine on the discharge list: Oxycodone 5 mg tablet, 1 tablet by mouth every 6 hours as needed for severe pain, 10 days '
       || '(indication: pain after hip replacement). Dispensing needs a pharmacist''s review.',
       'MED-107', 10, 'MED_ORDER:' || dm.dm_id, NULL, now()::timestamp + INTERVAL '1 hour', now()::timestamp - INTERVAL '1 hour'
  FROM discharge_medications dm JOIN discharges x ON x.discharge_id = dm.discharge_id
 WHERE x.patient_id = 'MRN-3204' AND dm.medication_code = 'MED-107';

INSERT INTO service_cases (case_no, case_id, patient_id, ward_id, opened_by, request_type, summary, reference_id, requested_amount,
                           parked_action, agent_brief, sla_due_at, created_at) VALUES
 (2, 'BMC-CASE-000002', 'MRN-3207', '3B', 'BMC-3201', 'bed_override',
  'Angela is in the discharge lounge waiting for her daughter to drive her home; her bed is needed for an admission from the emergency department.',
  '3B-07', NULL, 'BED_TURNOVER:3B-07', NULL, now()::timestamp + INTERVAL '30 minutes', now()::timestamp - INTERVAL '30 minutes'),
 (3, 'BMC-CASE-000003', 'MRN-4021', '4A', 'BMC-4101', 'discharge_decision',
  'Physical therapy cleared Dorothy this morning and her family asks whether she can go home today instead of tomorrow.',
  NULL, NULL, NULL, NULL, now()::timestamp + INTERVAL '3 hours', now()::timestamp - INTERVAL '1 hour');

DO $$ BEGIN PERFORM setval(pg_get_serial_sequence('service_cases', 'case_no'), 100); END $$;      -- cases opened in chat: BMC-CASE-000101, ...
