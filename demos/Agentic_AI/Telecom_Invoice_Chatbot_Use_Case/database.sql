-- Telecom Invoice Chatbot — Database Schema & Demo Data
-- PostgreSQL 14+
-- Database: telecom

-- Drop existing tables (reverse dependency order)
DROP TABLE IF EXISTS recharges CASCADE;
DROP TABLE IF EXISTS disputes CASCADE;
DROP TABLE IF EXISTS recharge_offers CASCADE;
DROP TABLE IF EXISTS payments CASCADE;
DROP TABLE IF EXISTS plans CASCADE;
DROP TABLE IF EXISTS usage_records CASCADE;
DROP TABLE IF EXISTS invoice_line_items CASCADE;
DROP TABLE IF EXISTS invoices CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

-- 1. Customers — CRM master records (subscriber identified by mobile number)
CREATE TABLE customers (
    id              SERIAL PRIMARY KEY,
    customer_id     VARCHAR(20) NOT NULL UNIQUE,        -- CUST-XXXXXXXX
    mobile_number   VARCHAR(25) NOT NULL UNIQUE,        -- +971-5X-XXX-XXXX
    first_name      VARCHAR(50) NOT NULL,
    last_name       VARCHAR(50) NOT NULL,
    email           VARCHAR(100),
    segment         VARCHAR(20) NOT NULL DEFAULT 'Consumer',   -- Consumer, Premium, Business, VIP
    account_type    VARCHAR(20) NOT NULL DEFAULT 'Postpaid',   -- Prepaid, Postpaid
    status          VARCHAR(20) NOT NULL DEFAULT 'Active',      -- Active, Suspended, Closed
    active_since    DATE NOT NULL,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_segment CHECK (segment IN ('Consumer','Premium','Business','VIP')),
    CONSTRAINT chk_account_type CHECK (account_type IN ('Prepaid','Postpaid'))
);

-- 2. Invoices — monthly invoice header
CREATE TABLE invoices (
    id              SERIAL PRIMARY KEY,
    invoice_id      VARCHAR(25) NOT NULL UNIQUE,        -- INV-2026-06-XXX
    customer_id     VARCHAR(20) NOT NULL REFERENCES customers(customer_id),
    billing_month   VARCHAR(20) NOT NULL,               -- e.g. June 2026
    period_start    DATE NOT NULL,
    period_end      DATE NOT NULL,
    subtotal        NUMERIC(10,2) NOT NULL DEFAULT 0,
    tax             NUMERIC(10,2) NOT NULL DEFAULT 0,
    total_amount    NUMERIC(10,2) NOT NULL DEFAULT 0,
    currency        VARCHAR(3) NOT NULL DEFAULT 'AED',
    due_date        DATE NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'Unpaid',      -- Unpaid, Paid, Overdue
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_invoice_status CHECK (status IN ('Unpaid','Paid','Overdue'))
);

-- 3. Invoice Line Items — charges that make up an invoice
CREATE TABLE invoice_line_items (
    id              SERIAL PRIMARY KEY,
    invoice_id      VARCHAR(25) NOT NULL REFERENCES invoices(invoice_id),
    customer_id     VARCHAR(20) NOT NULL,
    category        VARCHAR(20) NOT NULL,               -- PLAN, IDD, ADDON, ROAMING, TAX, OTHER
    description     VARCHAR(200) NOT NULL,
    amount          NUMERIC(10,2) NOT NULL,
    CONSTRAINT chk_li_category CHECK (category IN ('PLAN','IDD','ADDON','ROAMING','TAX','OTHER'))
);

-- 4. Usage Records — metered usage vs limits for a billing period
CREATE TABLE usage_records (
    id                  SERIAL PRIMARY KEY,
    customer_id         VARCHAR(20) NOT NULL REFERENCES customers(customer_id),
    billing_period      VARCHAR(20) NOT NULL,           -- e.g. June 2026
    data_used_gb        NUMERIC(6,2) NOT NULL DEFAULT 0,
    data_limit_gb       NUMERIC(6,2) NOT NULL DEFAULT 0,
    local_call_minutes  INTEGER NOT NULL DEFAULT 0,
    intl_call_minutes   INTEGER NOT NULL DEFAULT 0,
    sms_count           INTEGER NOT NULL DEFAULT 0,
    roaming_days        INTEGER NOT NULL DEFAULT 0,
    roaming_country     VARCHAR(50)
);

-- 5. Plans — subscribed base plan and add-ons
CREATE TABLE plans (
    id                  SERIAL PRIMARY KEY,
    customer_id         VARCHAR(20) NOT NULL REFERENCES customers(customer_id),
    plan_name           VARCHAR(80) NOT NULL,
    plan_type           VARCHAR(20) NOT NULL DEFAULT 'BASE',    -- BASE, ADDON
    monthly_fee         NUMERIC(10,2) NOT NULL DEFAULT 0,
    data_allowance_gb   NUMERIC(6,2) NOT NULL DEFAULT 0,        -- 9999 = unlimited
    voice_minutes       INTEGER NOT NULL DEFAULT 0,             -- 9999 = unlimited
    status              VARCHAR(20) NOT NULL DEFAULT 'Active',
    start_date          DATE NOT NULL,
    expiry_date         DATE,
    CONSTRAINT chk_plan_type CHECK (plan_type IN ('BASE','ADDON'))
);

-- 6. Payments — payment / top-up history
CREATE TABLE payments (
    id                  SERIAL PRIMARY KEY,
    customer_id         VARCHAR(20) NOT NULL REFERENCES customers(customer_id),
    payment_date        DATE NOT NULL,
    amount              NUMERIC(10,2) NOT NULL,
    currency            VARCHAR(3) NOT NULL DEFAULT 'AED',
    method              VARCHAR(30) NOT NULL,           -- Credit Card, Bank Transfer, Wallet, Auto-Debit
    status              VARCHAR(20) NOT NULL DEFAULT 'Success',     -- Success, Failed, Pending
    reference_number    VARCHAR(30) NOT NULL,
    invoice_id          VARCHAR(25),                    -- may reference a prior invoice not seeded
    CONSTRAINT chk_payment_status CHECK (status IN ('Success','Failed','Pending'))
);

-- 7. Recharge Offers — global catalog of available recharge packs
CREATE TABLE recharge_offers (
    id              SERIAL PRIMARY KEY,
    offer_id        VARCHAR(25) NOT NULL UNIQUE,        -- OFF-DATA-10GB
    offer_name      VARCHAR(80) NOT NULL,
    offer_type      VARCHAR(20) NOT NULL,               -- DATA, IDD, ROAMING, COMBO
    price           NUMERIC(10,2) NOT NULL,
    currency        VARCHAR(3) NOT NULL DEFAULT 'AED',
    data_amount_gb  NUMERIC(6,2) NOT NULL DEFAULT 0,
    validity_days   INTEGER NOT NULL DEFAULT 30,
    description     VARCHAR(200),
    CONSTRAINT chk_offer_type CHECK (offer_type IN ('DATA','IDD','ROAMING','COMBO'))
);

-- 8. Disputes — billing dispute tickets (pre-seeded + written by dispute agent)
CREATE TABLE disputes (
    id                  SERIAL PRIMARY KEY,
    dispute_id          VARCHAR(25) NOT NULL UNIQUE,    -- DSP-2026-XXXX
    customer_id         VARCHAR(20) NOT NULL REFERENCES customers(customer_id),
    invoice_id          VARCHAR(25) NOT NULL,
    reason              VARCHAR(300) NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'OPEN',    -- OPEN, UNDER_REVIEW, RESOLVED, REJECTED
    created_at          TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    estimated_resolution DATE,
    last_update         TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resolution          VARCHAR(300),
    CONSTRAINT chk_dispute_status CHECK (status IN ('OPEN','UNDER_REVIEW','RESOLVED','REJECTED'))
);

-- 9. Recharges — recharge activation log (starts empty; written by recharge agent)
CREATE TABLE recharges (
    id              SERIAL PRIMARY KEY,
    recharge_id     VARCHAR(25) NOT NULL,               -- RCG-2026-XXXX
    customer_id     VARCHAR(20) NOT NULL,
    offer_id        VARCHAR(25) NOT NULL,
    offer_name      VARCHAR(80),
    amount          NUMERIC(10,2),
    data_added_gb   NUMERIC(6,2),
    status          VARCHAR(20) DEFAULT 'ACTIVE',       -- ACTIVE, PENDING, EXPIRED
    applied_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    validity_start  DATE,
    validity_end    DATE
);

-- Indexes
CREATE INDEX idx_customers_mobile ON customers(mobile_number);
CREATE INDEX idx_customers_customer ON customers(customer_id);
CREATE INDEX idx_invoices_customer ON invoices(customer_id);
CREATE INDEX idx_invoices_invoice ON invoices(invoice_id);
CREATE INDEX idx_line_items_invoice ON invoice_line_items(invoice_id);
CREATE INDEX idx_usage_customer ON usage_records(customer_id);
CREATE INDEX idx_plans_customer ON plans(customer_id);
CREATE INDEX idx_payments_customer ON payments(customer_id);
CREATE INDEX idx_disputes_customer ON disputes(customer_id);
CREATE INDEX idx_disputes_dispute ON disputes(dispute_id);
CREATE INDEX idx_recharges_customer ON recharges(customer_id);

-- ============================================================
-- DEMO DATA — UAE telecom subscribers (currency AED)
-- ============================================================

-- Customers (8 subscribers)
INSERT INTO customers (customer_id, mobile_number, first_name, last_name, email, segment, account_type, status, active_since) VALUES
('CUST-10042871', '+971-50-123-4567', 'Ahmed',    'Al Rashid', 'ahmed.alrashid@email.ae', 'Premium',  'Postpaid', 'Active', '2019-03-15'),
('CUST-10042872', '+971-50-234-5678', 'Fatima',   'Al Zaabi',  'fatima.alzaabi@email.ae', 'Consumer', 'Postpaid', 'Active', '2021-07-22'),
('CUST-10042873', '+971-55-345-6789', 'Mohammed', 'Hassan',    'mohammed.hassan@email.ae','Consumer', 'Postpaid', 'Active', '2020-11-05'),
('CUST-10042874', '+971-56-456-7890', 'Sara',     'Abdullah',  'sara.abdullah@email.ae',  'Consumer', 'Prepaid',  'Active', '2022-02-18'),
('CUST-10042875', '+971-52-567-8901', 'Omar',     'Khalil',    'omar.khalil@email.ae',    'Business', 'Postpaid', 'Active', '2018-06-30'),
('CUST-10042876', '+971-50-678-9012', 'Layla',    'Ibrahim',   'layla.ibrahim@email.ae',  'VIP',      'Postpaid', 'Active', '2017-09-12'),
('CUST-10042877', '+971-54-789-0123', 'Yusuf',    'Ahmed',     'yusuf.ahmed@email.ae',    'Consumer', 'Prepaid',  'Active', '2023-01-25'),
('CUST-10042878', '+971-58-890-1234', 'Noura',    'Saeed',     'noura.saeed@email.ae',    'Premium',  'Postpaid', 'Active', '2019-12-08');

-- Invoices (current June 2026 billing cycle for postpaid subscribers)
INSERT INTO invoices (invoice_id, customer_id, billing_month, period_start, period_end, subtotal, tax, total_amount, currency, due_date, status) VALUES
('INV-2026-06-871', 'CUST-10042871', 'June 2026', '2026-06-01', '2026-06-30', 487.50,  0.00, 487.50, 'AED', '2026-07-15', 'Unpaid'),
('INV-2026-06-872', 'CUST-10042872', 'June 2026', '2026-06-01', '2026-06-30', 269.00, 13.45, 282.45, 'AED', '2026-07-15', 'Unpaid'),
('INV-2026-06-873', 'CUST-10042873', 'June 2026', '2026-06-01', '2026-06-30', 128.00,  6.40, 134.40, 'AED', '2026-07-15', 'Unpaid'),
('INV-2026-06-875', 'CUST-10042875', 'June 2026', '2026-06-01', '2026-06-30', 743.00, 37.15, 780.15, 'AED', '2026-07-15', 'Unpaid'),
('INV-2026-06-876', 'CUST-10042876', 'June 2026', '2026-06-01', '2026-06-30', 1009.00, 50.45, 1059.45,'AED', '2026-07-15', 'Unpaid'),
('INV-2026-06-878', 'CUST-10042878', 'June 2026', '2026-06-01', '2026-06-30', 299.00, 14.95, 313.95, 'AED', '2026-07-15', 'Unpaid');

-- Invoice Line Items
-- Ahmed Al Rashid (INV-2026-06-871) — flagship "why is my bill high" (roaming is legitimate: 3 days)
INSERT INTO invoice_line_items (invoice_id, customer_id, category, description, amount) VALUES
('INV-2026-06-871', 'CUST-10042871', 'PLAN',    'Postpaid Plan Premium 500 (monthly)',       299.00),
('INV-2026-06-871', 'CUST-10042871', 'IDD',     'International Calls (India)',                 85.00),
('INV-2026-06-871', 'CUST-10042871', 'ADDON',   'Data Add-on 10GB',                           49.00),
('INV-2026-06-871', 'CUST-10042871', 'ROAMING', 'Roaming Saudi Arabia (3 days)',              54.50);

-- Fatima Al Zaabi (INV-2026-06-872) — DISPUTE: roaming charged but never travelled (0 roaming days)
INSERT INTO invoice_line_items (invoice_id, customer_id, category, description, amount) VALUES
('INV-2026-06-872', 'CUST-10042872', 'PLAN',    'Postpaid Plan Value 200 (monthly)',         149.00),
('INV-2026-06-872', 'CUST-10042872', 'ROAMING', 'Roaming Europe (5 days)',                    120.00),
('INV-2026-06-872', 'CUST-10042872', 'TAX',     'VAT 5%',                                      13.45);

-- Mohammed Hassan (INV-2026-06-873) — RECHARGE: near data limit
INSERT INTO invoice_line_items (invoice_id, customer_id, category, description, amount) VALUES
('INV-2026-06-873', 'CUST-10042873', 'PLAN',    'Postpaid Plan Smart 100 (monthly)',          99.00),
('INV-2026-06-873', 'CUST-10042873', 'ADDON',   'Data Add-on 5GB',                            29.00),
('INV-2026-06-873', 'CUST-10042873', 'TAX',     'VAT 5%',                                       6.40);

-- Omar Khalil (INV-2026-06-875) — Business, high IDD usage
INSERT INTO invoice_line_items (invoice_id, customer_id, category, description, amount) VALUES
('INV-2026-06-875', 'CUST-10042875', 'PLAN',    'Business Unlimited Pro (monthly)',          499.00),
('INV-2026-06-875', 'CUST-10042875', 'ADDON',   'IDD Global Pack',                            99.00),
('INV-2026-06-875', 'CUST-10042875', 'IDD',     'International Calls (UK / US)',              145.00),
('INV-2026-06-875', 'CUST-10042875', 'TAX',     'VAT 5%',                                      37.15);

-- Layla Ibrahim (INV-2026-06-876) — VIP, roaming legitimate (7 days USA)
INSERT INTO invoice_line_items (invoice_id, customer_id, category, description, amount) VALUES
('INV-2026-06-876', 'CUST-10042876', 'PLAN',    'VIP Platinum Unlimited (monthly)',          799.00),
('INV-2026-06-876', 'CUST-10042876', 'ROAMING', 'Roaming USA (7 days)',                       210.00),
('INV-2026-06-876', 'CUST-10042876', 'TAX',     'VAT 5%',                                      50.45);

-- Noura Saeed (INV-2026-06-878) — clean Premium bill
INSERT INTO invoice_line_items (invoice_id, customer_id, category, description, amount) VALUES
('INV-2026-06-878', 'CUST-10042878', 'PLAN',    'Postpaid Plan Premium 500 (monthly)',       299.00),
('INV-2026-06-878', 'CUST-10042878', 'TAX',     'VAT 5%',                                      14.95);

-- Usage Records (June 2026)
INSERT INTO usage_records (customer_id, billing_period, data_used_gb, data_limit_gb, local_call_minutes, intl_call_minutes, sms_count, roaming_days, roaming_country) VALUES
('CUST-10042871', 'June 2026', 38.70, 50.00, 342, 47,  12, 3, 'Saudi Arabia'),   -- roaming matches invoice
('CUST-10042872', 'June 2026', 12.30, 20.00, 210,  0,   8, 0, NULL),             -- NO roaming -> dispute
('CUST-10042873', 'June 2026', 14.80, 15.00,  88,  0,   3, 0, NULL),             -- near data limit -> recharge
('CUST-10042874', 'June 2026',  5.20,  8.00,  60,  0,  15, 0, NULL),             -- prepaid
('CUST-10042875', 'June 2026', 72.50, 100.00, 540, 230, 45, 0, NULL),           -- business heavy IDD
('CUST-10042876', 'June 2026', 95.00, 9999.00, 320, 88, 20, 7, 'United States'),-- VIP unlimited, roaming ok
('CUST-10042877', 'June 2026',  2.10,  5.00,  40,  0,   5, 0, NULL),             -- prepaid
('CUST-10042878', 'June 2026', 22.40, 40.00, 180, 12,   9, 0, NULL);            -- clean premium

-- Plans (base plans + add-ons)
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

-- Payments (most recent first is handled by query ORDER BY)
INSERT INTO payments (customer_id, payment_date, amount, currency, method, status, reference_number, invoice_id) VALUES
-- Ahmed
('CUST-10042871', '2026-06-05', 402.00, 'AED', 'Credit Card',   'Success', 'PAY-2026-060501', 'INV-2026-05-871'),
('CUST-10042871', '2026-05-06', 380.00, 'AED', 'Credit Card',   'Success', 'PAY-2026-050601', 'INV-2026-04-871'),
('CUST-10042871', '2026-04-07', 355.50, 'AED', 'Credit Card',   'Success', 'PAY-2026-040701', 'INV-2026-03-871'),
-- Fatima
('CUST-10042872', '2026-06-04', 158.00, 'AED', 'Bank Transfer', 'Success', 'PAY-2026-060402', 'INV-2026-05-872'),
('CUST-10042872', '2026-05-05', 162.00, 'AED', 'Bank Transfer', 'Success', 'PAY-2026-050502', 'INV-2026-04-872'),
-- Mohammed
('CUST-10042873', '2026-06-06', 128.00, 'AED', 'Wallet',        'Success', 'PAY-2026-060603', 'INV-2026-05-873'),
('CUST-10042873', '2026-05-07', 118.50, 'AED', 'Wallet',        'Success', 'PAY-2026-050703', 'INV-2026-04-873'),
-- Sara (prepaid top-ups)
('CUST-10042874', '2026-06-10',  50.00, 'AED', 'Wallet',        'Success', 'PAY-2026-061004', NULL),
('CUST-10042874', '2026-05-28',  50.00, 'AED', 'Wallet',        'Success', 'PAY-2026-052804', NULL),
-- Omar (Business — rich history for "last 3 payments")
('CUST-10042875', '2026-06-05', 745.00, 'AED', 'Auto-Debit',    'Success', 'PAY-2026-060505', 'INV-2026-05-875'),
('CUST-10042875', '2026-05-05', 712.30, 'AED', 'Auto-Debit',    'Success', 'PAY-2026-050505', 'INV-2026-04-875'),
('CUST-10042875', '2026-04-06', 698.00, 'AED', 'Auto-Debit',    'Success', 'PAY-2026-040605', 'INV-2026-03-875'),
('CUST-10042875', '2026-03-05', 720.50, 'AED', 'Auto-Debit',    'Success', 'PAY-2026-030505', 'INV-2026-02-875'),
('CUST-10042875', '2026-02-05', 690.00, 'AED', 'Credit Card',   'Success', 'PAY-2026-020505', 'INV-2026-01-875'),
-- Layla (VIP)
('CUST-10042876', '2026-06-03', 1000.00,'AED', 'Auto-Debit',    'Success', 'PAY-2026-060306', 'INV-2026-05-876'),
('CUST-10042876', '2026-05-04', 980.00, 'AED', 'Auto-Debit',    'Success', 'PAY-2026-050406', 'INV-2026-04-876'),
-- Yusuf (prepaid top-up)
('CUST-10042877', '2026-06-12',  30.00, 'AED', 'Wallet',        'Success', 'PAY-2026-061207', NULL),
-- Noura
('CUST-10042878', '2026-06-07', 300.00, 'AED', 'Credit Card',   'Success', 'PAY-2026-060708', 'INV-2026-05-878'),
('CUST-10042878', '2026-05-08', 300.00, 'AED', 'Credit Card',   'Success', 'PAY-2026-050808', 'INV-2026-04-878');

-- Recharge Offers (global catalog)
INSERT INTO recharge_offers (offer_id, offer_name, offer_type, price, currency, data_amount_gb, validity_days, description) VALUES
('OFF-DATA-5GB',      'Data Booster 5GB',       'DATA',    29.00, 'AED',  5.00, 30, '5GB high-speed data valid for 30 days'),
('OFF-DATA-10GB',     'Data Booster 10GB',      'DATA',    49.00, 'AED', 10.00, 30, '10GB high-speed data valid for 30 days'),
('OFF-DATA-20GB',     'Data Max 20GB',          'DATA',    79.00, 'AED', 20.00, 30, '20GB high-speed data valid for 30 days'),
('OFF-IDD-INDIA',     'IDD India 100 min',      'IDD',     39.00, 'AED',  0.00, 30, '100 international minutes to India valid for 30 days'),
('OFF-ROAM-GCC',      'Roaming GCC 3-Day Pass', 'ROAMING', 60.00, 'AED',  3.00,  3, 'Unlimited GCC roaming calls + 3GB data for 3 days'),
('OFF-COMBO-SOCIAL',  'Social & Data Combo',    'COMBO',   59.00, 'AED', 12.00, 30, '12GB data + unlimited social media valid for 30 days');

-- Disputes (pre-seeded for status lookup demo; new ones added by the dispute agent)
INSERT INTO disputes (dispute_id, customer_id, invoice_id, reason, status, created_at, estimated_resolution, last_update, resolution) VALUES
('DSP-2026-0001', 'CUST-10042876', 'INV-2026-05-876', 'Disputed premium SMS charges of AED 45 not recognised by customer', 'UNDER_REVIEW', '2026-06-26 10:15:00', '2026-07-11', '2026-07-06 09:30:00', NULL),
('DSP-2026-0002', 'CUST-10042873', 'INV-2026-04-873', 'Incorrect late payment fee applied',                                'RESOLVED',     '2026-05-29 14:20:00', '2026-06-05', '2026-06-04 11:00:00', 'Late payment fee of AED 25 waived and credited to the account.');

-- Recharges: starts empty. Rows are inserted by the recharge_agent at runtime.
