-- Demo data for Ridgeline Power & Light - Electric Outage & Billing (governed). Fictional utility, people, towns and
-- addresses (no ZIP codes). All dates are relative to CURRENT_DATE / now(): bills cover the last three calendar
-- months, are issued on the 1st and due on the last day of the issue month, so the demo never goes stale.
-- Included by database.sql and reset_data.sql via \ir - do not load on its own.

-- ---------------------------------------------------------------------
-- Catalogue and routing
-- ---------------------------------------------------------------------
INSERT INTO rate_plans (plan_code, plan_name, description, base_charge, energy_rate, on_peak_rate, off_peak_rate,
                        export_credit_rate, needs_smart_meter, needs_solar) VALUES
 ('STANDARD', 'Residential Standard',     'One flat energy price at any time of day.',                                   9.50, 0.0450, NULL,   NULL,   0,      FALSE, FALSE),
 ('TOU',      'Residential Time-of-Use',  'Lower price outside weekdays 2 PM - 8 PM; higher price during those hours.',  9.50, NULL,   0.0800, 0.0300, 0,      TRUE,  FALSE),
 ('EV',       'EV Time-of-Use',           'Built for overnight EV charging: the lowest off-peak price, the highest on-peak price (weekdays 2 PM - 8 PM).', 9.50, NULL, 0.0900, 0.0250, 0, TRUE, FALSE),
 ('SOLAR',    'Solar Net Metering',       'Flat energy price plus a credit for every kWh your solar panels send to the grid.', 10.00, 0.0450, NULL, NULL, 0.0450, TRUE, TRUE);

INSERT INTO case_routing (request_type, label, team, sla_hours, sla_text, parked_action) VALUES
 ('billing_dispute',     'Billing dispute or re-bill',  'Billing Review',       72,  'A billing analyst will reply within 3 business days.', 'BILL_CREDIT'),
 ('payment_arrangement', 'Payment arrangement',         'Credit & Collections', 48,  'Our Credit & Collections team will reply within 2 business days.', 'PAYMENT_PLAN'),
 ('medical_baseline',    'Medical-baseline protection', 'Customer Care',        120, 'Our Customer Care team will reply within 5 business days.', 'MEDICAL_BASELINE'),
 ('hazardous_condition', 'Hazardous condition',         'Emergency Dispatch',   1,   'A dispatcher acts within 1 hour. If anyone is in danger, call 911.', NULL);

-- ---------------------------------------------------------------------
-- Agent reference tables (read-only for the A2A agents via ref_* functions; no customer or staff data)
-- ---------------------------------------------------------------------
-- bill_explainer_agent -> ref_bill_glossary()
INSERT INTO bill_glossary (section, term, meaning) VALUES
 ('CATEGORY',   'base_charge',         'the fixed monthly charge of the rate plan (bill line BASE_CHARGE)'),
 ('CATEGORY',   'energy',              'kWh used times the plan''s price; time-of-use plans split it into on-peak and off-peak (bill lines ENERGY, ENERGY_ON_PEAK, ENERGY_OFF_PEAK)'),
 ('CATEGORY',   'power_cost_rider',    'a per-kWh charge for fuel and purchased power, the same on every plan (bill line POWER_COST_RIDER)'),
 ('CATEGORY',   'credits',             'solar export credits or approved bill credits, shown as negative amounts (bill lines SOLAR_CREDIT, BILL_CREDIT)'),
 ('CATEGORY',   'taxes_fees',          'taxes and regulatory fees, 7% of the other charges (bill line TAXES_FEES)'),
 ('CATEGORY',   'other',               'anything else on the bill'),
 ('LINE_ITEM',  'BASE_CHARGE',         'Base charge (plan name): the plan''s fixed monthly charge - the same however much electricity is used'),
 ('LINE_ITEM',  'ENERGY',              'Energy charge (kWh x price) on a flat-price plan; ", estimated read" in the description means the kWh were estimated, not read'),
 ('LINE_ITEM',  'ENERGY_ON_PEAK',      'On-peak energy (kWh x on-peak price) on a time-of-use plan: electricity used weekdays 2 PM - 8 PM'),
 ('LINE_ITEM',  'ENERGY_OFF_PEAK',     'Off-peak energy (kWh x off-peak price) on a time-of-use plan: electricity used at all other times'),
 ('LINE_ITEM',  'POWER_COST_RIDER',    'Power cost rider (kWh x $0.01311): fuel and purchased-power cost per kWh, the same on every plan, so it rises and falls with usage'),
 ('LINE_ITEM',  'SOLAR_CREDIT',        'Solar export credit (kWh the solar panels sent to the grid x the export credit price), a negative amount'),
 ('LINE_ITEM',  'BILL_CREDIT',         'a credit approved by Ridgeline staff (for example after a billing dispute), a negative amount'),
 ('LINE_ITEM',  'TAXES_FEES',          'Taxes & regulatory fees (7%): 7% of the other charges, so they rise when the other charges rise'),
 ('TOU_PERIOD', 'on-peak',             'weekdays 2 PM - 8 PM'),
 ('TOU_PERIOD', 'off-peak',            'everything else: weekday nights and mornings, and all weekend'),
 ('COLUMN',     'previous_amount / latest_amount', 'the category''s amount on the previous / latest bill'),
 ('COLUMN',     'delta',               'the change computed by Ridgeline''s systems (positive = higher now); never recompute it'),
 ('COLUMN',     'previous_total / latest_total',   'the two bill totals; quote them, never add the rows up'),
 ('COLUMN',     'latest_kwh / previous_kwh',       'electricity used in each billing month'),
 ('COLUMN',     'same_month_last_year_kwh',        'electricity used in the same month a year ago'),
 ('COLUMN',     'kwh_change_vs_last_year_pct',     'the change in kWh vs the same month a year ago, in percent'),
 ('WEATHER',    'cooling_degree_days', 'a weather measure of how hot the month was (higher = hotter, more air conditioning)'),
 ('WEATHER',    'cooling_degree_days_last_year',   'the same measure for the same month last year; compare it with cooling_degree_days'),
 ('READ_TYPE',  'ACTUAL',              'the meter was read'),
 ('READ_TYPE',  'ESTIMATED',           'the meter was not read and the usage was estimated, so the bill may be corrected after the next actual read');

-- outage_triage_agent -> ref_outage_triage()  (+ the hazard ROUTING row from case_routing)
INSERT INTO outage_triage_guide (section, term, meaning) VALUES
 ('CATEGORY',    'HAZARD',             'anything that can hurt someone (see the hazard signs) - always HAZARD, even if the power is also out'),
 ('CATEGORY',    'OUTAGE',             'no power at all at the home'),
 ('CATEGORY',    'PARTIAL_OUTAGE',     'some lights or circuits work and others do not, or very dim lights'),
 ('CATEGORY',    'FLICKERING',         'lights flicker or dim on and off, with no hazard'),
 ('CATEGORY',    'NOT_AN_OUTAGE',      'the service is DISCONNECTED or RECONNECT_PENDING (for example for non-payment), or the question is about a bill, not power'),
 ('HAZARD_SIGN', 'downed power line',  'HAZARD: a line on the ground, across a road, fence or car'),
 ('HAZARD_SIGN', 'low-hanging line',   'HAZARD: a line sagging low enough to touch'),
 ('HAZARD_SIGN', 'sparking or arcing', 'HAZARD: sparks, flashes or buzzing arcs from a line, pole or equipment'),
 ('HAZARD_SIGN', 'smoking or burning', 'HAZARD: smoke, flames or a burning smell from a line, meter or equipment'),
 ('HAZARD_SIGN', 'transformer fire or explosion', 'HAZARD: a transformer on fire, or a loud bang with sparks or fire'),
 ('HAZARD_SIGN', 'tree on a line',     'HAZARD: a tree or branch resting on a power line'),
 ('HAZARD_SIGN', 'water near live equipment', 'HAZARD: flood water around a meter, transformer or fallen line'),
 ('HAZARD_SIGN', 'someone shocked',    'HAZARD: a person or animal got an electric shock'),
 ('CONNECTION',  'CONNECTED',          'the service is on, so no power means a real outage'),
 ('CONNECTION',  'DISCONNECTED',       'Ridgeline switched the service off (for example for non-payment) - NOT_AN_OUTAGE'),
 ('CONNECTION',  'RECONNECT_PENDING',  'a reconnection is already scheduled - NOT_AN_OUTAGE'),
 ('NEXT_PATH',   'open_hazard_case',   'for HAZARD: a person in Emergency Dispatch must act now'),
 ('NEXT_PATH',   'report_outage',      'for OUTAGE or PARTIAL_OUTAGE, and FLICKERING right now with a known outage in the area: file an outage report (the system links it to a known area outage or opens a crew ticket)'),
 ('NEXT_PATH',   'book_inspection',    'for FLICKERING that keeps coming back with no known outage: offer a meter inspection'),
 ('NEXT_PATH',   'explain_only',       'for NOT_AN_OUTAGE: nothing to file, explain (for example a disconnected service)'),
 ('SAFETY_LINE', 'HAZARD',             'Stay at least 35 feet away and keep others away. If anyone is in danger or there is fire, call 911 now.'),
 ('SAFETY_LINE', 'OUTAGE / PARTIAL_OUTAGE', 'Unplug sensitive electronics and keep the fridge closed; never use a generator indoors.'),
 ('SAFETY_LINE', 'FLICKERING',         'If you smell burning or see sparks, switch off the main breaker and tell us right away.'),
 ('RULE',        'when in doubt',      'between HAZARD and anything else, choose HAZARD'),
 ('RULE',        'hazard and outage together', 'the category is HAZARD and the rationale mentions the outage too'),
 ('RULE',        'danger to a person or fire', 'always tell the customer to call 911 now, before anything else'),
 ('RULE',        'restoration times',  'never promise a crew time or restoration time that is not in the facts');

-- rate_plan_agent -> ref_rate_plans()  (+ the PLAN rows from rate_plans)
INSERT INTO rate_plan_notes (section, term, meaning) VALUES
 ('TOU_PERIOD',  'on-peak',               'weekdays 2 PM - 8 PM'),
 ('TOU_PERIOD',  'off-peak',              'everything else: weekday nights and mornings, and all weekend'),
 ('COLUMN',      'rates',                 'the plan''s prices'),
 ('COLUMN',      'needs',                 'what the plan requires (a smart meter; solar panels on file)'),
 ('COLUMN',      'est_monthly_cost',      'Ridgeline''s estimate of the plan''s monthly base + energy charges on the customer''s last 3 bills (riders and taxes are the same on every plan and left out)'),
 ('COLUMN',      'current_plan_est_cost', 'the same estimate for the current plan'),
 ('COLUMN',      'est_monthly_savings',   'current minus this plan, as computed by Ridgeline (positive = cheaper than now; negative = dearer)'),
 ('COLUMN',      'is_current',            'yes for the current plan'),
 ('COLUMN',      'eligible',              'yes means the customer can switch now; no comes with a reason_code'),
 ('COLUMN',      'effective_date',        'when a switch would start: the next bill cycle'),
 ('REASON_CODE', 'NO_CHANGE',             'already the current plan'),
 ('REASON_CODE', 'SMART_METER_REQUIRED',  'the plan bills by time of day and needs a smart meter; a free smart-meter upgrade can be booked first'),
 ('REASON_CODE', 'NO_SOLAR',              'the plan is for homes with solar panels on file, and there are none'),
 ('REASON_CODE', 'CHANGE_PENDING',        'a plan change is already scheduled; only one change can be pending at a time'),
 ('ELIGIBILITY', 'smart meter',           'TOU, EV and SOLAR need a smart meter; STANDARD works with any meter'),
 ('ELIGIBILITY', 'solar panels',          'SOLAR also needs solar panels on file'),
 ('ELIGIBILITY', 'confirmation',          'nothing changes until the customer confirms the plan change'),
 ('HABIT',       'overnight EV charging', 'TOU and EV plans reward it (off-peak); EV has the cheapest off-peak price'),
 ('HABIT',       'heavy afternoon use',   'costs more on TOU and EV plans, which charge their highest price weekdays 2 PM - 8 PM'),
 ('HABIT',       'shifting laundry or dishwashing to the evening', 'moves use off-peak after 8 PM, which lowers TOU and EV bills'),
 ('HABIT',       'new habits',            'the estimates use past usage; new habits (such as a new EV or shifting laundry) change future bills - describe them in words only, never a new number');

INSERT INTO reviewers (reviewer_id, display_name, team, one_time_code, approval_limit) VALUES
 ('RPL-S-201', 'Avery Collins', 'Billing Review',       '5150', 200.00),
 ('RPL-S-305', 'Jordan Lee',    'Credit & Collections', '7720', 100.00);

-- ---------------------------------------------------------------------
-- Customers (account number + one-time code are the demo logins)
-- ---------------------------------------------------------------------
INSERT INTO customers (customer_id, otp_code, first_name, last_name, email, service_address, service_area, meter_number,
                       meter_type, connection_status, disconnected_on, plan_code, solar_installed, medical_baseline, autopay,
                       credit_risk_score, internal_notes, customer_since) VALUES
 ('RPL-100101', '4821', 'Laura',  'Bennett', 'laura.bennett@example.com',  '412 Cedar Ridge Rd, Oak Hollow, TX',   'Oak Hollow',  'MTR-200101', 'SMART',  'CONNECTED',    NULL, 'STANDARD', FALSE, FALSE, TRUE,  12, 'Prefers email.', current_date - 2900),
 ('RPL-100102', '6634', 'Marcus', 'Reed',    'marcus.reed@example.com',    '88 Willow Bend Dr, Mesa Verde, TX',    'Mesa Verde',  'MTR-200102', 'SMART',  'CONNECTED',    NULL, 'EV',       FALSE, FALSE, TRUE,  8,  NULL, current_date - 1500),
 ('RPL-100103', '5577', 'Priya',  'Nair',    'priya.nair@example.com',     '1507 Sunflower Ln, Cedar Bluff, TX',   'Cedar Bluff', 'MTR-200103', 'SMART',  'CONNECTED',    NULL, 'SOLAR',    TRUE,  FALSE, TRUE,  6,  NULL, current_date - 2100),
 ('RPL-100104', '4402', 'Diane',  'Foster',  'diane.foster@example.com',   '23 Prairie View Ct, Oak Hollow, TX',   'Oak Hollow',  'MTR-200104', 'SMART',  'CONNECTED',    NULL, 'STANDARD', FALSE, FALSE, FALSE, 15, 'Home oxygen concentrator.', current_date - 4000),
 ('RPL-100106', '9164', 'Grace',  'Kim',     'grace.kim@example.com',      '19 Birchwood Cir, Willow Creek, TX',   'Willow Creek','MTR-200106', 'ANALOG', 'CONNECTED',    NULL, 'STANDARD', FALSE, FALSE, FALSE, 10, 'Meter behind a locked gate.', current_date - 3300),
 ('RPL-100107', '7305', 'Henry',  'Wu',      'henry.wu@example.com',       '305 Aspen Trail, Pine Ridge, TX',      'Pine Ridge',  'MTR-200107', 'SMART',  'DISCONNECTED', (date_trunc('month', current_date) - INTERVAL '12 days')::date, 'STANDARD', FALSE, FALSE, FALSE, 71, 'Disconnected for non-payment.', current_date - 1200),
 ('RPL-100108', '8150', 'Olivia', 'Brooks',  'olivia.brooks@example.com',  '77 Magnolia St, Cedar Bluff, TX',      'Cedar Bluff', 'MTR-200108', 'SMART',  'CONNECTED',    NULL, 'STANDARD', FALSE, FALSE, TRUE,  9,  NULL, current_date - 800),
 ('RPL-100109', '6021', 'Samuel', 'Ortiz',   'samuel.ortiz@example.com',   '1120 Ranch Rd, Willow Creek, TX',      'Willow Creek','MTR-200109', 'SMART',  'CONNECTED',    NULL, 'STANDARD', FALSE, FALSE, FALSE, 14, NULL, current_date - 1700),
 ('RPL-100113', '1947', 'Nathan', 'Cole',    'nathan.cole@example.com',    '211 Meadowbrook Dr, Pine Ridge, TX',   'Pine Ridge',  'MTR-200113', 'SMART',  'CONNECTED',    NULL, 'STANDARD', FALSE, FALSE, FALSE, 55, 'Two missed payments.', current_date - 950),
 ('RPL-100115', '3388', 'Ethan',  'Mills',   'ethan.mills@example.com',    '870 Foxglove Ave, Cedar Bluff, TX',    'Cedar Bluff', 'MTR-200115', 'SMART',  'CONNECTED',    NULL, 'TOU',      FALSE, FALSE, TRUE,  11, NULL, current_date - 600),
 ('RPL-100116', '2210', 'Maria',  'Gonzalez','maria.gonzalez@example.com', '52 Sycamore Ln, Mesa Verde, TX',       'Mesa Verde',  'MTR-200116', 'SMART',  'DISCONNECTED', (date_trunc('month', current_date) - INTERVAL '20 days')::date, 'STANDARD', FALSE, FALSE, FALSE, 40, 'Paid in full after disconnection.', current_date - 1400);

-- ---------------------------------------------------------------------
-- Usage and bills: k = months back (1 = latest bill). on_share NULL = analog meter (no time-of-day data).
-- ---------------------------------------------------------------------
CREATE TEMP TABLE _u (cust TEXT, k INT, kwh NUMERIC, on_share NUMERIC, export_kwh NUMERIC, prior_kwh NUMERIC,
                      cdd INT, prior_cdd INT, read_type TEXT);
INSERT INTO _u VALUES
 ('RPL-100101',3,1320,0.25,0,1180,400,390,'ACTUAL'), ('RPL-100101',2,1540,0.25,0,1300,520,470,'ACTUAL'), ('RPL-100101',1,1850,0.25,0,1210,610,455,'ACTUAL'),
 ('RPL-100102',3,1290,0.15,0,1250,400,390,'ACTUAL'), ('RPL-100102',2,1240,0.15,0,1230,520,470,'ACTUAL'), ('RPL-100102',1,1420,0.15,0,1300,610,455,'ACTUAL'),
 ('RPL-100103',3, 980,0.30,640, 990,400,390,'ACTUAL'), ('RPL-100103',2,1050,0.30,600,1010,520,470,'ACTUAL'), ('RPL-100103',1,1120,0.30,620,1060,610,455,'ACTUAL'),
 ('RPL-100104',3,1100,0.30,0,1080,400,390,'ACTUAL'), ('RPL-100104',2,1250,0.30,0,1190,520,470,'ACTUAL'), ('RPL-100104',1,1400,0.30,0,1290,610,455,'ACTUAL'),
 ('RPL-100106',3,1090,NULL,0,1040,380,370,'ACTUAL'), ('RPL-100106',2,1180,NULL,0,1150,500,480,'ACTUAL'), ('RPL-100106',1,1700,NULL,0,1150,540,520,'ESTIMATED'),
 ('RPL-100107',3,2128,0.30,0,1900,560,500,'ACTUAL'), ('RPL-100107',2,1500,0.30,0,1450,520,470,'ACTUAL'), ('RPL-100107',1, 610,0.30,0,1500,610,455,'ACTUAL'),
 ('RPL-100108',3, 980,0.30,0, 950,400,390,'ACTUAL'), ('RPL-100108',2,1100,0.30,0,1040,520,470,'ACTUAL'), ('RPL-100108',1,1260,0.30,0,1180,610,455,'ACTUAL'),
 ('RPL-100109',3,1150,0.30,0,1100,380,370,'ACTUAL'), ('RPL-100109',2,1300,0.30,0,1240,500,480,'ACTUAL'), ('RPL-100109',1,1480,0.30,0,1400,540,520,'ACTUAL'),
 ('RPL-100113',3,1600,0.30,0,1550,560,500,'ACTUAL'), ('RPL-100113',2,1700,0.30,0,1620,520,470,'ACTUAL'), ('RPL-100113',1,1650,0.30,0,1600,610,455,'ACTUAL'),
 ('RPL-100115',3,1000,0.20,0, 980,400,390,'ACTUAL'), ('RPL-100115',2,1150,0.20,0,1100,520,470,'ACTUAL'), ('RPL-100115',1,1300,0.20,0,1220,610,455,'ACTUAL'),
 ('RPL-100116',3, 900,0.30,0, 880,400,390,'ACTUAL'), ('RPL-100116',2, 950,0.30,0, 920,520,470,'ACTUAL'), ('RPL-100116',1, 400,0.30,0, 940,610,455,'ACTUAL');

INSERT INTO bills (bill_id, customer_id, period_start, period_end, issue_date, due_date, read_type, kwh, on_peak_kwh,
                   off_peak_kwh, solar_export_kwh, prior_year_kwh, cooling_degree_days, prior_year_cdd)
SELECT 'BL-' || right(u.cust, 6) || '-' || to_char(ps, 'YYMM'), u.cust, ps, (ps + INTERVAL '1 month' - INTERVAL '1 day')::date,
       (ps + INTERVAL '1 month')::date, (ps + INTERVAL '2 month' - INTERVAL '1 day')::date, u.read_type, u.kwh,
       CASE WHEN u.on_share IS NULL THEN NULL ELSE round(u.kwh * u.on_share) END,
       CASE WHEN u.on_share IS NULL THEN NULL ELSE u.kwh - round(u.kwh * u.on_share) END,
       u.export_kwh, u.prior_kwh, u.cdd, u.prior_cdd
  FROM _u u CROSS JOIN LATERAL (SELECT (date_trunc('month', current_date) - make_interval(months => u.k))::date AS ps) d;

-- Line items from usage and the customer's plan (rider $0.01311/kWh on every plan; taxes & fees 7%).
INSERT INTO bill_lines (bill_id, category, description, amount)
SELECT b.bill_id, x.category, x.description, x.amount
  FROM bills b JOIN customers c USING (customer_id) JOIN rate_plans rp ON rp.plan_code = c.plan_code
 CROSS JOIN LATERAL (VALUES
   (1, 'BASE_CHARGE', 'Base charge (' || rp.plan_name || ')', rp.base_charge),
   (2, 'ENERGY', 'Energy charge (' || to_char(b.kwh, 'FM99,990') || ' kWh x $' || rp.energy_rate || CASE WHEN b.read_type = 'ESTIMATED' THEN ', estimated read' ELSE '' END || ')',
       CASE WHEN rp.energy_rate IS NOT NULL THEN round(b.kwh * rp.energy_rate, 2) END),
   (3, 'ENERGY_ON_PEAK', 'On-peak energy (' || to_char(b.on_peak_kwh, 'FM99,990') || ' kWh x $' || rp.on_peak_rate || ')',
       CASE WHEN rp.energy_rate IS NULL THEN round(b.on_peak_kwh * rp.on_peak_rate, 2) END),
   (4, 'ENERGY_OFF_PEAK', 'Off-peak energy (' || to_char(b.off_peak_kwh, 'FM99,990') || ' kWh x $' || rp.off_peak_rate || ')',
       CASE WHEN rp.energy_rate IS NULL THEN round(b.off_peak_kwh * rp.off_peak_rate, 2) END),
   (5, 'POWER_COST_RIDER', 'Power cost rider (' || to_char(b.kwh, 'FM99,990') || ' kWh x $0.01311)', round(b.kwh * 0.01311, 2)),
   (6, 'SOLAR_CREDIT', 'Solar export credit (' || to_char(b.solar_export_kwh, 'FM99,990') || ' kWh x $' || rp.export_credit_rate || ')',
       CASE WHEN b.solar_export_kwh > 0 AND rp.export_credit_rate > 0 THEN -round(b.solar_export_kwh * rp.export_credit_rate, 2) END)
 ) AS x(ord, category, description, amount)
 WHERE x.amount IS NOT NULL
 ORDER BY b.bill_id, x.ord;

INSERT INTO bill_lines (bill_id, category, description, amount)
SELECT bill_id, 'TAXES_FEES', 'Taxes & regulatory fees (7%)', round(sum(amount) * 0.07, 2)
  FROM bill_lines GROUP BY bill_id ORDER BY bill_id;

-- ---------------------------------------------------------------------
-- Payments: the two older bills are paid on time, the latest bill is not due yet - except:
--   Henry   the bill from 3 months ago is unpaid -> past due (he was disconnected); 2 months ago paid
--   Nathan  the bills from 2 and 3 months ago are unpaid -> past due (open payment-arrangement case)
--   Maria   was disconnected, then paid everything yesterday -> balance $0, reconnect allowed
-- ---------------------------------------------------------------------
INSERT INTO payments (reference, customer_id, bill_id, paid_on, amount, method)
SELECT 'PAY-' || lpad(row_number() OVER (ORDER BY b.period_start, b.bill_id)::text, 5, '0'), b.customer_id, b.bill_id,
       CASE WHEN b.customer_id = 'RPL-100116' THEN current_date - 1 ELSE b.due_date - 4 END,
       bill_total(b.bill_id),
       CASE WHEN c.autopay THEN 'AutoPay' WHEN b.customer_id = 'RPL-100116' THEN 'Debit card' ELSE 'Online' END
  FROM bills b JOIN customers c USING (customer_id)
 WHERE (b.period_start < date_trunc('month', current_date) - INTERVAL '1 month' OR b.customer_id = 'RPL-100116')
   AND NOT (b.customer_id = 'RPL-100107' AND b.period_start = date_trunc('month', current_date) - INTERVAL '3 month')
   AND b.customer_id <> 'RPL-100113';

-- ---------------------------------------------------------------------
-- Outages, an open ticket, appointment slots + one appointment, a scheduled plan change
-- ---------------------------------------------------------------------
INSERT INTO outages (outage_id, service_area, cause, status, started_at, etr, customers_affected, customers_reported) VALUES
 ('OUT-2026-0039', 'Willow Creek', 'VEGETATION', 'RESTORED',      now() - INTERVAL '3 days',   now() - INTERVAL '3 days' + INTERVAL '4 hours', 140, 22),
 ('OUT-2026-0041', 'Oak Hollow',   'STORM',      'RESTORING',     now() - INTERVAL '4 hours',  now() + INTERVAL '2 hours',  1240, 37),
 ('OUT-2026-0042', 'Mesa Verde',   'PLANNED',    'CREW_ASSIGNED', now() + INTERVAL '20 hours', now() + INTERVAL '24 hours', 320, 0),
 ('OUT-2026-0043', 'Pine Ridge',   'EQUIPMENT',  'INVESTIGATING', now() - INTERVAL '1 hour',   now() + INTERVAL '3 hours',  85, 4);

INSERT INTO outage_tickets (ticket_no, ticket_id, customer_id, outage_id, ticket_type, symptom, status, eta, created_at) VALUES
 (90, 'OTK-000090', 'RPL-100115', NULL, 'NEW', 'NO_POWER', 'CREW_DISPATCHED', now() + INTERVAL '90 minutes', now() - INTERVAL '3 hours');

INSERT INTO appointment_slots (slot_id, slot_date, time_window, capacity, booked) VALUES
 ('SLOT-01', current_date - 1, '8 AM - 12 PM', 3, 1),
 ('SLOT-02', current_date + 1, '8 AM - 12 PM', 2, 2),
 ('SLOT-03', current_date + 1, '1 PM - 5 PM',  2, 0),
 ('SLOT-04', current_date + 2, '8 AM - 12 PM', 3, 0),
 ('SLOT-05', current_date + 3, '1 PM - 5 PM',  3, 0),
 ('SLOT-06', current_date + 5, '8 AM - 12 PM', 3, 0),
 ('SLOT-07', current_date + 6, '1 PM - 5 PM',  2, 0);
-- the trigger counts this booking into SLOT-04 (booked 0 -> 1)
INSERT INTO appointments (appt_no, appointment_id, customer_id, appointment_type, slot_id, created_at) VALUES
 (90, 'APPT-000090', 'RPL-100109', 'METER_INSPECTION', 'SLOT-04', now() - INTERVAL '2 days');

INSERT INTO plan_changes (customer_id, from_plan, to_plan, effective_date, status, source_reference) VALUES
 ('RPL-100102', 'EV', 'TOU', (date_trunc('month', current_date) + INTERVAL '1 month')::date, 'SCHEDULED', NULL);

-- ---------------------------------------------------------------------
-- Pre-seeded OPEN cases so every reviewer queue has work (and one case no seeded reviewer can see)
-- ---------------------------------------------------------------------
INSERT INTO service_cases (case_no, case_id, customer_id, request_type, team, summary, agent_brief, requested_amount,
                           parked_action, parked_ref, sla_due_at, created_at) VALUES
 (101, 'RPL-CASE-000101', 'RPL-100109', 'billing_dispute', 'Billing Review',
  'I think the power cost rider was charged twice on my last bill and I want the extra amount credited.',
  'Customer disputes a line on the latest bill; latest bill is on an ACTUAL read. Customer asks for a $46.20 credit.',
  46.20, 'BILL_CREDIT', 'BL-100109-' || to_char(date_trunc('month', current_date) - INTERVAL '1 month', 'YYMM'),
  now() - INTERVAL '20 hours' + INTERVAL '72 hours', now() - INTERVAL '20 hours'),
 (102, 'RPL-CASE-000102', 'RPL-100113', 'payment_arrangement', 'Credit & Collections',
  'I lost hours at work and cannot pay the overdue amount at once. Can I pay it over a few months?',
  'Customer asks to spread the past-due balance over installments.',
  210.00, 'PAYMENT_PLAN', NULL, now() - INTERVAL '30 hours' + INTERVAL '48 hours', now() - INTERVAL '30 hours'),
 (103, 'RPL-CASE-000103', 'RPL-100104', 'medical_baseline', 'Customer Care',
  'I use a home oxygen concentrator and need medical-baseline protection on my account.',
  'Customer requests medical-baseline protection; a physician certification form is needed.',
  NULL, 'MEDICAL_BASELINE', NULL, now() - INTERVAL '2 days' + INTERVAL '120 hours', now() - INTERVAL '2 days');

-- Id sequences start above the seeded rows (RESTART IDENTITY in reset_data.sql resets them first).
DO $$ BEGIN
  PERFORM setval(pg_get_serial_sequence('service_cases', 'case_no'), 140);
  PERFORM setval(pg_get_serial_sequence('account_events', 'event_id'), 100);
  PERFORM setval(pg_get_serial_sequence('outage_tickets', 'ticket_no'), 100);
  PERFORM setval(pg_get_serial_sequence('appointments', 'appt_no'), 100);
  PERFORM setval(pg_get_serial_sequence('service_orders', 'order_no'), 100);
  PERFORM setval(pg_get_serial_sequence('review_decisions', 'decision_id'), 100);
  PERFORM setval(pg_get_serial_sequence('payment_arrangements', 'arrangement_no'), 100);
END $$;

DROP TABLE IF EXISTS _u;
