-- Demo data for Meridian Passenger Services (governed). Fictional airline, people and PNRs.
-- Hub-and-spoke through ATL. Times are relative to CURRENT_DATE so the demo always looks "today".
-- Included by database.sql and reset_data.sql via \ir - do not load on its own.

INSERT INTO flights (flight_number,origin,origin_city,destination,destination_city,scheduled_departure,scheduled_arrival,status,gate,delay_minutes,delay_reason,seats_available,cabin_available,aircraft) VALUES
 -- inbound to ATL
 ('FL801','DEN','Denver','ATL','Atlanta', current_date + time '08:30', current_date + time '11:15','DELAYED','B12',90,'Late arriving aircraft from DFW',0,'Economy','Boeing 737 MAX 9'),
 ('FL510','SEA','Seattle','ATL','Atlanta', current_date + time '07:15', current_date + time '12:30','DELAYED','C08',45,'Weather conditions in Seattle',0,'Economy','Boeing 737-800'),
 ('FL932','ORD','Chicago','ATL','Atlanta', current_date + time '11:00', current_date + time '14:00','CANCELLED','B11',0,'Aircraft maintenance',0,'Economy','Boeing 737 MAX 9'),
 ('FL620','SFO','San Francisco','ATL','Atlanta', current_date + time '08:00', current_date + time '15:00','DELAYED','C12',180,'Weather conditions in San Francisco',0,'Economy','Boeing 737 MAX 9'),
 ('FL215','LAX','Los Angeles','ATL','Atlanta', current_date + time '06:00', current_date + time '11:30','ON_TIME','C04',0,NULL,3,'Economy','Boeing 737 MAX 9'),
 ('FL725','BOS','Boston','ATL','Atlanta', current_date + time '09:00', current_date + time '13:30','ON_TIME','B06',0,NULL,5,'Economy','Boeing 737-800'),
 -- outbound from ATL
 ('FL445','ATL','Atlanta','MIA','Miami', current_date + time '12:30', current_date + time '16:45','ON_TIME','A08',0,NULL,0,'Economy','Boeing 737-800'),
 ('FL447','ATL','Atlanta','MIA','Miami', current_date + time '15:30', current_date + time '19:45','ON_TIME','A12',0,NULL,9,'Business','Boeing 737 MAX 9'),
 ('FL449','ATL','Atlanta','MIA','Miami', current_date + time '18:30', current_date + time '22:45','ON_TIME','A10',0,NULL,9,'Economy','Boeing 737-800'),
 ('FL612','ATL','Atlanta','ORD','Chicago', current_date + time '14:05', current_date + time '15:35','ON_TIME','A20',0,NULL,0,'Economy','Boeing 737 MAX 9'),
 ('FL614','ATL','Atlanta','ORD','Chicago', current_date + time '17:00', current_date + time '18:30','ON_TIME','A21',0,NULL,9,'Economy','Boeing 737 MAX 9'),
 ('FL302','ATL','Atlanta','JFK','New York', current_date + time '13:00', current_date + time '15:15','ON_TIME','A15',0,NULL,4,'Economy','Boeing 737 MAX 9'),
 ('FL717','ATL','Atlanta','SEA','Seattle', current_date + time '18:15', current_date + time '21:00','ON_TIME','C16',0,NULL,6,'Business','Boeing 737-800'),
 ('FL715','ATL','Atlanta','SEA','Seattle', current_date + time '14:30', current_date + time '17:15','ON_TIME','C14',0,NULL,5,'Economy','Boeing 737-800'),
 ('FL520','ATL','Atlanta','LAX','Los Angeles', current_date + time '15:00', current_date + time '17:30','ON_TIME','A22',0,NULL,5,'Economy','Boeing 737 MAX 9');

INSERT INTO passengers (passenger_id,first_name,last_name,email,phone,nationality) VALUES
 ('PAX-2026-00101','Carlos','Martinez','carlos.martinez@example.com','+1-305-555-0101','USA'),
 ('PAX-2026-00104','Maria','Fernandez','maria.fernandez@example.com','+1-312-555-0104','USA'),
 ('PAX-2026-00103','Roberto','Gonzalez','roberto.gonzalez@example.com','+1-786-555-0103','USA'),
 ('PAX-2026-00117','Daniel','Ortiz','daniel.ortiz@example.com','+1-305-555-0117','USA'),
 ('PAX-2026-00112','Sofia','Castro','sofia.castro@example.com','+1-206-555-0112','USA'),
 ('PAX-2026-00102','Ana','Silva','ana.silva@example.com','+1-212-555-0102','USA');

INSERT INTO frequentflyer (passenger_id,frequentflyer_number,tier,miles_balance,tier_miles_ytd) VALUES
 ('PAX-2026-00101','MM-98765432','Gold',87500,52000),
 ('PAX-2026-00104','MM-65432109','Basic',12300,8000),
 ('PAX-2026-00103','MM-76543210','Platinum',245000,95000),
 ('PAX-2026-00117','MM-77889900','Basic',6100,3500),
 ('PAX-2026-00112','MM-22334455','Gold',79000,51000),
 ('PAX-2026-00102','MM-87654321','Silver',34200,28000);

INSERT INTO bookings (pnr,passenger_id,booking_status,verification_pin) VALUES
 ('ABCDE1','PAX-2026-00101','CONFIRMED','4821'),
 ('PQRST4','PAX-2026-00104','CONFIRMED','7310'),
 ('KLMNO3','PAX-2026-00103','CONFIRMED','9205'),
 ('NPQRS5','PAX-2026-00117','CONFIRMED','6677'),
 ('MNOPQ0','PAX-2026-00112','CONFIRMED','5533'),
 ('FGHIJ2','PAX-2026-00102','CONFIRMED','1188');

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
 ((SELECT booking_id FROM bookings WHERE pnr='FGHIJ2'),2,'FL302','ATL','JFK','14A','Economy','CONFIRMED');

INSERT INTO service_teams VALUES
 ('COMPENSATION_CLAIM','Customer Care (compensation)',7),
 ('BAGGAGE_CLAIM','Baggage Services',5),
 ('SPECIAL_ASSISTANCE','Accessibility Desk',2),
 ('COMPLAINT','Customer Relations',10),
 ('NAME_CHANGE','Ticketing',3),
 ('OTHER','Customer Care',5);
