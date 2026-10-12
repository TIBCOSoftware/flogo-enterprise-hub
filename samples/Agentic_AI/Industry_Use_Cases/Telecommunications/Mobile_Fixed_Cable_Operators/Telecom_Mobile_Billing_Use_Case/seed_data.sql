-- Demo data for Tidewell Mobile - Mobile Billing & Spend Control (governed). Fictional operator, people and
-- numbers (555-01xx range). All dates are relative to CURRENT_DATE / now(): the current bill cycle is the current
-- calendar month and bills are issued on the 1st for the previous month, so the demo never goes stale.
-- Bills are due on the last day of the month they are issued in (the latest bill is never past due during the demo).
-- Included by database.sql and reset_data.sql via \ir - do not load on its own.

-- Date anchors for this load (temp table, dropped at the end).
DROP TABLE IF EXISTS _d;
CREATE TEMP TABLE _d AS
SELECT date_trunc('month', current_date)::date                          AS cyc,      -- current cycle start
       (date_trunc('month', current_date) - INTERVAL '1 month')::date   AS l_start,  -- latest bill period
       (date_trunc('month', current_date) - INTERVAL '1 day')::date     AS l_end,
       date_trunc('month', current_date)::date                          AS l_issue,
       (date_trunc('month', current_date) - INTERVAL '2 month')::date   AS p_start,  -- previous bill period
       (date_trunc('month', current_date) - INTERVAL '1 month' - INTERVAL '1 day')::date AS p_end,
       (date_trunc('month', current_date) - INTERVAL '1 month')::date   AS p_issue,
       date_trunc('month', now()) AS cyc_ts,
       now() - date_trunc('month', now()) AS into_cycle;                              -- time elapsed this cycle

-- ---------------------------------------------------------------------
-- Catalogue (USD per month, before taxes & fees; unlimited talk & text on every plan)
-- ---------------------------------------------------------------------
INSERT INTO plans (plan_code, plan_name, data_gb, monthly_price, roaming_included, is_device, device_months) VALUES
 ('BASIC5',   'Tidewell Basic 5GB',               5,    30.00, 'Not included - TravelPass $10/day or pay-per-use', FALSE, 0),
 ('ESS15',    'Tidewell Essential 15GB',          15,   45.00, 'Not included - TravelPass $10/day or pay-per-use', FALSE, 0),
 ('UNLPLUS',  'Tidewell Unlimited Plus',          NULL, 65.00, 'Not included - TravelPass $10/day or pay-per-use', FALSE, 0),
 ('UNLPREM',  'Tidewell Unlimited Premium',       NULL, 85.00, 'Mexico & Canada included; elsewhere TravelPass $10/day or pay-per-use', FALSE, 0),
 ('UNLPLUSD', 'Tidewell Unlimited Plus + device', NULL, 85.00, 'Not included - TravelPass $10/day or pay-per-use', TRUE, 36);

INSERT INTO case_routing (request_type, label, team, sla_business_days, sla_text) VALUES
 ('contract_cancellation', 'service cancellation', 'Retention',        1, 'A Retention specialist will contact you within 1 business day.'),
 ('port_out',              'number transfer',      'Retention',        1, 'A Retention specialist will contact you within 1 business day.'),
 ('billing_dispute',       'billing dispute',      'Billing Disputes', 5, 'Our Billing Disputes team will review this and reply within 5 business days.'),
 ('suspected_fraud',       'suspected fraud',      'Fraud Team',       1, 'Our Fraud Team will contact you within 1 business day.');

-- ---------------------------------------------------------------------
-- Customers - one persona per story / reason code (SPEC section 7)
-- ---------------------------------------------------------------------
INSERT INTO customers (customer_id, mobile_number, otp_code, first_name, last_name, email, ssn, plan_code,
                       device_installment_end, roaming_limit, travel_pass_since, autopay_day, last_sim_swap_at,
                       fraud_flag, risk_score, internal_notes, account_opened) VALUES
 ('TW-C-0101', '2125550101', '4821', 'Maria', 'Lopez',  'maria.lopez@example.com',  '900-71-4417', 'ESS15',
   NULL, NULL, NULL, 21, NULL, FALSE, 12, 'INTERNAL: loyal since 2019; eligible for retention offer tier B', current_date - 2400),
 ('TW-C-0102', '2125550102', '7305', 'James', 'Carter', 'james.carter@example.com', '900-58-2093', 'UNLPLUS',
   NULL, 50.00, NULL, 21, NULL, FALSE, 68, 'INTERNAL: collections stage 2; promise-to-pay missed twice', current_date - 1500),
 ('TW-C-0103', '2125550103', '9164', 'Priya', 'Shah',   'priya.shah@example.com',   '900-36-7781', 'UNLPLUSD',
   (current_date + INTERVAL '30 months')::date, NULL, NULL, 21,
   (SELECT l_end FROM _d) - INTERVAL '5 days' + INTERVAL '14 hours', FALSE, 41,
   'INTERNAL: SIM swap done at a partner store; store agent under review', current_date - 900),
 ('TW-C-0104', '2125550104', '2210', 'Kevin', 'Brooks', 'kevin.brooks@example.com', '900-24-5530', 'UNLPLUS',
   NULL, 100.00, (current_date - 120)::timestamp + INTERVAL '10 hours', 21, NULL, FALSE, 35,
   'INTERNAL: frequent traveller; upsell candidate', current_date - 400),
 ('TW-C-0105', '2125550105', '6634', 'Dana',  'Miller', 'dana.miller@example.com',  '900-83-1146', 'ESS15',
   NULL, NULL, NULL, 21, NULL, TRUE, 92, 'INTERNAL: account takeover suspected - hold until Fraud Team clears', current_date - 3000);

-- ---------------------------------------------------------------------
-- Bills (latest = previous calendar month, issued on the 1st, due the last day of that month) + lines + payments
-- ---------------------------------------------------------------------
INSERT INTO bills (bill_id, customer_id, period_start, period_end, issue_date, due_date)
SELECT 'TWB-' || v.n || '-' || to_char(CASE v.which WHEN 'L' THEN d.l_start ELSE d.p_start END, 'YYMM'), v.cust,
       CASE v.which WHEN 'L' THEN d.l_start ELSE d.p_start END,
       CASE v.which WHEN 'L' THEN d.l_end   ELSE d.p_end   END,
       CASE v.which WHEN 'L' THEN d.l_issue ELSE d.p_issue END,
       (date_trunc('month', CASE v.which WHEN 'L' THEN d.l_issue ELSE d.p_issue END) + INTERVAL '1 month' - INTERVAL '1 day')::date
  FROM _d d CROSS JOIN (VALUES ('0101','TW-C-0101','P'), ('0101','TW-C-0101','L'),
                               ('0102','TW-C-0102','L'),
                               ('0103','TW-C-0103','P'), ('0103','TW-C-0103','L'),
                               ('0104','TW-C-0104','P'), ('0104','TW-C-0104','L'),
                               ('0105','TW-C-0105','P'), ('0105','TW-C-0105','L')) v(n, cust, which);
-- James's older bill: unpaid and exactly 45 days past due (dates anchored on the due date).
INSERT INTO bills (bill_id, customer_id, period_start, period_end, issue_date, due_date)
SELECT 'TWB-0102-' || to_char(current_date - 89, 'YYMM'), 'TW-C-0102', current_date - 89, current_date - 60, current_date - 59, current_date - 45;

-- helper: bill id of a customer's latest (L) / previous (P) bill
CREATE OR REPLACE FUNCTION pg_temp.bid(p_n TEXT, p_which TEXT) RETURNS TEXT AS $$
  SELECT 'TWB-' || p_n || '-' || to_char(CASE p_which WHEN 'L' THEN (date_trunc('month', current_date) - INTERVAL '1 month')
                                                     ELSE (date_trunc('month', current_date) - INTERVAL '2 month') END, 'YYMM')
$$ LANGUAGE sql STABLE;

INSERT INTO bill_lines (bill_id, category, description, amount, charge_date)
SELECT pg_temp.bid(v.n, v.which), v.category, v.description, v.amount,
       (CASE v.which WHEN 'L' THEN d.l_start ELSE d.p_start END) + v.day_offset
  FROM _d d CROSS JOIN (VALUES
   -- Maria: previous $52.00 -> latest $270.00
   --   pay-per-use roaming in Mexico (4-day trip): data 85 MB x $2.05 = $174.25, calls 18 min x $1.79 = $32.22
   --   + StarPlay Games $9.99/month (premium content she did not knowingly sign up for) + taxes & fees $8.54
   ('0101','P','PLAN','Tidewell Essential 15GB - monthly plan', 45.00, 0),
   ('0101','P','TAXES_FEES','Taxes, surcharges & fees', 7.00, 0),
   ('0101','L','PLAN','Tidewell Essential 15GB - monthly plan', 45.00, 0),
   ('0101','L','PREMIUM_CONTENT','StarPlay Games (Pixelridge Media) - monthly subscription', 9.99, 5),
   ('0101','L','ROAMING','Pay-per-use roaming data, Mexico, 20 MB @ $2.05/MB', 41.00, 11),
   ('0101','L','ROAMING','Pay-per-use roaming calls, Mexico, 10 min @ $1.79/min', 17.90, 11),
   ('0101','L','ROAMING','Pay-per-use roaming data, Mexico, 25 MB @ $2.05/MB', 51.25, 12),
   ('0101','L','ROAMING','Pay-per-use roaming data, Mexico, 22 MB @ $2.05/MB', 45.10, 13),
   ('0101','L','ROAMING','Pay-per-use roaming calls, Mexico, 8 min @ $1.79/min', 14.32, 13),
   ('0101','L','ROAMING','Pay-per-use roaming data, Mexico, 18 MB @ $2.05/MB', 36.90, 14),
   ('0101','L','TAXES_FEES','Taxes, surcharges & fees', 8.54, 0),
   -- James: latest bill (not yet due) carries a late fee for the past-due older bill below
   ('0102','L','PLAN','Tidewell Unlimited Plus - monthly plan', 65.00, 0),
   ('0102','L','LATE_FEE','Late payment fee', 10.00, 0),
   ('0102','L','TAXES_FEES','Taxes, surcharges & fees', 7.30, 0),
   -- Priya: device installment plan; Canada roaming charges are added below (no roaming days, right after a SIM swap)
   ('0103','P','PLAN','Tidewell Unlimited Plus + device - monthly plan incl. device installment', 85.00, 0),
   ('0103','P','TAXES_FEES','Taxes, surcharges & fees', 9.10, 0),
   ('0103','L','PLAN','Tidewell Unlimited Plus + device - monthly plan incl. device installment', 85.00, 0),
   ('0103','L','TAXES_FEES','Taxes, surcharges & fees', 9.10, 0),
   -- Kevin: was on Essential 15GB until his upgrade this cycle
   ('0104','P','PLAN','Tidewell Essential 15GB - monthly plan', 45.00, 0),
   ('0104','P','TAXES_FEES','Taxes, surcharges & fees', 7.00, 0),
   ('0104','L','PLAN','Tidewell Essential 15GB - monthly plan', 45.00, 0),
   ('0104','L','TAXES_FEES','Taxes, surcharges & fees', 7.00, 0),
   -- Dana
   ('0105','P','PLAN','Tidewell Essential 15GB - monthly plan', 45.00, 0),
   ('0105','P','TAXES_FEES','Taxes, surcharges & fees', 7.00, 0),
   ('0105','L','PLAN','Tidewell Essential 15GB - monthly plan', 45.00, 0),
   ('0105','L','TAXES_FEES','Taxes, surcharges & fees', 7.00, 0)
  ) v(n, which, category, description, amount, day_offset);

-- Priya's Canada roaming charges ($96.32): 2 days after the SIM swap, with NO roaming days on record (fraud signal).
INSERT INTO bill_lines (bill_id, category, description, amount, charge_date)
SELECT pg_temp.bid('0103','L'), 'ROAMING', v.description, v.amount, d.l_end - 3
  FROM _d d CROSS JOIN (VALUES ('Pay-per-use roaming data, Canada, 40 MB @ $2.05/MB', 82.00),
                               ('Pay-per-use roaming calls, Canada, 8 min @ $1.79/min', 14.32)) v(description, amount);

-- James's older, past-due bill: $186.40 (a Canada trip before he set his $50 roaming limit).
INSERT INTO bill_lines (bill_id, category, description, amount, charge_date)
SELECT 'TWB-0102-' || to_char(current_date - 89, 'YYMM'), v.category, v.description, v.amount, current_date - 89 + v.day_offset
  FROM (VALUES ('PLAN','Tidewell Unlimited Plus - monthly plan', 65.00, 0),
               ('ROAMING','Pay-per-use roaming data, Canada, 40 MB @ $2.05/MB', 82.00, 9),
               ('ROAMING','Pay-per-use roaming calls, Canada, 15 min @ $1.79/min', 26.85, 10),
               ('TAXES_FEES','Taxes, surcharges & fees', 12.55, 0)) v(category, description, amount, day_offset);

-- Payments: every previous bill was paid by AutoPay on its due date. Latest bills are not due yet (unpaid).
-- James's older bill was never paid.
INSERT INTO payments (customer_id, bill_id, payment_date, amount, method, reference)
SELECT b.customer_id, b.bill_id, least(b.due_date, current_date), bill_total(b.bill_id), 'AutoPay',
       'AP-' || replace(b.bill_id, 'TWB-', '')
  FROM bills b WHERE b.customer_id <> 'TW-C-0102' AND b.issue_date < (SELECT l_issue FROM _d);
INSERT INTO payments (customer_id, bill_id, payment_date, amount, method, reference) VALUES
 ('TW-C-0102', NULL, current_date - 95, 71.80, 'Card', 'CARD-0102-OLD');

-- ---------------------------------------------------------------------
-- Roaming days (network records), usage, current-cycle charges, subscriptions, plan changes
-- ---------------------------------------------------------------------
-- Maria really was in Mexico for 4 days last month. James was in Canada for his older bill. Priya: none.
INSERT INTO roaming_days (customer_id, roam_date, country, data_mb, voice_min)
SELECT 'TW-C-0101', d.l_start + v.off, 'Mexico', v.mb, v.mins
  FROM _d d CROSS JOIN (VALUES (11, 20, 10), (12, 25, 0), (13, 22, 8), (14, 18, 0)) v(off, mb, mins)
UNION ALL
SELECT 'TW-C-0102', current_date - 89 + v.off, 'Canada', v.mb, v.mins
  FROM (VALUES (9, 40, 0), (10, 0, 15)) v(off, mb, mins)
UNION ALL   -- Kevin (TravelPass): 1 day in Canada on the 1st of this cycle
SELECT 'TW-C-0104', d.cyc, 'Canada', 350, 12 FROM _d d;

INSERT INTO unbilled_charges (customer_id, charge_date, category, description, amount)
SELECT 'TW-C-0104', d.cyc, 'TRAVEL_PASS', 'TravelPass - Canada, 1 day', 10.00 FROM _d d;

INSERT INTO usage_cycles (customer_id, cycle_start, data_used_gb, voice_used_min, sms_used)
SELECT v.cust, (date_trunc('month', current_date) - make_interval(months => v.ago))::date, v.gb, v.mins, v.sms
  FROM (VALUES
   ('TW-C-0101', 3, 11.8, 310, 120), ('TW-C-0101', 2, 12.6, 290, 135), ('TW-C-0101', 1, 13.9, 340, 150), ('TW-C-0101', 0, 5.2, 120, 48),
   ('TW-C-0102', 3, 22.4, 420, 60),  ('TW-C-0102', 2, 25.1, 455, 58),  ('TW-C-0102', 1, 23.7, 430, 61),  ('TW-C-0102', 0, 9.8, 160, 20),
   ('TW-C-0103', 3, 31.0, 510, 90),  ('TW-C-0103', 2, 28.4, 480, 85),  ('TW-C-0103', 1, 30.2, 495, 88),  ('TW-C-0103', 0, 12.5, 190, 30),
   ('TW-C-0104', 3, 14.1, 260, 70),  ('TW-C-0104', 2, 14.8, 275, 66),  ('TW-C-0104', 1, 14.6, 268, 72),  ('TW-C-0104', 0, 6.3, 95, 25),
   ('TW-C-0105', 3,  6.2, 150, 40),  ('TW-C-0105', 2,  5.8, 140, 38),  ('TW-C-0105', 1,  6.6, 160, 41),  ('TW-C-0105', 0, 2.1, 50, 12)
  ) v(cust, ago, gb, mins, sms);

INSERT INTO content_subscriptions (subscription_id, customer_id, service_name, provider, monthly_price, start_date, status, cancelled_at)
SELECT 'SUB-1001', 'TW-C-0101', 'StarPlay Games', 'Pixelridge Media', 9.99, d.l_start + 5, 'ACTIVE', NULL FROM _d d
UNION ALL
SELECT 'SUB-1002', 'TW-C-0101', 'Daily Horoscope', 'AstroText', 2.99, current_date - 200, 'CANCELLED', (current_date - 120)::timestamp FROM _d d
UNION ALL
SELECT 'SUB-2001', 'TW-C-0102', 'Score Alerts Plus', 'GoalFlash', 4.99, current_date - 300, 'CANCELLED', (current_date - 150)::timestamp FROM _d d;

-- Kevin already changed plan this cycle (ESS15 -> UNLPLUS) -> CHANGE_PENDING on any further change.
INSERT INTO plan_changes (customer_id, from_plan, to_plan, change_type, requested_at, effective_date, status)
SELECT 'TW-C-0104', 'ESS15', 'UNLPLUS', 'UPGRADE', d.cyc_ts + d.into_cycle * 0.4, (d.cyc_ts + d.into_cycle * 0.4)::date, 'APPLIED' FROM _d d;

-- Readable references: TW-ACT-000101..., TW-CASE-000041...
SELECT setval(pg_get_serial_sequence('account_events', 'event_id'), 100);
SELECT setval(pg_get_serial_sequence('service_cases', 'case_no'), 40);

DROP TABLE _d;
