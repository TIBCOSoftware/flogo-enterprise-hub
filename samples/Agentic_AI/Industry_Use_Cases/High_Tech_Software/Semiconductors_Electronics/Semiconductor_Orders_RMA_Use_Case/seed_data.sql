-- Demo data for Arcwell Components - Semiconductor Orders & RMA (governed). Fictional distributor, customers, people
-- and part numbers (Arcwell house scheme AW-<family>-<nnnn>, generic JEDEC-style packages, 555-01xx phones,
-- example.com e-mail). Volatile dates are relative to CURRENT_DATE / now(), so the demo never goes stale.
-- Included by database.sql and reset_data.sql via \ir - do not load on its own.

-- ---------------------------------------------------------------------
-- Policy, routing
-- ---------------------------------------------------------------------
INSERT INTO order_policy (id, handling_days, ltb_review_value, rma_sla_safety, rma_sla_standard, max_credit_limit)
VALUES (1, 2, 10000, 1, 3, 1000000);

INSERT INTO case_routing (request_type, label, team, sla_business_days, sla_text, buyer_openable) VALUES
 ('rma_disposition',  'RMA disposition',     'Quality Engineering', 3, 'Our Quality Engineering team decides the disposition within 3 business days (1 business day when safety-relevant).', FALSE),
 ('last_time_buy',    'large last-time-buy', 'Sales & Pricing',     2, 'Our Sales & Pricing team replies within 2 business days.', TRUE),
 ('factory_expedite', 'factory expedite',    'Sales & Pricing',     2, 'Our Sales & Pricing team asks the factory and replies within 2 business days.', TRUE),
 ('special_pricing',  'special pricing',     'Sales & Pricing',     2, 'Our Sales & Pricing team replies with a pricing decision within 2 business days.', TRUE),
 ('credit_review',    'credit review',       'Credit',              2, 'Our Credit team replies within 2 business days.', TRUE);

-- ---------------------------------------------------------------------
-- Catalog: 17 parts in 10 families (Arcwell house part numbers)
-- ---------------------------------------------------------------------
INSERT INTO parts (part_number, family, description, key_specs, package, aec_grade, rohs, lifecycle, moq, warranty_months, ltb_date, replacement_part, datasheet_url) VALUES
 ('AW-MF-4012', 'MOSFET',         'N-channel power MOSFET, 40 V',              '40 V, 120 A, 2.1 mOhm RDS(on) at 10 V, logic-level gate',              'DFN 5x6',   'AEC-Q101', TRUE, 'ACTIVE',   100,  12, NULL, NULL, 'https://docs.arcwell.example.com/AW-MF-4012.pdf'),
 ('AW-MF-6508', 'MOSFET',         'N-channel power MOSFET, 650 V',             '650 V, 8 A, 0.42 Ohm RDS(on), avalanche rated',                        'TO-220',    NULL,       TRUE, 'ACTIVE',    50,  12, NULL, NULL, 'https://docs.arcwell.example.com/AW-MF-6508.pdf'),
 ('AW-MF-6515', 'MOSFET',         'N-channel power MOSFET, 650 V',             '650 V, 15 A, 0.19 Ohm RDS(on), avalanche rated',                       'TO-247',    NULL,       TRUE, 'ACTIVE',    50,  12, NULL, NULL, 'https://docs.arcwell.example.com/AW-MF-6515.pdf'),
 ('AW-MF-6008', 'MOSFET',         'N-channel power MOSFET, 600 V',             '600 V, 8 A, 0.45 Ohm RDS(on)',                                         'TO-220',    NULL,       TRUE, 'ACTIVE',    50,  12, NULL, NULL, 'https://docs.arcwell.example.com/AW-MF-6008.pdf'),
 ('AW-GD-0450', 'Gate driver',    'Isolated single-channel gate driver',       '4 A source / 6 A sink, 5 kV RMS isolation, 3.3 V / 5 V logic input',   'SOIC-16',   NULL,       TRUE, 'ACTIVE',   100,  12, NULL, NULL, 'https://docs.arcwell.example.com/AW-GD-0450.pdf'),
 ('AW-MC-3204', 'Microcontroller','32-bit microcontroller, 64 KB flash',       '48 MHz core, 64 KB flash, 16 KB RAM, 2x CAN, 12-bit ADC',              'QFN-32',    'AEC-Q100', TRUE, 'NRND',     250,  12, NULL, 'AW-MC-3208', 'https://docs.arcwell.example.com/AW-MC-3204.pdf'),
 ('AW-MC-3208', 'Microcontroller','32-bit microcontroller, 128 KB flash',      '64 MHz core, 128 KB flash, 32 KB RAM, 2x CAN FD, 12-bit ADC',          'QFN-32',    'AEC-Q100', TRUE, 'ACTIVE',   250,  12, NULL, NULL, 'https://docs.arcwell.example.com/AW-MC-3208.pdf'),
 ('AW-SD-2010', 'Schottky diode', 'Schottky barrier rectifier, 20 V 1 A',      '20 V, 1 A, 0.39 V forward voltage at 1 A',                             'SOD-123',   NULL,       TRUE, 'EOL',     3000,  12, current_date + 30, 'AW-SD-2011', 'https://docs.arcwell.example.com/AW-SD-2010.pdf'),
 ('AW-SD-2011', 'Schottky diode', 'Schottky barrier rectifier, 20 V 1 A',      '20 V, 1 A, 0.34 V forward voltage at 1 A',                             'SOD-123',   NULL,       TRUE, 'ACTIVE',  3000,  12, NULL, NULL, 'https://docs.arcwell.example.com/AW-SD-2011.pdf'),
 ('AW-SD-4030', 'Schottky diode', 'Schottky barrier rectifier, 40 V 3 A',      '40 V, 3 A, 0.50 V forward voltage at 3 A',                             'SMA',       NULL,       TRUE, 'EOL',     2500,  12, current_date - 5, 'AW-SD-4031', 'https://docs.arcwell.example.com/AW-SD-4030.pdf'),
 ('AW-SD-4031', 'Schottky diode', 'Schottky barrier rectifier, 40 V 3 A',      '40 V, 3 A, 0.45 V forward voltage at 3 A',                             'SMA',       NULL,       TRUE, 'ACTIVE',  2500,  12, NULL, NULL, 'https://docs.arcwell.example.com/AW-SD-4031.pdf'),
 ('AW-VR-3350', 'Voltage regulator','3.3 V 500 mA low-dropout regulator',      '3.3 V fixed output, 500 mA, 250 mV dropout, 2.5-16 V input',          'SOT-223',   'AEC-Q100', TRUE, 'ACTIVE',   500,  12, NULL, NULL, 'https://docs.arcwell.example.com/AW-VR-3350.pdf'),
 ('AW-CP-1040', 'Capacitor',      'MLCC capacitor 10 uF 25 V X7R',             '10 uF, 25 V, X7R dielectric, +/-10%',                                  '0805',      'AEC-Q200', TRUE, 'ACTIVE',  4000,  12, NULL, NULL, 'https://docs.arcwell.example.com/AW-CP-1040.pdf'),
 ('AW-TV-0524', 'TVS diode',      'TVS diode array, 5 V, 4 lines',             '5 V working voltage, 4 channels, 30 kV ESD contact rating',            'SOT-23-6',  'AEC-Q101', TRUE, 'ACTIVE',  3000,  12, NULL, NULL, 'https://docs.arcwell.example.com/AW-TV-0524.pdf'),
 ('AW-OP-2201', 'Op amp',         'Dual operational amplifier, rail-to-rail output', '36 V supply, 10 MHz gain-bandwidth, rail-to-rail output',         'SOIC-8',    NULL,       TRUE, 'ACTIVE',   100,  12, NULL, NULL, 'https://docs.arcwell.example.com/AW-OP-2201.pdf'),
 ('AW-LG-0208', 'Logic',          'Single 2-input AND gate',                   '1.65-5.5 V supply, 24 mA output drive',                                'SOT-23-5',  NULL,       TRUE, 'OBSOLETE', 3000,  12, NULL, 'AW-LG-0218', 'https://docs.arcwell.example.com/AW-LG-0208.pdf'),
 ('AW-LG-0218', 'Logic',          'Single 2-input AND gate, low power',        '1.65-5.5 V supply, 32 mA output drive, 1 uA standby',                  'SOT-23-5',  NULL,       TRUE, 'ACTIVE',  3000,  12, NULL, NULL, 'https://docs.arcwell.example.com/AW-LG-0218.pdf');

INSERT INTO price_breaks (part_number, min_qty, unit_price) VALUES
 ('AW-MF-4012', 1, 1.42), ('AW-MF-4012', 100, 1.18), ('AW-MF-4012', 1000, 0.96), ('AW-MF-4012', 5000, 0.81), ('AW-MF-4012', 25000, 0.72),
 ('AW-MF-6508', 1, 2.10), ('AW-MF-6508', 100, 1.74), ('AW-MF-6508', 1000, 1.36), ('AW-MF-6508', 5000, 1.19),
 ('AW-MF-6515', 1, 3.85), ('AW-MF-6515', 100, 3.20), ('AW-MF-6515', 1000, 2.65),
 ('AW-MF-6008', 1, 1.98), ('AW-MF-6008', 100, 1.62), ('AW-MF-6008', 1000, 1.29),
 ('AW-GD-0450', 1, 3.95), ('AW-GD-0450', 100, 3.40), ('AW-GD-0450', 1000, 2.85), ('AW-GD-0450', 5000, 2.49),
 ('AW-MC-3204', 1, 2.95), ('AW-MC-3204', 250, 2.40), ('AW-MC-3204', 1000, 2.05), ('AW-MC-3204', 5000, 1.82),
 ('AW-MC-3208', 1, 3.40), ('AW-MC-3208', 250, 2.80), ('AW-MC-3208', 1000, 2.38), ('AW-MC-3208', 5000, 2.15),
 ('AW-SD-2010', 3000, 0.15), ('AW-SD-2010', 30000, 0.13), ('AW-SD-2010', 100000, 0.12),
 ('AW-SD-2011', 3000, 0.16), ('AW-SD-2011', 30000, 0.14), ('AW-SD-2011', 100000, 0.125),
 ('AW-SD-4030', 2500, 0.21), ('AW-SD-4030', 25000, 0.18),
 ('AW-SD-4031', 2500, 0.23), ('AW-SD-4031', 25000, 0.19),
 ('AW-VR-3350', 1, 0.74), ('AW-VR-3350', 500, 0.58), ('AW-VR-3350', 5000, 0.46),
 ('AW-CP-1040', 4000, 0.032), ('AW-CP-1040', 40000, 0.026), ('AW-CP-1040', 200000, 0.021),
 ('AW-TV-0524', 3000, 0.09), ('AW-TV-0524', 30000, 0.072),
 ('AW-OP-2201', 1, 0.88), ('AW-OP-2201', 100, 0.69), ('AW-OP-2201', 2500, 0.52),
 ('AW-LG-0208', 3000, 0.045),
 ('AW-LG-0218', 3000, 0.052), ('AW-LG-0218', 30000, 0.041);

INSERT INTO inventory (part_number, warehouse, qty_available, lead_time_weeks, next_receipt_date, next_receipt_qty) VALUES
 ('AW-MF-4012', 'Arcwell DC, Columbus OH', 180000, 10, NULL, NULL),
 ('AW-MF-6508', 'Arcwell DC, Columbus OH',  42000, 14, NULL, NULL),
 ('AW-MF-6515', 'Arcwell DC, Columbus OH',   9500, 16, current_date + 21, 5000),
 ('AW-MF-6008', 'Arcwell DC, Columbus OH',  30000, 12, NULL, NULL),
 ('AW-GD-0450', 'Arcwell DC, Columbus OH',  26000, 12, NULL, NULL),
 ('AW-MC-3204', 'Arcwell DC, Columbus OH',      0,  8, current_date + 30, 4000),
 ('AW-MC-3208', 'Arcwell DC, Columbus OH',  12000, 10, NULL, NULL),
 ('AW-SD-2010', 'Arcwell DC, Columbus OH', 400000, 52, NULL, NULL),
 ('AW-SD-2011', 'Arcwell DC, Columbus OH', 600000,  6, NULL, NULL),
 ('AW-SD-4030', 'Arcwell DC, Columbus OH',  15000, 52, NULL, NULL),
 ('AW-SD-4031', 'Arcwell DC, Columbus OH', 220000,  6, NULL, NULL),
 ('AW-VR-3350', 'Arcwell DC, Columbus OH',  95000,  8, NULL, NULL),
 ('AW-CP-1040', 'Arcwell DC, Columbus OH', 2400000, 16, NULL, NULL),
 ('AW-TV-0524', 'Arcwell DC, Columbus OH', 150000,  8, NULL, NULL),
 ('AW-OP-2201', 'Arcwell DC, Columbus OH',  60000,  9, NULL, NULL),
 ('AW-LG-0208', 'Arcwell DC, Columbus OH',      0, 52, NULL, NULL),
 ('AW-LG-0218', 'Arcwell DC, Columbus OH', 300000,  6, NULL, NULL);

INSERT INTO cross_references (part_number, alt_part, relation, notes) VALUES
 ('AW-SD-2010', 'AW-SD-2011', 'DROP_IN_REPLACEMENT',   'Same SOD-123 footprint and pinout; lower forward voltage. Recommended replacement in the end-of-life notice.'),
 ('AW-SD-4030', 'AW-SD-4031', 'DROP_IN_REPLACEMENT',   'Same SMA footprint and pinout; lower forward voltage.'),
 ('AW-MC-3204', 'AW-MC-3208', 'PIN_COMPATIBLE',        'Same QFN-32 pinout with more flash and RAM; firmware must be rebuilt for the new device.'),
 ('AW-MF-6508', 'AW-MF-6515', 'HIGHER_RATED',          '15 A and lower RDS(on); TO-247 needs a different footprint and heatsink mounting.'),
 ('AW-MF-6508', 'AW-MF-6008', 'FUNCTIONAL_EQUIVALENT', 'Same TO-220 footprint; rated 600 V instead of 650 V - confirm the voltage margin in your design.'),
 ('AW-LG-0208', 'AW-LG-0218', 'DROP_IN_REPLACEMENT',   'Same SOT-23-5 pinout; lower standby current.');

INSERT INTO pcn_notices (pcn_id, part_number, notice_type, title, description, published_date, effective_date, ltb_date, replacement_part) VALUES
 ('PCN-2026-0007', 'AW-MC-3204', 'PCN', 'Assembly site transfer and mold compound change: AW-MC-3204',
  'Assembly and final test of AW-MC-3204 move from the current subcontract site to a second qualified site, and the mold compound changes to a halogen-free equivalent. Form, fit and function are unchanged and the moisture sensitivity level stays MSL 3. Parts built at the new site carry date codes from the effective date onward and may ship mixed with old-site parts for up to 8 weeks. A qualification report is available on request, and customers may request samples during the 90-day review window. Customers who need old-site parts only should contact Arcwell before the effective date.',
  current_date - 20, current_date + 70, NULL, NULL),
 ('PCN-2026-0004', 'AW-SD-2010', 'EOL', 'End of life: AW-SD-2010 Schottky rectifier',
  'AW-SD-2010 (20 V 1 A, SOD-123) is being discontinued. Last-time-buy orders are accepted until the last-time-buy date; last shipments are scheduled within 6 months after it. Last-time-buy orders are non-cancellable and non-returnable. The recommended replacement AW-SD-2011 is a drop-in part with a lower forward voltage.',
  current_date - 120, current_date + 30, current_date + 30, 'AW-SD-2011'),
 ('PCN-2026-0002', 'AW-SD-4030', 'EOL', 'End of life: AW-SD-4030 Schottky rectifier',
  'AW-SD-4030 (40 V 3 A, SMA) is discontinued. The last-time-buy window has closed. The recommended replacement AW-SD-4031 is a drop-in part.',
  current_date - 200, current_date - 5, current_date - 5, 'AW-SD-4031');

-- ---------------------------------------------------------------------
-- Customer accounts + buyers (login: account + buyer e-mail + one-time code) and reviewers (staff ID + code)
-- ---------------------------------------------------------------------
INSERT INTO accounts (account_id, company, industry, city, state, payment_terms, credit_limit, open_balance, credit_hold, hold_reason, customer_since) VALUES
 ('AC-10021', 'Northfield Power Systems', 'Solar inverters and energy storage', 'Dayton',      'OH', 'Net 30', 250000, 38500, FALSE, NULL, '2019-04-01'),
 ('AC-10034', 'Bluegate Medical Devices', 'Medical devices',                    'Minneapolis', 'MN', 'Net 30',  60000, 58200, TRUE,
  'Invoice INV-55120 is 47 days past due', '2021-09-15'),
 ('AC-10047', 'Pinecrest Automation',     'Industrial automation',              'Greenville',  'SC', 'Net 45', 120000, 61000, FALSE, NULL, '2017-02-10'),
 ('AC-10058', 'Redline Motor Controls',   'Motor drives and EV chargers',       'Fort Worth',  'TX', 'Net 30',  40000, 12750, FALSE, NULL, '2022-06-01');

INSERT INTO buyers (buyer_id, account_id, first_name, last_name, email, otp_code, job_title, active) VALUES
 ('B-2101', 'AC-10021', 'Tessa',  'Brandt',  'tessa.brandt@northfieldpower.example.com', '4827', 'Senior Buyer',        TRUE),
 ('B-2102', 'AC-10021', 'Caleb',  'Monroe',  'caleb.monroe@northfieldpower.example.com', '1950', 'Component Engineer',  TRUE),
 ('B-3401', 'AC-10034', 'Luis',   'Romero',  'luis.romero@bluegatemed.example.com',      '6153', 'Purchasing Manager',  TRUE),
 ('B-4701', 'AC-10047', 'Hannah', 'Cole',    'hannah.cole@pinecrestauto.example.com',    '3390', 'Buyer',               TRUE),
 ('B-5801', 'AC-10058', 'Omar',   'Haddad',  'omar.haddad@redlinemotor.example.com',     '7712', 'Supply Chain Lead',   TRUE);

INSERT INTO reviewers (reviewer_id, display_name, team, one_time_code, approval_limit, active) VALUES
 ('ACS-5101', 'Rosa Delgado',     'Quality Engineering', '3141', 25000, TRUE),
 ('ACS-5202', 'Kenji Watanabe',   'Sales & Pricing',     '2718', 50000, TRUE),
 ('ACS-5303', 'Abigail Turner',   'Credit',              '1618', 75000, TRUE),
 ('ACS-5304', 'Victor Lindqvist', 'Credit',              '5772', NULL,  TRUE);

-- ---------------------------------------------------------------------
-- Orders and lines
-- ---------------------------------------------------------------------
INSERT INTO sales_orders (order_number, account_id, buyer_id, po_number, order_date, source) VALUES
 ('SO-2026-0006', 'AC-10047', 'B-4701', 'PA-43990',    current_date - 120, 'SEED'),
 ('SO-2026-0009', 'AC-10021', 'B-2101', 'NPS-PO-6120', current_date - 430, 'SEED'),
 ('SO-2026-0010', 'AC-10034', 'B-3401', 'BMD-2231',    current_date - 60,  'SEED'),
 ('SO-2026-0011', 'AC-10021', 'B-2101', 'NPS-PO-7442', current_date - 70,  'SEED'),
 ('SO-2026-0012', 'AC-10047', 'B-4701', 'PA-44817',    current_date - 25,  'SEED'),
 ('SO-2026-0013', 'AC-10058', 'B-5801', 'RMC-1187',    current_date - 15,  'SEED'),
 ('SO-2026-0014', 'AC-10021', 'B-2101', 'NPS-PO-7905', current_date - 10,  'SEED');

INSERT INTO order_lines (order_number, line_no, part_number, quantity, unit_price, requested_date, promised_date, shipped_qty, shipped_date) VALUES
 ('SO-2026-0006', 1, 'AW-VR-3350',  2000, 0.58, current_date - 112, current_date - 110, 2000, current_date - 110),
 ('SO-2026-0009', 1, 'AW-VR-3350',  1000, 0.58, current_date - 425, current_date - 425, 1000, current_date - 425),
 ('SO-2026-0010', 1, 'AW-OP-2201',  5000, 0.52, current_date - 50,  current_date - 50,  5000, current_date - 50),
 ('SO-2026-0011', 1, 'AW-MF-6508',  2000, 1.36, current_date - 62,  current_date - 62,  2000, current_date - 62),
 ('SO-2026-0011', 2, 'AW-GD-0450',  2000, 2.85, current_date - 62,  current_date - 62,  2000, current_date - 62),
 ('SO-2026-0012', 1, 'AW-MC-3204',  2500, 2.05, current_date + 40,  current_date + 40,     0, NULL),
 ('SO-2026-0012', 2, 'AW-SD-2010', 30000, 0.13, current_date + 5,   current_date + 5,      0, NULL),
 ('SO-2026-0013', 1, 'AW-MF-4012', 10000, 0.81, current_date + 3,   current_date + 3,      0, NULL),
 ('SO-2026-0014', 1, 'AW-GD-0450',  1000, 2.85, current_date + 14,  current_date + 21,     0, NULL),
 ('SO-2026-0014', 2, 'AW-MC-3204',   500, 2.40, current_date + 14,  current_date + 45,     0, NULL);

-- ---------------------------------------------------------------------
-- RMAs, credit memos, alert subscriptions
-- ---------------------------------------------------------------------
INSERT INTO rmas (rma_id, account_id, order_number, line_id, part_number, quantity, unit_price, defect_type, safety_relevant, description,
                  status, credit_amount, opened_date, decided_at, source) VALUES
 ('RMA-2026-0002', 'AC-10034', 'SO-2026-0010', (SELECT line_id FROM order_lines WHERE order_number = 'SO-2026-0010' AND line_no = 1),
  'AW-OP-2201', 100, 0.52, 'MECHANICAL_DAMAGE', FALSE, 'One reel arrived crushed; about 100 parts have bent leads.',
  'APPROVED', 52.00, current_date - 45, now() - INTERVAL '43 days', 'SEED'),
 ('RMA-2026-0003', 'AC-10047', 'SO-2026-0006', (SELECT line_id FROM order_lines WHERE order_number = 'SO-2026-0006' AND line_no = 1),
  'AW-VR-3350', 200, 0.58, 'PARAMETRIC_DRIFT', FALSE, 'About 200 regulators oscillate at the output on our new controller board; the old board revision is fine.',
  'UNDER_REVIEW', NULL, current_date - 1, NULL, 'SEED');

INSERT INTO credit_memos (memo_id, reference, rma_id, account_id, amount, case_id, created_at) VALUES
 (1, 'CM-000001', 'RMA-2026-0002', 'AC-10034', 52.00, NULL, now() - INTERVAL '43 days');

INSERT INTO pcn_subscriptions (account_id, buyer_id, part_number, created_at) VALUES
 ('AC-10047', 'B-4701', 'AW-SD-2010', now() - INTERVAL '100 days');

-- ---------------------------------------------------------------------
-- Already-OPEN cases so every reviewer queue has something in it
-- ---------------------------------------------------------------------
INSERT INTO service_cases (case_no, case_id, account_id, buyer_id, request_type, summary, reference_id, part_number, quantity, unit_price,
                           line_id, requested_amount, parked_action, agent_brief, priority, status, sla_due_at, created_at) VALUES
 (1, 'ARC-CASE-000001', 'AC-10047', 'B-4701', 'rma_disposition',
  'About 200 regulators oscillate at the output on our new controller board; the old board revision is fine.', 'RMA-2026-0003',
  'AW-VR-3350', 200, 0.58, (SELECT line_id FROM order_lines WHERE order_number = 'SO-2026-0006' AND line_no = 1), 116.00,
  'RMA_CREDIT:RMA-2026-0003',
  'RMA triage (AI-prepared, not verified): defect type PARAMETRIC_DRIFT; safety-relevant: no. Oscillation appeared only after a board change, which points to the application (output capacitor type or ESR) rather than the parts; ask for the new board''s output capacitor value and type, and test returned units on the reference circuit.',
  'NORMAL', 'OPEN', add_business_days_ts((now() - INTERVAL '1 day')::timestamp, 3), now() - INTERVAL '1 day'),
 (2, 'ARC-CASE-000002', 'AC-10047', 'B-4701', 'special_pricing',
  'Asks for a price match at $2.10 for 10,000 pieces a year of AW-MC-3208 to replace AW-MC-3204 in a new controller.', 'AW-MC-3208',
  'AW-MC-3208', NULL, NULL, NULL, NULL, NULL, NULL,
  'NORMAL', 'OPEN', add_business_days_ts((now() - INTERVAL '2 days')::timestamp, 2), now() - INTERVAL '2 days');

INSERT INTO service_cases (case_no, case_id, account_id, buyer_id, request_type, summary, reference_id, requested_amount, parked_action,
                           priority, status, sla_due_at, created_at) VALUES
 (3, 'ARC-CASE-000003', 'AC-10058', 'B-5801', 'credit_review',
  'Asks to raise the credit limit from $40,000 to $90,000 for a new EV-charger program starting next quarter.', 'AC-10058', 90000,
  'CREDIT_LIMIT:AC-10058', 'NORMAL', 'OPEN', add_business_days_ts((now() - INTERVAL '1 day')::timestamp, 2), now() - INTERVAL '1 day');

-- New ids continue from 101 so demo-created rows stand out.
DO $$
BEGIN
  PERFORM setval(pg_get_serial_sequence('service_cases', 'case_no'), 100);
  PERFORM setval(pg_get_serial_sequence('credit_memos', 'memo_id'), 100);
  PERFORM setval(pg_get_serial_sequence('credit_changes', 'change_id'), 100);
  PERFORM setval(pg_get_serial_sequence('account_events', 'event_id'), 100);
  PERFORM setval(pg_get_serial_sequence('expedite_events', 'event_id'), 100);
  PERFORM setval('so_seq', 100);
  PERFORM setval('rma_seq', 100);
END $$;

-- ---------------------------------------------------------------------
-- Agent reference tables (read-only for the A2A agents via ref_* functions; no customer, staff or case data)
-- ---------------------------------------------------------------------
-- part_finder_agent -> ref_part_selection()  (+ the REPLACEMENT rows from parts + cross_references)
INSERT INTO part_selection_guide (section, term, meaning) VALUES
 ('ABBREVIATION', 'N-ch / NMOS / P-ch',        'N-channel MOSFET; P-ch = P-channel MOSFET (a different kind of part)'),
 ('ABBREVIATION', 'Vds / V(BR)DSS / Id',       'Vds or V(BR)DSS = drain-source voltage rating; Id = continuous drain current rating'),
 ('ABBREVIATION', 'Rds(on) / Vf',              'Rds(on) = on-resistance; Vf = forward voltage of a diode; lower is better for both'),
 ('ABBREVIATION', 'SBD / LDO / MLCC / TVS / MCU', 'SBD or Schottky = Schottky barrier diode; LDO = low-dropout regulator; MLCC = multilayer ceramic capacitor; TVS = transient voltage suppressor; MCU = microcontroller'),
 ('ABBREVIATION', 'PV / EV',                   'PV or solar boost = photovoltaic inverter boost stage; EV = electric vehicle'),
 ('COLUMN',       'lifecycle',                 'ACTIVE = recommended for new designs; NRND = not recommended for new designs (still orderable); EOL = end of life, orderable only until its last-time-buy date (ltb_date); OBSOLETE = not orderable'),
 ('COLUMN',       'aec_grade',                 'AEC-Q100 (ICs), AEC-Q101 (discretes) or AEC-Q200 (passives) = automotive qualified; empty = commercial / industrial, not automotive qualified'),
 ('PACKAGE',      'outline names',             'package names are generic JEDEC-style outlines; a different package means a different PCB footprint, so it is not a drop-in'),
 ('PACKAGE',      'TO-220 / TO-247',           'through-hole power packages; TO-247 is larger and needs a different footprint and heatsink mounting than TO-220'),
 ('PACKAGE',      'DFN 5x6 / QFN-32 / SOT-223', 'surface-mount packages with an exposed pad or tab that carries heat into the board'),
 ('PACKAGE',      'SOD-123 / SMA / SOT-23 / SOIC / 0805', 'small surface-mount outlines: SOD-123 and SMA for diodes (SMA is larger), SOT-23-5/-6 and SOIC-8/-16 for ICs, 0805 = a 0.08 x 0.05 inch chip for passives'),
 ('RANKING',      '1 ratings',                 'never rank a part whose voltage or current rating is below the BOM line''s; a higher rating than needed is allowed but say it is higher'),
 ('RANKING',      '2 footprint',               'prefer the same package (drop-in) over a different footprint, and say plainly when a ranked part has a different package'),
 ('RANKING',      '3 lifecycle',               'prefer ACTIVE over NRND; for an EOL, NRND or obsolete BOM part, put Arcwell''s recommended replacement (REPLACEMENT rows) first when it is among the candidates'),
 ('RANKING',      '4 automotive',              'automotive applications need an AEC grade; if none of the candidates has one, say so'),
 ('RANKING',      '5 stock',                   'prefer parts with stock (qty_available above 0)'),
 ('EXCLUDE',      'RATING_BELOW',              'a voltage or current rating is below what the BOM line states'),
 ('EXCLUDE',      'OBSOLETE',                  'the part is obsolete and cannot be ordered'),
 ('EXCLUDE',      'PAST_LTB',                  'the part is end of life and its last-time-buy date has passed'),
 ('EXCLUDE',      'NOT_AUTOMOTIVE',            'automotive application, but the part has no AEC grade'),
 ('EXCLUDE',      'WRONG_FUNCTION',            'a different kind of part from the BOM line (for example P-channel for an N-channel line)'),
 ('NOTE_LINE',    'STANDARD',                  'Matches the stated ratings only - your engineers must confirm the part for your design.'),
 ('NOTE_LINE',    'AUTOMOTIVE',                'Matches the stated ratings only - for automotive use your engineers and quality team must confirm the part and its AEC qualification.'),
 ('NOTE_LINE',    'NO_MATCH',                  'No catalog part matches the stated ratings - Arcwell''s sales team can help look further.');

-- rma_triage_agent -> ref_defect_taxonomy()  (+ the ROUTING row from case_routing)
INSERT INTO defect_taxonomy (section, term, meaning) VALUES
 ('DEFECT_TYPE',  'ELECTRICAL_FAILURE',        'the part is dead, shorted or open (for example gate shorted, blew up, no output, fails after some weeks in the field)'),
 ('DEFECT_TYPE',  'PARAMETRIC_DRIFT',          'the part works but a parameter is out of specification or unstable (oscillation, leakage, voltage or timing drift, runs hot)'),
 ('DEFECT_TYPE',  'MECHANICAL_DAMAGE',         'physical damage: cracked body, bent leads, crushed reel or damaged packaging'),
 ('DEFECT_TYPE',  'SOLDERABILITY',             'poor wetting: leads or pads will not solder, oxidised terminations'),
 ('DEFECT_TYPE',  'WRONG_PART',                'wrong part number, marking or quantity received, or a mislabeled reel'),
 ('DEFECT_TYPE',  'OTHER',                     'anything that fits none of the other types'),
 ('SAFETY_SIGN',  'heat, smoke or fire',       'overheating, smoke, scorching, burning or fire at the part or the board: safety-relevant YES'),
 ('SAFETY_SIGN',  'arcing or power-path short', 'arcing, or a failure that is a short circuit in a power path (for example a shorted MOSFET or diode in a power stage): YES'),
 ('SAFETY_SIGN',  'mains or high-voltage equipment', 'the part sits in mains or high-voltage equipment - solar / PV inverters, EV chargers, motor drives, power supplies: YES'),
 ('SAFETY_SIGN',  'medical device',            'the part is used in a medical device: YES'),
 ('SAFETY_SIGN',  'automotive safety system',  'the part is used in an automotive safety system (braking, steering, airbag, battery management): YES'),
 ('SAFETY_SIGN',  'none of these',             'no sign above (for example a wrong label, or bent leads in a low-voltage product): NO. When unsure say YES and explain - Quality Engineering decides'),
 ('EVIDENCE',     'ELECTRICAL_FAILURE',        'how many failed out of how many installed; date codes or lot numbers from the reel label; operating voltage, current and temperature at failure; photos of the failed parts and the board; up to 5 failed units returned in ESD-safe packaging for failure analysis (FA)'),
 ('EVIDENCE',     'PARAMETRIC_DRIFT',          'which parameter is out of specification, with measured and expected values; how many units drift; date codes or lot numbers; test conditions (voltage, temperature, load); up to 5 affected units returned in ESD-safe packaging for failure analysis (FA)'),
 ('EVIDENCE',     'MECHANICAL_DAMAGE',         'photos of the damage and of the box, reel and labels as received; how many units are damaged; whether it was found at receiving or at assembly; the carrier delivery note if the box was damaged'),
 ('EVIDENCE',     'SOLDERABILITY',             'photos or X-ray images of the joints; the reflow profile and solder paste used; how long the parts were out of their dry pack; date codes or lot numbers; 10 unused parts from the same reel for a solderability test'),
 ('EVIDENCE',     'WRONG_PART',                'photos of the part marking and the reel label; the part number ordered and the marking received; how many units are affected; keep the parts unused in their original packaging'),
 ('EVIDENCE',     'OTHER',                     'what was expected and what happened; how many units are affected; date codes or lot numbers; photos if possible'),
 ('RULE',         'classify only',             'choose exactly one defect type; never state a root cause as fact, never blame the customer or the part, and never suggest a credit, replacement or disposition'),
 ('RULE',         'failure plus damage',       'when a part no longer works and is also physically damaged, choose ELECTRICAL_FAILURE and mention the damage in the rationale');

-- pcn_impact_agent -> ref_pcn_guide()
INSERT INTO pcn_change_guide (section, term, meaning) VALUES
 ('NOTICE_TYPE',  'PCN',                       'product change notice: the part keeps its part number but something about how it is made changes'),
 ('NOTICE_TYPE',  'EOL',                       'end-of-life notice: the part is being discontinued; last-time-buy orders are non-cancellable and non-returnable'),
 ('CHANGE_TYPE',  'assembly site transfer',    'the part is packaged and tested in a different factory. Buyer checks: whether their own customers must be told of a site change; the qualification report; samples from the new site during the review window'),
 ('CHANGE_TYPE',  'mold compound change',      'the plastic body material changes. Buyer checks: that the MSL and their reflow profile stay the same; the qualification report; samples for their own qualification'),
 ('CHANGE_TYPE',  'wafer fab or die change',   'the silicon is made in another fab or the die is revised. Buyer checks: the datasheet for any changed parameter; the qualification report; samples to re-test in their product'),
 ('CHANGE_TYPE',  'datasheet or marking change', 'only the documents or the printed marking change. Buyer checks: incoming-inspection records and drawings that show the marking'),
 ('CHANGE_TYPE',  'packing or label change',   'the reel, tray or label format changes. Buyer checks: pick-and-place feeder setup and receiving label scanning'),
 ('CHANGE_TYPE',  'discontinuation',           'the part will no longer be made (EOL). Buyer checks: how many parts they need until a replacement is qualified; whether to place a last-time-buy before the last-time-buy date; the replacement part''s datasheet and samples'),
 ('TERM',         'effective date',            'from this date parts may be built the new way (PCN) or the part is no longer made (EOL)'),
 ('TERM',         'last-time-buy (LTB) date',  'the last day an order is accepted for an EOL part'),
 ('TERM',         'form, fit and function unchanged', 'same size, same pins and same electrical behaviour in the datasheet'),
 ('TERM',         'MSL',                       'moisture sensitivity level: how long parts may sit out of their dry pack before soldering; an unchanged MSL means handling stays the same'),
 ('TERM',         'date code',                 'the build week printed on the part; mixed date codes means a shipment can contain both old and new parts'),
 ('TERM',         'qualification report / review window', 'the test data proving the change / the time to ask for samples or object before the change applies'),
 ('LINE_STATUS',  'BEFORE_CHANGE',             'ships before the effective date - built the current way'),
 ('LINE_STATUS',  'MAY_BE_MIXED',              'ships on or after the effective date - may contain changed parts (mixed date codes possible)'),
 ('LINE_STATUS',  'AFTER_LTB',                 'EOL part promised after the last-time-buy date - an accepted order still ships; ask Arcwell to confirm the date'),
 ('RULE',         'compare dates',             'compare each promised date with the effective date; a line promised on the effective date counts as on or after'),
 ('RULE',         'what buyers check',         'which open lines ship after the effective date, whether their own customer needs to be told, whether they need samples or the qualification report, and for EOL whether to place a last-time-buy or move to the replacement part'),
 ('RULE',         'inform only',               'never recommend placing an order, cancelling or qualifying a part, and never say the change is safe for a design - list what the buyer may want to check');
