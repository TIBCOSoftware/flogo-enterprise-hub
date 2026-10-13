-- Demo data for Northvale Aero Services - Aerospace MRO AOG Operations (governed). Fictional company, bases, aircraft
-- types, tails (N0xxNV - a real US registration never starts with 0), part numbers, staff and numbers (555-01xx,
-- example.com). ATA chapters are the public industry standard. Every volatile date is relative to CURRENT_DATE / now().
-- Included by database.sql and reset_data.sql via \ir - do not load on its own.

ALTER SEQUENCE po_seq RESTART WITH 101;
ALTER SEQUENCE dsp_seq RESTART WITH 101;
ALTER SEQUENCE rts_seq RESTART WITH 101;

-- ---------------------------------------------------------------------
-- Reference data and routing
-- ---------------------------------------------------------------------
INSERT INTO bases (base_id, base_name, ops_phone) VALUES
 ('GM', 'Granite Mesa', '(555) 010-2100'),
 ('HP', 'Harbor Point', '(555) 010-3100');

INSERT INTO aircraft_types (type_code, type_name, platform) VALUES
 ('NV-450', 'NV-450 tactical airlifter', 'Defense'),
 ('NV-200', 'NV-200 regional jet',       'Commercial'),
 ('NV-35',  'NV-35 ISR turboprop',       'Defense'),
 ('NV-60',  'NV-60 utility helicopter',  'Defense'),
 ('NV-700', 'NV-700 business jet',       'Commercial');

INSERT INTO case_routing (request_type, label, team, sla_hours, sla_text, controller_openable) VALUES
 ('spend_approval',     'part spend approval',                'Maintenance Management',   2, 'A maintenance manager decides within 2 hours.', FALSE),
 ('return_to_service',  'return-to-service sign-off',         'Quality & Airworthiness',  4, 'A certifying inspector reviews it within 4 hours.', TRUE),
 ('ad_compliance',      'airworthiness directive compliance', 'Quality & Airworthiness',  8, 'An airworthiness inspector reviews it within 8 hours.', TRUE),
 ('mel_deferral',       'MEL deferral',                       'Quality & Airworthiness',  2, 'An inspector reviews the deferral within 2 hours.', TRUE),
 ('grounding_change',   'grounding / ungrounding',            'Quality & Airworthiness',  2, 'An inspector reviews it within 2 hours.', TRUE),
 ('reliability_review', 'reliability (repeat defect) review', 'Quality & Airworthiness', 24, 'Reliability engineering reviews it within 24 hours.', TRUE);

-- ---------------------------------------------------------------------
-- Agent reference tables (what the three A2A agents may read through ref_* functions). Reference data only: no
-- staff, technician, reviewer, case, session, tail, work order or contact data. ATA chapters are the public standard.
-- ---------------------------------------------------------------------
-- fault_triage_agent: ATA chapters (name, scope, certification, Northvale triage note), symptom hints, write-up
-- shorthand and rules. The PART_FAMILY rows are NOT stored here: ref_ata_chapters() reads them from parts.
INSERT INTO ata_chapter_guide (section, term, meaning) VALUES
 ('ATA_CHAPTER', 'ATA 05 - Time limits / maintenance checks', 'Scheduled and phase inspections. Certification: STRUCTURES. Triage note: Confirm the inspection package and its due limit in the maintenance system before planning the hangar slot.'),
 ('ATA_CHAPTER', 'ATA 21 - Air conditioning and pressurization', 'Packs, cabin pressure controller, outflow valve. Certification: AVIONICS. Triage note: Pull the cabin pressure controller fault history before replacing any component.'),
 ('ATA_CHAPTER', 'ATA 24 - Electrical power', 'Generators, batteries, power buses. Certification: ELECTRICAL. Triage note: Check bus voltages and the generator control unit fault codes before removing anything.'),
 ('ATA_CHAPTER', 'ATA 27 - Flight controls', 'Control surfaces, cables, actuators of the flight controls. Certification: STRUCTURES. Triage note: Flight-control work needs a duplicate inspection - book a second inspector before work starts.'),
 ('ATA_CHAPTER', 'ATA 28 - Fuel', 'Tanks, fuel pumps, fuel lines. Certification: POWERPLANT. Triage note: Ventilate the area before any fuel leak check and note the leak classification on the work order.'),
 ('ATA_CHAPTER', 'ATA 29 - Hydraulic power', 'Pumps, reservoirs, pressure and return lines, fittings, accumulators. Certification: HYDRAULICS. Triage note: Check reservoir level and pump case drain flow before calling for a pump change, and record the leak rate on the work order.'),
 ('ATA_CHAPTER', 'ATA 31 - Indicating and recording systems', 'Cockpit displays and recorders. Certification: AVIONICS. Triage note: Record the display fault code and run the built-in test before swapping a display unit.'),
 ('ATA_CHAPTER', 'ATA 32 - Landing gear', 'Actuators, brakes, wheels. Certification: LANDING GEAR. Triage note: Measure the brake wear pins and inspect the actuator seals; jack the aircraft only with the gear pins installed.'),
 ('ATA_CHAPTER', 'ATA 33 - Lights', 'Interior and exterior lights. Certification: ELECTRICAL. Triage note: Check the lamp, the socket and the circuit breaker before ordering a light assembly.'),
 ('ATA_CHAPTER', 'ATA 34 - Navigation', 'Navigation radios and sensors. Certification: AVIONICS. Triage note: Run the built-in test and record the fault code before removing any navigation unit.'),
 ('ATA_CHAPTER', 'ATA 49 - Auxiliary power unit', 'The APU and its controls. Certification: POWERPLANT. Triage note: Download the APU fault log before any component change.'),
 ('ATA_CHAPTER', 'ATA 57 - Wings', 'Wing structure, spars, skins. Certification: STRUCTURES. Triage note: Send structural findings to Quality & Airworthiness with photos and measurements - no blend or repair before their direction.'),
 ('ATA_CHAPTER', 'ATA 65 - Tail rotor and main rotor', 'Rotor blades, hubs, drivetrain to the rotors. Certification: ROTOR SYSTEMS. Triage note: Record blade tracking and vibration readings before and after any rotor work.'),
 ('ATA_CHAPTER', 'ATA 73 - Engine fuel and control', 'Fuel nozzles, fuel control unit, engine controls. Certification: POWERPLANT. Triage note: Check fuel nozzle flow and the engine trend data before a component change.'),
 ('SYMPTOM', 'pressure fluctuating with a leak at the case drain', 'Points at the hydraulic pump seals, or at the pump itself if pressure is also fluctuating (ATA 29).'),
 ('SYMPTOM', 'fluid pooled under a gear well', 'Usually a hydraulic line or fitting leak (ATA 29); a brake or actuator leak if it is at the wheel itself (ATA 32).'),
 ('SYMPTOM', 'cabin altitude climbing', 'Cabin pressure controller or outflow valve (ATA 21).'),
 ('SYMPTOM', 'display blank or flickering', 'Display unit (ATA 31), or its power supply and circuit breaker (ATA 24).'),
 ('SYMPTOM', 'airframe vibration on a helicopter', 'Rotor track and balance (ATA 65).'),
 ('SHORTHAND', 'HYD', 'hydraulic'),
 ('SHORTHAND', 'HYD 2', 'the No.2 hydraulic system'),
 ('SHORTHAND', 'LO PRESS', 'low pressure caution'),
 ('SHORTHAND', 'press fluct', 'pressure fluctuating'),
 ('SHORTHAND', 'case drain', 'the pump''s case drain line'),
 ('SHORTHAND', 'weeping / seeping', 'slow leak'),
 ('SHORTHAND', 'B-nut', 'a tube fitting nut'),
 ('SHORTHAND', 'MLG', 'main landing gear'),
 ('SHORTHAND', 'inop', 'inoperative'),
 ('SHORTHAND', 'c/b', 'circuit breaker'),
 ('RULE', 'certification and type rating', 'A job needs a technician who holds the certification AND a type rating for that aircraft type; the maintenance system checks both.'),
 ('RULE', 'candidate parts only', 'Pick likely parts only from the candidate list you are given. The catalogue families in this guide are for orientation; the maintenance system re-checks every part against the aircraft type.'),
 ('RULE', 'copy the triage note', 'Copy the triage note of the chapter you pick exactly as this guide words it.');

-- repeat_defect_agent: flag levels with their standard notes, the window, same / different system, reliability-program
-- terms and rules. The WHO_DECIDES row is NOT stored here: ref_repeat_defect_criteria() reads it from case_routing. The
-- same-chapter count in the last 30 days stays computed in SQL (tail_history.same_ata_last_30_days).
INSERT INTO repeat_defect_guide (section, term, meaning) VALUES
 ('FLAG', 'REPEAT', '2 or more earlier events of the same system inside the 30-day window (the new write-up makes 3 or more) - reliability review recommended. Standard note: Meets the Northvale repeat-defect criteria - <ordinal> <system> event in 30 days; for Quality & Airworthiness to review.'),
 ('FLAG', 'POSSIBLE_REPEAT', '1 earlier event of the same system inside the 30-day window, or similar events 31-90 days ago. Standard note: Below the Northvale repeat-defect criteria but worth watching - similar <system> event(s) found; for Quality & Airworthiness to note.'),
 ('FLAG', 'NO_REPEAT', 'Nothing similar on this aircraft. Standard note: No similar event on this aircraft in the last 90 days.'),
 ('WINDOW', '30 days', 'Count only earlier events opened in the 30 days before the new write-up for REPEAT. The maintenance system counts same-chapter work orders in the last 30 days itself (same_ata_last_30_days); your flag adds the same-subsystem judgement.'),
 ('WINDOW', '31-90 days', 'Similar events 31 to 90 days before the new write-up make at most POSSIBLE_REPEAT.'),
 ('SAME_SYSTEM', 'definition', 'A repeat defect is the same system failing in the same way again on the same aircraft.'),
 ('SAME_SYSTEM', 'same chapter and subsystem', 'Same system means the same ATA chapter AND the same subsystem (for example the No.2 hydraulic system), even when the words differ.'),
 ('SAME_SYSTEM', 'No.2 hydraulic leak / pressure events', '''fluid pooled under the gear well'', ''HYD 2 LO PRESS caution'' and ''pressure fluctuation with leak at the pump case drain'' are all No.2 hydraulic system leak / pressure events.'),
 ('DIFFERENT_SYSTEM', 'brake wear check', 'A brake wear check (ATA 32) is not a hydraulic leak even though brakes use hydraulic fluid.'),
 ('DIFFERENT_SYSTEM', 'lights and displays', 'A light or display fault is never a hydraulic event.'),
 ('DIFFERENT_SYSTEM', 'shared words', 'Exclude events in other systems even when they share a word such as hydraulic or gear.'),
 ('TERM', 'PIREP', 'Pilot report - a defect written up by the flight crew.'),
 ('TERM', 'MAREP', 'Maintenance report - a defect found by maintenance, for example on a walkaround or inspection.'),
 ('TERM', 'NFF', 'No fault found - troubleshooting could not reproduce it. An NFF write-up still counts as an event of that system.'),
 ('TERM', 'deferred item', 'An item deferred under the MEL is still an open event of that system until it is fixed.'),
 ('TERM', 'chronic aircraft', 'An aircraft with repeat defects in more than one system; mention it only if the history shows it.'),
 ('TERM', 'reliability review', 'Quality & Airworthiness reliability engineers look at the repeat, its root cause and whether the fix worked.'),
 ('RULE', 'flag only', 'The flag goes to Quality & Airworthiness, who decide. Never say the aircraft is safe or unsafe.');

-- shift_handover_agent: the handover sections in order, status codes in plain words, standard lines and rules.
INSERT INTO handover_guide (section, term, meaning) VALUES
 ('SECTION', '1 AOG', 'AOG aircraft, most hours on ground first: what is being done and what it is waiting for.'),
 ('SECTION', '2 Open work', 'Open work orders by priority - AOG (aircraft on ground), then URGENT (before next flight), then ROUTINE (planned) - saying which are unassigned and which wait for parts.'),
 ('SECTION', '3 Parts on order', 'Parts on order with ETA, flagging anything expedited (EXPEDITE = rush delivery).'),
 ('SECTION', '4 Waiting on people / decisions', 'Open cases waiting for a person (team and reply-due time), then decisions made in the last 24 hours. A case is named by its request type, e.g. MEL deferral.'),
 ('SECTION', '5 Watch items', 'At most 3 things the next shift must chase, separated by semicolons.'),
 ('STATUS', 'OPEN', 'open - not started yet (AOG or work order), or waiting for a person (case)'),
 ('STATUS', 'RESOLVING', 'being worked - a technician is on it'),
 ('STATUS', 'RESOLVED', 'closed in the system (not an airworthiness release)'),
 ('STATUS', 'AWAITING_PARTS', 'on hold for parts'),
 ('STATUS', 'IN_PROGRESS', 'in work - technician assigned'),
 ('STATUS', 'CLOSED', 'work order closed'),
 ('STATUS', 'ORDERED', 'ordered, not shipped yet'),
 ('STATUS', 'IN_TRANSIT', 'shipped, on its way to the base'),
 ('STATUS', 'RECEIVED', 'received at the base'),
 ('STATUS', 'APPROVED', 'approved by the reviewing team'),
 ('STATUS', 'REJECTED', 'not approved by the reviewing team'),
 ('STANDARD_LINE', 'empty section', 'Nothing to hand over.'),
 ('STANDARD_LINE', 'closing line', 'Snapshot from the Northvale maintenance system at handover - statuses as recorded, not an airworthiness release.'),
 ('STANDARD_LINE', 'unassigned AOG work', 'Unassigned AOG work order - assign a certified, type-rated technician first.'),
 ('STANDARD_LINE', 'expedited part', 'Expedited - chase the ETA with stores at shift start.'),
 ('STANDARD_LINE', 'reply due this shift', 'Reply due within this shift - chase the team if there is no answer.'),
 ('RULE', 'no names', 'No people''s names, even if one appears in the input; a case is named by its request type.'),
 ('RULE', 'length', 'Each line one sentence. At most 20 lines in total.'),
 ('RULE', 'status words', 'Write each status as its plain words from this guide followed by the code in brackets, e.g. on hold for parts (AWAITING_PARTS).'),
 ('RULE', 'references', 'Use the item references exactly (AOG-..., WO-..., PO-...).'),
 ('RULE', 'no release wording', 'Never state that an aircraft is airworthy or released - only report statuses as given.');

-- ---------------------------------------------------------------------
-- Staff (codes are demo stand-ins for a badge / authenticator code)
-- ---------------------------------------------------------------------
INSERT INTO controllers (staff_id, display_name, base_id, one_time_code, spend_limit) VALUES
 ('NVA-2101', 'Teresa Lindqvist', 'GM', '3852', 25000),
 ('NVA-3101', 'Kenji Watanabe',   'HP', '9174', 25000);

INSERT INTO reviewers (reviewer_id, display_name, team, one_time_code, approval_limit) VALUES
 ('NVA-7101', 'Gloria Mendez',       'Maintenance Management',  '4417', 100000),   -- base maintenance manager
 ('NVA-7102', 'Victor Hale',         'Maintenance Management',  '5823',  50000),   -- shift manager -> OVER_AUTHORITY above $50,000
 ('NVA-8101', 'Ingrid Castellanos',  'Quality & Airworthiness', '6390',   NULL);   -- certifying inspector

-- ---------------------------------------------------------------------
-- Fleet
-- ---------------------------------------------------------------------
INSERT INTO aircraft (tail_number, type_code, base_id, flight_hours, cycles, status, next_check_type, next_check_due) VALUES
 ('N042NV', 'NV-450', 'GM', 15200, 6800, 'AOG',            'Phase inspection',  current_date + 2),
 ('N047NV', 'NV-450', 'GM', 14010, 6310, 'IN_SERVICE',     'Phase inspection',  current_date + 25),
 ('N021NV', 'NV-200', 'GM', 24500, 12300,'IN_SERVICE',     'A-check',           current_date + 5),
 ('N063NV', 'NV-60',  'GM',  3100, 2200, 'IN_SERVICE',     '100-hour inspection', current_date + 15),
 ('N034NV', 'NV-200', 'HP', 31000, 15400,'IN_SERVICE',     'C-check',           current_date + 60),
 ('N055NV', 'NV-700', 'HP', 11200, 5000, 'GROUNDED',       'AD compliance',     current_date + 7),
 ('N078NV', 'NV-35',  'HP',  6400, 5900, 'IN_MAINTENANCE', 'Phase inspection',  current_date + 10),
 ('N089NV', 'NV-700', 'HP',  8900, 4100, 'IN_SERVICE',     'C-check',           current_date + 40);

INSERT INTO technicians (tech_id, name, base_id, certifications, type_ratings, shift, availability, email, phone) VALUES
 ('TECH-201', 'Rosa Delgado',   'GM', ARRAY['HYDRAULICS','POWERPLANT'],            ARRAY['NV-450'],           'Day',   'AVAILABLE', 'rosa.delgado@northvale-aero.example.com',   '(555) 010-2141'),
 ('TECH-202', 'Caleb Brandt',   'GM', ARRAY['AVIONICS','STRUCTURES'],              ARRAY['NV-450','NV-200'],  'Day',   'AVAILABLE', 'caleb.brandt@northvale-aero.example.com',   '(555) 010-2142'),
 ('TECH-203', 'Samir Haddad',   'GM', ARRAY['HYDRAULICS','LANDING GEAR'],          ARRAY['NV-450'],           'Night', 'OFF',       'samir.haddad@northvale-aero.example.com',   '(555) 010-2143'),
 ('TECH-204', 'Bethany Cole',   'GM', ARRAY['ROTOR SYSTEMS','POWERPLANT'],         ARRAY['NV-60'],            'Swing', 'AVAILABLE', 'bethany.cole@northvale-aero.example.com',   '(555) 010-2144'),
 ('TECH-205', 'Nolan Pierce',   'GM', ARRAY['AVIONICS','ELECTRICAL'],              ARRAY['NV-200'],           'Day',   'ON_TASK',   'nolan.pierce@northvale-aero.example.com',   '(555) 010-2145'),
 ('TECH-301', 'Luis Ferreira',  'HP', ARRAY['HYDRAULICS','LANDING GEAR'],          ARRAY['NV-35'],            'Day',   'ON_TASK',   'luis.ferreira@northvale-aero.example.com',  '(555) 010-3141'),
 ('TECH-302', 'Grace Whitaker', 'HP', ARRAY['HYDRAULICS','AVIONICS','STRUCTURES'], ARRAY['NV-450','NV-700'],  'Day',   'AVAILABLE', 'grace.whitaker@northvale-aero.example.com', '(555) 010-3142'),
 ('TECH-303', 'Ahmed Saleh',    'HP', ARRAY['STRUCTURES','POWERPLANT'],            ARRAY['NV-700','NV-200'],  'Night', 'AVAILABLE', 'ahmed.saleh@northvale-aero.example.com',    '(555) 010-3143');

-- Work orders. N042NV's history holds two earlier hydraulic write-ups worded differently (the repeat-defect story).
INSERT INTO work_orders (wo_number, tail_number, wo_type, ata_chapter, description, priority, status, required_cert, opened_date, due_date, assigned_tech, closed_date) VALUES
 ('WO-2026-00101', 'N042NV', 'AOG',         '29', 'No.2 hydraulic system pressure fluctuation with fluid leak at the pump case drain line; aircraft AOG', 'AOG', 'AWAITING_PARTS', 'HYDRAULICS', current_date - 1, current_date + 1, NULL, NULL),
 ('WO-2026-00102', 'N042NV', 'Inspection',  '05', 'Phase inspection deferred pending AOG repair',                                   'ROUTINE', 'OPEN',        'STRUCTURES',    current_date - 1, current_date + 2,  NULL, NULL),
 ('WO-2026-00103', 'N063NV', 'Scheduled',   '05', '100-hour inspection - rotor system and drivetrain checks',                       'ROUTINE', 'OPEN',        'ROTOR SYSTEMS', current_date - 1, current_date + 15, NULL, NULL),
 ('WO-2026-00104', 'N021NV', 'Unscheduled', '21', 'Cabin pressurization controller intermittent fault - controller replacement',    'URGENT',  'IN_PROGRESS', 'AVIONICS',      current_date - 2, current_date + 3,  'TECH-205', NULL),
 ('WO-2026-00105', 'N021NV', 'Unscheduled', '33', 'Cabin reading light row 3 inoperative',                                         'ROUTINE', 'OPEN',        'ELECTRICAL',    current_date - 1, current_date + 10, NULL, NULL),
 ('WO-2026-00084', 'N042NV', 'Unscheduled', '33', 'Cargo bay flood light inoperative - lamp replaced',                             'ROUTINE', 'CLOSED',      'ELECTRICAL',    current_date - 41, current_date - 38, 'TECH-202', current_date - 40),
 ('WO-2026-00088', 'N042NV', 'Inspection',  '32', 'Left main landing gear brake wear check - within limits',                       'ROUTINE', 'CLOSED',      'LANDING GEAR',  current_date - 28, current_date - 25, 'TECH-203', current_date - 27),
 ('WO-2026-00091', 'N042NV', 'Unscheduled', '29', 'Fluid found pooled under the left main gear well after landing; No.2 system reservoir serviced and return-line B-nut re-torqued', 'URGENT', 'CLOSED', 'HYDRAULICS', current_date - 23, current_date - 21, 'TECH-201', current_date - 22),
 ('WO-2026-00096', 'N042NV', 'Unscheduled', '29', 'Crew report: HYD 2 LO PRESS caution in climb, cleared after landing; pressure line fitting O-ring replaced, leak check good', 'URGENT', 'CLOSED', 'HYDRAULICS', current_date - 10, current_date - 8, 'TECH-203', current_date - 9),
 ('WO-2026-00090', 'N047NV', 'Inspection',  '05', 'Phase 1 inspection - completed, returned to service',                           'ROUTINE', 'CLOSED',      'STRUCTURES',    current_date - 18, current_date - 10, 'TECH-202', current_date - 10),
 ('WO-2026-00201', 'N078NV', 'Inspection',  '32', 'Phase 2 inspection - main landing gear actuator leak; actuator replacement required', 'URGENT', 'AWAITING_PARTS', 'LANDING GEAR', current_date - 3, current_date + 7, 'TECH-301', NULL),
 ('WO-2026-00202', 'N055NV', 'Unscheduled', '57', 'Airworthiness directive - wing spar inspection required before next flight',    'URGENT',  'OPEN',        'STRUCTURES',    current_date - 2, current_date + 7,  NULL, NULL),
 ('WO-2026-00203', 'N034NV', 'Unscheduled', '32', 'No.3 wheel brake assembly worn to limit - replacement',                         'ROUTINE', 'AWAITING_PARTS', 'LANDING GEAR', current_date - 4, current_date + 6,  NULL, NULL),
 ('WO-2026-00204', 'N089NV', 'Scheduled',   '73', 'Fuel nozzle set replacement at 2,400 hours',                                     'ROUTINE', 'OPEN',        'POWERPLANT',    current_date - 1, current_date + 12, NULL, NULL);

INSERT INTO parts (part_number, description, ata_chapter, type_code, unit_price, lead_days, expedite_days, reorder_level) VALUES
 ('NV29-4471-P',  'Hydraulic pump assembly, No.2 system', '29', 'NV-450', 48750.00, 21,  5, 2),
 ('NV29-4471-SK', 'Hydraulic pump seal kit',              '29', 'NV-450',   850.00,  5,  1, 4),
 ('NV29-1180-F',  'Hydraulic pressure line fitting kit',  '29', 'NV-450',   420.00,  4,  1, 6),
 ('NV32-8830-A',  'Main landing gear actuator',           '32', 'NV-35',  63400.00, 45, 14, 1),
 ('NV31-2210-D',  'Multifunction display unit',           '31', 'NV-35',  22100.00, 14,  4, 1),
 ('NV32-1002-B',  'Wheel brake assembly',                 '32', 'NV-200',  9800.00, 10,  3, 3),
 ('NV21-6621-C',  'Cabin pressure controller',            '21', 'NV-200', 12750.00, 18,  5, 1),
 ('NV65-5540-R',  'Main rotor blade',                     '65', 'NV-60',  38900.00, 30, 10, 2),
 ('NV73-7788-N',  'Fuel nozzle set',                      '73', 'NV-700',  7400.00,  9,  3, 2),
 ('NV57-9012-K',  'Wing spar inspection kit',             '57', 'NV-700',  3100.00,  7,  2, 1);

INSERT INTO part_stock (part_number, base_id, on_hand) VALUES
 ('NV29-4471-P', 'GM', 0), ('NV29-4471-P', 'HP', 0),
 ('NV29-4471-SK','GM', 1), ('NV29-4471-SK','HP', 0),
 ('NV29-1180-F', 'GM', 8), ('NV29-1180-F', 'HP', 2),
 ('NV32-8830-A', 'GM', 0), ('NV32-8830-A', 'HP', 0),
 ('NV31-2210-D', 'GM', 0), ('NV31-2210-D', 'HP', 2),
 ('NV32-1002-B', 'GM', 4), ('NV32-1002-B', 'HP', 1),
 ('NV21-6621-C', 'GM', 0), ('NV21-6621-C', 'HP', 1),
 ('NV65-5540-R', 'GM', 2), ('NV65-5540-R', 'HP', 0),
 ('NV73-7788-N', 'GM', 0), ('NV73-7788-N', 'HP', 3),
 ('NV57-9012-K', 'GM', 0), ('NV57-9012-K', 'HP', 1);

-- Seeded orders (history - no proposal behind them)
INSERT INTO part_orders (order_id, proposal_id, part_number, base_id, quantity, wo_number, tail_number, priority, unit_price, total_usd, status, ordered_date, expected_delivery, ordered_by) VALUES
 ('PO-2026-0001', NULL, 'NV32-1002-B', 'HP', 1, 'WO-2026-00203', 'N034NV', 'ROUTINE', 9800.00,  9800.00,  'IN_TRANSIT', current_date - 4, current_date + 3, 'NVA-3101'),
 ('PO-2026-0002', NULL, 'NV21-6621-C', 'GM', 1, 'WO-2026-00104', 'N021NV', 'EXPEDITE', 12750.00, 12750.00, 'ORDERED',    current_date - 1, current_date + 4, 'NVA-2101');

INSERT INTO aog_incidents (aog_id, tail_number, base_id, reported_at, reason, severity, status, resolution, resolved_at) VALUES
 ('AOG-2026-014', 'N042NV', 'GM', now()::timestamp - INTERVAL '20 hours', 'No.2 hydraulic system pressure fluctuation and fluid leak found on pre-flight; aircraft grounded at Granite Mesa', 'CRITICAL', 'OPEN', NULL, NULL),
 ('AOG-2026-012', 'N078NV', 'HP', now()::timestamp - INTERVAL '3 days',   'Main landing gear actuator leak found on phase inspection', 'HIGH', 'RESOLVING', 'Technician assigned; replacement actuator awaiting spend approval', NULL),
 ('AOG-2026-009', 'N021NV', 'GM', now()::timestamp - INTERVAL '8 days',   'Cabin pressurization controller intermittent fault', 'MEDIUM', 'RESOLVED', 'Controller reset and deferred replacement; aircraft returned to service', now()::timestamp - INTERVAL '7 days');

-- ---------------------------------------------------------------------
-- Seeded OPEN cases (one queue per reviewer team is never empty)
-- ---------------------------------------------------------------------
-- Kenji's actuator spend approval: the parked proposal behind it (confirmed earlier today).
INSERT INTO pending_actions (proposal_id, controller_id, action_type, target_key, wo_number, part_number, quantity, priority, tech_id,
                             total_usd, needs_approval, outcome, reason_code, reason_text, summary, created_at, expires_at) VALUES
 ('NVA-PRP-SEED0101', 'NVA-3101', 'PART_ORDER', 'PART|WO-2026-00201|NV32-8830-A|1|EXPEDITE', 'WO-2026-00201', 'NV32-8830-A', 1, 'EXPEDITE', NULL,
  63400.00, TRUE, 'PROPOSED', NULL, NULL,
  'Order 1 x NV32-8830-A Main landing gear actuator for WO-2026-00201 on N078NV (NV-35 ISR turboprop), EXPEDITE: $63,400.00 total ($63,400.00 each). Above the $25,000.00 per-order limit.',
  now()::timestamp - INTERVAL '3 hours', now()::timestamp - INTERVAL '165 minutes');

INSERT INTO service_cases (case_no, case_id, base_id, tail_number, opened_by, request_type, summary, reference_id, requested_amount, unit_price,
                           parked_action, agent_brief, status, sla_due_at, created_at) VALUES
 (101, 'NVA-CASE-000101', 'HP', 'N078NV', 'NVA-3101', 'spend_approval',
  'Order 1 x NV32-8830-A Main landing gear actuator for WO-2026-00201 on N078NV (NV-35 ISR turboprop), EXPEDITE: $63,400.00 total. Above the $25,000.00 per-order limit.',
  'NV32-8830-A', 1, 63400.00, 'PART_ORDER:NVA-PRP-SEED0101', NULL, 'OPEN', now()::timestamp + INTERVAL '30 minutes', now()::timestamp - INTERVAL '90 minutes'),
 (102, 'NVA-CASE-000102', 'HP', 'N055NV', 'NVA-3101', 'ad_compliance',
  'N055NV is grounded for the wing spar inspection airworthiness directive (WO-2026-00202). Requesting the compliance method and sign-off plan before the inspection starts.',
  'N055NV', NULL, NULL, NULL, NULL, 'OPEN', now()::timestamp + INTERVAL '6 hours', now()::timestamp - INTERVAL '2 hours'),
 (103, 'NVA-CASE-000103', 'GM', 'N021NV', 'NVA-2101', 'mel_deferral',
  'Cabin reading light row 3 inoperative on N021NV (WO-2026-00105). Requesting an MEL deferral so the aircraft can keep flying until the next A-check.',
  'N021NV', NULL, NULL, NULL, NULL, 'OPEN', now()::timestamp + INTERVAL '90 minutes', now()::timestamp - INTERVAL '30 minutes');
SELECT setval(pg_get_serial_sequence('service_cases', 'case_no'), 103);
