-- Telecom Invoice Chatbot — Reset Demo Data
-- Run this to reset all tables to a clean demo state.
-- Restores disputes/recharges to their seeded state (undoes agent writes) and
-- refreshes due dates, payment dates, and dispute timestamps relative to today.
-- PostgreSQL 14+

-- Clear all data (reverse dependency order)
TRUNCATE recharges, disputes, recharge_offers, payments, plans, usage_records,
         invoice_line_items, invoices, customers RESTART IDENTITY CASCADE;

-- Customers
INSERT INTO customers (customer_id, mobile_number, first_name, last_name, email, segment, account_type, status, active_since) VALUES
('CUST-10042871', '+971-50-123-4567', 'Ahmed',    'Al Rashid', 'ahmed.alrashid@email.ae', 'Premium',  'Postpaid', 'Active', '2019-03-15'),
('CUST-10042872', '+971-50-234-5678', 'Fatima',   'Al Zaabi',  'fatima.alzaabi@email.ae', 'Consumer', 'Postpaid', 'Active', '2021-07-22'),
('CUST-10042873', '+971-55-345-6789', 'Mohammed', 'Hassan',    'mohammed.hassan@email.ae','Consumer', 'Postpaid', 'Active', '2020-11-05'),
('CUST-10042874', '+971-56-456-7890', 'Sara',     'Abdullah',  'sara.abdullah@email.ae',  'Consumer', 'Prepaid',  'Active', '2022-02-18'),
('CUST-10042875', '+971-52-567-8901', 'Omar',     'Khalil',    'omar.khalil@email.ae',    'Business', 'Postpaid', 'Active', '2018-06-30'),
('CUST-10042876', '+971-50-678-9012', 'Layla',    'Ibrahim',   'layla.ibrahim@email.ae',  'VIP',      'Postpaid', 'Active', '2017-09-12'),
('CUST-10042877', '+971-54-789-0123', 'Yusuf',    'Ahmed',     'yusuf.ahmed@email.ae',    'Consumer', 'Prepaid',  'Active', '2023-01-25'),
('CUST-10042878', '+971-58-890-1234', 'Noura',    'Saeed',     'noura.saeed@email.ae',    'Premium',  'Postpaid', 'Active', '2019-12-08');

-- Invoices (due dates relative to today for a live demo)
INSERT INTO invoices (invoice_id, customer_id, billing_month, period_start, period_end, subtotal, tax, total_amount, currency, due_date, status) VALUES
('INV-2026-06-871', 'CUST-10042871', 'June 2026', '2026-06-01', '2026-06-30', 487.50,  0.00, 487.50, 'AED', CURRENT_DATE + INTERVAL '7 days', 'Unpaid'),
('INV-2026-06-872', 'CUST-10042872', 'June 2026', '2026-06-01', '2026-06-30', 269.00, 13.45, 282.45, 'AED', CURRENT_DATE + INTERVAL '7 days', 'Unpaid'),
('INV-2026-06-873', 'CUST-10042873', 'June 2026', '2026-06-01', '2026-06-30', 128.00,  6.40, 134.40, 'AED', CURRENT_DATE + INTERVAL '7 days', 'Unpaid'),
('INV-2026-06-875', 'CUST-10042875', 'June 2026', '2026-06-01', '2026-06-30', 743.00, 37.15, 780.15, 'AED', CURRENT_DATE + INTERVAL '7 days', 'Unpaid'),
('INV-2026-06-876', 'CUST-10042876', 'June 2026', '2026-06-01', '2026-06-30', 1009.00,50.45, 1059.45,'AED', CURRENT_DATE + INTERVAL '7 days', 'Unpaid'),
('INV-2026-06-878', 'CUST-10042878', 'June 2026', '2026-06-01', '2026-06-30', 299.00, 14.95, 313.95, 'AED', CURRENT_DATE + INTERVAL '7 days', 'Unpaid');

-- Invoice Line Items
INSERT INTO invoice_line_items (invoice_id, customer_id, category, description, amount) VALUES
('INV-2026-06-871', 'CUST-10042871', 'PLAN',    'Postpaid Plan Premium 500 (monthly)',       299.00),
('INV-2026-06-871', 'CUST-10042871', 'IDD',     'International Calls (India)',                 85.00),
('INV-2026-06-871', 'CUST-10042871', 'ADDON',   'Data Add-on 10GB',                           49.00),
('INV-2026-06-871', 'CUST-10042871', 'ROAMING', 'Roaming Saudi Arabia (3 days)',              54.50),
('INV-2026-06-872', 'CUST-10042872', 'PLAN',    'Postpaid Plan Value 200 (monthly)',         149.00),
('INV-2026-06-872', 'CUST-10042872', 'ROAMING', 'Roaming Europe (5 days)',                    120.00),
('INV-2026-06-872', 'CUST-10042872', 'TAX',     'VAT 5%',                                      13.45),
('INV-2026-06-873', 'CUST-10042873', 'PLAN',    'Postpaid Plan Smart 100 (monthly)',          99.00),
('INV-2026-06-873', 'CUST-10042873', 'ADDON',   'Data Add-on 5GB',                            29.00),
('INV-2026-06-873', 'CUST-10042873', 'TAX',     'VAT 5%',                                       6.40),
('INV-2026-06-875', 'CUST-10042875', 'PLAN',    'Business Unlimited Pro (monthly)',          499.00),
('INV-2026-06-875', 'CUST-10042875', 'ADDON',   'IDD Global Pack',                            99.00),
('INV-2026-06-875', 'CUST-10042875', 'IDD',     'International Calls (UK / US)',              145.00),
('INV-2026-06-875', 'CUST-10042875', 'TAX',     'VAT 5%',                                      37.15),
('INV-2026-06-876', 'CUST-10042876', 'PLAN',    'VIP Platinum Unlimited (monthly)',          799.00),
('INV-2026-06-876', 'CUST-10042876', 'ROAMING', 'Roaming USA (7 days)',                       210.00),
('INV-2026-06-876', 'CUST-10042876', 'TAX',     'VAT 5%',                                      50.45),
('INV-2026-06-878', 'CUST-10042878', 'PLAN',    'Postpaid Plan Premium 500 (monthly)',       299.00),
('INV-2026-06-878', 'CUST-10042878', 'TAX',     'VAT 5%',                                      14.95);

-- Usage Records
INSERT INTO usage_records (customer_id, billing_period, data_used_gb, data_limit_gb, local_call_minutes, intl_call_minutes, sms_count, roaming_days, roaming_country) VALUES
('CUST-10042871', 'June 2026', 38.70, 50.00, 342, 47,  12, 3, 'Saudi Arabia'),
('CUST-10042872', 'June 2026', 12.30, 20.00, 210,  0,   8, 0, NULL),
('CUST-10042873', 'June 2026', 14.80, 15.00,  88,  0,   3, 0, NULL),
('CUST-10042874', 'June 2026',  5.20,  8.00,  60,  0,  15, 0, NULL),
('CUST-10042875', 'June 2026', 72.50, 100.00, 540, 230, 45, 0, NULL),
('CUST-10042876', 'June 2026', 95.00, 9999.00, 320, 88, 20, 7, 'United States'),
('CUST-10042877', 'June 2026',  2.10,  5.00,  40,  0,   5, 0, NULL),
('CUST-10042878', 'June 2026', 22.40, 40.00, 180, 12,   9, 0, NULL);

-- Plans
INSERT INTO plans (customer_id, plan_name, plan_type, monthly_fee, data_allowance_gb, voice_minutes, status, start_date, expiry_date) VALUES
('CUST-10042871', 'Postpaid Premium 500',   'BASE',  299.00,  40.00,  500,  'Active', '2019-03-15', '2027-03-15'),
('CUST-10042871', 'Data Add-on 10GB',       'ADDON',  49.00,  10.00,    0,  'Active', '2026-06-01', '2026-06-30'),
('CUST-10042872', 'Postpaid Value 200',     'BASE',  149.00,  20.00,  200,  'Active', '2021-07-22', '2027-07-22'),
('CUST-10042873', 'Postpaid Smart 100',     'BASE',   99.00,  15.00,  100,  'Active', '2020-11-05', '2027-11-05'),
('CUST-10042873', 'Data Add-on 5GB',        'ADDON',  29.00,   5.00,    0,  'Active', '2026-06-01', '2026-06-30'),
('CUST-10042874', 'Prepaid Freedom 50',     'BASE',   50.00,   8.00,  100,  'Active', '2022-02-18', NULL),
('CUST-10042875', 'Business Unlimited Pro', 'BASE',  499.00, 100.00, 9999,  'Active', '2018-06-30', '2027-06-30'),
('CUST-10042875', 'IDD Global Pack',        'ADDON',  99.00,   0.00,    0,  'Active', '2026-06-01', '2026-06-30'),
('CUST-10042876', 'VIP Platinum Unlimited', 'BASE',  799.00, 9999.00, 9999, 'Active', '2017-09-12', '2027-09-12'),
('CUST-10042877', 'Prepaid Super 30',       'BASE',   30.00,   5.00,   60,  'Active', '2023-01-25', NULL),
('CUST-10042878', 'Postpaid Premium 500',   'BASE',  299.00,  40.00,  500,  'Active', '2019-12-08', '2027-12-08');

-- Payments (dates relative to today)
INSERT INTO payments (customer_id, payment_date, amount, currency, method, status, reference_number, invoice_id) VALUES
('CUST-10042871', CURRENT_DATE - INTERVAL '3 days',  402.00, 'AED', 'Credit Card',   'Success', 'PAY-2026-060501', 'INV-2026-05-871'),
('CUST-10042871', CURRENT_DATE - INTERVAL '33 days', 380.00, 'AED', 'Credit Card',   'Success', 'PAY-2026-050601', 'INV-2026-04-871'),
('CUST-10042871', CURRENT_DATE - INTERVAL '63 days', 355.50, 'AED', 'Credit Card',   'Success', 'PAY-2026-040701', 'INV-2026-03-871'),
('CUST-10042872', CURRENT_DATE - INTERVAL '4 days',  158.00, 'AED', 'Bank Transfer', 'Success', 'PAY-2026-060402', 'INV-2026-05-872'),
('CUST-10042872', CURRENT_DATE - INTERVAL '34 days', 162.00, 'AED', 'Bank Transfer', 'Success', 'PAY-2026-050502', 'INV-2026-04-872'),
('CUST-10042873', CURRENT_DATE - INTERVAL '2 days',  128.00, 'AED', 'Wallet',        'Success', 'PAY-2026-060603', 'INV-2026-05-873'),
('CUST-10042873', CURRENT_DATE - INTERVAL '32 days', 118.50, 'AED', 'Wallet',        'Success', 'PAY-2026-050703', 'INV-2026-04-873'),
('CUST-10042874', CURRENT_DATE - INTERVAL '5 days',   50.00, 'AED', 'Wallet',        'Success', 'PAY-2026-061004', NULL),
('CUST-10042874', CURRENT_DATE - INTERVAL '18 days',  50.00, 'AED', 'Wallet',        'Success', 'PAY-2026-052804', NULL),
('CUST-10042875', CURRENT_DATE - INTERVAL '3 days',  745.00, 'AED', 'Auto-Debit',    'Success', 'PAY-2026-060505', 'INV-2026-05-875'),
('CUST-10042875', CURRENT_DATE - INTERVAL '33 days', 712.30, 'AED', 'Auto-Debit',    'Success', 'PAY-2026-050505', 'INV-2026-04-875'),
('CUST-10042875', CURRENT_DATE - INTERVAL '63 days', 698.00, 'AED', 'Auto-Debit',    'Success', 'PAY-2026-040605', 'INV-2026-03-875'),
('CUST-10042875', CURRENT_DATE - INTERVAL '93 days', 720.50, 'AED', 'Auto-Debit',    'Success', 'PAY-2026-030505', 'INV-2026-02-875'),
('CUST-10042875', CURRENT_DATE - INTERVAL '123 days',690.00, 'AED', 'Credit Card',   'Success', 'PAY-2026-020505', 'INV-2026-01-875'),
('CUST-10042876', CURRENT_DATE - INTERVAL '5 days', 1000.00, 'AED', 'Auto-Debit',    'Success', 'PAY-2026-060306', 'INV-2026-05-876'),
('CUST-10042876', CURRENT_DATE - INTERVAL '35 days', 980.00, 'AED', 'Auto-Debit',    'Success', 'PAY-2026-050406', 'INV-2026-04-876'),
('CUST-10042877', CURRENT_DATE - INTERVAL '1 days',   30.00, 'AED', 'Wallet',        'Success', 'PAY-2026-061207', NULL),
('CUST-10042878', CURRENT_DATE - INTERVAL '1 days',  300.00, 'AED', 'Credit Card',   'Success', 'PAY-2026-060708', 'INV-2026-05-878'),
('CUST-10042878', CURRENT_DATE - INTERVAL '31 days', 300.00, 'AED', 'Credit Card',   'Success', 'PAY-2026-050808', 'INV-2026-04-878');

-- Recharge Offers
INSERT INTO recharge_offers (offer_id, offer_name, offer_type, price, currency, data_amount_gb, validity_days, description) VALUES
('OFF-DATA-5GB',      'Data Booster 5GB',       'DATA',    29.00, 'AED',  5.00, 30, '5GB high-speed data valid for 30 days'),
('OFF-DATA-10GB',     'Data Booster 10GB',      'DATA',    49.00, 'AED', 10.00, 30, '10GB high-speed data valid for 30 days'),
('OFF-DATA-20GB',     'Data Max 20GB',          'DATA',    79.00, 'AED', 20.00, 30, '20GB high-speed data valid for 30 days'),
('OFF-IDD-INDIA',     'IDD India 100 min',      'IDD',     39.00, 'AED',  0.00, 30, '100 international minutes to India valid for 30 days'),
('OFF-ROAM-GCC',      'Roaming GCC 3-Day Pass', 'ROAMING', 60.00, 'AED',  3.00,  3, 'Unlimited GCC roaming calls + 3GB data for 3 days'),
('OFF-COMBO-SOCIAL',  'Social & Data Combo',    'COMBO',   59.00, 'AED', 12.00, 30, '12GB data + unlimited social media valid for 30 days');

-- Disputes (timestamps relative to today)
INSERT INTO disputes (dispute_id, customer_id, invoice_id, reason, status, created_at, estimated_resolution, last_update, resolution) VALUES
('DSP-2026-0001', 'CUST-10042876', 'INV-2026-05-876', 'Disputed premium SMS charges of AED 45 not recognised by customer', 'UNDER_REVIEW', CURRENT_DATE - INTERVAL '12 days', CURRENT_DATE + INTERVAL '3 days', CURRENT_DATE - INTERVAL '2 days', NULL),
('DSP-2026-0002', 'CUST-10042873', 'INV-2026-04-873', 'Incorrect late payment fee applied',                                'RESOLVED',     CURRENT_DATE - INTERVAL '40 days', CURRENT_DATE - INTERVAL '33 days', CURRENT_DATE - INTERVAL '35 days', 'Late payment fee of AED 25 waived and credited to the account.');

-- Recharges: intentionally left empty (populated by the recharge_agent at runtime).
