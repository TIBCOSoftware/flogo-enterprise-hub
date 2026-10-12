-- Demo data for the Kestrel Bank Retail Banking Assistant (governed). Fictional bank, people, accounts and merchants.
-- Dates are relative to CURRENT_DATE so the demo always looks "today".
-- Included by database.sql and reset_data.sql via \ir - do not load on its own.
--
-- Passcodes (demo stand-in for the code from the Kestrel app):
--   CUST-2026-00101 James Miller     482913   flagship: QUICKPAY*XYZ 249.99 UNRECOGNISED -> provisional credit + FRAUD_REVIEW
--   CUST-2026-00102 Olivia Davis     730516   STRMPLS* recurring -> CANCELLED_RECURRING; OVERDRAFT FEE -> FEE_REFUND case
--   CUST-2026-00103 William Garcia   615204   LUXEJET 1,850.00 -> no provisional credit (> 500), FRAUD_REVIEW (> 1,000)
--   CUST-2026-00104 Sophia Martinez  559371   DSP-2026-0001 OPEN (ALREADY_DISPUTED); CAFE LUMEN single (NOT_DUPLICATE); ACME x2 (DUPLICATE)
--   CUST-2026-00105 Benjamin Lee     204867   CARD-9005 BLOCKED (ALREADY_BLOCKED); AUTO loan -> LOAN_HARDSHIP case
--   CUST-2026-00106 Emma Johnson     918342   plain: two accounts, active debit card
--   CUST-2026-00107 Michael Brown    377150   CARD-9007 EXPIRED (CARD_EXPIRED)

INSERT INTO customers (customer_id, first_name, last_name, phone, email, passcode_hash) VALUES
 ('CUST-2026-00101','James',   'Miller',  '+1 415-555-0101','james.miller@example.com',   passcode_hash('CUST-2026-00101','482913')),
 ('CUST-2026-00102','Olivia',  'Davis',   '+1 415-555-0102','olivia.davis@example.com',   passcode_hash('CUST-2026-00102','730516')),
 ('CUST-2026-00103','William', 'Garcia',  '+1 312-555-0103','william.garcia@example.com', passcode_hash('CUST-2026-00103','615204')),
 ('CUST-2026-00104','Sophia',  'Martinez','+1 212-555-0104','sophia.martinez@example.com',passcode_hash('CUST-2026-00104','559371')),
 ('CUST-2026-00105','Benjamin','Lee',     '+1 206-555-0105','benjamin.lee@example.com',   passcode_hash('CUST-2026-00105','204867')),
 ('CUST-2026-00106','Emma',    'Johnson', '+1 617-555-0106','emma.johnson@example.com',   passcode_hash('CUST-2026-00106','918342')),
 ('CUST-2026-00107','Michael', 'Brown',   '+1 305-555-0107','michael.brown@example.com',  passcode_hash('CUST-2026-00107','377150'));

INSERT INTO accounts (account_id, customer_id, account_number_masked, account_type, balance, available_balance, currency, status) VALUES
 ('ACC-1001','CUST-2026-00101','****7721','CHECKING',  4250.75,  4250.75,'USD','ACTIVE'),
 ('ACC-1002','CUST-2026-00101','****7734','SAVINGS',  18500.00, 18500.00,'USD','ACTIVE'),
 ('ACC-1003','CUST-2026-00102','****3108','CHECKING',  2180.40,  2180.40,'USD','ACTIVE'),
 ('ACC-1004','CUST-2026-00102','****5567','CREDIT',    -642.18,  4357.82,'USD','ACTIVE'),
 ('ACC-1005','CUST-2026-00103','****6215','CHECKING',  6420.00,  6420.00,'USD','ACTIVE'),
 ('ACC-1006','CUST-2026-00104','****9042','CHECKING',  3105.25,  3105.25,'USD','ACTIVE'),
 ('ACC-1007','CUST-2026-00104','****4410','CREDIT',   -1284.60,  6715.40,'USD','ACTIVE'),
 ('ACC-1008','CUST-2026-00105','****2286','CHECKING',  1240.00,  1240.00,'USD','ACTIVE'),
 ('ACC-1009','CUST-2026-00106','****1150','CHECKING',  5600.00,  5600.00,'USD','ACTIVE'),
 ('ACC-1010','CUST-2026-00106','****1163','SAVINGS',  22000.00, 22000.00,'USD','ACTIVE'),
 ('ACC-1011','CUST-2026-00107','****8803','CHECKING',   980.15,   980.15,'USD','ACTIVE'),
 ('ACC-1012','CUST-2026-00107','****8857','CREDIT',    -210.00,  2790.00,'USD','ACTIVE');

INSERT INTO cards (card_id, customer_id, account_id, last4, card_number_masked, card_type, network, status, expiry, credit_limit) VALUES
 ('CARD-9001','CUST-2026-00101','ACC-1001','1123','**** **** **** 1123','DEBIT', 'VISA',      'ACTIVE', current_date + 730, NULL),
 ('CARD-9002','CUST-2026-00102','ACC-1004','5567','**** **** **** 5567','CREDIT','MASTERCARD','ACTIVE', current_date + 540, 5000.00),
 ('CARD-9003','CUST-2026-00103','ACC-1005','7781','**** **** **** 7781','DEBIT', 'VISA',      'ACTIVE', current_date + 900, NULL),
 ('CARD-9004','CUST-2026-00104','ACC-1007','4410','**** **** **** 4410','CREDIT','VISA',      'ACTIVE', current_date + 610, 8000.00),
 ('CARD-9005','CUST-2026-00105','ACC-1008','3390','**** **** **** 3390','DEBIT', 'VISA',      'BLOCKED',current_date + 400, NULL),
 ('CARD-9006','CUST-2026-00106','ACC-1009','6602','**** **** **** 6602','DEBIT', 'MASTERCARD','ACTIVE', current_date + 820, NULL),
 ('CARD-9007','CUST-2026-00107','ACC-1012','8857','**** **** **** 8857','CREDIT','VISA',      'EXPIRED',current_date - 45,  3000.00);

INSERT INTO transactions (transaction_id, account_id, customer_id, card_id, txn_date, descriptor, amount, txn_type, category, status) VALUES
 -- James: flagship QUICKPAY*XYZ 249.99 (UNRECOGNISED), a smaller QUICKPAY*XYZ (ambiguity by amount),
 -- a PENDING charge, a 150-day-old charge (OUTSIDE_WINDOW) and payroll (NOT_A_DEBIT)
 ('TXN-50001','ACC-1001','CUST-2026-00101',NULL,       current_date - 10, 'NORTHWIND LOGISTICS PAYROLL', 3850.00,'CREDIT','INCOME',       'POSTED'),
 ('TXN-50002','ACC-1001','CUST-2026-00101','CARD-9001',current_date - 8,  'FRESHMART GROCERY #44',         86.42,'DEBIT', 'GROCERIES',    'POSTED'),
 ('TXN-50003','ACC-1001','CUST-2026-00101','CARD-9001',current_date - 6,  'QUICKPAY*XYZ 872-555',         249.99,'DEBIT', 'SHOPPING',     'POSTED'),
 ('TXN-50004','ACC-1001','CUST-2026-00101',NULL,       current_date - 5,  'CITY POWER & LIGHT AUTOPAY',   112.30,'DEBIT', 'UTILITIES',    'POSTED'),
 ('TXN-50005','ACC-1001','CUST-2026-00101','CARD-9001',current_date - 2,  'GASGO FUEL #18',                54.20,'DEBIT', 'FUEL',         'POSTED'),
 ('TXN-50006','ACC-1001','CUST-2026-00101','CARD-9001',current_date,      'HARBOR BISTRO',                 47.80,'DEBIT', 'DINING',       'PENDING'),
 ('TXN-50007','ACC-1001','CUST-2026-00101','CARD-9001',current_date - 150,'ELECTROWORLD #9',              399.00,'DEBIT', 'SHOPPING',     'POSTED'),
 ('TXN-50013','ACC-1001','CUST-2026-00101','CARD-9001',current_date - 20, 'QUICKPAY*XYZ 872-555',          18.75,'DEBIT', 'SHOPPING',     'POSTED'),
 -- Olivia: StreamPlus monthly membership (RECURRING) and an overdraft fee
 ('TXN-50008','ACC-1004','CUST-2026-00102','CARD-9002',current_date - 3,  'STRMPLS*MEMBERSHIP 888-555',    15.99,'DEBIT', 'ENTERTAINMENT','POSTED'),
 ('TXN-50010','ACC-1003','CUST-2026-00102',NULL,       current_date - 4,  'OVERDRAFT FEE',                 35.00,'DEBIT', 'FEES',         'POSTED'),
 ('TXN-50011','ACC-1004','CUST-2026-00102','CARD-9002',current_date - 7,  'FRESHMART GROCERY #12',         63.10,'DEBIT', 'GROCERIES',    'POSTED'),
 ('TXN-50012','ACC-1004','CUST-2026-00102','CARD-9002',current_date - 33, 'STRMPLS*MEMBERSHIP 888-555',    15.99,'DEBIT', 'ENTERTAINMENT','POSTED'),
 -- William: a large travel charge he does not recognise
 ('TXN-50014','ACC-1005','CUST-2026-00103','CARD-9003',current_date - 4,  'LUXEJET TRAVEL 800-555',      1850.00,'DEBIT', 'TRAVEL',       'POSTED'),
 ('TXN-50015','ACC-1005','CUST-2026-00103','CARD-9003',current_date - 9,  'GASGO FUEL #3',                 41.00,'DEBIT', 'FUEL',         'POSTED'),
 -- Sophia: already-disputed digital charge, a single cafe charge, and a genuine duplicate pair
 ('TXN-50009','ACC-1007','CUST-2026-00104','CARD-9004',current_date - 12, 'GLOBAL*DIGITAL 900-555',       129.00,'DEBIT', 'DIGITAL',      'POSTED'),
 ('TXN-50016','ACC-1007','CUST-2026-00104','CARD-9004',current_date - 2,  'CAFE LUMEN',                     8.40,'DEBIT', 'DINING',       'POSTED'),
 ('TXN-50017','ACC-1007','CUST-2026-00104','CARD-9004',current_date - 5,  'ACME HARDWARE #212',            64.10,'DEBIT', 'HOME',         'POSTED'),
 ('TXN-50018','ACC-1007','CUST-2026-00104','CARD-9004',current_date - 5,  'ACME HARDWARE #212',            64.10,'DEBIT', 'HOME',         'POSTED'),
 -- Benjamin, Emma, Michael: ordinary activity
 ('TXN-50019','ACC-1008','CUST-2026-00105',NULL,       current_date - 6,  'FRESHMART GROCERY #7',          52.75,'DEBIT', 'GROCERIES',    'POSTED'),
 ('TXN-50020','ACC-1008','CUST-2026-00105',NULL,       current_date - 3,  'METRO TRANSIT FARE',             2.75,'DEBIT', 'TRANSPORT',    'POSTED'),
 ('TXN-50021','ACC-1009','CUST-2026-00106','CARD-9006',current_date - 3,  'CAFE LUMEN',                     6.20,'DEBIT', 'DINING',       'POSTED'),
 ('TXN-50022','ACC-1009','CUST-2026-00106',NULL,       current_date - 14, 'BRIGHTLINE MEDICAL PAYROLL',  4200.00,'CREDIT','INCOME',       'POSTED'),
 ('TXN-50023','ACC-1011','CUST-2026-00107',NULL,       current_date - 5,  'FRESHMART GROCERY #44',         71.30,'DEBIT', 'GROCERIES',    'POSTED');

INSERT INTO loans (loan_id, customer_id, loan_type, principal, outstanding_balance, interest_rate, monthly_payment, next_due_date, status) VALUES
 ('LOAN-3001','CUST-2026-00101','HOME',     320000.00, 285400.50, 6.25, 2103.45, current_date + 12, 'ACTIVE'),
 ('LOAN-3002','CUST-2026-00102','PERSONAL',  15000.00,   8200.00,11.50,  490.00, current_date + 16, 'ACTIVE'),
 ('LOAN-3003','CUST-2026-00105','AUTO',      42000.00,  31750.00, 7.90,  812.33, current_date + 14, 'ACTIVE');

INSERT INTO branches (branch_id, branch_name, address, city, state, zip, phone, hours) VALUES
 ('BR-001','Downtown Financial District','101 Market St',  'San Francisco','CA','94105','+1 415-555-1000','Mon-Fri 9:00-17:00'),
 ('BR-002','Midtown Center',             '500 5th Ave',    'New York',     'NY','10110','+1 212-555-1000','Mon-Fri 9:00-18:00'),
 ('BR-003','The Loop',                   '233 S Wacker Dr','Chicago',      'IL','60606','+1 312-555-1000','Mon-Fri 9:00-17:00'),
 ('BR-004','Capitol Hill',               '1420 Broadway',  'Seattle',      'WA','98122','+1 206-555-1000','Mon-Fri 9:00-17:00'),
 ('BR-005','Back Bay',                   '800 Boylston St','Boston',       'MA','02199','+1 617-555-1000','Mon-Sat 9:00-16:00');

INSERT INTO merchant_directory (descriptor_prefix, merchant_name, category, billing_model, support_contact, notes) VALUES
 ('QUICKPAY*XYZ',  'XYZ Gadgets Online',     'Electronics web store',          'ONE_OFF',  'support@xyzgadgets.example, 872-555-0140',
  'Online electronics retailer. Charges go through the QuickPay payment processor, so statements show QUICKPAY*XYZ plus its phone number instead of the store name. One-off purchases; no subscriptions.'),
 ('QUICKPAY*',     'QuickPay (payment processor)','Payment processor for many small web stores','ONE_OFF','help@quickpay.example',
  'Generic processor prefix. The text after the * identifies the actual merchant.'),
 ('STRMPLS*',      'StreamPlus',             'Video streaming subscription',   'RECURRING','help.streamplus.example, 888-555-0199',
  'Monthly membership (15.99 USD) billed on the sign-up anniversary until cancelled. Free trials convert to paid automatically. Cancel in account settings.'),
 ('GLOBAL*DIGITAL','Global Digital Media',   'App store / digital content',    'ONE_OFF',  'support@globaldigital.example, 900-555-0110',
  'One-off app, game and e-book purchases. In-app purchases by family members on a shared device are a common cause of unrecognised charges.'),
 ('LUXEJET',       'LuxeJet Travel',         'Flights and holiday packages',   'ONE_OFF',  'bookings@luxejet.example, 800-555-0177',
  'Online travel agency selling flights and package holidays. High-value one-off charges.'),
 ('ACME HARDWARE', 'Acme Hardware',          'Home improvement store',         'ONE_OFF',  'acmehardware.example',
  'Chain of hardware stores; the number after # is the store. In-store card purchases.'),
 ('CAFE LUMEN',    'Cafe Lumen',             'Coffee shop',                    'ONE_OFF',  'cafelumen.example',
  'Neighbourhood coffee shop. Small in-person purchases.'),
 ('TPT *',         'TapPoint POS (small merchants)','Card reader used by small shops and market stalls','ONE_OFF','tappoint.example',
  'Generic card-reader prefix. The text after the * is the small business name, often abbreviated.'),
 ('MRKT MKTP',     'Mercato Marketplace',    'Online marketplace (third-party sellers)','ONE_OFF','mercato.example/help',
  'Marketplace orders; the seller ships the goods. Not-received and not-as-described issues are raised with the marketplace first.'),
 ('FITCLUB*',      'FitClub Gyms',           'Gym membership',                 'RECURRING','fitclub.example, 877-555-0123',
  'Monthly gym membership billed on the 1st; a 30-day notice is required to cancel.'),
 ('GASGO FUEL',    'GasGo Fuel',             'Fuel station',                   'ONE_OFF',  'gasgo.example',
  'Fuel stations; pay-at-pump authorisations can show a temporary hold before the final amount posts.'),
 ('FRESHMART',     'FreshMart Grocery',      'Supermarket',                    'ONE_OFF',  'freshmart.example',
  'Supermarket chain; the number after # is the store.');

INSERT INTO service_teams (request_type, team, reply_business_days) VALUES
 ('FEE_REFUND',              'Customer Care',                2),
 ('LOAN_HARDSHIP',           'Financial Support',            1),
 ('CREDIT_LIMIT_INCREASE',   'Credit Risk',                  3),
 ('COMPLAINT',               'Complaints Resolution',        2),
 ('PERSONAL_DETAILS_CHANGE', 'Identity & Account Servicing', 2),
 ('ACCOUNT_CLOSURE',         'Identity & Account Servicing', 2),
 ('BEREAVEMENT',             'Bereavement Support',          1),
 ('FRAUD_REVIEW',            'Fraud Operations',             1),
 ('OTHER',                   'Customer Care',                3);

-- Sophia's existing OPEN dispute (seeded history, no action_id). trg_dispute_apply posts its provisional
-- credit and opens its FRAUD_REVIEW case exactly as for a live filing. Live disputes continue at DSP-2026-0002.
INSERT INTO disputes (dispute_id, action_id, customer_id, transaction_id, reason_code, customer_statement, amount,
                      provisional_credit, fraud_review, status, est_decision_date, created_at) VALUES
 ('DSP-2026-0001', NULL, 'CUST-2026-00104', 'TXN-50009', 'UNRECOGNISED',
  'I do not recognise this Global Digital charge.', 129.00, 129.00, TRUE, 'OPEN',
  add_business_days(current_date - 9, 10), current_date - 9 + time '09:14');

-- Seed rows are not agent actions: start the audit trail empty.
TRUNCATE agent_audit RESTART IDENTITY;
