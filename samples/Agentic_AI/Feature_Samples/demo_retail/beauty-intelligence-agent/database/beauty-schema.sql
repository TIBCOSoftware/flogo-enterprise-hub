-- BeautyCo Demo 1 — Beauty Intelligence Agent
-- Database: beauty_db
-- Run: psql -U postgres -d beauty_db -f beauty-schema.sql

-- ─── Members ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS members (
  member_id        VARCHAR(20)   PRIMARY KEY,
  first_name       VARCHAR(100)  NOT NULL,
  last_name        VARCHAR(100)  NOT NULL,
  email            VARCHAR(200),
  phone            VARCHAR(20),
  tier             VARCHAR(20)   NOT NULL DEFAULT 'MEMBER',
  join_date        DATE,
  preferred_store  VARCHAR(10),
  birth_month      INTEGER,
  kyc_status       VARCHAR(20)   NOT NULL DEFAULT 'VERIFIED',
  created_at       TIMESTAMP     NOT NULL DEFAULT NOW()
);

-- ─── Beauty Profiles ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS beauty_profiles (
  member_id        VARCHAR(20)   PRIMARY KEY REFERENCES members(member_id),
  skin_tone        VARCHAR(30),
  skin_concerns    TEXT[],
  hair_texture     VARCHAR(30),
  hair_concerns    TEXT[],
  fragrance_family VARCHAR(30),
  allergy_flags    TEXT[],
  updated_at       TIMESTAMP     NOT NULL DEFAULT NOW()
);

-- ─── Purchase History ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS purchases (
  id               SERIAL        PRIMARY KEY,
  member_id        VARCHAR(20)   NOT NULL REFERENCES members(member_id),
  transaction_id   VARCHAR(50)   NOT NULL,
  sku              VARCHAR(30)   NOT NULL,
  brand            VARCHAR(100),
  product_name     VARCHAR(200),
  category         VARCHAR(50),
  price            NUMERIC(10,2),
  channel          VARCHAR(20),
  store_id         VARCHAR(10),
  purchased_at     TIMESTAMP     NOT NULL DEFAULT NOW()
);

-- ─── Loyalty Accounts ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyalty_accounts (
  member_id           VARCHAR(20)   PRIMARY KEY REFERENCES members(member_id),
  points_available    INTEGER       NOT NULL DEFAULT 0,
  points_pending      INTEGER       NOT NULL DEFAULT 0,
  points_lifetime     INTEGER       NOT NULL DEFAULT 0,
  tier_spend_ytd      NUMERIC(10,2) NOT NULL DEFAULT 0,
  tier_spend_needed   NUMERIC(10,2),
  next_expiry_date    DATE,
  next_expiry_points  INTEGER,
  updated_at          TIMESTAMP     NOT NULL DEFAULT NOW()
);

-- ─── Loyalty Activity ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyalty_activity (
  id               SERIAL        PRIMARY KEY,
  member_id        VARCHAR(20)   NOT NULL REFERENCES members(member_id),
  activity_type    VARCHAR(30),
  points           INTEGER,
  transaction_id   VARCHAR(50),
  description      TEXT,
  activity_date    TIMESTAMP     NOT NULL DEFAULT NOW()
);

-- ─── Returns History ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS returns (
  id               SERIAL        PRIMARY KEY,
  member_id        VARCHAR(20)   NOT NULL REFERENCES members(member_id),
  sku              VARCHAR(30)   NOT NULL,
  brand            VARCHAR(100),
  product_name     VARCHAR(200),
  return_reason    VARCHAR(100),
  resolution       VARCHAR(50),
  returned_at      TIMESTAMP     NOT NULL DEFAULT NOW()
);

-- ─── Consultations ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS consultations (
  id                  SERIAL        PRIMARY KEY,
  member_id           VARCHAR(20)   NOT NULL,
  recommended_skus    TEXT,
  offer_applied       VARCHAR(50),
  consultation_notes  TEXT,
  channel_type        VARCHAR(20),
  created_at          TIMESTAMP     NOT NULL DEFAULT NOW()
);

-- ─── Loyalty Offers ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyalty_offers (
  offer_id         VARCHAR(36)   DEFAULT gen_random_uuid()::text PRIMARY KEY,
  member_id        VARCHAR(20)   NOT NULL,
  offer_type       VARCHAR(40),
  discount_percent NUMERIC(5,2),
  bonus_points     INTEGER,
  eligible_skus    TEXT[],
  expires_at       TIMESTAMP,
  created_at       TIMESTAMP     NOT NULL DEFAULT NOW()
);

-- ─── Agent Decision Audit Log ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS agent_log (
  id               SERIAL        PRIMARY KEY,
  member_id        VARCHAR(20),
  agent_reasoning  TEXT,
  tools_used       TEXT[],
  outcome          VARCHAR(200),
  confidence_score NUMERIC(4,3),
  created_at       TIMESTAMP     NOT NULL DEFAULT NOW()
);

-- ─── Indexes ────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_purchases_member ON purchases(member_id, purchased_at DESC);
CREATE INDEX IF NOT EXISTS idx_returns_member ON returns(member_id, returned_at DESC);
CREATE INDEX IF NOT EXISTS idx_agent_log_created ON agent_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_consultations_created ON consultations(created_at DESC);

-- ─── Seed: 3 Demo Members ───────────────────────────────────────────────────
INSERT INTO members (member_id, first_name, last_name, email, phone, tier, join_date, preferred_store, birth_month, kyc_status)
VALUES
  ('M-7724-ASHA', 'Asha',       'Patel',    'asha.patel@example.com',    '555-0101', 'DIAMOND',  '2019-03-15', '0847', 8,              'VERIFIED'),
  ('M-1138-CASS', 'Cassandra',  'Williams', 'cass.w@example.com',        '555-0202', 'PLATINUM', '2021-07-22', '0847', EXTRACT(MONTH FROM NOW())::INTEGER, 'VERIFIED'),
  ('M-0042-JUNE', 'June',       'Chen',     'june.chen@example.com',     '555-0303', 'MEMBER',   (NOW() - INTERVAL '90 days')::DATE, '1204', 4, 'VERIFIED')
ON CONFLICT DO NOTHING;

INSERT INTO beauty_profiles (member_id, skin_tone, skin_concerns, hair_texture, hair_concerns, fragrance_family, allergy_flags)
VALUES
  ('M-7724-ASHA', 'Medium',     '{aging,dryness}',              'Coarse',     '{frizz,dryness}',      'Floral',   '{}'),
  ('M-1138-CASS', 'Deep',       '{hyperpigmentation,acne}',     'Coily',      '{dryness,color_treated}', 'Woody', '{}'),
  ('M-0042-JUNE', 'Fair',       '{sensitivity,redness}',        'Fine',       '{thinning}',           'Fresh',    '{parabens}')
ON CONFLICT DO NOTHING;

INSERT INTO loyalty_accounts (member_id, points_available, points_pending, points_lifetime, tier_spend_ytd, tier_spend_needed, next_expiry_date, next_expiry_points)
VALUES
  ('M-7724-ASHA', 4200, 120,  18450, 1847.50, NULL,   (NOW() + INTERVAL '45 days')::DATE, 500),
  ('M-1138-CASS', 1850,  80,   4200,  612.00, 388.00, (NOW() + INTERVAL '90 days')::DATE, 200),
  ('M-0042-JUNE',  320,  20,    340,   89.95, 160.05, (NOW() + INTERVAL '180 days')::DATE, 50)
ON CONFLICT DO NOTHING;

INSERT INTO purchases (member_id, transaction_id, sku, brand, product_name, category, price, channel, store_id, purchased_at) VALUES
  ('M-7724-ASHA','TXN-20240115','CT-WONDERGLOW-01',  'Charlotte Tilbury','Wonderglow Primer',         'SKINCARE',  52.00,'IN_STORE','0847', NOW() - INTERVAL '14 days'),
  ('M-7724-ASHA','TXN-20240210','OLP-007-100ML',     'Olaplex',          'No.7 Bonding Oil 100ml',    'HAIRCARE',  28.00,'IN_STORE','0847', NOW() - INTERVAL '60 days'),
  ('M-7724-ASHA','TXN-20240320','DR-VITC-SERUM',     'Dr. Jart+',        'Vitamin C Serum 30ml',      'SKINCARE',  48.00,'ONLINE',  NULL,   NOW() - INTERVAL '90 days'),
  ('M-7724-ASHA','TXN-20240405','CT-PILLOWTALK-L',   'Charlotte Tilbury','Pillow Talk Lipstick',      'MAKEUP',    36.00,'IN_STORE','0847', NOW() - INTERVAL '120 days'),
  ('M-7724-ASHA','TXN-20240512','DRP-MOISTURISER',   'Drunk Elephant',   'Protini Polypeptide Cream', 'SKINCARE',  68.00,'IN_STORE','0847', NOW() - INTERVAL '150 days'),
  ('M-1138-CASS','TXN-20240220','FB-GLOSS-BOMB-210', 'Fenty Beauty',     'Gloss Bomb 210 Fenty Glow', 'MAKEUP',    21.00,'IN_STORE','0847', NOW() - INTERVAL '30 days'),
  ('M-1138-CASS','TXN-20240310','KVD-TATTOO-LINE',   'KVD Beauty',       'Tattoo Liner Trooper Black', 'MAKEUP',   24.00,'ONLINE',  NULL,   NOW() - INTERVAL '75 days'),
  ('M-1138-CASS','TXN-20240401','PAT-SKIN-TINT',     'Pattern Beauty',   'Shine Drops Skin Tint',     'SKINCARE',  32.00,'IN_STORE','0847', NOW() - INTERVAL '110 days'),
  ('M-0042-JUNE','TXN-20240501','CER-GENTLE-FACE',   'CeraVe',           'Gentle Foaming Cleanser',   'SKINCARE',  16.99,'IN_STORE','1204', NOW() - INTERVAL '10 days'),
  ('M-0042-JUNE','TXN-20240515','LA-ROCHE-SENSI',    'La Roche-Posay',   'Toleriane Sensitive Fluid', 'SKINCARE',  22.99,'ONLINE',  NULL,   NOW() - INTERVAL '5 days')
ON CONFLICT DO NOTHING;

INSERT INTO returns (member_id, sku, brand, product_name, return_reason, resolution, returned_at) VALUES
  ('M-7724-ASHA', 'ESTL-FACE-CREAM', 'Estée Lauder', 'Revitalizing Supreme+ Cream', 'SKIN_REACTION', 'REFUND',        NOW() - INTERVAL '30 days'),
  ('M-1138-CASS', 'NYX-SETTING-SPR', 'NYX Professional', 'Matte Finish Setting Spray', 'CHANGED_MIND', 'STORE_CREDIT', NOW() - INTERVAL '45 days')
ON CONFLICT DO NOTHING;

SELECT 'beauty_db seed data loaded successfully' AS status;
