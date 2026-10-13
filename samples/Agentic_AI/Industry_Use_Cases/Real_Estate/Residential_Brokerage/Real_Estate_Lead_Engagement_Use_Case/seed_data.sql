-- Demo data for Brightpath Realty - Real Estate Lead Engagement (governed). Fictional brokerage, metro (Larkspur
-- Valley), streets, people, 555-01xx phones and example.com e-mail. Listing features state facts only - no school,
-- safety or demographic claims (Fair Housing). Volatile dates are relative to CURRENT_DATE / now(), so the demo never
-- goes stale. Included by database.sql and reset_data.sql via \ir - do not load on its own.

-- ---------------------------------------------------------------------
-- Policy, routing, market reference
-- ---------------------------------------------------------------------
INSERT INTO showing_policy (id, first_start_hour, last_start_hour, min_notice_hours, max_days_ahead, max_upcoming, max_price_change_pct)
VALUES (1, 9, 18, 2, 30, 3, 15);

INSERT INTO case_routing (request_type, label, team, sla_business_days, sla_text, lead_openable) VALUES
 ('offer_request',       'offer / price question',    'Sales Agents',         1, 'Your Brightpath agent replies within 1 business day.', TRUE),
 ('list_price_change',   'list-price change',         'Sales Agents',         1, 'Your listing agent reviews it within 1 business day.', TRUE),
 ('stage_change',        'contract / closing update', 'Sales Agents',         2, 'Your agent confirms it with the transaction file within 2 business days.', TRUE),
 ('fair_housing_review', 'neighborhood question',     'Brokerage Compliance', 1, 'Our Brokerage Compliance team replies within 1 business day.', TRUE),
 ('advice_referral',     'legal / mortgage question', 'Brokerage Compliance', 2, 'Our team replies with a referral within 2 business days.', TRUE);

INSERT INTO area_market_stats (area, median_price, avg_days_on_market, active_listings, median_price_per_sqft, yoy_price_change_pct, months_of_inventory, as_of_month) VALUES
 ('Cedar Hollow',      712000, 24, 38, 405.00, 3.10, 2.8, to_char(current_date, 'Mon YYYY')),
 ('Willow Bend',       598000, 31, 44, 318.00, 2.40, 3.9, to_char(current_date, 'Mon YYYY')),
 ('Larkspur Downtown', 455000, 37, 61, 512.00, 1.20, 5.2, to_char(current_date, 'Mon YYYY')),
 ('Northgate',         835000, 42, 27, 296.00, 0.80, 6.4, to_char(current_date, 'Mon YYYY'));

-- ---------------------------------------------------------------------
-- Brightpath agents and staff reviewers
-- ---------------------------------------------------------------------
INSERT INTO agents (agent_id, full_name, title, email, phone, service_area, specialties) VALUES
 ('AGT-101', 'Marisol Vance',    'Buyer & listing agent',  'marisol.vance@brightpathrealty.example.com',    '(555) 010-4411', 'Cedar Hollow, Willow Bend',      'First-time buyers, single-family homes, relocation'),
 ('AGT-102', 'Wesley Tran',      'Listing agent',          'wesley.tran@brightpathrealty.example.com',      '(555) 010-4412', 'Northgate, Larkspur Downtown',   'Sellers, condos and townhomes'),
 ('AGT-103', 'Gabriela Fenwick', 'Relocation specialist',  'gabriela.fenwick@brightpathrealty.example.com', '(555) 010-4413', 'All of Larkspur Valley',         'Relocation, new construction');

INSERT INTO reviewers (reviewer_id, display_name, team, job_title, one_time_code, approval_limit) VALUES
 ('BPR-7101', 'Marisol Vance',  'Sales Agents',         'Buyer & listing agent',     '2468', 15000),
 ('BPR-7102', 'Theodore Ashby', 'Sales Agents',         'Managing broker',           '1357', NULL),
 ('BPR-7201', 'Imani Rourke',   'Brokerage Compliance', 'Compliance officer',        '8642', NULL);

-- ---------------------------------------------------------------------
-- Leads (login = e-mail + one-time code). Seller leads are inserted before their listings reference them.
-- ---------------------------------------------------------------------
INSERT INTO leads (lead_id, first_name, last_name, email, phone, otp_code, lead_type, stage, budget_min, budget_max, preferred_area,
                   min_bedrooms, min_bathrooms, property_type_pref, timeline, pre_approved, pre_approval_amount, source,
                   assigned_agent_id, created_at, last_activity_at) VALUES
 ('LEAD-2026-00101', 'Delia',  'Sorensen',  'delia.sorensen@example.com',  '(555) 010-1101', '5172', 'Buyer',  'Nurturing',      500000, 750000, 'Cedar Hollow',      3, 2.0, 'Single Family', '0-3 months', TRUE,  725000, 'Website',          'AGT-101', now() - INTERVAL '21 days', now() - INTERVAL '2 days'),
 ('LEAD-2026-00102', 'Marco',  'Sandoval',  'marco.sandoval@example.com',  '(555) 010-1102', '3846', 'Buyer',  'Under Contract', 600000, 800000, 'Cedar Hollow',      4, 3.0, 'Single Family', 'Closing',    TRUE,  780000, 'Referral',         'AGT-102', now() - INTERVAL '60 days', now() - INTERVAL '5 days'),
 ('LEAD-2026-00103', 'Kiran',  'Bhatt',     'kiran.bhatt@example.com',     '(555) 010-1103', '9021', 'Buyer',  'New',            450000, 650000, 'Cedar Hollow',      3, 2.0, 'Single Family', NULL,         FALSE, NULL,   'Website',          'AGT-103', now() - INTERVAL '1 day',   now() - INTERVAL '1 day'),
 ('LEAD-2026-00104', 'Russell','Thorne',    'russell.thorne@example.com',  '(555) 010-1104', '6630', 'Seller', 'Active',         NULL,   NULL,   'Willow Bend',       NULL, NULL, NULL,          '0-3 months', FALSE, NULL,   'Listing inquiry',  'AGT-101', now() - INTERVAL '70 days', now() - INTERVAL '3 days'),
 ('LEAD-2026-00105', 'Lena',   'Marchetti', 'lena.marchetti@example.com',  '(555) 010-1105', '4419', 'Seller', 'Active',         NULL,   NULL,   'Northgate',         NULL, NULL, NULL,          '0-3 months', FALSE, NULL,   'Referral',         'AGT-102', now() - INTERVAL '90 days', now() - INTERVAL '1 day'),
 ('LEAD-2026-00106', 'Miles',  'Hargrove',  'miles.hargrove@example.com',  '(555) 010-1106', '7305', 'Buyer',  'Nurturing',      550000, 720000, 'Cedar Hollow',      3, 2.0, 'Single Family', '3-6 months', TRUE,  700000, 'Open house',       'AGT-101', now() - INTERVAL '30 days', now() - INTERVAL '1 day'),
 ('LEAD-2026-00107', 'Elise',  'Navarro',   'elise.navarro@example.com',   '(555) 010-1107', '2287', 'Buyer',  'Lost',           300000, 400000, 'Larkspur Downtown', 2, 1.0, 'Condo',         'No timeline',FALSE, NULL,   'Website',          'AGT-103', now() - INTERVAL '150 days', now() - INTERVAL '80 days');

-- ---------------------------------------------------------------------
-- Listings (fictional streets in the fictional Larkspur Valley metro)
-- ---------------------------------------------------------------------
INSERT INTO listings (listing_id, address, area, price, bedrooms, bathrooms, sqft, lot_sqft, property_type, year_built, hoa_monthly, status,
                      list_date, listing_agent_id, seller_lead_id, features, description) VALUES
 ('LST-50001', '1418 Quillfeather Ln',   'Cedar Hollow',      689000, 3, 2.0, 1720, 6100,  'Single Family', 1998, NULL, 'Active',    current_date - 12, 'AGT-101', NULL,
  'Dedicated home office with a door and built-in shelves; walk score 88 - four blocks to Cedar Hollow Main Street cafes, grocery and the public library; updated kitchen; fenced back yard; one-car garage',
  'Light-filled 1998 bungalow on a tree-lined street with a true home office off the entry and an easy walk to Main Street.'),
 ('LST-50002', '26 Brambleton Way',      'Cedar Hollow',      735000, 4, 2.5, 2240, 7400,  'Single Family', 2006, NULL, 'Active',    current_date - 7,  'AGT-101', NULL,
  'Bonus den off the living room that can work as an office; walk score 71 - about ten minutes on foot to the farmers market and greenway trail; two-car garage; large patio',
  'Two-story home with four bedrooms, a flexible den and a short walk to the greenway trail.'),
 ('LST-50003', '903 Juniper Crest Dr',   'Cedar Hollow',      642000, 3, 2.0, 1610, 8800,  'Single Family', 1994, NULL, 'Active',    current_date - 21, 'AGT-101', NULL,
  'Car-dependent street (walk score 34), about 1.5 miles to shops; no separate office - large primary bedroom with a sitting area; big back yard; new roof',
  'Ranch home on a cul-de-sac with a big yard and a new roof.'),
 ('LST-50004', '77 Halcyon Ct',          'Cedar Hollow',      715000, 3, 2.5, 1850, 5200,  'Single Family', 2012, NULL, 'Pending',   current_date - 30, 'AGT-101', NULL,
  'Office nook upstairs; walk score 82 - near Main Street; solar panels; two-car garage',
  'The sellers have accepted an offer; backup offers considered.'),
 ('LST-50005', '410 Marigold Terrace',   'Cedar Hollow',      795000, 4, 3.0, 2480, 9000,  'Single Family', 2018, NULL, 'Active',    current_date - 5,  'AGT-101', NULL,
  'Main-floor office; walk score 64; three-car garage; covered porch',
  'Newer two-story with a main-floor office and a three-car garage.'),
 ('LST-50006', '1105 Wrenfield Pl',      'Cedar Hollow',      559000, 2, 2.0, 1240, 1100,  'Townhouse',     2015, 210,  'Active',    current_date - 15, 'AGT-101', NULL,
  'Loft that works as an office; walk score 90 - on Main Street; no yard; one assigned parking space',
  'End-unit townhome above the Main Street shops.'),
 ('LST-50014', '2210 Thistledown Rd',    'Willow Bend',       612000, 3, 2.0, 1880, 7000,  'Single Family', 2003, NULL, 'Active',    current_date - 41, 'AGT-101', 'LEAD-2026-00104',
  'Updated kitchen; den; covered patio; two-car garage; walk score 52 - a few minutes to the Willow Bend park trail',
  'Well-kept split-level near the Willow Bend park trail.'),
 ('LST-50015', '18 Saddlebrook Loop',    'Willow Bend',       575000, 4, 2.5, 2100, 6800,  'Single Family', 2009, NULL, 'Active',    current_date - 19, 'AGT-103', NULL,
  'Flex room upstairs; walk score 45; fenced yard; two-car garage',
  'Four-bedroom two-story with an upstairs flex room.'),
 ('LST-50016', '742 Amberglen Ct',       'Willow Bend',       489000, 3, 2.5, 1650, 2800,  'Townhouse',     2016, 185,  'Active',    current_date - 9,  'AGT-103', NULL,
  'Office alcove off the kitchen; walk score 70; two-car garage; small patio',
  'Three-bedroom townhome with an office alcove and attached garage.'),
 ('LST-50020', '58 Lanternwood Dr',      'Northgate',         865000, 4, 3.5, 3150, 12500, 'Single Family', 2014, NULL, 'Active',    current_date - 63, 'AGT-102', 'LEAD-2026-00105',
  'Main-floor office; media room; three-car garage; large lot; walk score 28',
  'Spacious Northgate home on a large lot with a main-floor office.'),
 ('LST-50021', '9 Kestrel Run',          'Northgate',         925000, 5, 4.0, 3600, 15000, 'Single Family', 2020, NULL, 'Active',    current_date - 28, 'AGT-102', NULL,
  'Two offices; pool; walk score 22; four-car garage',
  'Newer five-bedroom home with two offices and a pool.'),
 ('LST-50022', '3301 Tamarind Row',      'Northgate',         780000, 4, 3.0, 2700, 10000, 'Single Family', 2011, NULL, 'Sold',      current_date - 90, 'AGT-102', NULL,
  'Recently sold - comparable for pricing only',
  'Recently sold.'),
 ('LST-50030', '500 Fernvale St #1204',  'Larkspur Downtown', 465000, 2, 2.0, 1180, NULL,  'Condo',         2017, 420,  'Active',    current_date - 18, 'AGT-102', NULL,
  'Walk score 97; concierge; den that fits a desk; skyline views; one garage space',
  'High-floor downtown condo with a den and skyline views.'),
 ('LST-50031', '220 Lanyard Ave #305',   'Larkspur Downtown', 389000, 1, 1.0, 820,  NULL,  'Condo',         2008, 310,  'Active',    current_date - 33, 'AGT-102', NULL,
  'Walk score 95; in-unit laundry; bike storage',
  'One-bedroom condo steps from the downtown transit center.'),
 ('LST-50032', '88 Halberd St',          'Larkspur Downtown', 610000, 3, 2.5, 1720, 1600,  'Townhouse',     2019, 250,  'Active',    current_date - 11, 'AGT-103', NULL,
  'Ground-floor office with a separate entrance; rooftop terrace; walk score 93; two-car garage',
  'Modern three-level townhome with a ground-floor office and a rooftop terrace.'),
 ('LST-50033', '14 Calloway Mews',       'Larkspur Downtown', 540000, 2, 2.0, 1300, 900,   'Townhouse',     2013, 230,  'Withdrawn', current_date - 70, 'AGT-103', NULL,
  'Withdrawn from the market',
  'Withdrawn.');

INSERT INTO listing_price_changes (change_id, reference, listing_id, old_price, new_price, source, case_id, created_at) VALUES
 (1, 'LPC-000001', 'LST-50020', 895000, 865000, 'SEED', NULL, now() - INTERVAL '20 days');

-- ---------------------------------------------------------------------
-- Engagement history and showings
-- ---------------------------------------------------------------------
INSERT INTO lead_activity (lead_id, listing_id, activity_type, detail, created_at) VALUES
 ('LEAD-2026-00101', NULL,        'Search',         '3-bed single family in Cedar Hollow under $750k', now() - INTERVAL '9 days'),
 ('LEAD-2026-00101', 'LST-50001', 'Viewed Listing', 'Viewed 1418 Quillfeather Ln',                     now() - INTERVAL '8 days'),
 ('LEAD-2026-00101', 'LST-50001', 'Saved Listing',  'Saved 1418 Quillfeather Ln',                      now() - INTERVAL '8 days'),
 ('LEAD-2026-00101', 'LST-50002', 'Viewed Listing', 'Viewed 26 Brambleton Way',                        now() - INTERVAL '2 days'),
 ('LEAD-2026-00103', NULL,        'Search',         'Single family in Cedar Hollow, $450k-$650k',      now() - INTERVAL '1 day'),
 ('LEAD-2026-00106', 'LST-50002', 'Viewed Listing', 'Viewed 26 Brambleton Way',                        now() - INTERVAL '3 days'),
 ('LEAD-2026-00104', 'LST-50014', 'Listing Live',   '2210 Thistledown Rd listed at $612,000',          now() - INTERVAL '41 days');

INSERT INTO appointments (appointment_id, lead_id, listing_id, agent_id, scheduled_for, status, source, notes, created_at) VALUES
 ('APT-70001', 'LEAD-2026-00106', 'LST-50001', 'AGT-101', current_date + 2 + TIME '11:00', 'Confirmed', 'SEED', 'Second look.',      now() - INTERVAL '1 day'),
 ('APT-70002', 'LEAD-2026-00102', 'LST-50005', 'AGT-102', current_date - 20 + TIME '10:00', 'Completed', 'SEED', NULL,               now() - INTERVAL '25 days'),
 ('APT-70003', 'LEAD-2026-00101', 'LST-50003', 'AGT-101', current_date - 6 + TIME '16:00', 'Completed', 'SEED', 'Liked the yard; too far from shops.', now() - INTERVAL '9 days'),
 ('APT-70004', 'LEAD-2026-00106', 'LST-50014', 'AGT-101', current_date - 10 + TIME '14:00', 'Completed', 'SEED', NULL,               now() - INTERVAL '12 days');

INSERT INTO follow_up_tasks (task_no, task_id, lead_id, agent_id, message, intent, timeline, pre_approved, motivation, agent_brief, priority, due_at, status, created_at) VALUES
 (1, 'FUP-90001', 'LEAD-2026-00102', 'AGT-102', 'Please call me about the inspection results.', 'BUY', '0_3_MONTHS', 'YES', 'Under contract',
  NULL, 'HOT', now() - INTERVAL '6 days', 'Done', now() - INTERVAL '7 days');

-- ---------------------------------------------------------------------
-- Already-OPEN cases so every reviewer queue has something in it
-- ---------------------------------------------------------------------
INSERT INTO service_cases (case_no, case_id, lead_id, request_type, summary, reference_id, listing_id, target_stage, category,
                           requested_amount, current_amount, parked_action, agent_brief, priority, status, sla_due_at, created_at) VALUES
 (1, 'BPR-CASE-000001', 'LEAD-2026-00105', 'list_price_change',
  'Wants to lower the list price of 58 Lanternwood Dr from $865,000 to $825,000 after about nine weeks on the market.',
  'LST-50020', 'LST-50020', NULL, NULL, 825000, 865000, 'LIST_PRICE:LST-50020', NULL,
  'NORMAL', 'OPEN', add_business_days_ts((now() - INTERVAL '1 day')::timestamp, 1), now() - INTERVAL '1 day'),
 (2, 'BPR-CASE-000002', 'LEAD-2026-00106', 'fair_housing_review',
  'Asked which streets in Cedar Hollow have the most young families.',
  'FAMILY_STATUS', NULL, NULL, 'FAMILY_STATUS', NULL, NULL, NULL,
  'Fair-housing check (AI-prepared, not verified): flagged YES, category FAMILY_STATUS. The question asks where families with young children live, which concerns familial status, a protected class. Neutral answer given: Brightpath agents do not describe neighborhoods by who lives there; the lead was offered listings that match their search criteria and pointed to public city and census resources.',
  'HIGH', 'OPEN', add_business_days_ts((now() - INTERVAL '3 hours')::timestamp, 1), now() - INTERVAL '3 hours'),
 (3, 'BPR-CASE-000003', 'LEAD-2026-00106', 'offer_request',
  'Asks whether the sellers of 26 Brambleton Way would take $715,000 and wants help writing an offer.',
  'LST-50002', 'LST-50002', NULL, NULL, 715000, 735000, NULL, NULL,
  'NORMAL', 'OPEN', add_business_days_ts((now() - INTERVAL '5 hours')::timestamp, 1), now() - INTERVAL '5 hours');

-- New ids continue from 101 so demo-created rows stand out.
DO $$
BEGIN
  PERFORM setval(pg_get_serial_sequence('service_cases', 'case_no'), 100);
  PERFORM setval(pg_get_serial_sequence('follow_up_tasks', 'task_no'), 100);
  PERFORM setval(pg_get_serial_sequence('listing_price_changes', 'change_id'), 100);
  PERFORM setval(pg_get_serial_sequence('showing_events', 'event_id'), 100);
  PERFORM setval('appt_seq', 70101, FALSE);
END $$;

-- ---------------------------------------------------------------------
-- Agent reference tables (read-only for the A2A agents via ref_* functions; no lead, staff, case or contact data)
-- ---------------------------------------------------------------------
-- listing_match_agent -> ref_listing_match()
INSERT INTO listing_match_guide (section, term, meaning) VALUES
 ('COLUMN',       'listing_status',            'Active = can be shown and offered on; Pending = the sellers accepted an offer, so it is never ranked; Sold and Withdrawn listings are never candidates'),
 ('COLUMN',       'price / hoa_monthly',       'price = list price in US dollars; hoa_monthly = homeowners-association dues per month (empty = no HOA)'),
 ('COLUMN',       'bedrooms / bathrooms / sqft', 'bedroom and bathroom counts (a .5 is a half bath without a shower); sqft = interior square feet; lot_sqft = land area in square feet'),
 ('COLUMN',       'days_on_market',            'days since the listing went live; never use it to call a home a good deal or to say it will sell fast'),
 ('COLUMN',       'features / description',    'facts written by the listing agent; rank only on what they clearly state and never assume a feature that is not written'),
 ('WALK_SCORE',   '70 and above',              'very walkable - most daily errands can be done on foot'),
 ('WALK_SCORE',   '50 to 69',                  'somewhat walkable - some errands can be done on foot'),
 ('WALK_SCORE',   'below 50',                  'car-dependent - most errands need a car; never rank it for a walkability wish'),
 ('AMENITY',      'office with a door',        'a true home office - the strongest match for a home-office wish'),
 ('AMENITY',      'den / loft / flex room / nook', 'can work as an office but has no door - only a partial home-office match; say so'),
 ('AMENITY',      'no office space',           'a poor match for a home-office wish (a sitting area in a bedroom does not count)'),
 ('AMENITY',      'fenced yard / yard / patio', 'yard wishes: a fenced yard beats a yard, a yard beats a patio, and a patio beats no yard'),
 ('AMENITY',      'garage / assigned parking', 'a garage (more car spaces is better) beats one assigned space; street parking only is no parking match'),
 ('RANKING',      '1 hard limits',             'only Active rows that meet every stated hard limit (budget, minimum bedrooms, area, property type) can be ranked'),
 ('RANKING',      '2 wishes',                  'rank by how many of the stated wishes the features and description clearly support; a strong match beats a partial one'),
 ('RANKING',      '3 ties',                    'break ties by the lower price within budget'),
 ('RANKING',      '4 honesty',                 'say plainly which wish a ranked listing does not meet, for example "den, not a dedicated office"'),
 ('EXCLUDE',      'PENDING',                   'the sellers have accepted an offer - it cannot be shown or offered on'),
 ('EXCLUDE',      'OVER_BUDGET',               'the price is above the stated maximum budget'),
 ('EXCLUDE',      'TOO_FEW_BEDROOMS',          'fewer bedrooms than the stated minimum'),
 ('EXCLUDE',      'OUTSIDE_AREA',              'not in the area the buyer asked for'),
 ('EXCLUDE',      'WRONG_TYPE',                'a different property type from the one asked for (for example a condo when a single-family home was asked for)'),
 ('FAIR_HOUSING', 'wishes never ranked',       'schools, safety, crime, "family-friendly", quiet "for kids", places of worship and who lives nearby are never used for ranking - say that wish was not used and that Brightpath can share public sources instead'),
 ('NOTE_LINE',    'STANDARD',                  'Ranked only on the listing facts Brightpath has on file - your Brightpath agent can confirm every detail at a showing.'),
 ('NOTE_LINE',    'NO_MATCH',                  'None of the current listings meets every stated wish - your Brightpath agent can set up an alert for new listings that do.');

-- lead_intent_agent -> ref_lead_intent()   (the follow-up priority is NOT here: it is decided in SQL, follow_up_priority())
INSERT INTO lead_intent_guide (section, term, meaning) VALUES
 ('INTENT',       'BUY',                       'wants to purchase a home'),
 ('INTENT',       'SELL',                      'wants to sell a home'),
 ('INTENT',       'BUY_AND_SELL',              'selling one home and buying another (for example moving up or downsizing)'),
 ('INTENT',       'RENT',                      'wants to rent a home; Brightpath does not handle rentals'),
 ('INTENT',       'BROWSING',                  'curious or researching, "just looking", no plan yet'),
 ('INTENT',       'OTHER',                     'none of these - for example a complaint, a vendor or a question for the office'),
 ('TIMELINE',     '0_3_MONTHS',                'now, ASAP, "in a few weeks", "about two months", or a relocation start date within 3 months'),
 ('TIMELINE',     '3_6_MONTHS',                '"this spring" or "this summer" when that is 3 to 6 months away, "in a few months", "later this year" when within 6 months'),
 ('TIMELINE',     '6_12_MONTHS',               'six months to a year away, for example "by next summer" when that is within 12 months'),
 ('TIMELINE',     '12_PLUS',                   '"next year or later", "someday", or more than 12 months away'),
 ('TIMELINE',     'UNKNOWN',                   'no timing is stated - never guess one'),
 ('PRE_APPROVAL', 'YES',                       'a lender has pre-approved them, or pre-qualified them with a letter; paying cash also counts as YES'),
 ('PRE_APPROVAL', 'NO',                        'they say they have not started financing, still need a lender, or were turned down'),
 ('PRE_APPROVAL', 'UNKNOWN',                   'financing is not mentioned'),
 ('MOTIVATION',   'neutral phrases',           'one short neutral phrase in plain words, for example job relocation, more space, downsizing, investment, first home, closer to work; "not stated" when none is given'),
 ('RULE',         'protected characteristics', 'never record race, color, religion, national origin, sex, disability, family status or pregnancy, even if the person mentions them'),
 ('RULE',         'stated facts only',         'never guess personal details, income or credit that the message does not state'),
 ('FIRST_CALL',   'BUY',                       'Confirm the budget, must-haves and areas, ask whether a lender letter is in hand, and offer to set up a listing alert and a first round of showings.'),
 ('FIRST_CALL',   'SELL',                      'Offer a free comparative market analysis and an in-home listing consultation, and ask about the target move date and any planned repairs.'),
 ('FIRST_CALL',   'BUY_AND_SELL',              'Plan the sale and the purchase together: walk through the order of the two moves, and offer a comparative market analysis plus a listing alert for the next home.'),
 ('FIRST_CALL',   'RENT',                      'Explain kindly that Brightpath does not handle rentals, share public rental-listing resources, and ask whether buying later is of interest.'),
 ('FIRST_CALL',   'BROWSING',                  'Keep it light: offer a monthly market update for the areas mentioned and an open-house invitation, with no pressure to book showings.'),
 ('FIRST_CALL',   'OTHER',                     'Read the message first and pass it to the right person at the Brightpath office; no sales follow-up.');

-- fair_housing_agent -> ref_fair_housing()   (+ the ROUTING row - who reviews - from case_routing)
INSERT INTO fair_housing_guide (section, term, meaning) VALUES
 ('PROTECTED',    'race',                      'protected under the US Fair Housing Act - never describe an area by the race of the people who live there'),
 ('PROTECTED',    'color',                     'protected under the US Fair Housing Act - never describe an area or a home by the skin color of residents'),
 ('PROTECTED',    'religion',                  'protected under the US Fair Housing Act - never point anyone toward or away from an area because of places of worship or a religious community'),
 ('PROTECTED',    'national origin',           'protected under the US Fair Housing Act - never describe an area by where residents or their families come from, or by the languages spoken there'),
 ('PROTECTED',    'sex',                       'protected under the US Fair Housing Act (including sexual orientation and gender identity) - never describe who lives in an area by sex or gender'),
 ('PROTECTED',    'disability',                'protected under the US Fair Housing Act - share the accessibility features a listing states, but never describe neighbors or suggest an area because of a disability'),
 ('PROTECTED',    'familial status',           'protected under the US Fair Housing Act - households with children under 18, and pregnancy; never call an area family-friendly, full of kids or adults-only'),
 ('CATEGORY',     'SCHOOLS',                   'school quality or ratings, for example "are the schools good?" or "is it a good school district?"'),
 ('CATEGORY',     'SAFETY_CRIME',              'safety or crime, for example "is it safe at night?", "is this a good area or a bad area?"'),
 ('CATEGORY',     'DEMOGRAPHICS',              'who lives in an area by race, color or national origin, for example "what kind of people live there?", "people like me?", "is it diverse?"'),
 ('CATEGORY',     'FAMILY_STATUS',             '"is it family-friendly?", "lots of kids around?", "young families?", "quiet for a couple without kids?", "retirees only?"'),
 ('CATEGORY',     'RELIGION',                  'places of worship or a religious community as a reason to choose, for example "is there a church community nearby?"'),
 ('CATEGORY',     'DISABILITY',                'neighbors with disabilities or group homes nearby (a listing''s own accessibility features are fine to share)'),
 ('CATEGORY',     'OTHER_PROTECTED',           'who lives in an area by sex, sexual orientation or gender identity'),
 ('CATEGORY',     'NONE',                      'no Fair Housing risk - walkability, commute times, lot size, HOA rules or a listing''s own features'),
 ('NEUTRAL_ANSWER', 'SCHOOLS',                 'Brightpath agents do not rate schools, so that every buyer gets the same information. The Larkspur Valley Unified School District publishes attendance boundaries and school report cards, and I am happy to share listing facts like walk score, commute and lot size.'),
 ('NEUTRAL_ANSWER', 'SAFETY_CRIME',            'Brightpath agents do not rate the safety of any area, so that every buyer gets the same information. The Larkspur Valley Police Department publishes a public crime map, and I am happy to share listing facts like walk score, commute and lot size.'),
 ('NEUTRAL_ANSWER', 'DEMOGRAPHICS',            'Brightpath agents do not describe who lives in an area, so that every buyer gets the same information. The US Census Bureau publishes area statistics in its American Community Survey, and I am happy to share listing facts like walk score, commute and lot size.'),
 ('NEUTRAL_ANSWER', 'FAMILY_STATUS',           'Brightpath agents do not describe areas by the households who live there or rate schools or safety, so that every buyer gets the same information. The Larkspur Valley Unified School District publishes attendance boundaries and the Larkspur Valley Police Department publishes a public crime map; I am happy to share listing facts like lot size and the floor plan.'),
 ('NEUTRAL_ANSWER', 'RELIGION',                'Brightpath agents do not suggest areas based on religion or places of worship, so that every buyer gets the same information. Public map services list places of worship by address, and I am happy to share listing facts like commute and walk score.'),
 ('NEUTRAL_ANSWER', 'DISABILITY',              'Brightpath agents do not describe neighbors or suggest areas based on disability, so that every buyer gets the same information. I am happy to share each listing''s stated accessibility features, such as a step-free entry or a main-floor bedroom.'),
 ('NEUTRAL_ANSWER', 'OTHER_PROTECTED',         'Brightpath agents do not describe residents by sex, sexual orientation or gender identity, so that every buyer gets the same information. The US Census Bureau publishes area statistics in its American Community Survey, and I am happy to share listing facts like walk score and commute.'),
 ('RULE',         'never answer or hint',      'never answer the question itself and never hint, for example "you will love it there" or "it is very popular with families"'),
 ('RULE',         'most sensitive first',      'when several categories apply, choose the most sensitive: DEMOGRAPHICS, RELIGION, FAMILY_STATUS, DISABILITY, OTHER_PROTECTED, then SAFETY_CRIME, then SCHOOLS'),
 ('RULE',         'friendly tone',             'never refuse rudely or lecture; offer listing facts instead, and a person on Brightpath''s compliance team reviews every flagged question');
