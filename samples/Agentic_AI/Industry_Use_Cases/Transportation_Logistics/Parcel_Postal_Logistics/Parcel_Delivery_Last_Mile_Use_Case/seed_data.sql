-- Demo data for Swiftbound Last-Mile Parcel Delivery (governed). Fictional carrier, people, staff and parcels.
-- Dates are relative to CURRENT_DATE / now() so the demo always looks "today".
-- Included by database.sql and reset_data.sql via \ir - do not load on its own.

-- Cryptic tracking exception codes and their plain-English meaning (deterministic lookup; never model-invented).
INSERT INTO exception_codes (code, label, recipient_advice) VALUES
 ('NSH','Delivery attempted - nobody available to receive the parcel','Reschedule for a day you will be in, or redirect it to a nearby pickup point.'),
 ('ANF','Address could not be located / incomplete address','Confirm or correct your delivery address with the sender; we can also redirect it to a pickup point.'),
 ('REF','Parcel was refused at the door','If this was a mistake, reschedule a new attempt; otherwise it will be returned to the sender.'),
 ('DMG','Parcel reported damaged in transit','Open a damaged-parcel claim so a person can review it; do not accept a visibly damaged parcel.'),
 ('CUS','Held for customs clearance','No action is needed yet; clearance usually completes within 48 hours and delivery resumes automatically.'),
 ('WEA','Delayed by severe weather in the delivery area','Delivery will be re-attempted automatically once conditions allow.');

INSERT INTO recipients (recipient_id, account_ref, verification_pin, first_name, last_name, email, phone, address_line, postcode, service_area) VALUES
 ('RCP-2026-00101','K4R2QX','4021','Emma','Carter','emma.carter@example.com','+1-415-555-0101','14 Maple Ave','N1','NORTHSIDE'),
 ('RCP-2026-00102','W7M9PL','7788','Liam','Walsh','liam.walsh@example.com','+1-415-555-0102','9 Harbor St','W2','WESTEND'),
 ('RCP-2026-00103','D3H8TN','5590','Noah','Reyes','noah.reyes@example.com','+1-415-555-0103','27 Center Blvd','D3','DOWNTOWN'),
 ('RCP-2026-00104','A6L3HK','3344','Ava','Thompson','ava.thompson@example.com','+1-415-555-0104','3 Birch Lane','N4','NORTHSIDE'),
 ('RCP-2026-00105','M2P7VB','6150','Olivia','Grant','olivia.grant@example.com','+1-415-555-0105','61 Elm Court','D7','DOWNTOWN'),
 ('RCP-2026-00106','T8J4NC','2468','Sofia','Ramirez','sofia.ramirez@example.com','+1-415-555-0106','8 Willow Rd','W5','WESTEND'),
 ('RCP-2026-00107','H5R8WD','9137','Lucas','Bennett','lucas.bennett@example.com','+1-415-555-0107','40 Cedar St','N2','NORTHSIDE'),
 ('RCP-2026-00108','P9Q2ZE','8064','Chloe','Nguyen','chloe.nguyen@example.com','+1-415-555-0108','5 Spruce Way','D1','DOWNTOWN');

-- Delivery slots (area-scoped, capacity-limited). SLOT-N0 is deliberately in the past; SLOT-N3 is full.
INSERT INTO delivery_slots (slot_id, service_area, slot_date, window_start, window_end, capacity, booked_count) VALUES
 ('SLOT-N0','NORTHSIDE', current_date - 1, '09:00','12:00', 5, 0),
 ('SLOT-N1','NORTHSIDE', current_date + 1, '09:00','12:00', 5, 2),
 ('SLOT-N2','NORTHSIDE', current_date + 1, '18:00','21:00', 5, 1),
 ('SLOT-N3','NORTHSIDE', current_date + 2, '09:00','12:00', 3, 3),
 ('SLOT-W1','WESTEND',   current_date + 1, '13:00','16:00', 5, 0),
 ('SLOT-W2','WESTEND',   current_date + 2, '18:00','21:00', 5, 1),
 ('SLOT-D1','DOWNTOWN',  current_date + 1, '10:00','13:00', 5, 0);

-- Pickup points: unattended lockers (max MEDIUM) and staffed shops (max LARGE, accept signature & high value).
INSERT INTO pickup_points (pickup_id, point_type, name, service_area, address_line, max_parcel_size, open_hours) VALUES
 ('PU-N-LOCK1','LOCKER','Northside Station Lockers','NORTHSIDE','123 North Rd','MEDIUM','Mon-Sun 24h'),
 ('PU-N-SHOP1','SHOP','Corner Mart Northside','NORTHSIDE','5 Market St','LARGE','Mon-Sun 07:00-22:00'),
 ('PU-W-LOCK1','LOCKER','Westend Mall Lockers','WESTEND','West Mall, Level 1','MEDIUM','Mon-Sun 06:00-23:00'),
 ('PU-W-SHOP1','SHOP','Westend News & Post','WESTEND','88 West Ave','LARGE','Mon-Sat 08:00-20:00'),
 ('PU-D-SHOP1','SHOP','Downtown Pharmacy','DOWNTOWN','2 Central Sq','LARGE','Mon-Sun 08:00-21:00');

-- Parcels
INSERT INTO parcels (tracking_number, recipient_id, description, sender, declared_value, parcel_size,
  signature_required, service_level, destination_area, destination_postcode, promised_date, current_status,
  exception_code, attempts_made, expected_delivery) VALUES
 -- Emma (NORTHSIDE): failed attempt (flagship reschedule); high-value signature watch (locker guards)
 ('SB100000000001','RCP-2026-00101','Wireless headphones','AudioZone',120.00,'SMALL',FALSE,'STANDARD','NORTHSIDE','N1', current_date, 'EXCEPTION','NSH',1, NULL),
 ('SB100000000002','RCP-2026-00101','Designer watch','LuxTime',950.00,'SMALL',TRUE,'EXPRESS','NORTHSIDE','N1', current_date, 'EXCEPTION','NSH',1, NULL),
 ('SB100000000008','RCP-2026-00101','Gaming console','GameStop',650.00,'SMALL',FALSE,'STANDARD','NORTHSIDE','N1', current_date, 'EXCEPTION','NSH',1, NULL),
 -- Liam (WESTEND): large box (locker oversize); grocery box already out for delivery
 ('SB100000000003','RCP-2026-00102','Office chair (boxed)','DeskPro',180.00,'LARGE',FALSE,'STANDARD','WESTEND','W2', current_date, 'EXCEPTION','NSH',1, NULL),
 ('SB100000000004','RCP-2026-00102','Weekly grocery box','FreshCart',40.00,'MEDIUM',FALSE,'EXPRESS','WESTEND','W2', current_date, 'OUT_FOR_DELIVERY',NULL,0, current_date + time '17:00'),
 -- Noah (DOWNTOWN): delivered (cannot reschedule); damaged in transit (claim)
 ('SB100000000005','RCP-2026-00103','Paperback books','ReadMore',60.00,'SMALL',FALSE,'STANDARD','DOWNTOWN','D3', current_date - 1, 'DELIVERED',NULL,1, current_date - 1 + time '11:20'),
 ('SB100000000006','RCP-2026-00103','Ceramic vase','HomeStyle',85.00,'MEDIUM',FALSE,'STANDARD','DOWNTOWN','D3', current_date, 'EXCEPTION','DMG',1, NULL),
 -- Ava (NORTHSIDE): in customs (decode CUS); used for the cross-account scope test
 ('SB100000000007','RCP-2026-00104','Phone case','GadgetHub',25.00,'SMALL',FALSE,'STANDARD','NORTHSIDE','N4', current_date + 2, 'EXCEPTION','CUS',0, NULL),
 -- Sofia (WESTEND): delivery instructions storyline - an upcoming parcel, and a signature-required phone
 ('SB100000000009','RCP-2026-00106','Garden tools set','GreenThumb',95.00,'MEDIUM',FALSE,'STANDARD','WESTEND','W5', current_date + 1, 'IN_TRANSIT',NULL,0, NULL),
 ('SB100000000010','RCP-2026-00106','Smartphone','PhoneHub',899.00,'SMALL',TRUE,'EXPRESS','WESTEND','W5', current_date + 2, 'IN_TRANSIT',NULL,0, NULL),
 -- Olivia (DOWNTOWN): a laptop delivered yesterday - the damage claim storyline (claimable amount capped by coverage)
 ('SB100000000011','RCP-2026-00105','Laptop','TechNova',1180.00,'MEDIUM',FALSE,'STANDARD','DOWNTOWN','D7', current_date - 1, 'DELIVERED',NULL,1, current_date - 1 + time '10:40'),
 -- Lucas (NORTHSIDE) and Chloe (DOWNTOWN): the parcels behind the already-open cases in the reviewer queues
 ('SB100000000012','RCP-2026-00107','Camera lens','LensCraft',650.00,'SMALL',FALSE,'STANDARD','NORTHSIDE','N2', current_date - 2, 'DELIVERED',NULL,1, current_date - 2 + time '15:10'),
 ('SB100000000013','RCP-2026-00107','Hiking boots','TrailHead',160.00,'MEDIUM',FALSE,'STANDARD','NORTHSIDE','N2', current_date - 6, 'IN_TRANSIT',NULL,0, NULL),
 ('SB100000000014','RCP-2026-00108','Cosmetics set (3 items)','GlowLab',140.00,'SMALL',FALSE,'STANDARD','DOWNTOWN','D1', current_date - 3, 'DELIVERED',NULL,1, current_date - 3 + time '12:05'),
 ('SB100000000015','RCP-2026-00108','Desk lamp','BrightHome',70.00,'MEDIUM',FALSE,'STANDARD','DOWNTOWN','D1', current_date - 4, 'DELIVERED',NULL,1, current_date - 4 + time '16:30');

-- Scan timelines (newest last). Enough to make the tracking history realistic for the key parcels.
INSERT INTO scan_events (parcel_id, event_at, location, scan_code, description) VALUES
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000001'), current_date - 2 + time '18:05','AudioZone Warehouse','PU','Parcel collected from sender'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000001'), current_date - 1 + time '03:40','Swiftbound Hub','IT','Arrived at sorting hub'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000001'), current_date + time '07:55','Northside Depot','OFD','Out for delivery'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000001'), current_date + time '14:20','14 Maple Ave','NSH','Delivery attempted - nobody home'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000002'), current_date - 1 + time '09:10','Swiftbound Hub','IT','Arrived at sorting hub'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000002'), current_date + time '08:00','Northside Depot','OFD','Out for delivery'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000002'), current_date + time '13:05','14 Maple Ave','NSH','Delivery attempted - signature required, nobody home'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000008'), current_date + time '08:10','Northside Depot','OFD','Out for delivery'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000008'), current_date + time '13:40','14 Maple Ave','NSH','Delivery attempted - nobody home'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000003'), current_date + time '08:30','Westend Depot','OFD','Out for delivery'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000003'), current_date + time '12:45','9 Harbor St','NSH','Delivery attempted - nobody home'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000004'), current_date + time '07:30','Westend Depot','OFD','Out for delivery'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000005'), current_date - 1 + time '11:20','27 Center Blvd','DEL','Delivered - left with recipient'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000006'), current_date + time '09:15','Downtown Depot','DMG','Parcel found damaged during handling'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000007'), current_date - 1 + time '22:00','International Gateway','CUS','Held for customs clearance'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000009'), current_date + time '06:50','Swiftbound Hub','IT','Arrived at sorting hub'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000010'), current_date + time '07:15','Swiftbound Hub','IT','Arrived at sorting hub'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000011'), current_date - 1 + time '07:40','Downtown Depot','OFD','Out for delivery'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000011'), current_date - 1 + time '10:40','61 Elm Court','DEL','Delivered - handed to recipient'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000012'), current_date - 2 + time '15:10','40 Cedar St','DEL','Delivered - left at front door'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000013'), current_date - 8 + time '10:00','TrailHead Warehouse','PU','Parcel collected from sender'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000013'), current_date - 7 + time '02:30','Swiftbound Hub','IT','Arrived at sorting hub'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000014'), current_date - 3 + time '12:05','5 Spruce Way','DEL','Delivered - left in parcel room'),
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000015'), current_date - 4 + time '16:30','15 Spruce Way','DEL','Delivered - left at front door');

-- Routing table: team, reply time (business days), plain label and the claim type routed to each Claims team.
INSERT INTO service_teams (request_type, team, sla_days, label, claim_type) VALUES
 ('LOST_PARCEL','Claims (lost parcels)',7,'lost-parcel claim','LOST'),
 ('DAMAGED_PARCEL','Claims (damaged parcels)',7,'damaged-parcel claim','DAMAGED'),
 ('MISSING_ITEMS','Claims (missing contents)',7,'missing-contents claim','MISSING_CONTENTS'),
 ('WRONG_DELIVERY','Investigations',5,'wrong-delivery investigation',NULL),
 ('DELIVERY_COMPLAINT','Customer Relations',10,'delivery complaint',NULL),
 ('OTHER','Customer Care',5,'request',NULL);

-- Staff reviewers (the human in the loop). Hannah's 500 limit sits below the seeded 650 lens claim and Olivia's
-- 1,000 laptop claim (OVER_AUTHORITY demo); Victor is the senior damaged-parcel reviewer.
INSERT INTO reviewers (reviewer_id, display_name, team, one_time_code, approval_limit) VALUES
 ('SWB-4101','Hannah Brooks','Claims (damaged parcels)','418302',500.00),
 ('SWB-4102','Victor Osei','Claims (damaged parcels)','905127',2500.00),
 ('SWB-4103','Mei Tanaka','Claims (missing contents)','336914',750.00),
 ('SWB-4104','Daniel Ruiz','Claims (lost parcels)','772049',1500.00),
 ('SWB-4105','Grace Mensah','Investigations','260581',300.00),
 ('SWB-4106','Owen Fitzgerald','Customer Relations','649273',250.00);

-- ---------------------------------------------------------------------
-- Reference data of the A2A agents (no personal data).
-- ---------------------------------------------------------------------
INSERT INTO claim_guide (section, term, meaning) VALUES
 ('CLAIM_TYPE','DAMAGED','The parcel arrived, or was found in transit, with the item broken, cracked, dented, crushed or not working because of transport.'),
 ('CLAIM_TYPE','MISSING_CONTENTS','The parcel arrived but one or more items that should be inside are not there, or the box was opened and items taken.'),
 ('CLAIM_TYPE','LOST','The parcel never arrived and tracking has never shown it as delivered.'),
 ('PACKAGING','INTACT','Outer box and tape are undamaged, with no sign of an impact from outside.'),
 ('PACKAGING','OUTER_DAMAGE_ONLY','Dents, scuffs or a torn label on the outside, but the box is not crushed or opened.'),
 ('PACKAGING','CRUSHED','The box is crushed, caved in or flattened on one or more corners or sides.'),
 ('PACKAGING','TORN_OR_OPENED','The box or tape is torn, cut or opened, or the seal is broken.'),
 ('PACKAGING','WET','The box is wet, water-stained or soft from moisture.'),
 ('PACKAGING','NOT_STATED','The recipient did not describe the packaging, or there is no packaging to describe (a lost parcel).'),
 ('CAUSE','IMPACT_DROP','Damage consistent with a drop or a hard knock during handling.'),
 ('CAUSE','CRUSHING_LOAD','Damage consistent with heavy items stacked on top of the parcel.'),
 ('CAUSE','WATER_EXPOSURE','Damage from rain, a wet floor or another source of water.'),
 ('CAUSE','PUNCTURE','A hole or cut through the packaging into the item.'),
 ('CAUSE','TAMPERING_THEFT','Signs that the parcel was opened in transit and items were removed.'),
 ('CAUSE','INSUFFICIENT_PACKING','The item moved inside the box because it was packed loosely or without padding (a sender packing issue).'),
 ('CAUSE','UNKNOWN','The description does not show a likely cause.'),
 ('EVIDENCE','DAMAGED','Photos of the outer box from all sides, a close-up photo of the shipping label, photos of the damaged item, and the box and packing materials kept for inspection.'),
 ('EVIDENCE','MISSING_CONTENTS','Photos of the opened box and its seal, a photo of the shipping label, and the packing slip or order list that shows what should have been inside.'),
 ('EVIDENCE','LOST','The order confirmation or receipt that shows the item and its value, and a short statement that nobody at the address received the parcel.'),
 ('CLAIM_LINE','STANDARD_LINE','Keep the item and every piece of its packaging until a Swiftbound claims specialist has decided the claim, because it may be inspected.'),
 ('BRIEF_RULE','NO_AMOUNTS','Never state, estimate or suggest a compensation amount or whether the claim will be paid; the claims team decides.'),
 ('BRIEF_RULE','WORDS_AS_GIVEN','Quote the recipient''s own words for the damage; never add damage they did not describe.'),
 ('BRIEF_RULE','ONE_TYPE','Choose exactly one claim type; if both damage and missing items are described, choose the larger loss and mention the other in the summary.');

INSERT INTO safe_places (place_code, attended, meaning) VALUES
 ('FRONT_DOOR', FALSE, 'At the front door, tucked out of the rain.'),
 ('PORCH', FALSE, 'On a covered porch or veranda at the entrance.'),
 ('SIDE_GATE', FALSE, 'Behind a side gate or in a side passage, out of sight from the street.'),
 ('BACK_DOOR', FALSE, 'At the back door, reached through a garden or yard.'),
 ('GARAGE', FALSE, 'Inside an open or unlocked garage or carport at the address.'),
 ('MAILROOM', FALSE, 'In the building''s parcel room or residents'' parcel lockers.'),
 ('NAMED_NEIGHBOUR', FALSE, 'Handed to one neighbour the recipient names by house number or name - never just any neighbour.'),
 ('BUILDING_RECEPTION', TRUE, 'Handed to a staffed reception desk, concierge or front office at the address.'),
 ('HAND_TO_RECIPIENT', TRUE, 'Handed only to the recipient, or to someone at the address who signs for it; never left unattended.');

INSERT INTO instruction_risk_flags (flag_code, phrases, meaning) VALUES
 ('LEAVE_ON_STREET', ARRAY['on the street','on the sidewalk','on the pavement','on the curb','on the kerb','by the road','at the roadside'],
  'Swiftbound never leaves a parcel on the street, sidewalk or curb.'),
 ('ANY_NEIGHBOUR', ARRAY['any neighbo','whichever neighbo','anyone next door','anybody next door','anyone who answers'],
  'Swiftbound only leaves a parcel with a neighbour the recipient names, never with any neighbour.'),
 ('LEAVE_IN_VEHICLE', ARRAY['in my car ','in my car.','in my car,','inside my car','in my truck','in my van','in the trunk'],
  'Swiftbound drivers never put a parcel inside a vehicle.'),
 ('UNSECURED_IN_VIEW', ARRAY['in plain sight','in plain view','anywhere outside','leave it anywhere','visible from the street'],
  'Swiftbound does not leave a parcel anywhere outside in view of the street.'),
 ('OVER_FENCE', ARRAY['over the fence','over the gate','over the wall','throw it'],
  'Swiftbound drivers never throw or drop a parcel over a fence, gate or wall.'),
 ('LEAVE_WITH_CHILD', ARRAY['with my kid','with my son','with my daughter','with the kids','with a child','with my children'],
  'Swiftbound does not hand a parcel to a child.');

INSERT INTO instruction_guide (section, term, meaning) VALUES
 ('HAZARD','DOG','A dog is loose or kept at the address; the driver must not enter the yard while the dog is out.'),
 ('HAZARD','STEPS','Steep steps or many stairs at the entrance.'),
 ('HAZARD','GATE_LATCH','A gate that must be closed and latched again behind the driver.'),
 ('HAZARD','SLIPPERY','A slippery path, ice or wet decking at the entrance.'),
 ('HAZARD','NO_PARKING','No safe place to stop the van right outside; park further along.'),
 ('HAZARD','CONSTRUCTION','Building work or blocked access at the address.'),
 ('MASK_RULE','ACCESS_CODES','Never repeat a gate, door, keypad or building code: write [code withheld] in its place and set access_code_present to yes; the recipient shares the code with the driver in the Swiftbound app.'),
 ('MASK_RULE','PHONE_NUMBERS','Never repeat a phone number: write [number withheld] in its place.'),
 ('DRIVER_LINE','STANDARD_LINE','If the safe place is not safe, not dry or not accessible, keep the parcel, leave a delivery card and try again the next working day.'),
 ('BRIEF_RULE','ONE_PLACE','Choose exactly one SAFE_PLACE term; if the recipient names none, write NONE.'),
 ('BRIEF_RULE','NEGATIONS','Respect "not" instructions: a place the recipient says not to use must never be the safe place.'),
 ('BRIEF_RULE','NO_DECISION','Never say the instructions are accepted or allowed; Swiftbound''s system checks them before anything is saved.');

-- ---------------------------------------------------------------------
-- Already-open cases so every reviewer queue has work (1-2 per team). Claims go through the SAME rule function
-- the tool uses (claim_row_for); the trigger opens the Claims case and parks the compensation. Seed briefs name no one.
-- ---------------------------------------------------------------------
INSERT INTO damage_claims (parcel_id, recipient_id, claim_type, packaging_condition, cause_category, claimed_amount,
  declared_value, coverage_limit, eligible_amount, evidence_required, recipient_statement, agent_notes, ignored_terms)
SELECT * FROM claim_row_for('RCP-2026-00107', 'SB100000000012', 'DAMAGED', 'CRUSHED', 'CRUSHING_LOAD', '',
  'The lens box was flattened on one side, the lens hood is snapped off and the front glass is cracked.',
  'claim_type: DAMAGED' || chr(10) || 'packaging_condition: CRUSHED' || chr(10) || 'likely_cause: CRUSHING_LOAD' || chr(10)
  || 'evidence_to_send: Photos of the outer box from all sides, a close-up photo of the shipping label, photos of the damaged item, and the box and packing materials kept for inspection.' || chr(10)
  || 'claim_line: Keep the item and every piece of its packaging until a Swiftbound claims specialist has decided the claim, because it may be inspected.' || chr(10)
  || 'summary: The box arrived flattened on one side. The lens hood is broken and the front glass is cracked.');
INSERT INTO damage_claims (parcel_id, recipient_id, claim_type, packaging_condition, cause_category, claimed_amount,
  declared_value, coverage_limit, eligible_amount, evidence_required, recipient_statement, agent_notes, ignored_terms)
SELECT * FROM claim_row_for('RCP-2026-00107', 'SB100000000013', 'LOST', 'NOT_STATED', 'UNKNOWN', '',
  'My boots were due almost a week ago and tracking has not moved since the sorting hub.',
  'claim_type: LOST' || chr(10) || 'packaging_condition: NOT_STATED' || chr(10) || 'likely_cause: UNKNOWN' || chr(10)
  || 'evidence_to_send: The order confirmation or receipt that shows the item and its value, and a short statement that nobody at the address received the parcel.' || chr(10)
  || 'claim_line: Keep the item and every piece of its packaging until a Swiftbound claims specialist has decided the claim, because it may be inspected.' || chr(10)
  || 'summary: The parcel is several days past its promised date. The last scan is at the sorting hub.');
INSERT INTO damage_claims (parcel_id, recipient_id, claim_type, packaging_condition, cause_category, claimed_amount,
  declared_value, coverage_limit, eligible_amount, evidence_required, recipient_statement, agent_notes, ignored_terms)
SELECT * FROM claim_row_for('RCP-2026-00108', 'SB100000000014', 'MISSING_CONTENTS', 'TORN_OR_OPENED', 'TAMPERING_THEFT', '45',
  'The tape was cut and re-stuck, and only two of the three items were inside - the face serum is missing.',
  'claim_type: MISSING_CONTENTS' || chr(10) || 'packaging_condition: TORN_OR_OPENED' || chr(10) || 'likely_cause: TAMPERING_THEFT' || chr(10)
  || 'evidence_to_send: Photos of the opened box and its seal, a photo of the shipping label, and the packing slip or order list that shows what should have been inside.' || chr(10)
  || 'claim_line: Keep the item and every piece of its packaging until a Swiftbound claims specialist has decided the claim, because it may be inspected.' || chr(10)
  || 'summary: The tape was cut and re-stuck. One of three items is missing.');

INSERT INTO service_cases (recipient_id, account_ref, tracking_number, request_type, recipient_statement, agent_brief, created_at) VALUES
 ('RCP-2026-00108','P9Q2ZE','SB100000000015','WRONG_DELIVERY',
  'Tracking says my desk lamp was delivered at the front door, but it is not here - the photo shows a different house number.',
  'Parcel shows DELIVERED with a front-door photo that appears to be at another address. Recipient reports it never arrived.',
  now() - INTERVAL '3 days'),
 ('RCP-2026-00107','H5R8WD','SB100000000012','DELIVERY_COMPLAINT',
  'My camera lens was left at the front door in full view of the street instead of being handed to me.',
  'Recipient complains a parcel was left unattended at the front door. A damage claim for the same parcel is open separately.',
  now() - INTERVAL '2 days');

-- Make the seeded claim cases look recent (1-2 days old) with reply-due dates from the routing table.
UPDATE service_cases s SET created_at = now() - CASE s.request_type WHEN 'LOST_PARCEL' THEN INTERVAL '2 days' ELSE INTERVAL '1 day' END
 WHERE s.parked_action LIKE 'COMPENSATION:%';
UPDATE damage_claims c SET created_at = s.created_at FROM service_cases s WHERE s.case_id = c.case_id;
UPDATE service_cases s SET sla_due_at = add_business_days(s.created_at::date, t.sla_days) + s.created_at::time
  FROM service_teams t WHERE t.request_type = s.request_type;
