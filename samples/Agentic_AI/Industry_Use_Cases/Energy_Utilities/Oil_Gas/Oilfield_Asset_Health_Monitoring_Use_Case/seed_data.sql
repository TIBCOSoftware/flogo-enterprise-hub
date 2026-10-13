-- Mesa Ridge Energy demo data (fictional). Every date is relative to CURRENT_DATE / now(), so the demo never goes stale.
-- Loaded by database.sql and by reset_data.sql. Temperatures in degrees F.

INSERT INTO sites (site_id, site_name, basin, town, field_crew, control_phone) VALUES
 ('PB', 'Permian Basin Site Alpha', 'Permian Basin', 'Midland, TX',     'Permian Field Crew A',    '(432) 555-0141'),
 ('BK', 'Bakken Site Bravo',        'Bakken',        'Williston, ND',   'Bakken Field Crew B',     '(701) 555-0152'),
 ('EF', 'Eagle Ford Site Charlie',  'Eagle Ford',    'Karnes City, TX', 'Eagle Ford Field Crew C', '(830) 555-0163');

INSERT INTO case_routing (request_type, label, team, sla_hours, sla_text, operator_openable) VALUES
 ('supervisor_approval', 'work order budget approval', 'Production Engineering', 4,
  'A Production Engineering supervisor replies within 4 hours.', FALSE),
 ('shut_in', 'shut-in / emergency shutdown', 'Production Engineering', 1,
  'A Production Engineering supervisor replies within 1 hour. In an emergency, follow the site emergency procedure and call the control room first.', TRUE),
 ('threshold_change', 'sensor threshold change', 'Production Engineering', 24,
  'Production Engineering replies within 24 hours.', TRUE),
 ('alert_closure', 'alert closure', 'Production Engineering', 8,
  'Production Engineering replies within 8 hours.', TRUE),
 ('safety_signal', 'safety signal', 'HSE', 1,
  'HSE replies within 1 hour. If anyone is at risk, follow the site emergency procedure now.', TRUE);

INSERT INTO operators (staff_id, display_name, site_id, one_time_code, spend_limit) VALUES
 ('MRE-4101', 'Jolene Pruitt', 'PB', '2468', 25000),
 ('MRE-4201', 'Travis Okafor', 'BK', '1357', 25000),
 ('MRE-4301', 'Elena Varga',   'EF', '8642', 25000);

INSERT INTO reviewers (reviewer_id, display_name, title, team, one_time_code, approval_limit) VALUES
 ('MRE-7101', 'Wade Hollister', 'Production Engineering superintendent', 'Production Engineering', '4096', 150000),
 ('MRE-7102', 'Nadia Brennan',  'Production Engineering field supervisor', 'Production Engineering', '7531', 50000),
 ('MRE-8101', 'Curtis Rayburn', 'HSE lead', 'HSE', '6174', NULL);

-- The health model (rule tables)
INSERT INTO sensor_thresholds (sensor, label, unit, sort_order, warn_low, crit_low, warn_high, crit_high, mode_low, mode_high) VALUES
 ('vibration',   'vibration',   'g RMS', 1, NULL, NULL, 3.5,  6.0,  NULL,            'bearing_wear'),
 ('temperature', 'temperature', 'F',     2, NULL, NULL, 185,  221,  NULL,            'overheating'),
 ('pressure',    'pressure',    'psi',   3, 800,  600,  1200, 1500, 'seal_leak',     'pressure_anomaly'),
 ('flow',        'flow',        'bbl/h', 4, 80,   60,   120,  140,  'flow_blockage', 'pressure_anomaly');

INSERT INTO confidence_lookup (anomalous_sensors, confidence) VALUES (0, 0.95), (1, 0.75), (2, 0.85), (3, 0.92), (4, 0.97);

INSERT INTO failure_horizon (health_status, min_days, max_days, wo_priority, schedule_days) VALUES
 ('CRITICAL', 3, 7, 'URGENT', 1), ('WARNING', 10, 21, 'HIGH', 3), ('NORMAL', 90, NULL, NULL, NULL);

INSERT INTO failure_modes (asset_type, failure_mode, label, recommended_action, typical_parts, est_cost_usd, est_downtime_hours) VALUES
 ('ROD_PUMP', 'bearing_wear', 'Rod pump bearing wear (gearbox, saddle or wrist pin)', 'Inspect and replace the worn gearbox, saddle or wrist-pin bearings; check alignment and lubrication.', 'saddle bearing assembly, wrist-pin bearing kit, gearbox oil', 8400, 16),
 ('ROD_PUMP', 'overheating', 'Gearbox or motor overheating', 'Check lubrication level and grade, belt tension and motor load; correct the cause before restart.', 'gearbox oil, V-belt set, motor cooling fan', 5600, 10),
 ('ROD_PUMP', 'seal_leak', 'Stuffing box / polished rod seal leak', 'Repack the stuffing box and inspect the polished rod for scoring.', 'stuffing box packing set, polished rod liner', 3900, 6),
 ('ROD_PUMP', 'pressure_anomaly', 'Tubing or flowline pressure anomaly', 'Check the flowline and choke for restriction and verify the pressure transmitter.', 'choke trim, pressure transmitter', 4500, 8),
 ('ROD_PUMP', 'flow_blockage', 'Fluid pound, gas lock or low fillage', 'Adjust strokes per minute and check the pump intake and gas anchor for scale or sand.', 'gas anchor, pump barrel cleanout kit', 6800, 14),
 ('ROD_PUMP', 'electrical_fault', 'Motor or pump-off controller fault', 'Megger the motor and inspect the pump-off controller and contactor.', 'motor contactor, pump-off controller card', 7200, 10),
 ('ESP', 'bearing_wear', 'ESP pump or motor bearing wear', 'Pull the ESP with a workover rig and replace the worn pump or motor section.', 'pump stage set, motor thrust bearing', 38000, 72),
 ('ESP', 'overheating', 'ESP motor overheating', 'Check the motor load and the fluid level over the pump; plan a pull if the trend continues.', 'motor section, motor lead extension', 36500, 72),
 ('ESP', 'seal_leak', 'ESP seal (protector) section leak', 'Pull the ESP and replace the seal (protector) section.', 'protector section, mechanical seal kit', 29000, 60),
 ('ESP', 'pressure_anomaly', 'ESP discharge pressure anomaly', 'Check the surface choke, the check valve and the drive settings.', 'check valve, drive tuning', 9500, 12),
 ('ESP', 'flow_blockage', 'ESP intake scale or sand plugging', 'Treat or clean out the intake and check the gas separator.', 'gas separator, scale-inhibitor treatment', 12000, 24),
 ('ESP', 'electrical_fault', 'ESP cable or drive fault', 'Test the power cable and the variable speed drive; replace the faulty part.', 'drive power module, cable splice kit', 22000, 36),
 ('COMPRESSOR', 'bearing_wear', 'Compressor crankshaft or main bearing wear', 'Inspect and replace the main and connecting-rod bearings; check the crankshaft.', 'main bearing set, rod bearing set, lube oil filter', 41000, 96),
 ('COMPRESSOR', 'overheating', 'Compressor overheating (top end and cooler)', 'Top-end overhaul (valves, rings and packing) plus a cooler cleaning and fan repair.', 'valve and ring kit, rod packing, cooler fan belt and bearings', 68000, 120),
 ('COMPRESSOR', 'seal_leak', 'Compressor rod packing leak', 'Replace the rod packing and check the packing vent system.', 'rod packing set, gaskets', 12500, 24),
 ('COMPRESSOR', 'pressure_anomaly', 'Compressor discharge pressure anomaly', 'Check the suction and discharge valves and the recycle valve; verify the transmitters.', 'compressor valve set, pressure transmitter', 9800, 18),
 ('COMPRESSOR', 'flow_blockage', 'Suction strainer or scrubber blockage', 'Clean the suction strainer and the scrubber; check the dump valve.', 'strainer element, scrubber dump valve trim', 7400, 12),
 ('COMPRESSOR', 'electrical_fault', 'Compressor driver or panel fault', 'Inspect the driver motor, the control panel and the shutdown switches.', 'motor starter, control panel relay', 15000, 24),
 ('WELLHEAD_VALVE', 'bearing_wear', 'Valve actuator gear or stem bearing wear', 'Service the actuator gearbox and the stem bearings.', 'actuator gear kit, stem bearing', 3000, 6),
 ('WELLHEAD_VALVE', 'overheating', 'Valve actuator overheating', 'Check the actuator duty cycle and heater; replace the actuator motor if needed.', 'actuator motor', 3600, 6),
 ('WELLHEAD_VALVE', 'seal_leak', 'Bonnet or stem packing leak', 'Replace the bonnet gasket and the stem packing.', 'bonnet gasket, stem packing set', 3200, 4),
 ('WELLHEAD_VALVE', 'pressure_anomaly', 'Pressure anomaly across the valve', 'Check the seat and gate for wear and verify the gauge.', 'seat and gate kit, pressure gauge', 2800, 6),
 ('WELLHEAD_VALVE', 'flow_blockage', 'Partially closed or obstructed valve', 'Check the valve position and clear hydrates or debris.', 'hydrate inhibitor, valve position indicator', 2400, 4),
 ('WELLHEAD_VALVE', 'electrical_fault', 'Valve actuator control fault', 'Test the actuator controller and the limit switches.', 'limit switch kit, actuator controller', 4100, 6);

-- ---------------------------------------------------------------------
-- Agent reference tables (what the three A2A agents may read through ref_* functions). Reference data only: no
-- operator, reviewer, crew-member, case, session, asset, work-order, alert or contact data.
-- ---------------------------------------------------------------------
-- field_note_triage_agent: safety-language signs (literal words and paraphrases), words that are not safety language
-- by themselves, the standard crew check per failure mode, field shorthand and rules. The FAILURE_MODE rows are NOT
-- stored here: ref_field_note_guide() reads them from failure_modes; WHO_DECIDES comes from case_routing. The literal
-- keyword backstop (safety_keyword) and the HSE case trigger stay in SQL.
INSERT INTO field_note_guide (section, term, meaning) VALUES
 ('SAFETY_SIGN', 'gas odor', 'Safety language: a gas odor or a smell of gas near equipment, in any words.'),
 ('SAFETY_SIGN', 'H2S / sour gas', 'Safety language: H2S, hydrogen sulfide or sour gas, including paraphrases such as a rotten-egg smell, a personal or area gas monitor alarming, beeping or chirping, or burning eyes or throat near equipment.'),
 ('SAFETY_SIGN', 'spill', 'Safety language: a spill, pooling fluid, a sheen on water or ground, a stain spreading under a flange, or well fluid or oil spraying or misting from a line or fitting.'),
 ('SAFETY_SIGN', 'fire', 'Safety language: fire, flames, smoke, scorching or an electrical arc.'),
 ('SAFETY_SIGN', 'injury', 'Safety language: an injury, someone feeling dizzy or sick, or a near miss.'),
 ('SAFETY_SIGN', 'uncontrolled release', 'Safety language: an uncontrolled release, a hissing leak that is getting louder, a blowout or a pressure release that will not stop.'),
 ('SAFETY_SIGN', 'when in doubt', 'When in doubt, say yes - HSE decides, and a false alarm costs little.'),
 ('NOT_SAFETY', 'misfire', 'An engine misfire is not safety language by itself.'),
 ('NOT_SAFETY', 'hot', 'Hot or running hot (a temperature) is not safety language by itself.'),
 ('NOT_SAFETY', 'grease slinging / purging', 'Grease slinging or purging from a bearing is lubricant loss (a bearing sign), not a spill and not safety language by itself.'),
 ('NOT_SAFETY', 'weeping / seeping packing', 'Weeping or seeping packing with no fluid on the ground is not safety language by itself; fluid on the ground is a spill.'),
 ('CREW_CHECK', 'bearing_wear', 'Record the vibration at the bearing housing and the oil or grease condition, and listen through a full stroke or revolution before any bearing is ordered.'),
 ('CREW_CHECK', 'overheating', 'Record the housing temperature, the lubricant level and grade and the cooling (belts, fans, fluid level over an ESP) before any part is ordered.'),
 ('CREW_CHECK', 'seal_leak', 'Measure the leak rate, find where it comes from (packing, gasket or seal section) and photograph it before the repack is planned.'),
 ('CREW_CHECK', 'pressure_anomaly', 'Compare the local gauge with the transmitter and check the choke and the valves for restriction before any setting is changed.'),
 ('CREW_CHECK', 'flow_blockage', 'Check the intake, strainer or valve for scale, sand, paraffin or hydrates and record the fillage or flow trend before a cleanout is planned.'),
 ('CREW_CHECK', 'electrical_fault', 'Record the controller or drive fault code and have a qualified electrician test the motor and cable before any part is ordered.'),
 ('CREW_CHECK', 'none', 'No fault described - log the note for monitoring and compare it with the next sensor reading.'),
 ('CREW_CHECK', 'safety language', 'Safety language found - for HSE to assess; no crew task is suggested from this note.'),
 ('SHORTHAND', 'SPM', 'strokes per minute'),
 ('SHORTHAND', 'fluid pound / pump-off', 'low fillage of the rod pump'),
 ('SHORTHAND', 'rod pump parts', 'horsehead, walking beam, saddle bearing, wrist pin, gearbox; the stuffing box and polished rod are its wellhead seal'),
 ('SHORTHAND', 'ESP', 'electric submersible pump (seal or protector section, gas separator, intake, drive)'),
 ('SHORTHAND', 'compressor parts', 'scrubber, rod packing, cooler / fin fan, throw'),
 ('SHORTHAND', 'wellhead valve parts', 'bonnet, stem packing, gate, seat, actuator'),
 ('RULE', 'asset system backstop', 'The asset system itself also matches these literal words: gas odor, smell of gas, H2S, hydrogen sulfide, spill, fire, flames, smoke, injury, explosion, blowout, uncontrolled release. Your job is the paraphrases it cannot see.'),
 ('RULE', 'modes from your list', 'Pick the failure mode only from the list you are given; the failure-mode rows here only explain the codes.'),
 ('RULE', 'copy the crew check', 'Copy the crew check of the failure mode you pick (or of safety language) exactly as this guide words it.');

-- similar_failure_agent: match levels with their standard notes, worked examples, a glossary of failure terms and the
-- ranking / copying rules. The past work orders themselves still come from the orchestrator (failure_history).
INSERT INTO failure_match_guide (section, term, meaning) VALUES
 ('MATCH_LEVEL', 'STRONG', 'The same failure mode AND the same component, even in other words. Standard note: Same component failing the same way - the recorded fix is the first reference for the crew to confirm on site.'),
 ('MATCH_LEVEL', 'MODERATE', 'The same failure mode on a different component of the same machine. Standard note: Same failure mode on another component - use the recorded fix as background only.'),
 ('MATCH_LEVEL', 'WEAK', 'A shared symptom only (noise, heat); list WEAK matches only when nothing better exists. Standard note: Shared symptom only - a weak reference until the crew confirms the cause.'),
 ('MATCH_LEVEL', 'NO_MATCH', 'Nothing in the rows matches. Standard note: No close match in the Mesa Ridge reliability library - the crew diagnoses on site.'),
 ('EXAMPLE', 'growl vs squeal', '''growl from the gearbox on every downstroke'' and ''high-pitched squeal from the saddle bearing'' are both rod-pump bearing wear.'),
 ('EXAMPLE', 'hot rod vs bearing', '''polished rod running hot, oil weeping at the stuffing box'' is a seal leak, not bearing wear, even though both mention heat.'),
 ('TERM', 'fluid pound', 'The rod pump plunger hits fluid after a partly empty stroke (low fillage) - a flow_blockage sign, not bearing wear.'),
 ('TERM', 'gas lock', 'Gas fills the pump so it moves no fluid - a flow_blockage sign.'),
 ('TERM', 'scale / sand / paraffin', 'Deposits that plug an intake, strainer or valve - flow_blockage.'),
 ('TERM', 'hydrates', 'Ice-like gas hydrates that block a valve or line in cold weather - flow_blockage.'),
 ('TERM', 'packing', 'The seal around a moving rod or stem (stuffing box, rod packing, stem packing); a leak there is seal_leak.'),
 ('TERM', 'protector section', 'The ESP seal section that keeps well fluid out of the motor - seal_leak when it fails.'),
 ('TERM', 'megger', 'An insulation-resistance test of a motor or cable - an electrical_fault check.'),
 ('TERM', 'top-end overhaul', 'Compressor valves, rings and packing replaced together.'),
 ('TERM', 'workover', 'Pulling the tubing and downhole equipment with a rig, needed to change an ESP.'),
 ('TERM', 'downtime', 'Hours the asset was not producing for the job, as recorded on the work order.'),
 ('RULE', 'component and way of failing', 'Match on the failing component and the way it fails, not on wording.'),
 ('RULE', 'ranking', 'Rank STRONG first, then MODERATE, then WEAK; within a level, the most recent first. At most 3 matches.'),
 ('RULE', 'copy exactly', 'Copy the fix and the parts exactly as recorded; never improve or combine them.'),
 ('RULE', 'reference, not instruction', 'A past fix is a reference for the crew, not an instruction.'),
 ('RULE', 'rows given only', 'Use only the work orders you are given; never invent one.');

-- shift_handover_agent: the handover sections in order, every status code in plain words, standard lines and rules.
INSERT INTO handover_guide (section, term, meaning) VALUES
 ('SECTION', '1 Safety', 'Safety first: any open case waiting for HSE (its detail ends with SAFETY) and any field note whose status is SAFETY_CASE.'),
 ('SECTION', '2 Asset health', 'CRITICAL assets, then WARNING assets, each with the worst sensor, the likely failure mode and the days to failure as given.'),
 ('SECTION', '3 Open work', 'Open work orders by priority - EMERGENCY, then URGENT, then HIGH, then ROUTINE - with the crew and the scheduled date.'),
 ('SECTION', '4 Alerts', 'Alerts that are not closed, CRITICAL first.'),
 ('SECTION', '5 Waiting on people / decisions', 'Other cases waiting for a person (team and reply-due time), then decisions made in the last 24 hours. A case is named by its request type, e.g. shut-in.'),
 ('SECTION', '6 Watch items', 'At most 3 things the next shift must chase, separated by semicolons.'),
 ('STATUS', 'OPEN', 'open - not started (work order), not yet handled (alert), or waiting for a person (case)'),
 ('STATUS', 'SCHEDULED', 'crew and date booked, work not started'),
 ('STATUS', 'IN_PROGRESS', 'in work - the crew is on it'),
 ('STATUS', 'CLOSED', 'closed in the system'),
 ('STATUS', 'ACKNOWLEDGED', 'seen by the control room, still open'),
 ('STATUS', 'APPROVED', 'approved by the reviewing team'),
 ('STATUS', 'REJECTED', 'not approved by the reviewing team'),
 ('STATUS', 'NORMAL', 'every sensor inside its limits'),
 ('STATUS', 'WARNING', 'at least one sensor past its warning limit'),
 ('STATUS', 'CRITICAL', 'at least one sensor past its critical limit'),
 ('STATUS', 'SAFETY_CASE', 'sent to HSE as a safety signal'),
 ('STATUS', 'WORK_ORDER_ELIGIBLE', 'a work order can be proposed'),
 ('STATUS', 'MONITOR', 'logged for monitoring, no work order from it'),
 ('STATUS', 'OPERATIONAL', 'running'),
 ('STATUS', 'MAINTENANCE', 'in maintenance'),
 ('STATUS', 'SHUT_IN', 'shut in by Production Engineering'),
 ('STANDARD_LINE', 'empty section', 'Nothing to hand over.'),
 ('STANDARD_LINE', 'closing line', 'Snapshot from the Mesa Ridge asset system at handover - statuses as recorded, not a safety assessment.'),
 ('STANDARD_LINE', 'emergency work', 'EMERGENCY work order - confirm the crew is on its way at shift start.'),
 ('STANDARD_LINE', 'reply due this shift', 'Reply due within this shift - chase the team if there is no answer.'),
 ('STANDARD_LINE', 'with HSE', 'With HSE - wait for their decision before any work on this asset.'),
 ('RULE', 'no names', 'No people''s names, even if one appears in the input; a case is named by its request type.'),
 ('RULE', 'length', 'Each line one sentence. At most 20 lines in total.'),
 ('RULE', 'status words', 'Write each status as its plain words from this guide followed by the code in brackets, e.g. in work - the crew is on it (IN_PROGRESS).'),
 ('RULE', 'references', 'Use asset ids and references exactly as given (MRE-WO-... work orders, ALR-... alerts).'),
 ('RULE', 'no safety calls', 'Never state that an asset or a site is safe - only report statuses as given.');

-- Assets: <TYPE>-<SITE>-<well or station>, always matching the site.
INSERT INTO assets (asset_id, asset_type, site_id, description, install_date, status) VALUES
 ('PUMP-PB-W47',  'ROD_PUMP',       'PB', 'Rod pump unit - Well 47',              current_date - 940,  'OPERATIONAL'),
 ('PUMP-PB-W48',  'ROD_PUMP',       'PB', 'Rod pump unit - Well 48',              current_date - 840,  'OPERATIONAL'),
 ('COMP-PB-S12',  'COMPRESSOR',     'PB', 'Gas compressor - Station 12',          current_date - 1070, 'OPERATIONAL'),
 ('PUMP-PB-W33',  'ESP',            'PB', 'Electric submersible pump - Well 33',  current_date - 1210, 'MAINTENANCE'),
 ('VALVE-PB-W52', 'WELLHEAD_VALVE', 'PB', 'Wellhead valve assembly - Well 52',    current_date - 700,  'OPERATIONAL'),
 ('PUMP-BK-W21',  'ESP',            'BK', 'Electric submersible pump - Well 21',  current_date - 1165, 'OPERATIONAL'),
 ('COMP-BK-S05',  'COMPRESSOR',     'BK', 'Gas compressor - Station 5',           current_date - 760,  'OPERATIONAL'),
 ('VALVE-BK-W03', 'WELLHEAD_VALVE', 'BK', 'Wellhead valve assembly - Well 3',     current_date - 995,  'OPERATIONAL'),
 ('PUMP-EF-W14',  'ROD_PUMP',       'EF', 'Rod pump unit - Well 14',              current_date - 1235, 'OPERATIONAL'),
 ('VALVE-EF-W07', 'WELLHEAD_VALVE', 'EF', 'Wellhead valve assembly - Well 7',     current_date - 815,  'OPERATIONAL');

-- Sensor readings: every 4 hours over the last 24 hours (offset = hours before the latest reading). The latest reading
-- sets the health status computed by classify_asset().
INSERT INTO sensor_readings (asset_id, reading_at, vibration_g, temperature_f, pressure_psi, flow_bbl_h, power_kw)
SELECT r.asset_id, date_trunc('hour', clock_timestamp()::timestamp) - r.off * INTERVAL '1 hour', r.vib, r.temp, r.pres, r.flow, r.pwr
  FROM (VALUES
   -- PUMP-PB-W47: WARNING - vibration climbing (bearing wear), temperature just over the line
   ('PUMP-PB-W47', 20, 3.2, 171.0, 1080.0, 100.5, 42.0), ('PUMP-PB-W47', 16, 3.6, 174.0, 1100.0, 98.0, 43.1),
   ('PUMP-PB-W47', 12, 4.1, 178.0, 1120.0, 97.2, 43.8),  ('PUMP-PB-W47',  8, 4.6, 182.0, 1130.0, 96.0, 44.5),
   ('PUMP-PB-W47',  4, 5.0, 186.0, 1140.0, 95.8, 45.0),  ('PUMP-PB-W47',  0, 5.4, 189.0, 1150.0, 95.2, 45.3),
   -- PUMP-PB-W48: NORMAL
   ('PUMP-PB-W48', 20, 2.0, 159.8, 1040.0, 103.0, 40.0), ('PUMP-PB-W48', 16, 2.1, 161.6, 1045.0, 102.8, 40.2),
   ('PUMP-PB-W48', 12, 1.9, 160.7, 1050.0, 103.2, 39.8), ('PUMP-PB-W48',  8, 2.0, 161.6, 1048.0, 102.5, 40.1),
   ('PUMP-PB-W48',  4, 2.1, 162.5, 1050.0, 102.0, 40.3), ('PUMP-PB-W48',  0, 2.1, 162.1, 1050.0, 102.5, 40.2),
   -- COMP-PB-S12: CRITICAL - discharge temperature (overheating), vibration and pressure up
   ('COMP-PB-S12', 20, 4.0, 194.0, 1250.0, 92.0, 78.0),  ('COMP-PB-S12', 16, 4.5, 203.0, 1300.0, 90.0, 80.5),
   ('COMP-PB-S12', 12, 5.2, 212.9, 1350.0, 89.0, 83.0),  ('COMP-PB-S12',  8, 5.8, 221.0, 1400.0, 88.5, 85.0),
   ('COMP-PB-S12',  4, 6.2, 228.2, 1450.0, 88.0, 87.0),  ('COMP-PB-S12',  0, 6.5, 233.6, 1480.0, 88.0, 88.5),
   -- PUMP-PB-W33: in MAINTENANCE (flow low - intake cleanout under way)
   ('PUMP-PB-W33', 20, 2.9, 175.0, 860.0, 82.0, 49.0),   ('PUMP-PB-W33', 16, 3.0, 175.5, 855.0, 80.5, 49.4),
   ('PUMP-PB-W33', 12, 3.0, 176.0, 850.0, 79.0, 49.6),   ('PUMP-PB-W33',  8, 3.1, 176.0, 846.0, 78.0, 49.8),
   ('PUMP-PB-W33',  4, 3.0, 176.4, 842.0, 76.8, 50.0),   ('PUMP-PB-W33',  0, 3.0, 176.0, 840.0, 76.0, 50.1),
   -- VALVE-PB-W52: NORMAL
   ('VALVE-PB-W52', 20, 1.7, 152.6, 975.0, 106.0, 12.0), ('VALVE-PB-W52', 16, 1.8, 154.4, 980.0, 105.5, 12.1),
   ('VALVE-PB-W52', 12, 1.7, 153.5, 978.0, 105.0, 12.0), ('VALVE-PB-W52',  8, 1.8, 154.4, 980.0, 105.2, 12.1),
   ('VALVE-PB-W52',  4, 1.9, 155.3, 982.0, 104.8, 12.2), ('VALVE-PB-W52',  0, 1.8, 154.4, 980.0, 105.0, 12.1),
   -- PUMP-BK-W21: WARNING - discharge pressure and flow falling (seal leak); seal job already in progress
   ('PUMP-BK-W21', 20, 3.3, 180.0, 850.0, 85.0, 48.0),   ('PUMP-BK-W21', 16, 3.5, 181.5, 820.0, 82.0, 49.5),
   ('PUMP-BK-W21', 12, 3.6, 183.0, 780.0, 78.0, 50.0),   ('PUMP-BK-W21',  8, 3.8, 185.0, 750.0, 76.0, 51.0),
   ('PUMP-BK-W21',  4, 3.9, 186.5, 720.0, 74.0, 51.5),   ('PUMP-BK-W21',  0, 4.0, 188.0, 690.0, 72.0, 52.0),
   -- COMP-BK-S05: NORMAL
   ('COMP-BK-S05', 20, 2.9, 170.6, 1090.0, 99.0, 70.0),  ('COMP-BK-S05', 16, 3.0, 172.4, 1095.0, 98.5, 70.5),
   ('COMP-BK-S05', 12, 2.8, 171.5, 1092.0, 99.0, 70.2),  ('COMP-BK-S05',  8, 3.0, 172.4, 1098.0, 98.0, 70.8),
   ('COMP-BK-S05',  4, 3.1, 173.3, 1100.0, 98.0, 71.0),  ('COMP-BK-S05',  0, 3.0, 173.3, 1100.0, 98.0, 70.8),
   -- VALVE-BK-W03: NORMAL
   ('VALVE-BK-W03', 20, 1.7, 152.6, 975.0, 106.0, 12.0), ('VALVE-BK-W03', 16, 1.8, 154.4, 980.0, 105.5, 12.1),
   ('VALVE-BK-W03', 12, 1.7, 153.5, 978.0, 105.0, 12.0), ('VALVE-BK-W03',  8, 1.8, 154.4, 980.0, 105.2, 12.1),
   ('VALVE-BK-W03',  4, 1.9, 155.3, 982.0, 104.8, 12.2), ('VALVE-BK-W03',  0, 1.8, 154.4, 980.0, 105.0, 12.1),
   -- PUMP-EF-W14: CRITICAL - every sensor out of range, vibration worst (bearing wear)
   ('PUMP-EF-W14', 20, 5.0, 197.6, 750.0, 72.0, 55.0),   ('PUMP-EF-W14', 16, 5.5, 204.8, 700.0, 68.0, 57.0),
   ('PUMP-EF-W14', 12, 6.0, 212.0, 660.0, 64.0, 59.0),   ('PUMP-EF-W14',  8, 6.5, 217.4, 620.0, 60.0, 61.0),
   ('PUMP-EF-W14',  4, 6.8, 222.8, 600.0, 57.0, 62.5),   ('PUMP-EF-W14',  0, 7.1, 226.4, 580.0, 55.0, 63.0),
   -- VALVE-EF-W07: NORMAL
   ('VALVE-EF-W07', 20, 2.4, 165.2, 1015.0, 111.0, 11.5), ('VALVE-EF-W07', 16, 2.5, 167.0, 1020.0, 110.5, 11.6),
   ('VALVE-EF-W07', 12, 2.4, 166.1, 1018.0, 110.0, 11.5), ('VALVE-EF-W07',  8, 2.5, 167.0, 1020.0, 110.2, 11.6),
   ('VALVE-EF-W07',  4, 2.6, 167.9, 1022.0, 109.8, 11.7), ('VALVE-EF-W07',  0, 2.5, 167.0, 1020.0, 110.0, 11.6)
  ) AS r (asset_id, off, vib, temp, pres, flow, pwr);

-- Work orders: the reliability library (closed, with the fix) + two open jobs.
INSERT INTO work_orders (wo_number, asset_id, wo_type, failure_mode, symptom, priority, status, crew, scheduled_date, estimate_usd,
                         opened_at, closed_at, fix_applied, parts_used, downtime_hours) VALUES
 ('MRE-WO-1001', 'PUMP-PB-W48', 'CORRECTIVE', 'bearing_wear', 'Growl from the gearbox on every downstroke, vibration climbing for a week, grease purging at the wrist pin.', 'HIGH', 'CLOSED', 'Permian Field Crew A', current_date - 88, 8400, now()::timestamp - INTERVAL '90 days', now()::timestamp - INTERVAL '85 days', 'Replaced both wrist-pin bearings and the saddle bearing, realigned the walking beam, changed the gearbox oil.', 'wrist-pin bearing kit, saddle bearing assembly, gearbox oil', 14),
 ('MRE-WO-1002', 'PUMP-EF-W14', 'CORRECTIVE', 'bearing_wear', 'High-pitched squeal from the saddle bearing area, vibration around 5 g, heat on the bearing housing.', 'HIGH', 'CLOSED', 'Eagle Ford Field Crew C', current_date - 163, 8400, now()::timestamp - INTERVAL '165 days', now()::timestamp - INTERVAL '160 days', 'Replaced the saddle bearing and greased the tail bearing; vibration back to 2 g.', 'saddle bearing assembly, grease', 10),
 ('MRE-WO-1003', 'PUMP-PB-W47', 'CORRECTIVE', 'seal_leak', 'Polished rod running hot, oil weeping at the stuffing box.', 'ROUTINE', 'CLOSED', 'Permian Field Crew A', current_date - 212, 3900, now()::timestamp - INTERVAL '214 days', now()::timestamp - INTERVAL '210 days', 'Repacked the stuffing box and replaced the polished rod liner.', 'stuffing box packing set, polished rod liner', 5),
 ('MRE-WO-1004', 'PUMP-EF-W14', 'CORRECTIVE', 'flow_blockage', 'Clunk on the downstroke, fluid pound on the dynamometer card, low fillage.', 'HIGH', 'CLOSED', 'Eagle Ford Field Crew C', current_date - 303, 6800, now()::timestamp - INTERVAL '305 days', now()::timestamp - INTERVAL '300 days', 'Slowed the unit from 8 to 6 strokes per minute and replaced the plugged gas anchor.', 'gas anchor', 12),
 ('MRE-WO-1005', 'PUMP-PB-W48', 'CORRECTIVE', 'electrical_fault', 'Unit stops at random; the pump-off controller shows a motor overload.', 'HIGH', 'CLOSED', 'Permian Field Crew A', current_date - 402, 7200, now()::timestamp - INTERVAL '404 days', now()::timestamp - INTERVAL '400 days', 'Replaced the motor contactor and reset the pump-off controller.', 'motor contactor', 8),
 ('MRE-WO-1006', 'PUMP-BK-W21', 'CORRECTIVE', 'seal_leak', 'Discharge pressure dropping, flow down about 10 percent, motor current unstable.', 'HIGH', 'CLOSED', 'Bakken Field Crew B', current_date - 27, 9500, now()::timestamp - INTERVAL '30 days', now()::timestamp - INTERVAL '25 days', 'Inspected the seal section: early seal wear, protector oil topped up, monitoring increased.', 'protector oil', 18),
 ('MRE-WO-1007', 'PUMP-PB-W33', 'CORRECTIVE', 'flow_blockage', 'Flow falling off, intake pressure rising, motor amps cycling.', 'HIGH', 'CLOSED', 'Permian Field Crew A', current_date - 143, 12000, now()::timestamp - INTERVAL '145 days', now()::timestamp - INTERVAL '140 days', 'Treated the intake with acid and cleaned out the gas separator.', 'scale-inhibitor treatment, gas separator', 22),
 ('MRE-WO-1008', 'COMP-BK-S05', 'CORRECTIVE', 'overheating', 'Discharge temperature high, one cooler fan not turning, belt squeal.', 'URGENT', 'CLOSED', 'Bakken Field Crew B', current_date - 122, 7400, now()::timestamp - INTERVAL '124 days', now()::timestamp - INTERVAL '120 days', 'Replaced the cooler fan belt and bearings and washed the cooler fins.', 'cooler fan belt and bearings', 16),
 ('MRE-WO-1009', 'COMP-PB-S12', 'CORRECTIVE', 'bearing_wear', 'Knock in the crankcase under load, oil pressure dropping.', 'URGENT', 'CLOSED', 'Permian Field Crew A', current_date - 335, 41000, now()::timestamp - INTERVAL '338 days', now()::timestamp - INTERVAL '330 days', 'Replaced the main and rod bearings and flushed the lube system.', 'main bearing set, rod bearing set, lube oil filter', 90),
 ('MRE-WO-1010', 'COMP-PB-S12', 'CORRECTIVE', 'seal_leak', 'Gas venting at the rod packing, packing vent flow high.', 'HIGH', 'CLOSED', 'Permian Field Crew A', current_date - 203, 12500, now()::timestamp - INTERVAL '205 days', now()::timestamp - INTERVAL '200 days', 'Replaced the rod packing on throws 1 and 2.', 'rod packing set', 20),
 ('MRE-WO-1011', 'VALVE-BK-W03', 'CORRECTIVE', 'seal_leak', 'Bonnet weeping, slight hiss at the stem.', 'ROUTINE', 'CLOSED', 'Bakken Field Crew B', current_date - 97, 3200, now()::timestamp - INTERVAL '98 days', now()::timestamp - INTERVAL '95 days', 'Replaced the bonnet gasket and the stem packing.', 'bonnet gasket, stem packing set', 4),
 ('MRE-WO-1012', 'VALVE-EF-W07', 'CORRECTIVE', 'flow_blockage', 'Valve hard to stroke in a cold snap, flow restricted.', 'HIGH', 'CLOSED', 'Eagle Ford Field Crew C', current_date - 262, 2400, now()::timestamp - INTERVAL '263 days', now()::timestamp - INTERVAL '260 days', 'Cleared a hydrate with methanol injection and serviced the actuator.', 'hydrate inhibitor', 5);

INSERT INTO work_orders (wo_number, asset_id, wo_type, failure_mode, symptom, priority, status, crew, scheduled_date, estimate_usd, opened_at) VALUES
 ('MRE-WO-1028', 'PUMP-BK-W21', 'CORRECTIVE', 'seal_leak', 'Seal degradation progressing - pull the ESP and replace the seal section.', 'HIGH', 'IN_PROGRESS', 'Bakken Field Crew B', current_date + 2, 29000, now()::timestamp - INTERVAL '4 days'),
 ('MRE-WO-1029', 'PUMP-PB-W33', 'CORRECTIVE', 'flow_blockage', 'Intake scale cleanout and gas separator change.', 'HIGH', 'IN_PROGRESS', 'Permian Field Crew A', current_date, 12000, now()::timestamp - INTERVAL '2 days');

-- Alerts (monitoring system). PUMP-EF-W14 already has today's alert (-> ALREADY_LOGGED_TODAY).
INSERT INTO alerts (alert_id, asset_id, severity, failure_mode, message, logged_date, logged_at, logged_by, status, closed_at) VALUES
 ('ALR-000090', 'COMP-BK-S05', 'WARNING', 'overheating', 'WARNING - COMP-BK-S05 | discharge temperature high | cooler fan', current_date - 124,
  now()::timestamp - INTERVAL '124 days', NULL, 'CLOSED', now()::timestamp - INTERVAL '120 days'),
 ('ALR-000091', 'PUMP-BK-W21', 'WARNING', 'seal_leak', 'WARNING - PUMP-BK-W21 | ESP seal section leak | pressure and flow falling', current_date - 3,
  now()::timestamp - INTERVAL '3 days', NULL, 'ACKNOWLEDGED', NULL),
 ('ALR-000092', 'PUMP-EF-W14', 'CRITICAL', 'bearing_wear', 'CRITICAL - PUMP-EF-W14 | rod pump bearing wear | all sensors out of range', current_date,
  greatest(now()::timestamp - INTERVAL '2 hours', current_date::timestamp), NULL, 'OPEN', NULL);

-- Seeded OPEN cases so both reviewer queues are never empty.
INSERT INTO service_cases (case_no, case_id, site_id, asset_id, opened_by, request_type, summary, reference_id, requested_amount,
                           parked_action, agent_brief, status, sla_due_at, created_at) VALUES
 (101, 'MRE-CASE-000101', 'BK', 'COMP-BK-S05', 'MRE-4201', 'threshold_change',
  'Raise the vibration warning line for COMP-BK-S05 from 3.5 to 4.0 g: since the new skid mount it reads about 0.4 g higher at the same load.',
  'COMP-BK-S05', NULL, NULL, NULL, 'OPEN', now()::timestamp + INTERVAL '19 hours', now()::timestamp - INTERVAL '5 hours'),
 (102, 'MRE-CASE-000102', 'BK', 'PUMP-BK-W21', 'MRE-4201', 'alert_closure',
  'Close alert ALR-000091: the seal replacement (MRE-WO-1028) is in progress and the alert has been acknowledged.',
  'ALR-000091', NULL, 'ALERT_CLOSE:ALR-000091', NULL, 'OPEN', now()::timestamp + INTERVAL '5 hours', now()::timestamp - INTERVAL '3 hours'),
 (103, 'MRE-CASE-000103', 'EF', 'VALVE-EF-W07', 'MRE-4301', 'safety_signal',
  'Field note on VALVE-EF-W07: "Small dark stain on the gravel under the flowline flange, maybe a slow drip, no odor."',
  'VALVE-EF-W07', NULL, 'SAFETY_WO:VALVE-EF-W07',
  'Triage agent: possible slow hydrocarbon drip at the flowline flange; no odor reported | safety language: stain / drip (source AGENT) | sensors: NORMAL',
  'OPEN', now()::timestamp + INTERVAL '20 minutes', now()::timestamp - INTERVAL '40 minutes');

-- Sequences: new ids continue after the seeded ones.
SELECT setval(pg_get_serial_sequence('service_cases', 'case_no'), 103);
SELECT setval('wo_seq', 1101, false);
SELECT setval('alert_seq', 101, false);
SELECT setval('note_seq', 101, false);
SELECT setval('sht_seq', 101, false);
