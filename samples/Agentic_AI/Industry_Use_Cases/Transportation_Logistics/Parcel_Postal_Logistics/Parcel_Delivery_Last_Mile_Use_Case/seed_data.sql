-- Demo data for Swiftbound Last-Mile Parcel Delivery (governed). Fictional carrier, people and parcels.
-- Dates are relative to CURRENT_DATE so the demo always looks "today".
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
 ('RCP-2026-00104','A6L3HK','3344','Ava','Thompson','ava.thompson@example.com','+1-415-555-0104','3 Birch Lane','N4','NORTHSIDE');

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
 -- Noah (DOWNTOWN): delivered (cannot reschedule); damaged (human claim)
 ('SB100000000005','RCP-2026-00103','Paperback books','ReadMore',60.00,'SMALL',FALSE,'STANDARD','DOWNTOWN','D3', current_date - 1, 'DELIVERED',NULL,1, current_date - 1 + time '11:20'),
 ('SB100000000006','RCP-2026-00103','Ceramic vase','HomeStyle',85.00,'MEDIUM',FALSE,'STANDARD','DOWNTOWN','D3', current_date, 'EXCEPTION','DMG',1, NULL),
 -- Ava (NORTHSIDE): in customs (decode CUS); used for the cross-account scope test
 ('SB100000000007','RCP-2026-00104','Phone case','GadgetHub',25.00,'SMALL',FALSE,'STANDARD','NORTHSIDE','N4', current_date + 2, 'EXCEPTION','CUS',0, NULL);

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
 ((SELECT parcel_id FROM parcels WHERE tracking_number='SB100000000007'), current_date - 1 + time '22:00','International Gateway','CUS','Held for customs clearance');

INSERT INTO service_teams VALUES
 ('LOST_PARCEL','Claims (lost parcels)',7),
 ('DAMAGED_PARCEL','Claims (damaged parcels)',7),
 ('MISSING_ITEMS','Claims (missing contents)',7),
 ('WRONG_DELIVERY','Investigations',5),
 ('DELIVERY_COMPLAINT','Customer Relations',10),
 ('OTHER','Customer Care',5);
