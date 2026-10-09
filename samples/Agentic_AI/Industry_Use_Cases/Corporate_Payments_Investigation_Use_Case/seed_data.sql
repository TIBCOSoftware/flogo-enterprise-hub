-- Demo data for Aurelia Global Bank Corporate Payment Investigation & Status (governed).
-- Fictional bank, corporate clients, accounts, beneficiaries and payments.
-- Dates/times are relative to CURRENT_DATE / now() so the demo always looks "today".
-- Included by database.sql and reset_data.sql via \ir - do not load on its own.
--
-- Passcodes (demo stand-in for the code from the Aurelia corporate portal):
--   CLI-2026-00101 Northwind Manufacturing  486201  flagship: PMT-...02 RETURNED AC04 (decode); PMT-...01 IN_TRANSIT (trace)
--   CLI-2026-00102 Helios Trading           730955  PMT-...06 wrong beneficiary (recall -> Payment Ops); PMT-...07 HELD (sanctions)
--   CLI-2026-00103 Veridian Foods           615338  PMT-...09 INCOMING (NOT_RECALLABLE); PMT-...10 fee charge (FEE_WAIVER)
--   CLI-2026-00104 Barco Logistics          904177  clean COMPLETED; used for cross-client scoping

INSERT INTO clients (client_id, legal_name, contact_email, passcode_hash) VALUES
 ('CLI-2026-00101','Northwind Manufacturing','treasury@northwind.example', passcode_hash('CLI-2026-00101','486201')),
 ('CLI-2026-00102','Helios Trading',         'ap@helios.example',          passcode_hash('CLI-2026-00102','730955')),
 ('CLI-2026-00103','Veridian Foods',         'finance@veridian.example',   passcode_hash('CLI-2026-00103','615338')),
 ('CLI-2026-00104','Barco Logistics',        'treasury@barco.example',     passcode_hash('CLI-2026-00104','904177'));

INSERT INTO accounts (account_id, client_id, account_number_masked, currency) VALUES
 ('ACC-1001','CLI-2026-00101','****4471','USD'),
 ('ACC-1002','CLI-2026-00101','****4482','EUR'),
 ('ACC-1003','CLI-2026-00101','****4493','GBP'),
 ('ACC-1004','CLI-2026-00102','****5510','USD'),
 ('ACC-1005','CLI-2026-00102','****5521','EUR'),
 ('ACC-1006','CLI-2026-00103','****6630','EUR'),
 ('ACC-1007','CLI-2026-00103','****6641','USD'),
 ('ACC-1008','CLI-2026-00104','****7750','USD');

-- Return/reason-code directory (read by the A2A agent; no client data).
INSERT INTO reason_codes (code, rail, plain_language, category, typical_action) VALUES
 ('AC04','SEPA', 'Account closed - the beneficiary''s account no longer exists.',                         'ACCOUNT',    'Confirm the beneficiary''s current account details and re-send the payment.'),
 ('AC06','SEPA', 'Account blocked - the beneficiary''s account is blocked for this type of credit.',       'ACCOUNT',    'Ask the beneficiary to unblock the account or supply an alternative, then re-send.'),
 ('BE01','SWIFT','Beneficiary name and account number do not match the records at the beneficiary bank.',  'BENEFICIARY','Verify the exact legal name against the account number and correct the beneficiary details.'),
 ('AM05','SWIFT','Duplicate payment - this instruction appears to repeat an earlier one.',                 'TECHNICAL',  'Check whether the earlier payment settled; cancel the duplicate if so.'),
 ('RR04','SWIFT','Regulatory or compliance reason - the payment was stopped for a regulatory check.',      'COMPLIANCE', 'Provide the compliance documentation the bank requests; the bank decides.'),
 ('MS03','ANY',  'Reason not specified - the agent bank gave no specific reason.',                          'OTHER',      'Raise a trace so the agent bank supplies the specific reason.'),
 ('RC01','SWIFT','Bank identifier (BIC / routing number) is incorrect.',                                   'TECHNICAL',  'Correct the beneficiary bank BIC / routing number and re-send.');

-- Deterministic settlement rules (rail+currency -> cutoff hour, T+n business days).
INSERT INTO cutoff_rules (rail, currency, cutoff_hour, settlement_days) VALUES
 ('SWIFT','USD',16,1),
 ('SWIFT','GBP',16,1),
 ('SEPA','EUR',15,0),
 ('FEDWIRE','USD',18,0),
 ('FASTER_PAYMENTS','GBP',24,0),
 ('ACH','USD',17,2);

INSERT INTO service_teams (request_type, team, reply_business_days) VALUES
 ('RECALL',          'Payment Operations',     1),
 ('PAYMENT_REPAIR',  'Payment Operations',     1),
 ('FEE_WAIVER',      'Client Servicing',       2),
 ('COMPENSATION',    'Client Servicing',       2),
 ('FRAUD',           'Financial Crime',        1),
 ('SANCTIONS_QUERY', 'Sanctions & Compliance', 2),
 ('OTHER',           'Client Servicing',       3);

-- Payments. created_at drives both the timeline and the deterministic delivery estimate.
INSERT INTO payments (payment_ref, client_id, debtor_account, direction, rail, amount, currency, fx_rate, fees,
                      beneficiary_name, beneficiary_bank_bic, status, return_reason_code, value_date, created_at) VALUES
 -- Northwind
 ('PMT-2026-000001','CLI-2026-00101','ACC-1001','OUTGOING','SWIFT',   250000.00,'USD',NULL,    45.00,'Pacific Components Ltd','DEUTDEFFXXX','IN_TRANSIT',NULL, current_date - 2, current_date - 3 + time '09:00'),
 ('PMT-2026-000002','CLI-2026-00101','ACC-1002','OUTGOING','SEPA',     48500.00,'EUR',0.920000, 0.00,'Lyon Textiles SARL',   'CRLYFRPPXXX','RETURNED','AC04', current_date - 1, current_date - 2 + time '10:30'),
 ('PMT-2026-000003','CLI-2026-00101','ACC-1001','OUTGOING','FEDWIRE',  12000.00,'USD',NULL,    15.00,'Atlas Freight Inc',    'WFBIUS6SXXX','COMPLETED',NULL, current_date - 4, current_date - 4 + time '09:15'),
 ('PMT-2026-000004','CLI-2026-00101','ACC-1003','OUTGOING','SWIFT',    90000.00,'GBP',0.790000,25.00,'Thames Industrial PLC','MIDLGB22XXX','INITIATED',NULL, current_date + 1, now() - interval '30 minutes'),
 ('PMT-2026-000005','CLI-2026-00101','ACC-1001','OUTGOING','SWIFT',   175000.00,'USD',NULL,    50.00,'Shenzhen Parts Co',    'BKCHCNBJXXX','IN_TRANSIT',NULL, current_date + 1, current_date + time '20:00'),
 -- Helios
 ('PMT-2026-000006','CLI-2026-00102','ACC-1004','OUTGOING','SWIFT',   780000.00,'USD',NULL,    60.00,'Quantum Metals Ltd',   'CHASUS33XXX','IN_TRANSIT',NULL, current_date + 1, current_date - 1 + time '11:00'),
 ('PMT-2026-000007','CLI-2026-00102','ACC-1004','OUTGOING','SWIFT',    54000.00,'USD',NULL,     0.00,'Gulf Trading FZE',     'NBADAEAAXXX','HELD',    NULL, current_date + 1, current_date - 2 + time '09:40'),
 ('PMT-2026-000008','CLI-2026-00102','ACC-1005','OUTGOING','SEPA',     32000.00,'EUR',0.920000, 0.00,'Berlin Components GmbH','COBADEFFXXX','IN_TRANSIT',NULL, current_date - 3, current_date - 3 + time '08:50'),
 -- Veridian
 ('PMT-2026-000009','CLI-2026-00103','ACC-1006','INCOMING','SEPA',     56000.00,'EUR',0.920000, 0.00,'Veridian Foods SA',    'INGBNL2AXXX','IN_TRANSIT',NULL, current_date,     current_date - 2 + time '12:00'),
 ('PMT-2026-000010','CLI-2026-00103','ACC-1007','OUTGOING','ACH',       8900.00,'USD',NULL,    45.00,'Office Supplies Direct','CITIUS33XXX','IN_TRANSIT',NULL, current_date + 2, current_date + time '08:00'),
 ('PMT-2026-000011','CLI-2026-00103','ACC-1007','OUTGOING','FEDWIRE',  15000.00,'USD',NULL,    20.00,'Pacific Rim Importers','BOFAUS3NXXX','COMPLETED',NULL, current_date - 10,current_date - 12 + time '09:00'),
 -- Barco (cross-client scoping)
 ('PMT-2026-000012','CLI-2026-00104','ACC-1008','OUTGOING','SWIFT',    61000.00,'USD',NULL,    40.00,'Rotterdam Shipping BV','RABONL2UXXX','COMPLETED',NULL, current_date - 5, current_date - 6 + time '10:00');

-- GPI-style timelines for a few payments.
INSERT INTO payment_events (payment_ref, event_time, actor, action, detail) VALUES
 ('PMT-2026-000001', current_date - 3 + time '09:00','Aurelia Global Bank','INITIATED',       'Payment instruction received.'),
 ('PMT-2026-000001', current_date - 3 + time '09:05','Aurelia Global Bank','DEBITED',         'Debtor account debited 250,000.00 USD.'),
 ('PMT-2026-000001', current_date - 3 + time '09:20','Aurelia Global Bank','SENT_TO_AGENT',   'Forwarded to correspondent DEUTDEFF.'),
 ('PMT-2026-000001', current_date - 2 + time '14:10','Deutsche Bank AG',   'IN_TRANSIT',      'Credit pending at beneficiary bank.'),
 ('PMT-2026-000002', current_date - 2 + time '10:30','Aurelia Global Bank','INITIATED',       'Payment instruction received.'),
 ('PMT-2026-000002', current_date - 2 + time '10:45','Aurelia Global Bank','SENT_TO_AGENT',   'Forwarded to correspondent CRLYFRPP.'),
 ('PMT-2026-000002', current_date - 1 + time '09:30','Credit Lyonnais',    'RETURNED',        'Returned with reason AC04 (account closed).'),
 ('PMT-2026-000003', current_date - 4 + time '09:15','Aurelia Global Bank','INITIATED',       'Payment instruction received.'),
 ('PMT-2026-000003', current_date - 4 + time '13:00','Wells Fargo',        'COMPLETED',       'Credited to beneficiary; settled.'),
 ('PMT-2026-000006', current_date - 1 + time '11:00','Aurelia Global Bank','INITIATED',       'Payment instruction received.'),
 ('PMT-2026-000006', current_date - 1 + time '11:15','Aurelia Global Bank','SENT_TO_AGENT',   'Forwarded to correspondent CHASUS33.'),
 ('PMT-2026-000008', current_date - 3 + time '08:50','Aurelia Global Bank','INITIATED',       'Payment instruction received.'),
 ('PMT-2026-000008', current_date - 3 + time '09:10','Aurelia Global Bank','SENT_TO_AGENT',   'Forwarded to correspondent COBADEFF.');

-- Helios PMT-...08 already has an OPEN investigation (seeded history, no action_id) -> ALREADY_UNDER_INVESTIGATION.
-- Live traces continue at INV-2026-0002. trg_investigation_apply writes its payment_event + audit; audit is cleared below.
INSERT INTO investigations (investigation_id, action_id, client_id, payment_ref, reason_code, client_statement, status, est_response_date, created_at) VALUES
 ('INV-2026-0001', NULL, 'CLI-2026-00102', 'PMT-2026-000008', 'MS03',
  'Supplier says the EUR payment has not arrived.', 'OPEN', add_business_days(current_date - 2, 3), current_date - 2 + time '15:20');

-- Seed rows are not agent actions: start the audit trail empty.
TRUNCATE agent_audit RESTART IDENTITY;
