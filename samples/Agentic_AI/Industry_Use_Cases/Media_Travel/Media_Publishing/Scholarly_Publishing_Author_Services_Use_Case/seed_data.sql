-- Demo data for the Scholarly Publishing Author Services Assistant (governed). Fictional publisher, journals,
-- institutions, staff and people. Dates are relative to today so the demo always looks current.
-- Included by database.sql and reset_data.sql via \ir - do not load on its own.
--
-- Authors (ORCID iD + the code from the "verification email"):
--   AUT-1001 Dr. Maya Okafor     0000-0002-1825-0097  482913  MS-2026-0412 transfer offer (HCRL: statements complete, covered
--                                                            in full; CHRR: author contributions missing); MS-2026-0301
--                                                            revision requested + reviewer comments (revision checklist)
--   AUT-1002 Prof. Lars Eriksen  0000-0004-7316-2588  771204  MS-2026-0450 accepted, agreement budget used up -> pays $2,900
--                                                            (live APC waiver -> reviewer loop); MS-2026-0433 over every limit
--   AUT-1003 Dr. Ana Ribeiro     0000-0003-1415-9269  305118  MS-2026-0419 under an editorial hold (details hidden)
--   AUT-1004 Dr. Elena Vasquez   0000-0001-5109-3700  615204  MS-2026-0466 transfer offer -> EDSR needs open data + a
--                                                            competing-interests statement (submission check INCOMPLETE);
--                                                            MS-2026-0458 accepted at EDSR, seeded OPEN $1,850 waiver case
--
-- Staff reviewers (human in the loop; staff ID + staff code):
--   PUB-7001 Grace Whitfield   Open Access Office                  246810  approval limit $1,500.00 (OVER_AUTHORITY demo)
--   PUB-7002 Samuel Osei       Open Access Office                  135790  approval limit $5,000.00
--   PUB-7003 Helen Marsh       Editorial Office (handling editor)  864209  appeals + submission statements exceptions
--   PUB-7004 Tom Becker        Editorial Office (authorship)       502468
--   PUB-7005 Rafael Duarte     Research Integrity Team             719350

INSERT INTO institutions VALUES
 ('INST-001','University of Northbridge','United Kingdom'),
 ('INST-002','Kestrel Institute of Technology','Norway'),
 ('INST-003','Harbourview College','Canada'),
 ('INST-004','Lakeshore State University','United States');

INSERT INTO oa_agreements VALUES
 ('AGR-001','INST-001','Northbridge Read & Publish 2026','Read & Publish',100, date_trunc('year',current_date)::date, (date_trunc('year',current_date) + interval '1 year - 1 day')::date, 250000, 118400),
 ('AGR-002','INST-002','Kestrel Publish & Read 2026','Publish & Read',100, date_trunc('year',current_date)::date, (date_trunc('year',current_date) + interval '1 year - 1 day')::date,  90000,  89200);

-- Submission policies (reference data for submission_check_agent). keyword_pattern = the deterministic presence check.
INSERT INTO submission_policies (policy_set, statement, sort_order, requirement, must_include, standard_wording, keyword_pattern) VALUES
 ('STANDARD','DATA_AVAILABILITY',1,'MANDATORY',
  'Where the data supporting the results can be found (repository and identifier), or why they cannot be shared.',
  'Please add a Data Availability Statement saying where the data supporting your results can be found (repository and persistent identifier), or why they cannot be shared.',
  'data availab|data (and code )?(are|is) (openly |publicly )?available|repository|doi'),
 ('STANDARD','ETHICS_APPROVAL',2,'RECOMMENDED',
  'The approving committee and approval number when people, animals or protected sites are involved; otherwise "Not applicable".',
  'If your study involved people, animals or protected sites, please name the approving committee and give the approval number; otherwise state "Ethics approval: Not applicable."',
  'ethic|institutional review board|committee|not applicable'),
 ('STANDARD','FUNDING',3,'MANDATORY',
  'Each funder''s name and grant number, or a sentence saying there was no external funding.',
  'Please list every funder with its grant number, or state: "This research received no external funding."',
  'fund|grant|financial support|supported by'),
 ('STANDARD','COMPETING_INTERESTS',4,'MANDATORY',
  'A statement covering all authors, even when there are none.',
  'Please add a Competing Interests statement covering all authors; if there are none, write: "The authors declare no competing interests."',
  'competing interest|conflicts? of interest'),
 ('STANDARD','AUTHOR_CONTRIBUTIONS',5,'RECOMMENDED',
  'Each author''s role, ideally in CRediT terms.',
  'We recommend an Author Contributions statement that describes each author''s role in CRediT terms (for example conceptualization, methodology, writing - original draft).',
  'contribution|credit|conceptuali'),
 ('OPEN_DATA','DATA_AVAILABILITY',1,'MANDATORY',
  'The repository name and a persistent identifier (DOI or accession number) for both the data and the code behind the results. "Available on request" is not accepted.',
  'This journal requires open data and code: please deposit the data and code behind your results in a public repository and cite them with a persistent identifier (DOI or accession number) in your Data Availability Statement.',
  'data availab|data (and code )?(are|is) (openly |publicly )?available|repository|doi'),
 ('OPEN_DATA','ETHICS_APPROVAL',2,'RECOMMENDED',
  'The approving committee and approval number when people, animals or protected sites are involved; otherwise "Not applicable".',
  'If your study involved people, animals or protected sites, please name the approving committee and give the approval number; otherwise state "Ethics approval: Not applicable."',
  'ethic|institutional review board|committee|not applicable'),
 ('OPEN_DATA','FUNDING',3,'MANDATORY',
  'Each funder''s name and grant number, or a sentence saying there was no external funding.',
  'Please list every funder with its grant number, or state: "This research received no external funding."',
  'fund|grant|financial support|supported by'),
 ('OPEN_DATA','COMPETING_INTERESTS',4,'MANDATORY',
  'A statement covering all authors, even when there are none.',
  'Please add a Competing Interests statement covering all authors; if there are none, write: "The authors declare no competing interests."',
  'competing interest|conflicts? of interest'),
 ('OPEN_DATA','AUTHOR_CONTRIBUTIONS',5,'MANDATORY',
  'Each author''s role in CRediT terms (for example conceptualization, methodology, software, writing).',
  'Please add an Author Contributions statement that describes each author''s role in CRediT terms (for example conceptualization, methodology, software, writing - original draft).',
  'contribution|credit|conceptuali'),
 ('HUMAN_SUBJECTS','DATA_AVAILABILITY',1,'MANDATORY',
  'Where de-identified data can be accessed and under what conditions, or why they cannot be shared.',
  'Please add a Data Availability Statement saying where the de-identified data can be accessed and under what conditions, or why they cannot be shared.',
  'data availab|data (and code )?(are|is) (openly |publicly )?available|repository|doi'),
 ('HUMAN_SUBJECTS','ETHICS_APPROVAL',2,'MANDATORY',
  'The name of the ethics committee or institutional review board, the approval number, and how consent was obtained or why it was waived.',
  'Please name the ethics committee or institutional review board that approved the study, give the approval number, and say how informed consent was obtained or why it was waived.',
  'ethic|institutional review board|committee|not applicable'),
 ('HUMAN_SUBJECTS','FUNDING',3,'MANDATORY',
  'Each funder''s name and grant number, or a sentence saying there was no external funding.',
  'Please list every funder with its grant number, or state: "This research received no external funding."',
  'fund|grant|financial support|supported by'),
 ('HUMAN_SUBJECTS','COMPETING_INTERESTS',4,'MANDATORY',
  'A statement covering all authors, even when there are none.',
  'Please add a Competing Interests statement covering all authors; if there are none, write: "The authors declare no competing interests."',
  'competing interest|conflicts? of interest'),
 ('HUMAN_SUBJECTS','AUTHOR_CONTRIBUTIONS',5,'MANDATORY',
  'Each author''s role in CRediT terms.',
  'Please add an Author Contributions statement that describes each author''s role in CRediT terms (for example conceptualization, methodology, investigation, writing - original draft).',
  'contribution|credit|conceptuali');

INSERT INTO journals (journal_code,title,subject_area,aims_scope,keywords,oa_model,apc_usd,word_limit,median_days_to_first_decision,accepts_transfers,is_active,policy_set) VALUES
 ('JACI','Journal of Applied Climate Informatics','Climate Science',
  'Methods papers on data pipelines, sensor networks and software for climate records. We do not publish regional impact or hazard studies.',
  'climate data, data pipelines, reanalysis, sensor networks, research software','Hybrid',3400,8000,38,TRUE,TRUE,'STANDARD'),
 ('CHRR','Coastal Hazards and Risk Review','Earth & Environmental Science',
  'Coastal flooding, storm surge, sea-level rise and the risk they pose to people and infrastructure, including statistical and machine-learning risk models.',
  'coastal flooding, storm surge, sea-level rise, flood risk, hazard mapping, machine learning','Gold OA',2900,9000,41,TRUE,TRUE,'OPEN_DATA'),
 ('EDSR','Environmental Data Science Reports','Earth & Environmental Science',
  'Short, reproducible studies that apply machine learning and statistics to environmental data, with open code and data.',
  'machine learning, downscaling, environmental data, reproducibility, deep learning','Gold OA',1850,6000,27,TRUE,TRUE,'OPEN_DATA'),
 ('HCRL','Hydrology and Climate Resilience Letters','Earth & Environmental Science',
  'Hydrology, flood modelling, climate adaptation and resilience planning at catchment to city scale.',
  'hydrology, flood modelling, climate adaptation, resilience, rainfall','Hybrid',3100,8500,45,TRUE,TRUE,'STANDARD'),
 ('UPIS','Urban Planning and Infrastructure Studies','Social Science',
  'Policy and planning research on urban infrastructure, transport and housing.',
  'urban planning, infrastructure policy, housing, transport','Hybrid',2600,10000,60,TRUE,TRUE,'HUMAN_SUBJECTS'),
 ('CMLT','Computational Materials Letters','Materials Science',
  'Rapid communications on computational materials discovery and simulation.',
  'materials discovery, density functional theory, simulation, alloys','Gold OA',2200,5000,21,TRUE,TRUE,'OPEN_DATA'),
 ('BIOM','Biomolecular Methods','Life Sciences',
  'New laboratory and computational methods for structural and molecular biology.',
  'protein structure, cryo-EM, molecular biology methods','Hybrid',3800,9000,50,TRUE,TRUE,'STANDARD'),
 ('NEUR','Frontiers of Neural Computation','Computer Science',
  'Theory and applications of neural networks and deep learning.',
  'neural networks, deep learning, representation learning, optimisation','Hybrid',3000,9000,44,FALSE,TRUE,'STANDARD'),
 ('GEOS','Geospatial Analytics Quarterly','Earth & Environmental Science',
  'Remote sensing, GIS and spatial statistics, including satellite-based flood and land-use mapping.',
  'remote sensing, GIS, spatial statistics, satellite imagery, flood mapping','Hybrid',2750,8000,52,TRUE,TRUE,'STANDARD'),
 ('OCEN','Ocean Dynamics Letters','Earth & Environmental Science',
  'Physical oceanography: circulation, waves, tides and sea level.',
  'ocean circulation, waves, tides, sea level','Gold OA',2400,7000,35,TRUE,TRUE,'OPEN_DATA'),
 ('SOCM','Society and Medicine','Health Sciences',
  'Social determinants of health and health policy.',
  'public health, health policy, epidemiology','Hybrid',3300,8000,58,TRUE,TRUE,'HUMAN_SUBJECTS'),
 ('ENGR','Engineering Structures Review','Engineering',
  'Structural engineering, including flood-resilient infrastructure design.',
  'structural engineering, resilient design, infrastructure','Hybrid',2950,9000,47,TRUE,TRUE,'STANDARD'),
 ('RETR','Archive of Climate Methods (retired)','Climate Science',
  'Retired title. No longer accepting submissions.',
  'climate methods','Hybrid',0,8000,0,FALSE,FALSE,'STANDARD');

INSERT INTO agreement_journals VALUES
 ('AGR-001','JACI'),('AGR-001','HCRL'),('AGR-001','EDSR'),('AGR-001','GEOS'),('AGR-001','UPIS'),('AGR-001','ENGR'),
 ('AGR-002','CMLT'),('AGR-002','EDSR'),('AGR-002','CHRR'),('AGR-002','OCEN');

INSERT INTO authors VALUES
 ('AUT-1001','0000-0002-1825-0097','Dr. Maya Okafor','maya.okafor@northbridge.example','INST-001','482913'),
 ('AUT-1002','0000-0004-7316-2588','Prof. Lars Eriksen','lars.eriksen@kestrel.example','INST-002','771204'),
 ('AUT-1003','0000-0003-1415-9269','Dr. Ana Ribeiro','ana.ribeiro@harbourview.example','INST-003','305118'),
 ('AUT-1004','0000-0001-5109-3700','Dr. Elena Vasquez','elena.vasquez@lakeshore.example','INST-004','615204');

INSERT INTO manuscripts (manuscript_id,corresponding_author_id,journal_code,title,abstract,keywords,article_type,word_count,status,status_detail,decision_summary,declarations,submitted_on,last_updated,integrity_hold) VALUES
 ('MS-2026-0412','AUT-1001','JACI',
  'Machine-learning downscaling of compound coastal flood risk for small island states',
  'We present a gradient-boosted downscaling model that combines storm-surge hindcasts, tide-gauge records and rainfall reanalysis to estimate compound coastal flood risk at 250 m resolution for twelve small island states. Validated against surveyed flood extents, the model reduces error by 31% versus dynamical downscaling at a fraction of the compute cost. We release code and data.',
  'coastal flooding, compound flood risk, machine learning, downscaling, storm surge, small island states',
  'Research Article',7800,'REJECTED_TRANSFER_ELIGIBLE',
  'Decision sent. The editor offered a transfer to a better-suited journal.',
  'Sound work, but out of scope: the journal publishes data-pipeline methods, not regional hazard studies. Reviewers praised the validation. Transfer offered.',
  'Data availability: The code and data are openly available in the Zenodo repository (https://doi.org/10.5281/zenodo.7700412).' || chr(10) ||
  'Ethics: Not applicable; the study uses public hindcast, tide-gauge and reanalysis data only.' || chr(10) ||
  'Funding: This work was funded by the Coastal Resilience Research Fund (grant CRRF-2025-118).' || chr(10) ||
  'Competing interests: The authors declare no competing interests.',
  current_date - 64, now() - interval '3 days', FALSE),
 ('MS-2026-0388','AUT-1001','HCRL',
  'Rainfall intensity trends and culvert failure in mid-sized UK towns',
  'An analysis of 40 years of rainfall intensity records against culvert failure reports in 58 towns.',
  'rainfall, hydrology, infrastructure failure, climate adaptation',
  'Research Article',6900,'UNDER_REVIEW',
  'Under review. Reviewers assigned; 2 of 3 reports received.',NULL,
  'Data availability: Rainfall records are public; the culvert failure dataset is deposited in the Dryad repository (https://doi.org/10.5061/dryad.0388).' || chr(10) ||
  'Ethics: Not applicable.' || chr(10) ||
  'Funding: This research received no external funding.' || chr(10) ||
  'Competing interests: The authors declare no competing interests.' || chr(10) ||
  'Author contributions: Conceptualization and formal analysis by the first author; data curation by the second author; writing by both authors.',
  current_date - 41, now() - interval '6 days', FALSE),
 ('MS-2026-0301','AUT-1001','GEOS',
  'Sentinel-1 flood extent mapping with uncertainty bands',
  'A method for mapping flood extent from SAR imagery with calibrated uncertainty.',
  'remote sensing, flood mapping, uncertainty, satellite imagery',
  'Research Article',7100,'REVISION_REQUESTED',
  'Minor revision requested. Revised manuscript due in 21 days.',
  'Clarify the calibration dataset and add a comparison with optical imagery.',
  'Data availability: Sentinel-1 scenes are public; flood masks are on Zenodo (https://doi.org/10.5281/zenodo.7700301).' || chr(10) ||
  'Ethics: Not applicable.' || chr(10) ||
  'Funding: Supported by the European Space Research Programme (grant ESRP-2024-09).' || chr(10) ||
  'Competing interests: The authors declare no competing interests.' || chr(10) ||
  'Author contributions: Conceptualization, methodology and writing by the first author; software and validation by the second author.',
  current_date - 95, now() - interval '9 days', FALSE),
 ('MS-2026-0450','AUT-1002','CHRR',
  'Storm-surge barriers and fjord ecosystems: a 30-year view',
  'Long-term monitoring of fjord ecology before and after storm-surge barrier construction.',
  'storm surge, coastal ecology, fjords, infrastructure',
  'Research Article',8200,'ACCEPTED',
  'Accepted. Awaiting open-access licence and APC arrangement before production.',
  'Accepted after one round of revision.',
  'Data availability: Monitoring data and analysis code are in the PANGAEA repository (https://doi.org/10.1594/PANGAEA.0450).' || chr(10) ||
  'Ethics: Field sampling was approved by the regional environment agency (permit FJ-2019-221).' || chr(10) ||
  'Funding: Nordic Coastal Research Council (grant NCRC-2020-14).' || chr(10) ||
  'Competing interests: The authors declare no competing interests.' || chr(10) ||
  'Author contributions: Conceptualization and supervision by the first author; investigation by the second author; writing - original draft by both authors.',
  current_date - 120, now() - interval '2 days', FALSE),
 ('MS-2026-0433','AUT-1002','OCEN',
  'A unified wave-tide model for Arctic coastlines',
  'We couple spectral wave and tidal models for sea-ice-affected coasts, with an extended validation across 64 stations.',
  'waves, tides, arctic, coastal modelling, sea ice',
  'Research Article',11800,'REJECTED_TRANSFER_ELIGIBLE',
  'Decision sent. The editor offered a transfer.',
  'Strong modelling but beyond this letters journal''s length; suggested a transfer to a journal that takes long-form articles.',
  'Data availability: Model code and station data are on Zenodo (https://doi.org/10.5281/zenodo.7700433).' || chr(10) ||
  'Ethics: Not applicable.' || chr(10) ||
  'Funding: Arctic Science Foundation (grant ASF-2023-02).' || chr(10) ||
  'Competing interests: The authors declare no competing interests.' || chr(10) ||
  'Author contributions: Methodology and software by the first author; validation by the second author; writing by both authors.',
  current_date - 70, now() - interval '5 days', FALSE),
 ('MS-2026-0419','AUT-1003','SOCM',
  'Neighbourhood heat exposure and emergency admissions',
  'Links heat exposure maps to emergency admissions across three cities.',
  'public health, heat, epidemiology',
  'Research Article',7400,'REJECTED_TRANSFER_ELIGIBLE',
  'Decision sent. The editor offered a transfer.',
  'Out of scope; transfer offered.',
  'Data availability: De-identified admissions data are available through the regional health data service.' || chr(10) ||
  'Ethics: Approved by the institutional Research Ethics Board (REB-2025-044); consent waived for de-identified records.' || chr(10) ||
  'Funding: This research received no external funding.' || chr(10) ||
  'Competing interests: The authors declare no competing interests.',
  current_date - 50, now() - interval '4 days', TRUE),
 ('MS-2026-0466','AUT-1004','GEOS',
  'Satellite soil moisture as an early-warning signal for wildfire spread in the US Southwest',
  'We combine satellite soil-moisture retrievals, burned-area records and gridded weather data in a gradient-boosted model to forecast week-ahead wildfire spread across 412 fire events in Arizona and New Mexico. Soil-moisture deficit is the strongest single predictor and improves spread forecasts by 18% over weather-only baselines.',
  'wildfire, soil moisture, machine learning, environmental data, remote sensing, early warning',
  'Research Article',5600,'REJECTED_TRANSFER_ELIGIBLE',
  'Decision sent. The editor offered a transfer.',
  'The modelling, not the geospatial method, is the main contribution; the editor suggests a data-science journal. Transfer offered.',
  'Data availability: Data are available from the corresponding author on reasonable request.' || chr(10) ||
  'Ethics: Not applicable.' || chr(10) ||
  'Funding: Supported by the Southwest Fire Science Consortium (grant SFSC-2026-07).' || chr(10) ||
  'Author contributions: Conceptualization and methodology by the first author; data curation and software by the second author; writing by both authors.',
  current_date - 58, now() - interval '2 days', FALSE),
 ('MS-2026-0458','AUT-1004','EDSR',
  'Downscaled heat-index projections for thirty US cities',
  'Statistically downscaled heat-index projections for thirty US cities under two emissions scenarios, with open code.',
  'heat index, downscaling, climate projections, cities, environmental data',
  'Research Article',5200,'ACCEPTED',
  'Accepted. Awaiting the APC arrangement before production.',
  'Accepted after minor revision.',
  'Data availability: Projections and code are on Zenodo (https://doi.org/10.5281/zenodo.7700458).' || chr(10) ||
  'Ethics: Not applicable.' || chr(10) ||
  'Funding: This research received no external funding.' || chr(10) ||
  'Competing interests: The authors declare no competing interests.' || chr(10) ||
  'Author contributions: Conceptualization, software and writing - original draft by the first author; validation by the second author.',
  current_date - 110, now() - interval '1 day', FALSE);

-- Editor's decision letter + anonymous reviewer comments (no reviewer names are stored).
INSERT INTO review_comments (manuscript_id, comment_ref, source, comment_text) VALUES
 ('MS-2026-0301','E.1','EDITOR',
  'Both reviewers find the method promising. Please address every comment, in particular the calibration dataset (Reviewer 1) and the comparison with optical imagery (Reviewer 2). The revised manuscript is due in 21 days.'),
 ('MS-2026-0301','R1.1','REVIEWER_1',
  'The calibration dataset is described only briefly. Please state which flood events were used for calibration, how many SAR scenes, and how they were kept separate from the validation events; the reported accuracy depends on this.'),
 ('MS-2026-0301','R1.2','REVIEWER_1',
  'The uncertainty bands in Figure 4 are hard to read. Please use a colour-blind-safe palette and label the 5th and 95th percentiles.'),
 ('MS-2026-0301','R1.3','REVIEWER_1',
  'Table 2 gives only point values for the F1 scores. Please report confidence intervals as well.'),
 ('MS-2026-0301','R2.1','REVIEWER_2',
  'I am not convinced the method generalises. Please add a comparison with flood extents derived from optical imagery for at least one event where cloud-free scenes exist.'),
 ('MS-2026-0301','R2.2','REVIEWER_2',
  'The introduction misses recent work on Bayesian change detection for SAR flood mapping; please discuss it.'),
 ('MS-2026-0301','R2.3','REVIEWER_2',
  'Optional: a short note on the computing time per scene would help practitioners.');

-- Review guide (reference data for review_summary_agent). WHO_DECIDES comes from review_teams.
INSERT INTO review_guide (section, term, meaning) VALUES
 ('COMMENT_TYPE','METHODS','The study design, procedure, model, calibration or validation: how the work was done and whether it supports the conclusions.'),
 ('COMMENT_TYPE','STATISTICS','Statistical tests, uncertainty, confidence intervals, error measures, sample sizes or significance.'),
 ('COMMENT_TYPE','DATA','Which data were used, how they were selected or split, data quality, and data or code availability.'),
 ('COMMENT_TYPE','CLARITY','Wording, structure, figures, tables, labels and presentation, where the results themselves do not change.'),
 ('COMMENT_TYPE','LITERATURE','Missing, outdated or misrepresented references to previous work, and how the work is positioned against it.'),
 ('COMMENT_TYPE','ETHICS','Consent, approvals, competing interests, image or data integrity, and responsible reporting.'),
 ('PRIORITY','MAJOR','The editor names it as required, or the comment questions whether the conclusions hold, or it asks for new analysis, new data or a new comparison.'),
 ('PRIORITY','MINOR','A small, clearly bounded change: a clarification, a figure or table fix, a missing number, an added reference, or wording.'),
 ('PRIORITY','OPTIONAL','The commenter marks it as optional or as a suggestion (optional, consider, could, might, would help); the author may decline it with a short reason.'),
 ('CHECKLIST_RULE','ONE_ITEM_PER_COMMENT','Write exactly one checklist item for each comment reference you were given, in the given order, and cite the reference.'),
 ('CHECKLIST_RULE','NO_NEW_REQUESTS','Never add a request that is not in the comments, and never drop, merge or split a comment.'),
 ('CHECKLIST_RULE','EDITOR_FIRST','List the Editor''s items first, then each reviewer in number order.'),
 ('CHECKLIST_RULE','NEUTRAL','Do not judge whether a comment is right and do not predict the editor''s decision.'),
 ('RESPONSE_LETTER','POINT_BY_POINT','In your response letter, answer every item point by point in the same order, quote its reference, and say exactly where in the revised manuscript you made each change.');

INSERT INTO review_teams (request_type, label, team, sla_days, author_openable) VALUES
 ('APC_WAIVER','fee waiver request','Open Access Office',5,TRUE),
 ('DECISION_APPEAL','decision appeal','Editorial Office (handling editor)',10,TRUE),
 ('AUTHORSHIP_CHANGE','authorship change request','Editorial Office (authorship)',7,TRUE),
 ('INTEGRITY_QUERY','research integrity query','Research Integrity Team',10,TRUE),
 ('STATEMENTS_EXCEPTION','submission statements exception','Editorial Office (handling editor)',5,TRUE),
 ('OTHER','request','Author Services',3,TRUE);

-- Human in the loop: staff reviewers (team = review_teams.team). Grace's limit is just below Elena's seeded $1,850
-- waiver (and Lars's $2,900), so OVER_AUTHORITY is demoable.
INSERT INTO reviewers (reviewer_id, display_name, team, one_time_code, approval_limit) VALUES
 ('PUB-7001','Grace Whitfield','Open Access Office','246810',1500.00),
 ('PUB-7002','Samuel Osei','Open Access Office','135790',5000.00),
 ('PUB-7003','Helen Marsh','Editorial Office (handling editor)','864209',NULL),
 ('PUB-7004','Tom Becker','Editorial Office (authorship)','502468',NULL),
 ('PUB-7005','Rafael Duarte','Research Integrity Team','719350',NULL);

-- Already-OPEN cases so every reviewer queue has work (sla_due_at comes from trg_case_defaults; "recent" = relative to now()).
INSERT INTO review_cases (case_id, author_id, manuscript_id, request_type, author_statement, agent_brief, requested_amount,
                          parked_action, created_at) VALUES
 ('RC-S0A1F1','AUT-1004','MS-2026-0458','APC_WAIVER',
  'Our lab has no grant money left this year and Lakeshore State has no agreement with you. Could the APC be waived or reduced?',
  'Accepted article at EDSR (Gold OA, APC $1,850). The author''s institution has no open-access agreement, so the author pays the full APC. The author reports no remaining grant funds and asks for a waiver or reduction. No recommendation.',
  1850.00, 'APC_WAIVER:MS-2026-0458', now() - interval '2 days'),
 ('RC-S0B2E2','AUT-1002','MS-2026-0433','DECISION_APPEAL',
  'The decision says the article is too long, but the extended validation across 64 stations is the main contribution. We would like the editor to reconsider.',
  'Article declined with a transfer offer because it exceeds the journal''s length. The author asks the handling editor to reconsider, arguing the extended validation is essential. No recommendation.',
  NULL, NULL, now() - interval '3 days'),
 ('RC-S0C3D3','AUT-1004','MS-2026-0458','AUTHORSHIP_CHANGE',
  'A colleague who built the validation dataset should be added as a third author before production.',
  'Accepted article. The author asks to add a third author who prepared the validation dataset. All current authors'' agreement is not yet confirmed. No recommendation.',
  NULL, NULL, now() - interval '1 day'),
 ('RC-S0D4C4','AUT-1003','MS-2026-0419','INTEGRITY_QUERY',
  'A reader pointed out that two panel labels in Figure 3 are swapped. We want to report it and correct it.',
  'The author reports swapped panel labels in Figure 3 and wants to correct them. No recommendation.',
  NULL, NULL, now() - interval '4 days');
