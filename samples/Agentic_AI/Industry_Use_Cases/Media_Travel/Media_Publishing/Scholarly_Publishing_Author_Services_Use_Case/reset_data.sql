-- Reset the demo: clears everything the assistant wrote (sessions, proposals, transfers, cases)
-- and reloads the demo data with dates relative to today.
-- psql -d author_services -f reset_data.sql

TRUNCATE review_cases, transfers, pending_actions, author_sessions, manuscripts, authors,
  agreement_journals, oa_agreements, journals, institutions, review_teams RESTART IDENTITY CASCADE;

-- ---------------------------------------------------------------------
-- Demo data (fictional publisher, journals, people). Dates are relative to today.
-- ---------------------------------------------------------------------
INSERT INTO institutions VALUES
 ('INST-001','University of Northbridge','United Kingdom'),
 ('INST-002','Kestrel Institute of Technology','Norway'),
 ('INST-003','Harbourview College','Canada');

INSERT INTO oa_agreements VALUES
 ('AGR-001','INST-001','Northbridge Read & Publish 2026','Read & Publish',100, date_trunc('year',current_date)::date, (date_trunc('year',current_date) + interval '1 year - 1 day')::date, 250000, 118400),
 ('AGR-002','INST-002','Kestrel Publish & Read 2026','Publish & Read',100, date_trunc('year',current_date)::date, (date_trunc('year',current_date) + interval '1 year - 1 day')::date,  90000,  89200);

INSERT INTO journals (journal_code,title,subject_area,aims_scope,keywords,oa_model,apc_usd,word_limit,median_days_to_first_decision,accepts_transfers,is_active) VALUES
 ('JACI','Journal of Applied Climate Informatics','Climate Science',
  'Methods papers on data pipelines, sensor networks and software for climate records. We do not publish regional impact or hazard studies.',
  'climate data, data pipelines, reanalysis, sensor networks, research software','Hybrid',3400,8000,38,TRUE,TRUE),
 ('CHRR','Coastal Hazards and Risk Review','Earth & Environmental Science',
  'Coastal flooding, storm surge, sea-level rise and the risk they pose to people and infrastructure, including statistical and machine-learning risk models.',
  'coastal flooding, storm surge, sea-level rise, flood risk, hazard mapping, machine learning','Gold OA',2900,9000,41,TRUE,TRUE),
 ('EDSR','Environmental Data Science Reports','Earth & Environmental Science',
  'Short, reproducible studies that apply machine learning and statistics to environmental data, with open code and data.',
  'machine learning, downscaling, environmental data, reproducibility, deep learning','Gold OA',1850,6000,27,TRUE,TRUE),
 ('HCRL','Hydrology and Climate Resilience Letters','Earth & Environmental Science',
  'Hydrology, flood modelling, climate adaptation and resilience planning at catchment to city scale.',
  'hydrology, flood modelling, climate adaptation, resilience, rainfall','Hybrid',3100,8500,45,TRUE,TRUE),
 ('UPIS','Urban Planning and Infrastructure Studies','Social Science',
  'Policy and planning research on urban infrastructure, transport and housing.',
  'urban planning, infrastructure policy, housing, transport','Hybrid',2600,10000,60,TRUE,TRUE),
 ('CMLT','Computational Materials Letters','Materials Science',
  'Rapid communications on computational materials discovery and simulation.',
  'materials discovery, density functional theory, simulation, alloys','Gold OA',2200,5000,21,TRUE,TRUE),
 ('BIOM','Biomolecular Methods','Life Sciences',
  'New laboratory and computational methods for structural and molecular biology.',
  'protein structure, cryo-EM, molecular biology methods','Hybrid',3800,9000,50,TRUE,TRUE),
 ('NEUR','Frontiers of Neural Computation','Computer Science',
  'Theory and applications of neural networks and deep learning.',
  'neural networks, deep learning, representation learning, optimisation','Hybrid',3000,9000,44,FALSE,TRUE),
 ('GEOS','Geospatial Analytics Quarterly','Earth & Environmental Science',
  'Remote sensing, GIS and spatial statistics, including satellite-based flood and land-use mapping.',
  'remote sensing, GIS, spatial statistics, satellite imagery, flood mapping','Hybrid',2750,8000,52,TRUE,TRUE),
 ('OCEN','Ocean Dynamics Letters','Earth & Environmental Science',
  'Physical oceanography: circulation, waves, tides and sea level.',
  'ocean circulation, waves, tides, sea level','Gold OA',2400,7000,35,TRUE,TRUE),
 ('SOCM','Society and Medicine','Health Sciences',
  'Social determinants of health and health policy.',
  'public health, health policy, epidemiology','Hybrid',3300,8000,58,TRUE,TRUE),
 ('ENGR','Engineering Structures Review','Engineering',
  'Structural engineering, including flood-resilient infrastructure design.',
  'structural engineering, resilient design, infrastructure','Hybrid',2950,9000,47,TRUE,TRUE),
 ('RETR','Archive of Climate Methods (retired)','Climate Science',
  'Retired title. No longer accepting submissions.',
  'climate methods','Hybrid',0,8000,0,FALSE,FALSE);

INSERT INTO agreement_journals VALUES
 ('AGR-001','JACI'),('AGR-001','HCRL'),('AGR-001','EDSR'),('AGR-001','GEOS'),('AGR-001','UPIS'),('AGR-001','ENGR'),
 ('AGR-002','CMLT'),('AGR-002','EDSR'),('AGR-002','CHRR'),('AGR-002','OCEN');

INSERT INTO authors VALUES
 ('AUT-1001','0000-0002-1825-0097','Dr. Maya Okafor','maya.okafor@northbridge.example','INST-001','482913'),
 ('AUT-1002','0000-0004-7316-2588','Prof. Lars Eriksen','lars.eriksen@kestrel.example','INST-002','771204'),
 ('AUT-1003','0000-0003-1415-9269','Dr. Ana Ribeiro','ana.ribeiro@harbourview.example','INST-003','305118');

INSERT INTO manuscripts (manuscript_id,corresponding_author_id,journal_code,title,abstract,keywords,article_type,word_count,status,status_detail,decision_summary,submitted_on,last_updated,integrity_hold) VALUES
 ('MS-2026-0412','AUT-1001','JACI',
  'Machine-learning downscaling of compound coastal flood risk for small island states',
  'We present a gradient-boosted downscaling model that combines storm-surge hindcasts, tide-gauge records and rainfall reanalysis to estimate compound coastal flood risk at 250 m resolution for twelve small island states. Validated against surveyed flood extents, the model reduces error by 31% versus dynamical downscaling at a fraction of the compute cost. We release code and data.',
  'coastal flooding, compound flood risk, machine learning, downscaling, storm surge, small island states',
  'Research Article',7800,'REJECTED_TRANSFER_ELIGIBLE',
  'Decision sent. The editor offered a transfer to a better-suited journal.',
  'Sound work, but out of scope: the journal publishes data-pipeline methods, not regional hazard studies. Reviewers praised the validation. Transfer offered.',
  current_date - 64, now() - interval '3 days', FALSE),
 ('MS-2026-0388','AUT-1001','HCRL',
  'Rainfall intensity trends and culvert failure in mid-sized UK towns',
  'An analysis of 40 years of rainfall intensity records against culvert failure reports in 58 towns.',
  'rainfall, hydrology, infrastructure failure, climate adaptation',
  'Research Article',6900,'UNDER_REVIEW',
  'Under review. Reviewers assigned; 2 of 3 reports received.',NULL,
  current_date - 41, now() - interval '6 days', FALSE),
 ('MS-2026-0301','AUT-1001','GEOS',
  'Sentinel-1 flood extent mapping with uncertainty bands',
  'A method for mapping flood extent from SAR imagery with calibrated uncertainty.',
  'remote sensing, flood mapping, uncertainty, satellite imagery',
  'Research Article',7100,'REVISION_REQUESTED',
  'Minor revision requested. Revised manuscript due in 21 days.',
  'Clarify the calibration dataset and add a comparison with optical imagery.',
  current_date - 95, now() - interval '9 days', FALSE),
 ('MS-2026-0450','AUT-1002','CHRR',
  'Storm-surge barriers and fjord ecosystems: a 30-year view',
  'Long-term monitoring of fjord ecology before and after storm-surge barrier construction.',
  'storm surge, coastal ecology, fjords, infrastructure',
  'Research Article',8200,'ACCEPTED',
  'Accepted. Awaiting open-access licence and APC arrangement before production.',
  'Accepted after one round of revision.',
  current_date - 120, now() - interval '2 days', FALSE),
 ('MS-2026-0433','AUT-1002','OCEN',
  'A unified wave-tide model for Arctic coastlines',
  'We couple spectral wave and tidal models for sea-ice-affected coasts, with an extended validation across 64 stations.',
  'waves, tides, arctic, coastal modelling, sea ice',
  'Research Article',11800,'REJECTED_TRANSFER_ELIGIBLE',
  'Decision sent. The editor offered a transfer.',
  'Strong modelling but beyond this letters journal''s length; suggested a transfer to a journal that takes long-form articles.',
  current_date - 70, now() - interval '5 days', FALSE),
 ('MS-2026-0419','AUT-1003','SOCM',
  'Neighbourhood heat exposure and emergency admissions',
  'Links heat exposure maps to emergency admissions across three cities.',
  'public health, heat, epidemiology',
  'Research Article',7400,'REJECTED_TRANSFER_ELIGIBLE',
  'Decision sent. The editor offered a transfer.',
  'Out of scope; transfer offered.',
  current_date - 50, now() - interval '4 days', TRUE);

INSERT INTO review_teams VALUES
 ('APC_WAIVER','Open Access Office',5),
 ('DECISION_APPEAL','Editorial Office (handling editor)',10),
 ('AUTHORSHIP_CHANGE','Editorial Office (authorship)',7),
 ('INTEGRITY_QUERY','Research Integrity Team',10),
 ('OTHER','Author Services',3);
