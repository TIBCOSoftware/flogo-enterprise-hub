-- Demo data for the Kestrel Bank Retail Banking Assistant (JWT auth variant). Fictional bank, people, accounts and merchants.
-- Dates are relative to CURRENT_DATE so the demo always looks "today".
-- Included by database.sql and reset_data.sql via \ir - do not load on its own.
--
-- Customers (sign in at the bank's identity provider; the JWT sub is the customer id - mint demo tokens with
-- _rebuild/mint_user_tokens.py). "james_view" is James on a view-only channel: same sub, read scopes only.
--   CUST-2026-00101 James Miller       flagship: QUICKPAY*XYZ 249.99 UNRECOGNISED -> provisional credit + FRAUD_REVIEW
--   CUST-2026-00102 Olivia Davis       STRMPLS* recurring -> CANCELLED_RECURRING; OVERDRAFT FEE -> FEE_REFUND case
--   CUST-2026-00103 William Garcia     LUXEJET 1,850.00 -> no provisional credit (> 500), FRAUD_REVIEW (> 1,000)
--   CUST-2026-00104 Sophia Martinez    DSP-2026-0001 OPEN (ALREADY_DISPUTED); CAFE LUMEN single (NOT_DUPLICATE); ACME x2 (DUPLICATE)
--   CUST-2026-00105 Benjamin Lee       CARD-9005 BLOCKED (ALREADY_BLOCKED); AUTO loan -> LOAN_HARDSHIP case
--   CUST-2026-00106 Emma Johnson       plain: two accounts, active debit card
--   CUST-2026-00107 Michael Brown      CARD-9007 EXPIRED (CARD_EXPIRED); seeded OPEN $29 late-fee refund case (Customer Care)
--   CUST-2026-00108 Patricia Wilson    'safe account' story -> scam_signal_agent -> HIGH -> payment HELD + Fraud Operations case
-- Also: Emma has a saved landlord (LOW band) and a new crypto-exchange payee (MEDIUM band); William has a seeded HELD
-- payment (romance/investment) in the Fraud Operations queue; Olivia has a seeded OPEN hardship case (Financial Support).
--
-- Staff reviewers (human in the loop; the JWT sub is the staff ID):
--   KST-7001 Maya Chen     Customer Care      approval limit $25.00  (OVER_AUTHORITY demo on the $29 / $35 fees)
--   KST-7002 Daniel Ortiz  Financial Support  approval limit $5,000.00
--   KST-7003 Priya Nair    Fraud Operations   approval limit $20,000.00

INSERT INTO customers (customer_id, first_name, last_name, phone, email) VALUES
 ('CUST-2026-00101','James',   'Miller',  '+1 415-555-0101','james.miller@example.com'),
 ('CUST-2026-00102','Olivia',  'Davis',   '+1 415-555-0102','olivia.davis@example.com'),
 ('CUST-2026-00103','William', 'Garcia',  '+1 312-555-0103','william.garcia@example.com'),
 ('CUST-2026-00104','Sophia',  'Martinez','+1 212-555-0104','sophia.martinez@example.com'),
 ('CUST-2026-00105','Benjamin','Lee',     '+1 206-555-0105','benjamin.lee@example.com'),
 ('CUST-2026-00106','Emma',    'Johnson', '+1 617-555-0106','emma.johnson@example.com'),
 ('CUST-2026-00107','Michael', 'Brown',   '+1 305-555-0107','michael.brown@example.com'),
 ('CUST-2026-00108','Patricia','Wilson',  '+1 503-555-0108','patricia.wilson@example.com');

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
 ('ACC-1012','CUST-2026-00107','****8857','CREDIT',    -210.00,  2790.00,'USD','ACTIVE'),
 ('ACC-1013','CUST-2026-00108','****5120','CHECKING',  3250.00,  3250.00,'USD','ACTIVE'),
 ('ACC-1014','CUST-2026-00108','****5133','SAVINGS',  24000.00, 24000.00,'USD','ACTIVE');

INSERT INTO cards (card_id, customer_id, account_id, last4, card_number_masked, card_type, network, status, expiry, credit_limit) VALUES
 ('CARD-9001','CUST-2026-00101','ACC-1001','1123','**** **** **** 1123','DEBIT', 'VISA',      'ACTIVE', current_date + 730, NULL),
 ('CARD-9002','CUST-2026-00102','ACC-1004','5567','**** **** **** 5567','CREDIT','MASTERCARD','ACTIVE', current_date + 540, 5000.00),
 ('CARD-9003','CUST-2026-00103','ACC-1005','7781','**** **** **** 7781','DEBIT', 'VISA',      'ACTIVE', current_date + 900, NULL),
 ('CARD-9004','CUST-2026-00104','ACC-1007','4410','**** **** **** 4410','CREDIT','VISA',      'ACTIVE', current_date + 610, 8000.00),
 ('CARD-9005','CUST-2026-00105','ACC-1008','3390','**** **** **** 3390','DEBIT', 'VISA',      'BLOCKED',current_date + 400, NULL),
 ('CARD-9006','CUST-2026-00106','ACC-1009','6602','**** **** **** 6602','DEBIT', 'MASTERCARD','ACTIVE', current_date + 820, NULL),
 ('CARD-9007','CUST-2026-00107','ACC-1012','8857','**** **** **** 8857','CREDIT','VISA',      'EXPIRED',current_date - 45,  3000.00),
 ('CARD-9008','CUST-2026-00108','ACC-1013','5120','**** **** **** 5120','DEBIT', 'VISA',      'ACTIVE', current_date + 680, NULL);

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
 ('TXN-50023','ACC-1011','CUST-2026-00107',NULL,       current_date - 5,  'FRESHMART GROCERY #44',         71.30,'DEBIT', 'GROCERIES',    'POSTED'),
 -- Michael: a late fee (seeded fee-refund case); Emma: monthly rent to her saved landlord (her normal largest payment)
 ('TXN-50024','ACC-1012','CUST-2026-00107',NULL,       current_date - 9,  'LATE PAYMENT FEE',              29.00,'DEBIT', 'FEES',         'POSTED'),
 ('TXN-50025','ACC-1009','CUST-2026-00106',NULL,       current_date - 25, 'HARBOR PROPERTY MGMT RENT',   1850.00,'DEBIT', 'RENT',         'POSTED'),
 ('TXN-50026','ACC-1009','CUST-2026-00106',NULL,       current_date - 55, 'HARBOR PROPERTY MGMT RENT',   1850.00,'DEBIT', 'RENT',         'POSTED'),
 -- Patricia: ordinary activity - her largest payment in 90 days is the 1,400 rent
 ('TXN-50027','ACC-1013','CUST-2026-00108',NULL,       current_date - 28, 'OAKWOOD APARTMENTS RENT',     1400.00,'DEBIT', 'RENT',         'POSTED'),
 ('TXN-50028','ACC-1013','CUST-2026-00108','CARD-9008',current_date - 6,  'FRESHMART GROCERY #31',         92.15,'DEBIT', 'GROCERIES',    'POSTED'),
 ('TXN-50029','ACC-1013','CUST-2026-00108','CARD-9008',current_date - 3,  'WELLCARE PHARMACY',             38.60,'DEBIT', 'HEALTH',       'POSTED'),
 ('TXN-50030','ACC-1013','CUST-2026-00108',NULL,       current_date - 12, 'STATE PENSION FUND DEPOSIT',  2150.00,'CREDIT','INCOME',       'POSTED');

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

INSERT INTO service_teams (request_type, label, team, reply_business_days, customer_openable) VALUES
 ('FEE_REFUND',              'fee refund',              'Customer Care',                2, TRUE),
 ('LOAN_HARDSHIP',           'hardship request',        'Financial Support',            1, TRUE),
 ('CREDIT_LIMIT_INCREASE',   'credit limit increase',   'Credit Risk',                  3, TRUE),
 ('COMPLAINT',               'complaint',               'Complaints Resolution',        2, TRUE),
 ('PERSONAL_DETAILS_CHANGE', 'personal details change', 'Identity & Account Servicing', 2, TRUE),
 ('ACCOUNT_CLOSURE',         'account closure',         'Identity & Account Servicing', 2, TRUE),
 ('BEREAVEMENT',             'bereavement support',     'Bereavement Support',          1, TRUE),
 ('FRAUD_REVIEW',            'fraud review',            'Fraud Operations',             1, TRUE),
 ('PAYMENT_HOLD',            'payment security check',  'Fraud Operations',             1, FALSE),   -- opened only by the payment rules
 ('OTHER',                   'other request',           'Customer Care',                3, TRUE);

-- Sophia's existing OPEN dispute (seeded history, no action_id). trg_dispute_apply posts its provisional
-- credit and opens its FRAUD_REVIEW case exactly as for a live filing. Live disputes continue at DSP-2026-0002.
INSERT INTO disputes (dispute_id, action_id, customer_id, transaction_id, reason_code, customer_statement, amount,
                      provisional_credit, fraud_review, status, est_decision_date, created_at) VALUES
 ('DSP-2026-0001', NULL, 'CUST-2026-00104', 'TXN-50009', 'UNRECOGNISED',
  'I do not recognise this Global Digital charge.', 129.00, 129.00, TRUE, 'OPEN',
  add_business_days(current_date - 9, 10), current_date - 9 + time '09:14');

-- ---------------------------------------------------------------------
-- Human in the loop: staff reviewers (team = service_teams.team). Maya's low limit makes OVER_AUTHORITY demoable.
-- ---------------------------------------------------------------------
INSERT INTO reviewers (reviewer_id, display_name, team, approval_limit) VALUES
 ('KST-7001', 'Maya Chen',    'Customer Care',         25.00),
 ('KST-7002', 'Daniel Ortiz', 'Financial Support',   5000.00),
 ('KST-7003', 'Priya Nair',   'Fraud Operations',   20000.00);

-- ---------------------------------------------------------------------
-- Saved payees (new payees are added in the Kestrel app, never by the assistant)
-- ---------------------------------------------------------------------
INSERT INTO payees (payee_id, customer_id, payee_name, bank_name, account_masked, payee_type, added_at, last_paid_at) VALUES
 ('PYE-0101', 'CUST-2026-00108', 'Oakwood Apartments',         'First Cascade Bank',     '****2210', 'BUSINESS',        now() - INTERVAL '700 days', (current_date - 28) + time '08:00'),
 ('PYE-0102', 'CUST-2026-00108', 'R. Hale - Secure Holding',   'Northgate Digital Bank', '****8841', 'PERSON',          now() - INTERVAL '25 minutes', NULL),
 ('PYE-0201', 'CUST-2026-00106', 'Harbor Property Management', 'Bayline Savings Bank',   '****4477', 'BUSINESS',        now() - INTERVAL '400 days', (current_date - 25) + time '09:00'),
 ('PYE-0202', 'CUST-2026-00106', 'Apex Coin Exchange',         'Apex Digital Trust',     '****0918', 'CRYPTO_EXCHANGE', now() - INTERVAL '2 days', NULL),
 ('PYE-0301', 'CUST-2026-00103', 'Crestline Crypto Desk',      'Meridian Trust Co',      '****3305', 'CRYPTO_EXCHANGE', now() - INTERVAL '3 days', NULL);

-- ---------------------------------------------------------------------
-- Agent reference tables (read-only for the A2A agents via ref_* functions; no customer, payee or staff data).
-- The WHO_DECIDES rows come from service_teams above, not from these tables.
-- ---------------------------------------------------------------------
-- scam_signal_agent -> ref_scam_signals()
INSERT INTO scam_signal_guide (section, term, meaning) VALUES
 ('HIGH_RISK',   'IMPERSONATION',        'Someone claiming to be from the bank, the police, a government agency or a well-known company (often by phone or text, sometimes from a spoofed number) is directing the payment.'),
 ('HIGH_RISK',   'SAFE_ACCOUNT',         'The customer was told to move money to a "safe", "secure" or "holding" account to protect it from fraud.'),
 ('HIGH_RISK',   'REMOTE_ACCESS',        'The customer was asked to install screen-sharing or remote-control software, or someone else is operating their device or online banking.'),
 ('HIGH_RISK',   'SECRECY',              'The customer was told to keep the payment secret, not to tell bank staff or family, or was given a cover story to use if the bank asks.'),
 ('HIGH_RISK',   'CODE_SHARING',         'The customer was asked to read out or forward one-time passcodes, card details or online banking logins.'),
 ('CAUTION',     'URGENCY',              'Pressure to pay immediately: threats of loss, arrest or account closure, or a deadline of minutes or hours.'),
 ('CAUTION',     'INVESTMENT_PROMISE',   'An investment that promises guaranteed, very high or very fast returns, often found through social media, a messaging group or a new online contact.'),
 ('CAUTION',     'ROMANCE',              'The money goes to, or is requested by, an online partner or friend the customer has never met in person.'),
 ('CAUTION',     'CHANGED_DETAILS',      'A supplier, landlord, attorney or contractor sent new bank details by email or text for a payment that is due.'),
 ('CAUTION',     'TOO_GOOD_PURCHASE',    'A purchase, rental deposit or ticket at an unusually low price that can only be paid by bank transfer.'),
 ('CAUTION',     'CRYPTO_OR_GIFT_CARDS', 'The customer was told by someone else to buy cryptocurrency or gift cards, or to pay a crypto exchange.'),
 ('PAYEE_TYPE',  'PERSON',               'a personal account belonging to an individual'),
 ('PAYEE_TYPE',  'BUSINESS',             'an account belonging to a registered business'),
 ('PAYEE_TYPE',  'INVESTMENT_PLATFORM',  'an investment or trading platform'),
 ('PAYEE_TYPE',  'CRYPTO_EXCHANGE',      'a cryptocurrency exchange or digital wallet service'),
 ('SCORE_RULE',  'clear high-risk sign', 'Set the narrative score between 70 and 100 when the story clearly describes at least one HIGH_RISK sign.'),
 ('SCORE_RULE',  'caution signs only',   'Set the narrative score between 30 and 69 when the story describes only CAUTION signs, or hints at a HIGH_RISK sign without saying it clearly.'),
 ('SCORE_RULE',  'ordinary payment',     'Set the narrative score between 0 and 29 when the story is an ordinary, self-initiated payment to someone the customer knows, with no signs.'),
 ('SCORE_RULE',  'evidence rule',        'Quote the customer''s own words for every indicator, and never infer a sign the story does not describe.'),
 ('REVIEW_STEP', 'SAFE_ACCOUNT',         'Call the customer back on the phone number on file, explain that no bank uses safe accounts, and ask whether anyone told them to move the money.'),
 ('REVIEW_STEP', 'IMPERSONATION',        'Ask who contacted the customer, from which number and what they said; never use contact details the caller provided.'),
 ('REVIEW_STEP', 'REMOTE_ACCESS',        'Ask the customer to uninstall the remote-control app and change their online banking password before anything is released.'),
 ('REVIEW_STEP', 'SECRECY',              'Ask gently whether anyone told them what to say to the bank; a cover story is one of the strongest scam signs.'),
 ('REVIEW_STEP', 'INVESTMENT_PROMISE',   'Check whether the platform is registered with the financial regulator and whether the customer has ever withdrawn money from it.'),
 ('REVIEW_STEP', 'ROMANCE',              'Ask whether the customer has met the person face to face and whether they have sent this person money before.');

-- hardship_intake_agent -> ref_hardship_guide()
INSERT INTO hardship_guide (section, term, meaning) VALUES
 ('CAUSE',        'JOB_LOSS',             'the customer lost their job, was laid off or their contract ended'),
 ('CAUSE',        'REDUCED_INCOME',       'the customer still works but earns less (fewer hours, a pay cut or a business slowdown)'),
 ('CAUSE',        'MEDICAL',              'illness, injury, surgery or caring for a sick family member stops or limits work (record only that it is medical)'),
 ('CAUSE',        'SEPARATION_DIVORCE',   'a separation or divorce changed the household income or who pays the bills'),
 ('CAUSE',        'BEREAVEMENT',          'the death of a partner or family member changed the household income or bills'),
 ('CAUSE',        'NATURAL_DISASTER',     'a fire, flood, storm or other disaster damaged the home or stopped work'),
 ('CAUSE',        'OTHER_HARDSHIP',       'any other temporary financial difficulty the customer describes'),
 ('DURATION',     'SHORT_TERM',           'expected to last up to 3 months'),
 ('DURATION',     'MEDIUM_TERM',          'expected to last 3 to 6 months'),
 ('DURATION',     'LONG_TERM_OR_UNKNOWN', 'expected to last more than 6 months, permanent, or the customer does not know yet'),
 ('PRODUCT',      'HOME',                 'home loan (mortgage)'),
 ('PRODUCT',      'AUTO',                 'auto loan'),
 ('PRODUCT',      'PERSONAL',             'personal loan'),
 ('PRODUCT',      'CREDIT',               'credit card account'),
 ('PRODUCT',      'CHECKING',             'checking account'),
 ('PRODUCT',      'SAVINGS',              'savings account'),
 ('PROGRAM',      'PAYMENT_DEFERRAL_3M',  'defers up to 3 monthly payments on an active HOME, AUTO or PERSONAL loan; interest keeps accruing and the deferred payments move to the end of the loan; suits SHORT_TERM hardship'),
 ('PROGRAM',      'REDUCED_PAYMENT_PLAN', 'lowers the monthly payment on a HOME, AUTO or PERSONAL loan for 6 to 12 months; suits MEDIUM_TERM or LONG_TERM_OR_UNKNOWN hardship'),
 ('PROGRAM',      'CARD_HARDSHIP_PLAN',   'pauses interest and sets a fixed monthly payment on a CREDIT card balance for up to 12 months'),
 ('PROGRAM',      'FEE_WAIVER',           'waives overdraft and late-payment fees on CHECKING and CREDIT accounts for 3 months'),
 ('PROGRAM',      'FINANCIAL_COUNSELING','a free, confidential session with an independent non-profit credit counselor; suits any cause and duration'),
 ('DOCUMENT',     'JOB_LOSS',             'a termination or layoff letter, or the last pay stub and an unemployment benefit statement'),
 ('DOCUMENT',     'REDUCED_INCOME',       'the two most recent pay stubs, or the last two months of business income statements'),
 ('DOCUMENT',     'MEDICAL',              'a doctor''s or hospital letter showing the dates the customer cannot work (no diagnosis details are needed)'),
 ('DOCUMENT',     'SEPARATION_DIVORCE',   'the separation agreement or a letter from the customer''s attorney'),
 ('DOCUMENT',     'BEREAVEMENT',          'a copy of the death certificate'),
 ('DOCUMENT',     'NATURAL_DISASTER',     'the insurance claim number or the FEMA registration number'),
 ('DOCUMENT',     'OTHER_HARDSHIP',       'any letter or statement that shows the change in income or costs'),
 ('SUPPORT_LINE', 'standard sentence',    'You do not have to work this out alone: Kestrel''s Financial Support team can also arrange a free, confidential talk with an independent credit counselor.'),
 ('BRIEF_RULE',   'facts only',           'State only what the customer said; never guess a diagnosis, an income figure or an outcome.'),
 ('BRIEF_RULE',   'no promise',           'Never say a program is approved, likely or guaranteed; a Financial Support specialist decides.'),
 ('BRIEF_RULE',   'sensitive detail',     'Leave out medical details beyond the word medical; mention a vulnerability (for example a recent bereavement) only as a short care note.');

-- ---------------------------------------------------------------------
-- Seeded human-owned work, so every reviewer team's queue has something in it (1-2 OPEN cases per team).
-- (Sophia's DSP-2026-0001 above already opened a FRAUD_REVIEW case for Fraud Operations.)
-- ---------------------------------------------------------------------
-- Fraud Operations: William's romance / investment payment, assessed by the same SQL rules and HELD (HIGH band);
-- trg_payment_request opens its PAYMENT_HOLD case exactly as for a live request.
INSERT INTO payment_requests (customer_id, account_id, payee_id, amount, customer_story, agent_notes, narrative_indicators,
                              ignored_indicators, narrative_score, signals, risk_points, risk_band, status, warning_required,
                              created_at, expires_at)
SELECT 'CUST-2026-00103', 'ACC-1005', 'PYE-0301', 6200.00,
       'A woman I met on a dating app three months ago trades crypto for a living. She asked me to send $6,200 to her trading '
       || 'desk so she can double it before Friday, and said not to mention it to my family until it pays off.',
       'indicators: ROMANCE, INVESTMENT_PROMISE, SECRECY, URGENCY' || chr(10)
       || 'evidence: ROMANCE: "a woman I met on a dating app"; INVESTMENT_PROMISE: "so she can double it"; SECRECY: "not to '
       || 'mention it to my family"; URGENCY: "before Friday"' || chr(10) || 'narrative_score: 85' || chr(10)
       || 'reviewer_steps: Ask whether the customer has met the person face to face and whether they have sent this person money '
       || 'before. | Check whether the platform is registered with the financial regulator and whether the customer has ever '
       || 'withdrawn money from it. | Ask gently whether anyone told them what to say to the bank; a cover story is one of the '
       || 'strongest scam signs.',
       s.narrative_indicators, s.ignored_indicators, s.narrative_score, s.signals, s.risk_points, s.risk_band,
       CASE WHEN s.risk_band = 'HIGH' THEN 'HELD' ELSE 'PROPOSED' END, s.risk_band = 'MEDIUM',
       now() - INTERVAL '20 hours', now() - INTERVAL '20 hours' + INTERVAL '15 minutes'
  FROM scam_assessment('CUST-2026-00103', 'ACC-1005', 'PYE-0301', 6200.00, 'ROMANCE, INVESTMENT_PROMISE, SECRECY, URGENCY', '85') s;

-- Financial Support: Olivia's hardship request (brief in the hardship_intake_agent's shape), parked 3-payment deferral.
INSERT INTO service_cases (customer_id, request_type, customer_statement, agent_brief, assigned_team, requested_amount,
                           parked_action, created_at)
SELECT 'CUST-2026-00102', 'LOAN_HARDSHIP',
       'I had surgery last month and I am on unpaid leave for about two more months. I can''t keep up with my personal loan '
       || 'payments until I am back at work.',
       'cause: MEDICAL' || chr(10) || 'expected_duration: SHORT_TERM - about two more months of unpaid leave' || chr(10)
       || 'affected_products: PERSONAL loan - monthly payment $490.00' || chr(10)
       || 'programmes_to_consider: PAYMENT_DEFERRAL_3M, FINANCIAL_COUNSELING' || chr(10)
       || 'documents_to_request: a doctor''s or hospital letter showing the dates the customer cannot work (no diagnosis details are needed)'
       || chr(10) || 'care_note: none' || chr(10)
       || 'support_line: You do not have to work this out alone: Kestrel''s Financial Support team can also arrange a free, '
       || 'confidential talk with an independent credit counselor.' || chr(10)
       || 'summary: The customer is on unpaid medical leave for about two more months. They cannot make their personal loan payments until they return to work.',
       t.team, deferral_max_payments() * l.monthly_payment, 'LOAN_DEFERRAL:' || l.loan_id, now() - INTERVAL '2 days'
  FROM service_teams t, loans l WHERE t.request_type = 'LOAN_HARDSHIP' AND l.loan_id = 'LOAN-3002';

-- Customer Care: Michael's $29 late-fee refund (above Maya Chen's $25 approval limit -> OVER_AUTHORITY demo).
INSERT INTO service_cases (customer_id, request_type, customer_statement, agent_brief, assigned_team, requested_amount,
                           parked_action, created_at)
SELECT 'CUST-2026-00107', 'FEE_REFUND',
       'I was charged a $29 late fee on my credit card, but my payment was only one day late because of the bank holiday. Please refund it.',
       'Customer asks for a refund of the $29.00 late payment fee on the credit account; says the payment was one day late '
       || 'because of a bank holiday.',
       t.team, x.amount, 'FEE_REFUND:' || x.transaction_id, now() - INTERVAL '1 day'
  FROM service_teams t, transactions x WHERE t.request_type = 'FEE_REFUND' AND x.transaction_id = 'TXN-50024';

-- Seed rows are not agent actions: start the audit trail empty.
TRUNCATE agent_audit RESTART IDENTITY;
