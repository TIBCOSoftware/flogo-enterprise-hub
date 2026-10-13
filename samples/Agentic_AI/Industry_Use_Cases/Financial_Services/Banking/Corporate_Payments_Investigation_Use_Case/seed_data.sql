-- Demo data for Aurelia Global Bank Corporate Payment Investigation & Status (governed).
-- Fictional bank, corporate clients, staff, accounts, buyers, beneficiaries and payments.
-- Dates/times are relative to CURRENT_DATE / now() so the demo always looks "today".
-- Included by database.sql and reset_data.sql via \ir - do not load on its own.
--
-- Passcodes (demo stand-in for the code from the Aurelia corporate portal):
--   CLI-2026-00101 Northwind Manufacturing  486201  flagship: PMT-...02 RETURNED AC04 (decode); PMT-...01 IN_TRANSIT (trace);
--                                                   PMT-...13 incoming from Harbor Retail Group with a short-pay note (cash application)
--   CLI-2026-00102 Helios Trading           730955  PMT-...06 wrong beneficiary (recall -> Payment Ops); PMT-...07 HELD (sanctions)
--   CLI-2026-00103 Veridian Foods           615338  PMT-...09 INCOMING (NOT_RECALLABLE); PMT-...10 fee charge (FEE_WAIVER)
--   CLI-2026-00104 Bramwell Logistics       904177  pays a supplier with a name check: ACME Corp (MATCH) and "new bank details"
--                                                   for Rotterdam Shipping BV (NO_MATCH -> held for Payment Operations)
-- Staff reviewers (staff ID / code / team / approval limit):
--   AGB-5001 Elena Park     482615  Payment Operations    $250,000    (OVER_AUTHORITY on the $310,000 recall in CASE-00001)
--   AGB-5002 Marcus Webb    739104  Payment Operations    $2,000,000
--   AGB-5003 Sofia Alvarez  615920  Client Servicing      $2,500      (OVER_AUTHORITY on the $3,150 deduction in CASE-00004)

INSERT INTO clients (client_id, legal_name, contact_email, passcode_hash) VALUES
 ('CLI-2026-00101','Northwind Manufacturing','treasury@northwind.example', passcode_hash('CLI-2026-00101','486201')),
 ('CLI-2026-00102','Helios Trading',         'ap@helios.example',          passcode_hash('CLI-2026-00102','730955')),
 ('CLI-2026-00103','Veridian Foods',         'finance@veridian.example',   passcode_hash('CLI-2026-00103','615338')),
 ('CLI-2026-00104','Bramwell Logistics',     'treasury@bramwell.example',  passcode_hash('CLI-2026-00104','904177'));

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

-- Human-owned request types -> team + reply time. RECALL, PAYEE_VERIFICATION and DEDUCTION_REVIEW cases are opened only
-- by the rules (confirm_recall, a held payment, a posted cash application), never directly by the assistant.
INSERT INTO service_teams (request_type, label, team, reply_business_days, client_openable) VALUES
 ('RECALL',             'payment recall request',      'Payment Operations',     1, FALSE),
 ('PAYEE_VERIFICATION', 'payee verification hold',     'Payment Operations',     1, FALSE),
 ('PAYMENT_REPAIR',     'payment repair request',      'Payment Operations',     1, TRUE),
 ('FEE_WAIVER',         'fee waiver request',          'Client Servicing',       2, TRUE),
 ('COMPENSATION',       'compensation request',        'Client Servicing',       2, TRUE),
 ('DEDUCTION_REVIEW',   'short-payment deduction',     'Client Servicing',       2, FALSE),
 ('FRAUD',              'suspected fraud report',      'Financial Crime',        1, TRUE),
 ('SANCTIONS_QUERY',    'sanctions screening query',   'Sanctions & Compliance', 2, TRUE),
 ('OTHER',              'request',                     'Client Servicing',       3, TRUE);

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
 -- Bramwell (cross-client scoping)
 ('PMT-2026-000012','CLI-2026-00104','ACC-1008','OUTGOING','SWIFT',    61000.00,'USD',NULL,    40.00,'Rotterdam Shipping BV','RABONL2UXXX','COMPLETED',NULL, current_date - 5, current_date - 6 + time '10:00');

-- Incoming payments with remittance text (cash application) and the seeded recall (reviewer queue).
INSERT INTO payments (payment_ref, client_id, debtor_account, direction, rail, amount, currency, fx_rate, fees,
                      beneficiary_name, beneficiary_bank_bic, ordering_party, remittance_info, status, status_before_recall,
                      return_reason_code, value_date, created_at) VALUES
 ('PMT-2026-000013','CLI-2026-00101','ACC-1001','INCOMING','FEDWIRE',  46728.00,'USD',NULL,     0.00,'Northwind Manufacturing','BOFAUS3NXXX',
  'Harbor Retail Group', 'INV 4417/4425 LESS 2PCT EARLY PAY FRT DED 312.00', 'COMPLETED', NULL, NULL, current_date - 1, current_date - 1 + time '10:15'),
 ('PMT-2026-000014','CLI-2026-00101','ACC-1001','OUTGOING','SWIFT',   310000.00,'USD',NULL,    55.00,'Baltic Timber OU',      'HABALV22XXX',
  NULL, NULL, 'RECALL_REQUESTED', 'IN_TRANSIT', NULL, current_date + 1, current_date - 1 + time '09:30'),
 ('PMT-2026-000015','CLI-2026-00102','ACC-1004','INCOMING','FEDWIRE',  61850.00,'USD',NULL,     0.00,'Helios Trading',         'CITIUS33XXX',
  'Coastal Grocers Inc', 'INV 7702 SHORT PAID 3150.00 DAMAGED GOODS CLAIM 88-14', 'COMPLETED', NULL, NULL, current_date - 2, current_date - 2 + time '14:05');

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
 ('PMT-2026-000008', current_date - 3 + time '09:10','Aurelia Global Bank','SENT_TO_AGENT',   'Forwarded to correspondent COBADEFF.'),
 ('PMT-2026-000013', current_date - 1 + time '10:15','Bank of America',    'RECEIVED',        'Incoming credit from Harbor Retail Group.'),
 ('PMT-2026-000014', current_date - 1 + time '09:30','Aurelia Global Bank','INITIATED',       'Payment instruction received.'),
 ('PMT-2026-000014', current_date - 1 + time '09:45','Aurelia Global Bank','SENT_TO_AGENT',   'Forwarded to correspondent HABALV22.'),
 ('PMT-2026-000014', current_date - 1 + time '16:20','Aurelia Global Bank','RECALL REQUESTED','Recall request submitted to Payment Operations (duplicate of an earlier payment).'),
 ('PMT-2026-000015', current_date - 2 + time '14:05','Citibank',           'RECEIVED',        'Incoming credit from Coastal Grocers Inc.');

-- Helios PMT-...08 already has an OPEN investigation (seeded history, no action_id) -> ALREADY_UNDER_INVESTIGATION.
-- Live traces continue at INV-2026-0002. trg_investigation_apply writes its payment_event + audit; audit is cleared below.
INSERT INTO investigations (investigation_id, action_id, client_id, payment_ref, reason_code, client_statement, status, est_response_date, created_at) VALUES
 ('INV-2026-0001', NULL, 'CLI-2026-00102', 'PMT-2026-000008', 'MS03',
  'Supplier says the EUR payment has not arrived.', 'OPEN', add_business_days(current_date - 2, 3), current_date - 2 + time '15:20');

-- ---------------------------------------------------------------------
-- Human in the loop: staff reviewers (team = service_teams.team). Elena's and Sofia's limits make OVER_AUTHORITY demoable.
-- ---------------------------------------------------------------------
INSERT INTO reviewers (reviewer_id, display_name, team, one_time_code, approval_limit) VALUES
 ('AGB-5001', 'Elena Park',    'Payment Operations', '482615',  250000.00),
 ('AGB-5002', 'Marcus Webb',   'Payment Operations', '739104', 2000000.00),
 ('AGB-5003', 'Sofia Alvarez', 'Client Servicing',   '615920',    2500.00);

-- ---------------------------------------------------------------------
-- Receivables: the clients' open invoices (cash application candidates).
-- ---------------------------------------------------------------------
INSERT INTO open_invoices (client_id, invoice_no, buyer_name, invoice_date, due_date, currency, amount, terms,
                           discount_pct, discount_days, open_amount) VALUES
 ('CLI-2026-00101','4398','Harbor Retail Group',   current_date - 40, current_date - 10, 'USD', 12500.00, '2/10 NET 30', 2, 10, 12500.00),
 ('CLI-2026-00101','4417','Harbor Retail Group',   current_date - 7,  current_date + 23, 'USD', 30000.00, '2/10 NET 30', 2, 10, 30000.00),
 ('CLI-2026-00101','4425','Harbor Retail Group',   current_date - 7,  current_date + 23, 'USD', 18000.00, '2/10 NET 30', 2, 10, 18000.00),
 ('CLI-2026-00101','4431','Harbor Retail Group',   current_date - 3,  current_date + 27, 'USD', 18000.00, '2/10 NET 30', 2, 10, 18000.00),
 ('CLI-2026-00101','4433','Summit Outdoor Supply', current_date - 12, current_date + 18, 'USD',  9750.00, 'NET 30',      0,  0,  9750.00),
 ('CLI-2026-00102','7702','Coastal Grocers Inc',   current_date - 25, current_date + 5,  'USD', 65000.00, 'NET 30',      0,  0, 65000.00),
 ('CLI-2026-00102','7715','Coastal Grocers Inc',   current_date - 9,  current_date + 21, 'USD', 22400.00, 'NET 30',      0,  0, 22400.00);

-- ---------------------------------------------------------------------
-- Verification of payee: the account names on file (a stand-in for the scheme's name-check service).
-- ---------------------------------------------------------------------
INSERT INTO payee_register (account_ref, bank_bic, registered_name, currency, rail) VALUES
 ('4410028811',             'CHASUS33XXX', 'Acme Corporation Ltd',             'USD', 'FEDWIRE'),
 ('7781200456',             'CITIUS33XXX', 'RD Global Trading LLC',            'USD', 'FEDWIRE'),
 ('3390044127',             'WFBIUS6SXXX', 'Atlas Freight Forwarding Inc',     'USD', 'ACH'),
 ('5520019837',             'BOFAUS3NXXX', 'Pacific Rim Imports & Export LLC', 'USD', 'FEDWIRE'),
 ('DE44500105175407324931', 'COBADEFFXXX', 'Müller Logistik GmbH',             'EUR', 'SEPA');

-- ---------------------------------------------------------------------
-- Agent reference tables (read-only for the A2A agents via ref_* functions; no client, buyer, payee or staff data).
-- The WHO_DECIDES rows come from service_teams above, not from these tables.
-- ---------------------------------------------------------------------
-- remittance_match_agent -> ref_remittance_guide()
INSERT INTO remittance_guide (section, term, meaning) VALUES
 ('DEDUCTION',    'EARLY_PAY_DISCOUNT', 'The buyer took the early-payment discount in the invoice terms (2/10 NET 30 means 2 percent off when paid within 10 days of the invoice date). Give it without an amount: the system works out how much was earned.'),
 ('DEDUCTION',    'FREIGHT',            'The buyer deducted freight, delivery or shipping charges they dispute, for example shipping billed on a prepaid order or a late-delivery penalty.'),
 ('DEDUCTION',    'DAMAGED_GOODS',      'The buyer deducted the value of goods that arrived damaged or defective and is claiming against the shipment.'),
 ('DEDUCTION',    'PRICING',            'The buyer paid a different price than invoiced: a price dispute, a missing promotional allowance or a credit memo they expected.'),
 ('DEDUCTION',    'SHORTAGE',           'The buyer received fewer units than invoiced and paid only for what arrived.'),
 ('DEDUCTION',    'UNAPPLIED',          'Part of the short payment has no stated reason in the note; give its amount so it stays visible, and never guess a reason.'),
 ('NOTE_PATTERN', 'INV',                'An invoice number follows (INV, INVOICE, IN#); several numbers may be joined by a slash, a comma, an ampersand or the word and.'),
 ('NOTE_PATTERN', 'LESS N PCT',         'The buyer took N percent off the invoice, usually the early-payment discount (written LESS 2PCT, less 2 percent or with a percent sign).'),
 ('NOTE_PATTERN', 'DED',                'A deduction follows, usually with its reason and amount (DED, DEDN, DEDUCT).'),
 ('NOTE_PATTERN', 'FRT',                'Freight (FRT, FRGHT): a freight deduction.'),
 ('NOTE_PATTERN', 'DMG',                'Damaged goods (DMG, DAMAGED, DEFECT): a damaged-goods claim.'),
 ('NOTE_PATTERN', 'SP',                 'Short paid or short payment (SP, SHORT PAY): the buyer paid less than the invoice total.'),
 ('NOTE_PATTERN', 'CLAIM',              'A buyer claim or debit memo number (CLAIM 88-14, DM 102): keep it in the explanation; it is not an invoice number.'),
 ('MATCH_RULE',   'numbers first',      'Match by the invoice numbers written in the note; use amounts and the buyer name only to break a tie.'),
 ('MATCH_RULE',   'candidates only',    'Only invoices from the candidate list can be matched; a number in the note that is not a candidate is reported, never invented.'),
 ('MATCH_RULE',   'amount per item',    'Give every deduction except the early-payment discount with the amount stated in the note.'),
 ('MATCH_RULE',   'reconcile',          'Add up the matched invoices, take away the deductions and compare the result with the payment amount; say so when they do not reconcile.'),
 ('CONFIDENCE',   'HIGH',               'Every matched invoice number appears in the note and the amounts reconcile to the cent.'),
 ('CONFIDENCE',   'MEDIUM',             'The invoice numbers appear in the note, but one amount or one reason had to be inferred.'),
 ('CONFIDENCE',   'LOW',                'No invoice number appears in the note, the numbers fit more than one set of candidates, or the amounts do not reconcile.'),
 ('REVIEW_LINE',  'standard sentence',  'Deductions stay recorded as claims against the buyer until Aurelia Client Servicing accepts or rejects them; the invoice remains open for the disputed amount in the meantime.');

-- payee_name_match_agent -> ref_payee_name_rules(). SQL normalises names with the LEGAL_SUFFIX, ABBREVIATION and
-- TRANSLITERATION rows too (terms "X = Y" are read by payee_name_norm), so both sides use one rule set.
INSERT INTO payee_name_guide (section, term, meaning) VALUES
 ('VERDICT',         'MATCH',           'The names are the same company: they differ only in legal-form words, standard abbreviations, letter case, punctuation or accents. The payment can go ahead in the usual way.'),
 ('VERDICT',         'CLOSE_MATCH',     'The names are similar but not the same: a word is missing or extra, a letter is wrong, or a trading name is used. The client must confirm the payee before any money moves.'),
 ('VERDICT',         'NO_MATCH',        'The names belong to different companies. The payment must not go to this account until a person has verified the payee with the client.'),
 ('REASON',          'SUFFIX_ONLY',     'Only the legal-form words differ, for example LTD against LIMITED or CORP against CORPORATION.'),
 ('REASON',          'ABBREVIATION',    'One name uses a standard abbreviation of a word in the other, for example INTL for INTERNATIONAL.'),
 ('REASON',          'TRANSLITERATION', 'The names differ only in accented letters written another way, for example MÜLLER, MUELLER and MULLER.'),
 ('REASON',          'TYPO',            'One or two letters differ, are swapped or are missing in an otherwise identical name.'),
 ('REASON',          'MISSING_WORD',    'One name has an extra or missing descriptive word such as FORWARDING, TRADING, GROUP or IMPORTS.'),
 ('REASON',          'TRADING_NAME',    'One name looks like a brand or trading name of the other rather than its registered name.'),
 ('REASON',          'DIFFERENT_NAME',  'The distinctive words of the two names are different, so they point to different companies.'),
 ('LEGAL_SUFFIX',    'LTD',             'Limited company, a legal-form word to ignore when comparing names.'),
 ('LEGAL_SUFFIX',    'LIMITED',         'Limited company written in full; same as LTD.'),
 ('LEGAL_SUFFIX',    'CORP',            'Corporation, short form; a legal-form word.'),
 ('LEGAL_SUFFIX',    'CORPORATION',     'Corporation written in full; same as CORP.'),
 ('LEGAL_SUFFIX',    'INC',             'Incorporated (United States); a legal-form word.'),
 ('LEGAL_SUFFIX',    'LLC',             'Limited liability company (United States); a legal-form word.'),
 ('LEGAL_SUFFIX',    'PLC',             'Public limited company (United Kingdom); a legal-form word.'),
 ('LEGAL_SUFFIX',    'GMBH',            'German or Austrian limited company; a legal-form word.'),
 ('LEGAL_SUFFIX',    'SARL',            'French or Luxembourg limited company; a legal-form word.'),
 ('LEGAL_SUFFIX',    'BV',              'Dutch or Belgian private limited company; a legal-form word.'),
 ('LEGAL_SUFFIX',    'SA',              'Public company in French- and Spanish-speaking countries; a legal-form word.'),
 ('LEGAL_SUFFIX',    'AG',              'German or Swiss stock corporation; a legal-form word.'),
 ('ABBREVIATION',    'INTL = INTERNATIONAL', 'INTL is the standard short form of INTERNATIONAL.'),
 ('ABBREVIATION',    'MFG = MANUFACTURING',  'MFG is the standard short form of MANUFACTURING.'),
 ('ABBREVIATION',    'SVCS = SERVICES',      'SVCS is the standard short form of SERVICES.'),
 ('ABBREVIATION',    'BROS = BROTHERS',      'BROS is the standard short form of BROTHERS.'),
 ('ABBREVIATION',    'TECH = TECHNOLOGY',    'TECH is the standard short form of TECHNOLOGY.'),
 ('TRANSLITERATION', 'Ü = U',           'u with umlaut; written U or UE in systems without accents, so MÜLLER, MUELLER and MULLER are one name.'),
 ('TRANSLITERATION', 'Ö = O',           'o with umlaut; written O or OE in systems without accents.'),
 ('TRANSLITERATION', 'Ä = A',           'a with umlaut; written A or AE in systems without accents.'),
 ('TRANSLITERATION', 'ß = SS',          'sharp s; written SS in systems without it.'),
 ('TRANSLITERATION', 'É = E',           'e with an accent; written E in systems without accents.'),
 ('TRANSLITERATION', 'Ø = O',           'o with a stroke (Danish, Norwegian); written O or OE in systems without it.');

-- ---------------------------------------------------------------------
-- Seeded human-owned work, so every reviewer team's queue has something in it (2 OPEN cases per team).
-- ---------------------------------------------------------------------
-- Payment Operations: Northwind's duplicate $310,000 payment, already RECALL_REQUESTED (above Elena Park's $250,000 limit).
INSERT INTO review_cases (client_id, request_type, payment_ref, client_statement, agent_brief, assigned_team, currency,
                          requested_amount, parked_action, created_at)
SELECT 'CLI-2026-00101', 'RECALL', 'PMT-2026-000014',
       'We paid Baltic Timber twice for the same shipment by mistake. Please recall the second $310,000 payment.',
       'SYSTEM: recall requested on PMT-2026-000014 (OUTGOING SWIFT $310,000.00 to Baltic Timber OU), reason AM05 '
       || '(duplicate payment). Funds are not auto-reversed; Payment Operations decides whether to send the recall to the '
       || 'beneficiary bank.',
       t.team, 'USD', 310000.00, 'RECALL:PMT-2026-000014', current_date - 1 + time '16:20'
  FROM service_teams t WHERE t.request_type = 'RECALL';

-- Payment Operations: Veridian's payment to "new bank details" for a supplier, assessed by the same SQL rules
-- (CLOSE_MATCH over the hold threshold -> HELD); trg_payment_request opens its PAYEE_VERIFICATION case exactly as live.
INSERT INTO payment_requests (client_id, account_id, beneficiary_account, typed_name, registered_name, amount, currency, rail,
                              purpose, agent_verdict, agent_reasons, ignored_reasons, agent_notes, name_score, name_check,
                              status, warning_required, created_at, expires_at)
SELECT 'CLI-2026-00103', 'ACC-1007', g.account_ref, 'Pacific Rim Importers', g.registered_name, 42500.00, g.currency, g.rail,
       'Pacific Rim Importers emailed us new bank details for this month''s $42,500 order. Please pay their new account.',
       s.agent_verdict, s.agent_reasons, s.ignored_reasons,
       'verdict: CLOSE_MATCH' || chr(10) || 'reasons: MISSING_WORD, TRADING_NAME' || chr(10)
       || 'explanation: The account name adds the words IMPORTS & EXPORT and reads like a different trading name than the one given.'
       || chr(10) || 'verdict_note: The names are similar but not the same: a word is missing or extra, a letter is wrong, or a '
       || 'trading name is used. The client must confirm the payee before any money moves.',
       s.name_score, s.name_check, s.status, s.warning_required, now() - INTERVAL '5 hours', now() - INTERVAL '5 hours' + INTERVAL '15 minutes'
  FROM payee_register g
  CROSS JOIN LATERAL payee_assessment('Pacific Rim Importers', g.registered_name, 42500.00, 'CLOSE_MATCH', 'MISSING_WORD, TRADING_NAME') s
 WHERE g.account_ref = '5520019837';

-- Client Servicing: Bramwell's $40 SWIFT fee, parked as a fee refund.
INSERT INTO review_cases (client_id, request_type, payment_ref, client_statement, agent_brief, assigned_team, currency,
                          requested_amount, parked_action, created_at)
SELECT 'CLI-2026-00104', 'FEE_WAIVER', p.payment_ref,
       'We were charged a $40 fee on our SWIFT payment to Rotterdam Shipping, but our agreement says SWIFT fees are waived. Please refund it.',
       'Client asks for a refund of the $40.00 fee on PMT-2026-000012 (SWIFT to Rotterdam Shipping BV); says their agreement waives SWIFT fees.',
       t.team, p.currency, p.fees, 'FEE_REFUND:' || p.payment_ref, now() - INTERVAL '1 day'
  FROM service_teams t, payments p WHERE t.request_type = 'FEE_WAIVER' AND p.payment_ref = 'PMT-2026-000012';

-- Client Servicing: Helios's short payment from Coastal Grocers, applied through the same cash-application rules; the
-- $3,150 damaged-goods deduction is over the tolerance, so trg_cash_posting opens a DEDUCTION_REVIEW case (above Sofia
-- Alvarez's $2,500 limit -> OVER_AUTHORITY demo).
INSERT INTO cash_applications (client_id, payment_ref, remittance_text, currency, invoice_list, invoices_total, payment_amount,
                               discount_allowed, discount_accepted, deductions, ignored_items, disputed_amount, auto_write_off,
                               review_amount, agent_confidence, agent_notes, created_at, expires_at)
SELECT 'CLI-2026-00102', a.payment_ref, 'INV 7702 SHORT PAID 3150.00 DAMAGED GOODS CLAIM 88-14', a.currency, a.invoice_list,
       a.invoices_total, a.payment_amount, a.discount_allowed, a.discount_accepted, a.deductions, a.ignored_items,
       a.disputed_amount, a.auto_write_off, a.review_amount, a.confidence,
       'invoices: 7702' || chr(10) || 'deductions: DAMAGED_GOODS 3150.00' || chr(10) || 'confidence: HIGH' || chr(10)
       || 'explanation: The note names invoice 7702 and a damaged-goods claim 88-14 of 3,150.00; 65,000.00 less 3,150.00 '
       || 'reconciles to the payment.' || chr(10)
       || 'review_note: Deductions stay recorded as claims against the buyer until Aurelia Client Servicing accepts or rejects '
       || 'them; the invoice remains open for the disputed amount in the meantime.',
       now() - INTERVAL '1 day', now() - INTERVAL '1 day' + INTERVAL '15 minutes'
  FROM cash_assessment('CLI-2026-00102', 'PMT-2026-000015', '7702', 'DAMAGED_GOODS 3150.00', 'HIGH') a
 WHERE a.ok;
INSERT INTO cash_postings (application_id, posted_at)
SELECT c.application_id, now() - INTERVAL '1 day' FROM cash_applications c WHERE c.payment_ref = 'PMT-2026-000015';

-- Seed rows are not agent actions: start the audit trail empty.
TRUNCATE agent_audit RESTART IDENTITY;
