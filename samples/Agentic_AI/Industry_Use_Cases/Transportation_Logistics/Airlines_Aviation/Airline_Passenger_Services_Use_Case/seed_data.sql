-- Demo data for Meridian Passenger Services (governed). Fictional airline, people, staff and PNRs.
-- Hub-and-spoke through ATL. Times are relative to CURRENT_DATE / now() so the demo always looks "today".
-- Included by database.sql and reset_data.sql via \ir - do not load on its own.

INSERT INTO flights (flight_number,origin,origin_city,destination,destination_city,scheduled_departure,scheduled_arrival,status,gate,delay_minutes,delay_reason,seats_available,cabin_available,aircraft) VALUES
 -- inbound to ATL
 ('FL801','DEN','Denver','ATL','Atlanta', current_date + time '08:30', current_date + time '11:15','DELAYED','B12',90,'Late arriving aircraft from DFW',0,'Economy','Boeing 737 MAX 9'),
 ('FL510','SEA','Seattle','ATL','Atlanta', current_date + time '07:15', current_date + time '12:30','DELAYED','C08',45,'Weather conditions in Seattle',0,'Economy','Boeing 737-800'),
 ('FL932','ORD','Chicago','ATL','Atlanta', current_date + time '11:00', current_date + time '14:00','CANCELLED','B11',0,'Aircraft maintenance',0,'Economy','Boeing 737 MAX 9'),
 ('FL620','SFO','San Francisco','ATL','Atlanta', current_date + time '08:00', current_date + time '15:00','DELAYED','C12',180,'Weather conditions in San Francisco',0,'Economy','Boeing 737 MAX 9'),
 ('FL215','LAX','Los Angeles','ATL','Atlanta', current_date + time '06:00', current_date + time '11:30','ON_TIME','C04',0,NULL,3,'Economy','Boeing 737 MAX 9'),
 ('FL725','BOS','Boston','ATL','Atlanta', current_date + time '09:00', current_date + time '13:30','ON_TIME','B06',0,NULL,5,'Economy','Boeing 737-800'),
 -- already flown (baggage storylines)
 ('FL721','BOS','Boston','ATL','Atlanta', current_date - 1 + time '09:00', current_date - 1 + time '11:40','ARRIVED','B07',0,NULL,0,'Economy','Boeing 737-800'),
 ('FL719','BOS','Boston','ATL','Atlanta', current_date - 8 + time '09:00', current_date - 8 + time '11:40','ARRIVED','B05',0,NULL,0,'Economy','Boeing 737-800'),
 -- outbound from ATL
 ('FL445','ATL','Atlanta','MIA','Miami', current_date + time '12:30', current_date + time '16:45','ON_TIME','A08',0,NULL,0,'Economy','Boeing 737-800'),
 ('FL447','ATL','Atlanta','MIA','Miami', current_date + time '15:30', current_date + time '19:45','ON_TIME','A12',0,NULL,9,'Business','Boeing 737 MAX 9'),
 ('FL449','ATL','Atlanta','MIA','Miami', current_date + time '18:30', current_date + time '22:45','ON_TIME','A10',0,NULL,9,'Economy','Boeing 737-800'),
 ('FL612','ATL','Atlanta','ORD','Chicago', current_date + time '14:05', current_date + time '15:35','ON_TIME','A20',0,NULL,0,'Economy','Boeing 737 MAX 9'),
 ('FL614','ATL','Atlanta','ORD','Chicago', current_date + time '17:00', current_date + time '18:30','ON_TIME','A21',0,NULL,9,'Economy','Boeing 737 MAX 9'),
 ('FL302','ATL','Atlanta','JFK','New York', current_date + time '13:00', current_date + time '15:15','ON_TIME','A15',0,NULL,4,'Economy','Boeing 737 MAX 9'),
 ('FL717','ATL','Atlanta','SEA','Seattle', current_date + time '18:15', current_date + time '21:00','ON_TIME','C16',0,NULL,6,'Business','Boeing 737-800'),
 ('FL715','ATL','Atlanta','SEA','Seattle', current_date + time '14:30', current_date + time '17:15','ON_TIME','C14',0,NULL,5,'Economy','Boeing 737-800'),
 ('FL520','ATL','Atlanta','LAX','Los Angeles', current_date + time '15:00', current_date + time '17:30','ON_TIME','A22',0,NULL,5,'Economy','Boeing 737 MAX 9'),
 -- tomorrow (special-assistance storylines)
 ('FL305','ATL','Atlanta','BOS','Boston', current_date + 1 + time '10:00', current_date + 1 + time '12:30','ON_TIME','A05',0,NULL,7,'Economy','Boeing 737-800');

INSERT INTO passengers (passenger_id,first_name,last_name,email,phone,nationality) VALUES
 ('PAX-2026-00101','Carlos','Martinez','carlos.martinez@example.com','+1-305-555-0101','USA'),
 ('PAX-2026-00104','Maria','Fernandez','maria.fernandez@example.com','+1-312-555-0104','USA'),
 ('PAX-2026-00103','Roberto','Gonzalez','roberto.gonzalez@example.com','+1-786-555-0103','USA'),
 ('PAX-2026-00117','Daniel','Ortiz','daniel.ortiz@example.com','+1-305-555-0117','USA'),
 ('PAX-2026-00112','Sofia','Castro','sofia.castro@example.com','+1-206-555-0112','USA'),
 ('PAX-2026-00102','Ana','Silva','ana.silva@example.com','+1-212-555-0102','USA'),
 ('PAX-2026-00121','Linda','Park','linda.park@example.com','+1-617-555-0121','USA'),
 ('PAX-2026-00125','Kevin','Wright','kevin.wright@example.com','+1-617-555-0125','USA'),
 ('PAX-2026-00128','Rosa','Delgado','rosa.delgado@example.com','+1-404-555-0128','USA');

INSERT INTO frequentflyer (passenger_id,frequentflyer_number,tier,miles_balance,tier_miles_ytd) VALUES
 ('PAX-2026-00101','MM-98765432','Gold',87500,52000),
 ('PAX-2026-00104','MM-65432109','Basic',12300,8000),
 ('PAX-2026-00103','MM-76543210','Platinum',245000,95000),
 ('PAX-2026-00117','MM-77889900','Basic',6100,3500),
 ('PAX-2026-00112','MM-22334455','Gold',79000,51000),
 ('PAX-2026-00102','MM-87654321','Silver',34200,28000),
 ('PAX-2026-00121','MM-31415926','Silver',28800,21000),
 ('PAX-2026-00125','MM-27182818','Gold',91200,48000),
 ('PAX-2026-00128','MM-16180339','Basic',4100,2600);

INSERT INTO bookings (pnr,passenger_id,booking_status,verification_pin) VALUES
 ('ABCDE1','PAX-2026-00101','CONFIRMED','4821'),
 ('PQRST4','PAX-2026-00104','CONFIRMED','7310'),
 ('KLMNO3','PAX-2026-00103','CONFIRMED','9205'),
 ('NPQRS5','PAX-2026-00117','CONFIRMED','6677'),
 ('MNOPQ0','PAX-2026-00112','CONFIRMED','5533'),
 ('FGHIJ2','PAX-2026-00102','CONFIRMED','1188'),
 ('WXYZA7','PAX-2026-00121','CONFIRMED','3046'),
 ('TUVWX9','PAX-2026-00125','CONFIRMED','8152'),
 ('HJKLM8','PAX-2026-00128','CONFIRMED','2468');

-- Segments (origin/destination mirror the flight so the route guard can check them)
INSERT INTO booking_segments (booking_id,segment_order,flight_number,origin,destination,seat_number,cabin,segment_status) VALUES
 -- Carlos ABCDE1: DEN->ATL->MIA, FL801 delayed 90 -> MISSES FL445 (alts FL447/FL449)
 ((SELECT booking_id FROM bookings WHERE pnr='ABCDE1'),1,'FL801','DEN','ATL','4A','Business','CHECKED_IN'),
 ((SELECT booking_id FROM bookings WHERE pnr='ABCDE1'),2,'FL445','ATL','MIA','3C','Business','CONFIRMED'),
 -- Maria PQRST4: SEA->ATL->ORD, FL510 delayed 45 -> AT_RISK (~50 min) (alt FL614)
 ((SELECT booking_id FROM bookings WHERE pnr='PQRST4'),1,'FL510','SEA','ATL','8C','Economy','CHECKED_IN'),
 ((SELECT booking_id FROM bookings WHERE pnr='PQRST4'),2,'FL612','ATL','ORD','10A','Economy','CONFIRMED'),
 -- Roberto KLMNO3: ATL->MIA direct, on time -> no connection
 ((SELECT booking_id FROM bookings WHERE pnr='KLMNO3'),1,'FL445','ATL','MIA','1A','Business','CONFIRMED'),
 -- Daniel NPQRS5: ORD->ATL->MIA, inbound FL932 CANCELLED -> MISSED (alt FL447/FL449)
 ((SELECT booking_id FROM bookings WHERE pnr='NPQRS5'),1,'FL932','ORD','ATL','21D','Economy','CONFIRMED'),
 ((SELECT booking_id FROM bookings WHERE pnr='NPQRS5'),2,'FL445','ATL','MIA','22A','Economy','CONFIRMED'),
 -- Sofia MNOPQ0: SFO->ATL->SEA, FL620 delayed 180 -> MISSES FL717, NO same-day alternative
 ((SELECT booking_id FROM bookings WHERE pnr='MNOPQ0'),1,'FL620','SFO','ATL','5A','Business','CHECKED_IN'),
 ((SELECT booking_id FROM bookings WHERE pnr='MNOPQ0'),2,'FL717','ATL','SEA','6C','Business','CONFIRMED'),
 -- Ana FGHIJ2: LAX->ATL->JFK, on time -> SAFE (90 min)
 ((SELECT booking_id FROM bookings WHERE pnr='FGHIJ2'),1,'FL215','LAX','ATL','12B','Economy','CHECKED_IN'),
 ((SELECT booking_id FROM bookings WHERE pnr='FGHIJ2'),2,'FL302','ATL','JFK','14A','Economy','CONFIRMED'),
 -- Linda WXYZA7: BOS->ATL yesterday on FL721; her checked bag did not arrive (live baggage storyline)
 ((SELECT booking_id FROM bookings WHERE pnr='WXYZA7'),1,'FL721','BOS','ATL','14C','Economy','COMPLETED'),
 -- Kevin TUVWX9: BOS->ATL 8 days ago on FL719 (bag never found - seeded LOST claim), ATL->BOS tomorrow on FL305
 ((SELECT booking_id FROM bookings WHERE pnr='TUVWX9'),1,'FL719','BOS','ATL','9A','Economy','COMPLETED'),
 ((SELECT booking_id FROM bookings WHERE pnr='TUVWX9'),2,'FL305','ATL','BOS','9C','Economy','CONFIRMED'),
 -- Rosa HJKLM8: ATL->BOS tomorrow on FL305 (live special-assistance storyline)
 ((SELECT booking_id FROM bookings WHERE pnr='HJKLM8'),1,'FL305','ATL','BOS','3D','Economy','CONFIRMED');

-- Routing table: the existing service teams. OTHER goes to Customer Relations so every team has a reviewer.
INSERT INTO service_teams (request_type, label, team, sla_days) VALUES
 ('COMPENSATION_CLAIM','compensation claim','Customer Care (compensation)',7),
 ('BAGGAGE_CLAIM','baggage claim','Baggage Services',5),
 ('SPECIAL_ASSISTANCE','special assistance request','Accessibility Desk',2),
 ('COMPLAINT','complaint','Customer Relations',10),
 ('NAME_CHANGE','name change','Ticketing',3),
 ('OTHER','request','Customer Relations',5);

-- Staff reviewers (fictional). Dana's $250 limit is below the $300 / $450 interim requests -> OVER_AUTHORITY demo;
-- Victor is the senior Baggage Services reviewer.
INSERT INTO reviewers (reviewer_id, display_name, team, one_time_code, approval_limit) VALUES
 ('MER-7001','Dana Brooks','Baggage Services','246810',250),
 ('MER-7002','Victor Hale','Baggage Services','135790',2000),
 ('MER-7003','Marcus Lee','Accessibility Desk','864209',NULL),
 ('MER-7004','Elena Ruiz','Customer Care (compensation)','502468',500),
 ('MER-7005','Nadia Karim','Customer Relations','719350',500),
 ('MER-7006','Owen Price','Ticketing','357911',NULL);

-- Compensation bands (goodwill travel credit for the most disrupted leg). The highest band that applies wins.
INSERT INTO compensation_bands (band, cancelled, min_delay_minutes, max_usd, label) VALUES
 ('CANCELLED', TRUE, NULL, 300, 'cancelled flight'),
 ('DELAY_180', FALSE, 180, 250, 'delay of 3 hours or more'),
 ('DELAY_60', FALSE, 60, 100, 'delay of 1 to 3 hours');

-- ---- baggage reference data (no personal data) ----
INSERT INTO baggage_claim_types (claim_type, meaning, min_days_after_arrival, interim_cap_usd, sort_order) VALUES
 ('DELAYED', 'The bag did not arrive with the traveller and is still being traced.', 0, 300, 1),
 ('LOST', 'The bag has not been found after the trace period.', 5, 500, 2),
 ('DAMAGED', 'The bag arrived, but the bag itself is broken or torn (wheel, handle, zip, shell or fabric).', 0, 250, 3),
 ('PILFERED', 'The bag arrived, but items are missing from inside it.', 0, 250, 4);

INSERT INTO baggage_report_fields (field, meaning, required_for, sort_order) VALUES
 ('BAG_TAG', 'The bag tag number on the sticker from check-in: two letters and six digits, for example MR123456.', '{DELAYED,LOST,DAMAGED,PILFERED}', 1),
 ('BRAND', 'The brand or maker name on the bag, or "no brand".', '{DELAYED,LOST}', 2),
 ('DELIVERY_ADDRESS', 'Where Baggage Services should deliver the bag once it is found, and until which date.', '{DELAYED}', 3),
 ('CONTACT_PHONE', 'A phone number where Baggage Services can reach the traveller about the bag.', '{DELAYED,LOST}', 4),
 ('ITEM_LIST', 'A list of the items that are missing, with an approximate value for each.', '{LOST,PILFERED}', 5),
 ('DAMAGE_PHOTO', 'A photo of the damage and of the bag tag, taken before any repair.', '{DAMAGED}', 6);

INSERT INTO baggage_guide (section, term, meaning) VALUES
 -- Meridian bag-type chart (two-digit codes in the industry style)
 ('BAG_TYPE','01','Horizontal suitcase, hard shell (rigid case carried flat, often without wheels)'),
 ('BAG_TYPE','02','Upright suitcase, hard shell (rigid case that stands upright, usually on wheels)'),
 ('BAG_TYPE','21','Horizontal suitcase, soft-sided (fabric case carried flat)'),
 ('BAG_TYPE','22','Upright suitcase, soft-sided (fabric case that stands upright, usually on wheels)'),
 ('BAG_TYPE','25','Duffel or sports holdall (soft bag with straps, no frame)'),
 ('BAG_TYPE','26','Garment bag (folding bag for suits and dresses)'),
 ('BAG_TYPE','29','Backpack or rucksack'),
 ('BAG_TYPE','71','Box or carton'),
 ('BAG_TYPE','99','Anything not listed above (describe it in the report)'),
 ('COLOUR','BK','Black'),
 ('COLOUR','BU','Blue (any shade, including navy)'),
 ('COLOUR','GY','Grey or silver'),
 ('COLOUR','RD','Red, pink or burgundy'),
 ('COLOUR','GN','Green or olive'),
 ('COLOUR','BN','Brown, tan or beige'),
 ('COLOUR','MC','Several colours or a pattern'),
 ('CONTENT','CLOTHING','Clothes, shoes and accessories'),
 ('CONTENT','ELECTRONICS','Laptops, tablets, chargers, cables, cameras and other devices'),
 ('CONTENT','TOILETRIES','Toiletries and personal-care items'),
 ('CONTENT','DOCUMENTS','Papers, books and business documents'),
 ('CONTENT','MEDICATION','Medicines and medical supplies; tell Baggage Services first if any are needed urgently'),
 ('CONTENT','VALUABLES','Cash, jewelry and similar valuables; list them, but they are reviewed separately and are not interim expenses'),
 ('CONTENT','OTHER','Anything that fits none of the categories above'),
 ('CLAIM_NOTE','STANDARD','Keep the receipts for any essentials you buy while you wait; Meridian Baggage Services decides any reimbursement and replies by the date on your case.');

-- ---- special-assistance reference data: IATA SSR codes (no personal data) ----
INSERT INTO ssr_codes (code, label, meaning, traveller_requestable, medical_clearance, wheelchair_level, sort_order) VALUES
 ('WCHR','Wheelchair for the distance','Can climb aircraft steps and walk to the seat, but needs a wheelchair for the long walk through the airport.', TRUE, FALSE, 1, 1),
 ('WCHS','Wheelchair, no steps','Can walk to and from the seat on board, but cannot climb aircraft steps; needs a wheelchair and a lift or jet bridge to board.', TRUE, FALSE, 2, 2),
 ('WCHC','Wheelchair to the seat','Cannot walk at all; needs a wheelchair and help all the way to and from the seat on board.', TRUE, FALSE, 3, 3),
 ('WCMP','Own manual wheelchair','Travels with their own manual wheelchair, checked in at the gate.', TRUE, FALSE, NULL, 4),
 ('WCLB','Own powered wheelchair (lithium battery)','Travels with their own powered wheelchair with a lithium-ion battery; the battery is checked before the flight.', TRUE, FALSE, NULL, 5),
 ('BLND','Blind or low vision','Blind or partially sighted; may need guidance through the airport and a safety briefing on board.', TRUE, FALSE, NULL, 6),
 ('DEAF','Deaf or hard of hearing','Deaf or hard of hearing; may need announcements and the safety briefing given in person or in writing.', TRUE, FALSE, NULL, 7),
 ('DPNA','Intellectual or developmental disability','Has an intellectual or developmental disability and needs assistance and a calm, guided journey.', TRUE, FALSE, NULL, 8),
 ('SVAN','Service animal','Travels with a trained service animal in the cabin.', TRUE, FALSE, NULL, 9),
 ('MAAS','Meet and assist','Needs someone to meet them and guide them through the airport (no wheelchair).', TRUE, FALSE, NULL, 10),
 ('OXYG','Medical oxygen on board','Needs medical oxygen during the flight.', TRUE, TRUE, NULL, 11),
 ('MEDA','Medical case','Has a medical condition that may need care or equipment in flight; a medical information form (MEDIF) is checked first.', TRUE, TRUE, NULL, 12),
 ('STCR','Stretcher','Travels lying on a stretcher.', FALSE, TRUE, NULL, 13);

INSERT INTO assistance_guide (section, term, meaning) VALUES
 ('HOW_TO_CHOOSE','ONE_WHEELCHAIR_CODE','Choose at most one of WCHR, WCHS or WCHC: the one that matches what the passenger can still do on steps and on foot.'),
 ('HOW_TO_CHOOSE','OWN_WHEELCHAIR','If the passenger brings their own wheelchair, add WCMP (manual) or WCLB (lithium battery) as well.'),
 ('HOW_TO_CHOOSE','MEDICAL_NEEDS','If the need involves oxygen on board, a recent operation or a condition that may need care in flight, add MEDA; only the Accessibility Desk can give medical clearance.'),
 ('HOW_TO_CHOOSE','WHEN_UNSURE','If the needs do not say enough to choose a code, add no code for that need and put the question to ask in follow_up.'),
 ('STANDARD_LINE','CONFIRMATION','Assistance stays pending until the Meridian Accessibility Desk confirms it, and you will hear from them before you fly.');

-- ---- 1-2 OPEN cases per reviewer team, so no queue is empty in a demo (written through the same rule functions) ----
-- Baggage Services: Kevin's LOST bag (8 days), interim expenses $450 (above Dana's $250 limit -> OVER_AUTHORITY demo)
INSERT INTO baggage_claims (case_id, booking_id, pnr, segment_id, flight_number, claim_type, agent_claim_type, bag_type, colour,
                            contents, missing_fields, rule_note, ignored_items, description, agent_notes, interim_requested)
SELECT 'SC-S0A1B1', c.* FROM bookings b CROSS JOIN LATERAL baggage_claim_core(b.booking_id, 'FL719',
  'Black hard-shell upright suitcase, tag MR204417, never came off the belt eight days ago. Work clothes, shoes and a camera inside. '
  || 'I have spent about $450 on replacement work clothes.', '450',
  'claim_type: LOST' || chr(10) || 'bag_type: 02 - Upright suitcase, hard shell' || chr(10) || 'colour: BK' || chr(10)
  || 'contents: CLOTHING, ELECTRONICS' || chr(10) || 'missing_fields: BRAND, CONTACT_PHONE, ITEM_LIST' || chr(10)
  || 'claim_note: Keep the receipts for any essentials you buy while you wait; Meridian Baggage Services decides any reimbursement and replies by the date on your case.') c
 WHERE b.pnr = 'TUVWX9';
-- Accessibility Desk: Kevin asked for WCHR on tomorrow's FL305 (pending confirmation)
INSERT INTO assistance_requests (case_id, booking_id, pnr, segment_id, flight_number, codes, ignored_codes, medical_clearance, needs, agent_notes)
SELECT 'SC-S0C3A3', c.* FROM bookings b CROSS JOIN LATERAL assistance_core(b.booking_id, 'FL305',
  'My knee is healing. I can manage the aircraft steps and walk to my seat, but not the long walk to the gate.',
  'ssr_codes: WCHR' || chr(10) || 'codes:' || chr(10) || '- WCHR: Wheelchair for the distance: Can climb aircraft steps and walk to the seat, '
  || 'but needs a wheelchair for the long walk through the airport.' || chr(10) || 'medical_clearance: NO' || chr(10) || 'follow_up: none') c
 WHERE b.pnr = 'TUVWX9';
-- Customer Care (compensation): Sofia's 180-minute delay (band DELAY_180, up to $250)
INSERT INTO service_cases (case_id, booking_id, pnr, request_type, traveler_statement, agent_brief, requested_amount, parked_action)
SELECT 'SC-S0B2C2', b.booking_id, b.pnr, 'COMPENSATION_CLAIM',
       'My flight from San Francisco was three hours late and I missed my connection to Seattle. I would like compensation.',
       'Inbound FL620 SFO-ATL arrived 180 minutes late; the ATL-SEA connection was missed and no same-day alternative exists. '
       || 'Traveller requests compensation.', pk.requested_amount, pk.parked_action
  FROM bookings b CROSS JOIN LATERAL case_parking(b.booking_id, 'COMPENSATION_CLAIM', '') pk
 WHERE b.pnr = 'MNOPQ0';
-- Customer Relations: a service complaint (no amount)
INSERT INTO service_cases (case_id, booking_id, pnr, request_type, traveler_statement, agent_brief)
SELECT 'SC-S0D4C4', b.booking_id, b.pnr, 'COMPLAINT',
       'Nobody at the gate in Seattle told us about the delay until boarding time.',
       'Traveller complains about the lack of delay announcements at the departure gate for FL510. No compensation requested.'
  FROM bookings b WHERE b.pnr = 'PQRST4';
-- Ticketing: a name change (no amount)
INSERT INTO service_cases (case_id, booking_id, pnr, request_type, traveler_statement, agent_brief)
SELECT 'SC-S0E5N5', b.booking_id, b.pnr, 'NAME_CHANGE',
       'My ticket has my middle name as my last name. Please correct it to match my passport.',
       'Traveller reports the given and family names are swapped on the ticket and asks for a correction to match the passport.'
  FROM bookings b WHERE b.pnr = 'NPQRS5';

-- Seeded cases look a few days old ("recent" relative to now()).
UPDATE service_cases SET created_at = created_at - INTERVAL '2 days', sla_due_at = sla_due_at - INTERVAL '2 days'
 WHERE case_id IN ('SC-S0A1B1', 'SC-S0B2C2', 'SC-S0D4C4');
UPDATE service_cases SET created_at = created_at - INTERVAL '1 day', sla_due_at = sla_due_at - INTERVAL '1 day'
 WHERE case_id IN ('SC-S0C3A3', 'SC-S0E5N5');
UPDATE baggage_claims SET created_at = created_at - INTERVAL '2 days' WHERE case_id = 'SC-S0A1B1';
UPDATE assistance_requests SET created_at = created_at - INTERVAL '1 day' WHERE case_id = 'SC-S0C3A3';
