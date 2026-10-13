-- Demo data for Harborline Life & Retirement - Life & Retirement Member Services (governed). Fictional company,
-- people, employers and numbers (555-01xx range, 900-series SSN-like numbers). Volatile dates are relative to
-- CURRENT_DATE / now(), so the demo never goes stale.
-- Included by database.sql and reset_data.sql via \ir - do not load on its own.

-- ---------------------------------------------------------------------
-- Plan rules, fund lineup, routing
-- ---------------------------------------------------------------------
INSERT INTO plan_limits (id, irs_deferral_limit, catchup_limit, catchup_age, plan_max_rate) VALUES (1, 23500, 7500, 50, 15);

INSERT INTO funds (fund_id, fund_name, category, risk_level, ytd_return, one_yr_return, three_yr_return, expense_ratio, nav, open_to_new_money) VALUES
 ('FND-001', 'Aggressive Growth Equity Fund', 'Equity',       'High',   14.20, 18.50, 12.10, 0.850, 42.15, TRUE),
 ('FND-002', 'US Large-Cap Index Fund',       'Index',        'Medium', 11.50, 15.20, 10.80, 0.040, 88.40, TRUE),
 ('FND-003', 'Total Bond Market Fund',        'Bond',         'Low',     3.20,  4.10,  2.50, 0.050, 10.85, TRUE),
 ('FND-004', 'Balanced Allocation Fund',      'Balanced',     'Medium',  7.80,  9.50,  6.90, 0.350, 25.60, TRUE),
 ('FND-005', 'Target Retirement 2045 Fund',   'Target Date',  'Medium',  9.10, 11.80,  8.20, 0.150, 33.20, TRUE),
 ('FND-006', 'Money Market Fund',             'Money Market', 'Low',     4.90,  5.10,  3.80, 0.110,  1.00, TRUE),
 ('FND-007', 'International Equity Fund',     'Equity',       'High',   10.30, 13.70,  7.50, 0.550, 29.75, TRUE),
 ('FND-008', 'Dividend Value Fund',           'Equity',       'Medium',  8.60, 10.90,  8.00, 0.400, 51.30, TRUE),
 ('FND-009', 'Short-Term Treasury Fund',      'Bond',         'Low',     2.80,  3.50,  2.10, 0.080, 20.10, TRUE),
 ('FND-010', 'Target Retirement 2035 Fund',   'Target Date',  'Medium',  8.30, 10.50,  7.60, 0.150, 28.90, TRUE),
 ('FND-011', 'Sector Opportunities Fund',     'Equity',       'High',    5.40,  6.20,  1.90, 0.950, 17.60, FALSE);   -- closed to new money

INSERT INTO case_routing (request_type, label, team, sla_business_days, sla_text, member_openable) VALUES
 ('claim_decision',      'claim decision',          'Claims Examination',           10, 'A claims examiner decides within 10 business days.', FALSE),
 ('claim_appeal',        'claim appeal',            'Claims Examination',            5, 'A claims examiner who did not make the original decision replies within 5 business days.', TRUE),
 ('withdrawal_rollover', 'withdrawal or rollover',  'Policy & Retirement Services',  3, 'Our Policy & Retirement Services team replies within 3 business days.', TRUE),
 ('beneficiary_change',  'beneficiary change',      'Policy & Retirement Services',  5, 'Our Policy & Retirement Services team sends you the beneficiary form within 5 business days.', TRUE),
 ('investment_advice',   'investment advice',       'Member Care',                   2, 'A licensed adviser from Member Care calls you within 2 business days.', TRUE),
 ('complaint',           'complaint',               'Member Care',                   5, 'Member Care replies to complaints within 5 business days.', TRUE);

-- ---------------------------------------------------------------------
-- Agent reference tables (read-only for the A2A agents via ref_* functions; no member or staff data).
-- The WHO_DECIDES / WHO_HELPS rows come from case_routing above, not from these tables.
-- ---------------------------------------------------------------------
-- claim_intake_agent -> ref_claim_checklist()
INSERT INTO claim_intake_guide (section, term, meaning) VALUES
 ('CLAIM_TYPE',     'CriticalIllness',      'a diagnosis of a covered critical illness such as cancer, heart attack, stroke or major organ failure, claimed under a Critical Illness policy'),
 ('CLAIM_TYPE',     'IncomeProtection',     'the member is unable to work because of illness or injury and has been signed off by a doctor, claimed under an Income Protection policy'),
 ('CLAIM_TYPE',     'NotClaimableHere',     'a life (death) claim - made by the beneficiary, not the member - or anything not covered by the member''s products, or a story that is unclear'),
 ('PRODUCT',        'Critical Illness',     'pays a lump sum when a covered critical illness is diagnosed - claim type CriticalIllness'),
 ('PRODUCT',        'Income Protection',    'pays a monthly benefit while the member cannot work, after the 90-day wait - claim type IncomeProtection'),
 ('PRODUCT',        'Term Life',            'pays the beneficiary when the member dies; the beneficiary makes that claim, not the member - NotClaimableHere'),
 ('PRODUCT',        'Whole Life',           'pays the beneficiary when the member dies; the beneficiary makes that claim, not the member - NotClaimableHere'),
 ('DOCUMENT',       'CriticalIllness - attending physician''s statement', 'attending physician''s statement with the diagnosis and the date of diagnosis'),
 ('DOCUMENT',       'CriticalIllness - specialist report',   'specialist report, pathology or test results confirming the diagnosis'),
 ('DOCUMENT',       'CriticalIllness - discharge summary',   'hospital discharge summary if the member was admitted'),
 ('DOCUMENT',       'CriticalIllness - claim form',          'completed claim form'),
 ('DOCUMENT',       'IncomeProtection - attending physician''s statement', 'attending physician''s statement with the date the member stopped work and the expected return date'),
 ('DOCUMENT',       'IncomeProtection - employer statement', 'employer statement of absence and earnings'),
 ('DOCUMENT',       'IncomeProtection - claim form',         'completed claim form'),
 ('DOCUMENT',       'IncomeProtection - last pay stub',      'last pay stub before the absence'),
 ('DOCUMENT',       'NotClaimableHere - death certificate',  'life claims are made by the beneficiary with a certified death certificate - a person at Harborline helps with these'),
 ('WAITING_PERIOD', 'Income Protection',    'Income Protection benefits start only after 90 consecutive days unable to work (the 90-day waiting period)'),
 ('RULE',           'who decides',          'Harborline''s systems check the policy and a claims examiner decides every claim - never decide or hint at eligibility, payment, amounts or approval'),
 ('RULE',           'no active policy',     'if the member holds no Active policy of the matching type, still give the matching claim type; Harborline''s system checks the policy'),
 ('RULE',           'documents_needed',     'list 2 to 5 documents for the chosen claim type; for NotClaimableHere say that a person at Harborline will help');

-- life_event_agent -> ref_life_event()
INSERT INTO life_event_guide (section, term, meaning) VALUES
 ('LIFE_EVENT',      'divorce',             'beneficiaries listed as Spouse on policies and the 401(k) may no longer reflect the member''s wishes; update marital status'),
 ('LIFE_EVENT',      'marriage',            'consider adding the new spouse as a beneficiary; under ERISA a spouse is generally the 401(k) beneficiary unless they consent otherwise; update marital status; revisit coverage amounts'),
 ('LIFE_EVENT',      'birth or adoption',   'consider adding the child as a primary or contingent beneficiary (often through a Trust for a minor); revisit life coverage amounts'),
 ('LIFE_EVENT',      'job change',          'options for the 401(k) with Harborline - leave it, roll it over to a new employer''s plan or to an IRA, or take a distribution; rollovers and withdrawals are handled by a person'),
 ('LIFE_EVENT',      'death of a spouse',   'beneficiaries listed as Spouse need replacing; update marital status; a survivor claim is made by the beneficiary'),
 ('LIFE_EVENT',      'retirement',          'review withdrawal and income options for the 401(k) and IRAs, and beneficiaries'),
 ('RELATIONSHIP',    'Spouse',              'husband or wife'),
 ('RELATIONSHIP',    'Child',               'son or daughter'),
 ('RELATIONSHIP',    'Parent',              'mother or father'),
 ('RELATIONSHIP',    'Sibling',             'brother or sister'),
 ('RELATIONSHIP',    'Trust',               'a trust named as beneficiary'),
 ('RELATIONSHIP',    'Other',               'anyone else'),
 ('DESIGNATION',     'Primary',             'primary beneficiaries are paid first'),
 ('DESIGNATION',     'Contingent',          'contingent beneficiaries are paid only if no primary beneficiary survives'),
 ('DESIGNATION',     'share percent',       'shares are percentages of the benefit and add up to 100 within each level (primary, contingent)'),
 ('SPOUSAL_CONSENT', '401(k) beneficiary',  'in a 401(k) plan the spouse is the default beneficiary (ERISA), so naming anyone else needs the spouse''s written, witnessed consent - this is why 401(k) beneficiary changes need a signed form'),
 ('RULE',            'needs a person',      'beneficiary changes (signed form) and withdrawals or rollovers need a person; investment advice needs a licensed adviser'),
 ('RULE',            'no advice',           'never give legal, tax or investment advice'),
 ('RULE',            'nothing changes',     'a checklist changes nothing - never say that a change has been made');

-- appeal_summary_agent -> ref_appeal_guide()
INSERT INTO appeal_review_guide (section, term, meaning) VALUES
 ('DENIAL_REASON',  'WAITING_PERIOD_NOT_MET',        'the member was not unable to work for the full waiting period before the claim date, as recorded'),
 ('DENIAL_REASON',  'INSUFFICIENT_MEDICAL_EVIDENCE', 'the medical evidence on file did not support the claim'),
 ('DENIAL_REASON',  'PRE_EXISTING_CONDITION',        'the condition existed before the policy started and is excluded by the policy'),
 ('DENIAL_REASON',  'POLICY_LAPSED',                 'the policy was not in force on the date of the claim event'),
 ('DENIAL_REASON',  'NOT_A_COVERED_CONDITION',       'the condition is not one the policy covers'),
 ('DENIAL_REASON',  'EXAMINER_DECISION',             'a claims examiner denied the claim after reviewing it; the examiner''s reason is the denial text recorded with it'),
 ('WAITING_PERIOD', 'waiting period',                'the number of consecutive days the member must be unable to work, as certified by a physician, before Income Protection benefits start'),
 ('WAITING_PERIOD', 'elimination period',            'another name for the waiting period; for Harborline Income Protection it is 90 days'),
 ('NEW_EVIDENCE',   'what counts',                   'information that was not in the claim file when it was decided'),
 ('NEW_EVIDENCE',   'physician''s statement',        'a new or corrected physician''s statement'),
 ('NEW_EVIDENCE',   'specialist or test reports',    'specialist or test reports'),
 ('NEW_EVIDENCE',   'employer records',              'employer records of the absence'),
 ('NEW_EVIDENCE',   'hospital records',              'hospital records'),
 ('NEW_EVIDENCE',   'restatement',                   'a restatement of the original claim is not new evidence'),
 ('FAIR_REVIEW',    'full and fair review',          'ERISA-style: an appeal is reviewed by a different person from the one who made the original decision, who looks at all the evidence, including anything new'),
 ('BRIEF_RULE',     'neutral',                       'the brief is neutral: it never recommends approving or rejecting and never predicts the outcome'),
 ('BRIEF_RULE',     'dates and amounts',             'never compute amounts or count days between dates; quote dates and periods exactly as given'),
 ('BRIEF_RULE',     'member statements',             'report what the member says as their statement ("the member says ..."), not as fact');

-- ---------------------------------------------------------------------
-- Members (login: member ID + one-time code) and reviewers (login: staff ID + code)
-- ---------------------------------------------------------------------
INSERT INTO members (member_id, otp_code, first_name, last_name, email, ssn, date_of_birth, state, marital_status, employer, annual_salary, member_since) VALUES
 ('HLR-100101', '4821', 'James',    'Carter',   'james.carter@example.com',    '900-11-0101', '1984-03-14', 'CA', 'Divorced', 'Bayview Logistics',       96000,  '2012-06-01'),
 ('HLR-100102', '2468', 'Maria',    'Gonzalez', 'maria.gonzalez@example.com',  '900-11-0102', '1985-09-22', 'IL', 'Married',  'Lakeshore Analytics',    260000,  '2016-02-15'),
 ('HLR-100103', '1357', 'David',    'Chen',     'david.chen@example.com',      '900-11-0103', '1979-12-05', 'WA', 'Married',  'Cascade Medical Supply', 118000,  '2013-11-20'),
 ('HLR-100104', '5530', 'Susan',    'Miller',   'susan.miller@example.com',    '900-11-0104', '1990-07-30', 'MA', 'Single',   'Beacon Street Design',    72000,  '2020-08-10'),
 ('HLR-100105', '8642', 'Robert',   'Johnson',  'robert.johnson@example.com',  '900-11-0105', '1962-01-19', 'CO', 'Married',  'Front Range Utilities',  142000,  '2007-04-25'),
 ('HLR-100106', '7316', 'Linda',    'Williams', 'linda.williams@example.com',  '900-11-0106', '1974-11-11', 'TX', 'Widowed',  'Hill Country Schools',    84000,  '2011-09-05'),
 ('HLR-100107', '9753', 'Michael',  'Brown',    'michael.brown@example.com',   '900-11-0107', '1988-05-02', 'GA', 'Single',   'Peachtree Freight',       68000,  '2018-03-12'),
 ('HLR-100108', '3690', 'Jennifer', 'Davis',    'jennifer.davis@example.com',  '900-11-0108', '1983-08-17', 'FL', 'Married',  'Coral Bay Hospitality',   77000,  '2015-07-19'),
 ('HLR-100110', '1122', 'Patricia', 'Wilson',   'patricia.wilson@example.com', '900-11-0110', '1995-02-09', 'OR', 'Single',   'Rose City Software',      91000,  '2021-05-14');

INSERT INTO reviewers (reviewer_id, display_name, team, one_time_code, approval_limit, active) VALUES
 ('HLS-2041', 'Grace Okafor', 'Claims Examination',           '3141', 50000, TRUE),
 ('HLS-2057', 'Marcus Reed',  'Policy & Retirement Services', '2718',  5000, TRUE);

-- ---------------------------------------------------------------------
-- Policies and beneficiaries
-- ---------------------------------------------------------------------
INSERT INTO policies (policy_id, member_id, product_type, product_name, status, status_date, coverage_amount, premium, waiting_period_days, start_date, renewal_date) VALUES
 ('POL-1001', 'HLR-100101', 'TermLife',         '20-Year Term Life',        'Active',  NULL,                  500000, 45.00, NULL, '2015-06-01', '2035-06-01'),
 ('POL-1002', 'HLR-100101', 'CriticalIllness',  'Critical Illness Protect', 'Active',  NULL,                  100000, 28.50, NULL, '2018-04-10', '2028-04-10'),
 ('POL-1003', 'HLR-100101', 'IncomeProtection', 'Income Shield Plan',       'Active',  NULL,                    4000, 32.00,   90, '2019-01-15', '2029-01-15'),
 ('POL-1004', 'HLR-100102', 'WholeLife',        'Whole Life Secure',        'Active',  NULL,                  250000, 68.00, NULL, '2016-02-15', NULL),
 ('POL-1006', 'HLR-100103', 'IncomeProtection', 'Income Shield Plan',       'Active',  NULL,                    5500, 41.00,   90, '2014-06-01', '2034-06-01'),
 ('POL-1007', 'HLR-100103', 'TermLife',         '20-Year Term Life',        'Active',  NULL,                  400000, 52.00, NULL, '2014-06-01', '2034-06-01'),
 ('POL-1008', 'HLR-100104', 'CriticalIllness',  'Critical Illness Protect', 'Lapsed',  current_date - 45,      75000, 24.00, NULL, '2020-08-10', NULL),
 ('POL-1009', 'HLR-100105', 'CriticalIllness',  'Critical Illness Protect', 'Active',  NULL,                  150000, 62.00, NULL, '2010-05-01', '2030-05-01'),
 ('POL-1010', 'HLR-100105', 'WholeLife',        'Whole Life Secure',        'Active',  NULL,                  350000, 95.00, NULL, '2007-04-25', NULL),
 ('POL-1011', 'HLR-100106', 'IncomeProtection', 'Income Shield Plan',       'Active',  NULL,                    3800, 30.00,   90, '2016-01-10', '2036-01-10'),
 ('POL-1012', 'HLR-100106', 'TermLife',         '20-Year Term Life',        'Active',  NULL,                  450000, 58.00, NULL, '2011-09-05', '2031-09-05'),
 ('POL-1013', 'HLR-100107', 'TermLife',         '20-Year Term Life',        'Active',  NULL,                  200000, 22.00, NULL, '2018-03-12', '2038-03-12'),
 ('POL-1014', 'HLR-100108', 'IncomeProtection', 'Income Shield Plan',       'Active',  NULL,                    4500, 36.00,   90, '2015-07-19', '2035-07-19'),
 ('POL-1015', 'HLR-100108', 'TermLife',         '20-Year Term Life',        'Active',  NULL,                  300000, 31.00, NULL, '2015-07-19', '2035-07-19'),
 ('POL-1017', 'HLR-100110', 'CriticalIllness',  'Critical Illness Protect', 'Pending', current_date - 12,      75000, 26.00, NULL, current_date - 12, NULL),
 ('POL-1018', 'HLR-100107', 'CriticalIllness',  'Critical Illness Protect', 'Active',  NULL,                  120000, 27.00, NULL, '2019-09-01', '2029-09-01'),
 ('POL-1019', 'HLR-100107', 'IncomeProtection', 'Income Shield Plan',       'Active',  NULL,                    3500, 29.00,   90, '2019-09-01', '2029-09-01');

INSERT INTO beneficiaries (beneficiary_id, policy_id, beneficiary_name, relationship, share_pct, designation, date_added) VALUES
 ('BEN-001', 'POL-1001', 'Emily Carter',              'Spouse', 100, 'Primary',    '2015-06-01'),   -- James is now divorced
 ('BEN-002', 'POL-1002', 'Emily Carter',              'Spouse', 100, 'Primary',    '2018-04-10'),
 ('BEN-003', 'POL-1004', 'Carlos Gonzalez',           'Spouse', 100, 'Primary',    '2016-02-15'),
 ('BEN-004', 'POL-1007', 'Helen Chen',                'Spouse',  60, 'Primary',    '2014-06-01'),
 ('BEN-005', 'POL-1007', 'Ethan Chen',                'Child',   40, 'Primary',    '2014-06-01'),
 ('BEN-006', 'POL-1010', 'Nancy Johnson',             'Spouse', 100, 'Primary',    '2007-04-25'),
 ('BEN-007', 'POL-1012', 'The Williams Family Trust', 'Trust',  100, 'Primary',    '2011-09-05'),
 ('BEN-008', 'POL-1013', 'Karen Brown',               'Parent', 100, 'Primary',    '2018-03-12'),
 ('BEN-009', 'POL-1015', 'Mark Davis',                'Spouse', 100, 'Primary',    '2015-07-19');

-- ---------------------------------------------------------------------
-- Retirement accounts and holdings (balance = units x NAV)
-- ---------------------------------------------------------------------
INSERT INTO retirement_accounts (account_id, member_id, account_type, contribution_rate, employer_match_rate, vested_pct, opened_date) VALUES
 ('RET-5001', 'HLR-100101', '401(k)',          3, 6, 100, '2012-06-01'),   -- James: 3% while the match goes to 6%
 ('RET-5002', 'HLR-100101', 'Roth IRA',        NULL, NULL, 100, '2016-01-10'),
 ('RET-5003', 'HLR-100102', '401(k)',          8, 6, 100, '2016-02-15'),   -- Maria: high earner -> IRS limit at 12%
 ('RET-5004', 'HLR-100103', 'Traditional IRA', NULL, NULL, 100, '2013-11-20'),
 ('RET-5005', 'HLR-100105', '401(k)',          8, 6, 100, '2007-04-25'),   -- Robert: 64, $8,000 rollover case open
 ('RET-5006', 'HLR-100106', '401(k)',          5, 5, 100, '2011-09-05'),
 ('RET-5007', 'HLR-100107', 'Roth IRA',        NULL, NULL, 100, '2018-03-12'),
 ('RET-5008', 'HLR-100108', '401(k)',          4, 5,  80, '2015-07-19');

INSERT INTO holdings (account_id, fund_id, units) VALUES
 ('RET-5001', 'FND-001',  1500.0000),   -- $63,225 = 34.80% in a high-risk fund
 ('RET-5001', 'FND-002',   800.0000),   -- $70,720
 ('RET-5001', 'FND-003',  4400.0000),   -- $47,740
 ('RET-5002', 'FND-005',  1364.4578),
 ('RET-5003', 'FND-002',   650.0000),
 ('RET-5003', 'FND-004',  1593.7500),
 ('RET-5004', 'FND-008',  1200.0000),
 ('RET-5004', 'FND-003',  6067.2811),
 ('RET-5005', 'FND-005',  9500.0000),
 ('RET-5005', 'FND-003', 18147.0000),
 ('RET-5006', 'FND-002',  1500.0000),
 ('RET-5006', 'FND-003',  6571.4286),
 ('RET-5007', 'FND-001',   754.4484),
 ('RET-5008', 'FND-004',  1789.0625),
 ('RET-5008', 'FND-006', 30600.0000);

-- Semi-monthly payroll contributions (1st and 15th): the last 6 payrolls for every 401(k), plus IRA and premium rows.
INSERT INTO contributions (member_id, account_id, amount, contribution_type, contribution_date)
SELECT a.member_id, a.account_id, round(m.annual_salary * a.contribution_rate / 100 / 24, 2), 'Employee', p.dt
  FROM retirement_accounts a JOIN members m ON m.member_id = a.member_id
 CROSS JOIN LATERAL (SELECT dt::date FROM generate_series(date_trunc('month', current_date) - INTERVAL '4 months',
                                                          current_date::timestamp, INTERVAL '1 day') dt
                      WHERE extract(day FROM dt) IN (1, 15) ORDER BY dt DESC LIMIT 6) p
 WHERE a.account_type = '401(k)';
INSERT INTO contributions (member_id, account_id, amount, contribution_type, contribution_date)
SELECT c.member_id, c.account_id, round(m.annual_salary * least(a.contribution_rate, a.employer_match_rate) / 100 / 24, 2), 'Employer', c.contribution_date
  FROM contributions c JOIN retirement_accounts a ON a.account_id = c.account_id JOIN members m ON m.member_id = c.member_id
 WHERE c.contribution_type = 'Employee';
INSERT INTO contributions (member_id, account_id, policy_id, amount, contribution_type, contribution_date) VALUES
 ('HLR-100101', 'RET-5002', NULL, 583.33, 'Employee', date_trunc('month', current_date)::date),
 ('HLR-100101', NULL, 'POL-1001',   45.00, 'Premium',  date_trunc('month', current_date)::date),
 ('HLR-100101', NULL, 'POL-1003',   32.00, 'Premium',  date_trunc('month', current_date)::date),
 ('HLR-100101', 'RET-5002', NULL, 2000.00, 'Rollover', (date_trunc('year', current_date) + INTERVAL '14 days')::date),
 ('HLR-100106', NULL, 'POL-1011',   30.00, 'Premium',  date_trunc('month', current_date)::date),
 ('HLR-100107', 'RET-5007', NULL,  350.00, 'Employee', date_trunc('month', current_date)::date);

-- Year-to-date payroll deferrals = payrolls so far this year x per-paycheck amount.
UPDATE retirement_accounts a
   SET ytd_employee = round(m.annual_salary * a.contribution_rate / 100 / 24 * n.paychecks, 2),
       ytd_employer = round(m.annual_salary * least(a.contribution_rate, a.employer_match_rate) / 100 / 24 * n.paychecks, 2)
  FROM members m, (SELECT count(*) AS paychecks FROM generate_series(date_trunc('year', current_date), current_date::timestamp, INTERVAL '1 day') dt
                    WHERE extract(day FROM dt) IN (1, 15)) n
 WHERE m.member_id = a.member_id AND a.account_type = '401(k)';

-- ---------------------------------------------------------------------
-- Claims (James and Michael have none; Linda's was denied for the waiting period)
-- ---------------------------------------------------------------------
INSERT INTO claims (claim_id, policy_id, member_id, claim_type, amount, status, filed_date, incident_date, description,
                    documents_needed, denial_reason_code, denial_reason_text, approved_amount, decided_at, source) VALUES
 ('CLM-2026-0001', 'POL-1006', 'HLR-100103', 'IncomeProtection',   5500, 'UnderReview', current_date - 25, current_date - 120,
  'Signed off work with a lower back injury; claiming the monthly benefit.', 'attending physician statement; employer statement of absence',
  NULL, NULL, NULL, NULL, 'SEED'),
 ('CLM-2026-0002', 'POL-1009', 'HLR-100105', 'CriticalIllness',  150000, 'Paid',        current_date - 160, current_date - 175,
  'Cardiac diagnosis; critical illness lump sum.', NULL, NULL, NULL, 150000, now() - INTERVAL '140 days', 'SEED'),
 ('CLM-2026-0003', 'POL-1014', 'HLR-100108', 'IncomeProtection',   4500, 'Paid',        current_date - 210, current_date - 320,
  'Temporary disability after surgery; recovered.', NULL, NULL, NULL, 4500, now() - INTERVAL '190 days', 'SEED'),
 ('CLM-2026-0004', 'POL-1011', 'HLR-100106', 'IncomeProtection',   3800, 'Denied',      current_date - 40, current_date - 95,
  'Unable to work because of a heart condition; claiming the monthly benefit.', 'attending physician statement; employer statement of absence',
  'WAITING_PERIOD_NOT_MET',
  'The employer statement records ' || to_char(current_date - 95, 'YYYY-MM-DD') || ' as the date you stopped work, so the 90-day waiting period had not been met when the claim was filed.',
  NULL, now() - INTERVAL '20 days', 'SEED');

INSERT INTO claim_payments (payment_id, reference, claim_id, amount, case_id, paid_at) VALUES
 (1, 'HLR-PAY-000001', 'CLM-2026-0002', 150000, NULL, now() - INTERVAL '138 days'),
 (2, 'HLR-PAY-000002', 'CLM-2026-0003',   4500, NULL, now() - INTERVAL '188 days');

-- ---------------------------------------------------------------------
-- Already-OPEN cases so every reviewer queue has something in it
-- ---------------------------------------------------------------------
INSERT INTO service_cases (case_no, case_id, member_id, request_type, summary, reference_id, requested_amount, parked_action,
                           agent_brief, status, sla_due_at, created_at) VALUES
 (1, 'HLR-CASE-000001', 'HLR-100103', 'claim_decision',
  'Signed off work with a lower back injury; claiming the monthly benefit.', 'CLM-2026-0001', 5500, 'CLAIM_DECISION:CLM-2026-0001',
  'Claim intake (AI-prepared, not verified): claim type Income Protection. Documents to request: attending physician statement; employer statement of absence.',
  'OPEN', add_business_days((now() - INTERVAL '3 days')::timestamp, 10), now() - INTERVAL '3 days'),
 (2, 'HLR-CASE-000002', 'HLR-100105', 'withdrawal_rollover',
  'Would like to withdraw $8,000 from his 401(k) to pay for a roof repair.', 'RET-5005', 8000, 'WITHDRAWAL:RET-5005',
  NULL, 'OPEN', add_business_days((now() - INTERVAL '1 day')::timestamp, 3), now() - INTERVAL '1 day'),
 (3, 'HLR-CASE-000003', 'HLR-100108', 'beneficiary_change',
  'Wants to add her two children as contingent beneficiaries on her term life policy.', 'POL-1015', NULL, NULL,
  NULL, 'OPEN', add_business_days((now() - INTERVAL '2 days')::timestamp, 5), now() - INTERVAL '2 days');

-- New ids continue from 101 so demo-created rows stand out.
SELECT setval(pg_get_serial_sequence('service_cases', 'case_no'), 100);
SELECT setval(pg_get_serial_sequence('claim_payments', 'payment_id'), 100);
SELECT setval(pg_get_serial_sequence('withdrawals', 'withdrawal_id'), 100);
SELECT setval(pg_get_serial_sequence('account_events', 'event_id'), 100);
SELECT setval('claim_seq', 100);
