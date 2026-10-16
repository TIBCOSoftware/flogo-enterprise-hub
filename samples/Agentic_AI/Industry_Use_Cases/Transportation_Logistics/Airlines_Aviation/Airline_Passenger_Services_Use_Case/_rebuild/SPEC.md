# Meridian Passenger Services (governed) — use-case spec

Fictional US airline **Meridian** (ATL hub), locale USA / USD. Database `airline_governed`. Runtime model `gpt-5.5`.
Ports: WebSocket `9850` `/passengerservices`, MCP `9852` `/passenger-services-gov-mcp`, A2A `9853`–`9855`.

## Personas and identity

| Persona | Proof | Session |
|---|---|---|
| Traveler | 6-character PNR + 4-digit PIN (`verify_traveller`); 5 wrong PINs lock the PNR for 15 min | `traveler_sessions` role `TRAVELER`, 60 min |
| Staff reviewer | staff ID `MER-70nn` + staff code (`verify_reviewer`); 5 wrong codes lock it for 15 min | same table, role `REVIEWER` + team; every function checks the role |

## Decision-framework classification

| Operation | Owner | Where |
|---|---|---|
| Itinerary, flight status, loyalty, own cases | deterministic, scoped read | `my_itinerary`, `flight_status_for_session`, `my_loyalty`, `my_cases` |
| Connection risk SAFE / AT_RISK / MISSED | deterministic arithmetic | `connection_risk` |
| Rank replacement flights against free-text preferences | **agent** `rebooking_options_agent` | reads `search_alternatives` (route + time + cabin) |
| Rebook a leg | deterministic, two-step | `rebook_eval` → `pending_actions` → `rebookings` + trigger |
| Bag description → claim type, bag-type / colour codes, contents, missing report fields | **agent** `baggage_claim_agent` | reads `ref_baggage_guide`; SQL validates in `baggage_assessment` |
| Record the claim, open the Baggage Services case | deterministic, guarded write | `baggage_claim_row` → `baggage_claims` + `trg_baggage_case` |
| Free-text needs → IATA SSR codes | **agent** `special_assistance_agent` | reads `ref_assistance_codes`; SQL validates in `assistance_assessment` |
| Add the SSRs to the traveler's own segment as PENDING_CONFIRMATION, open the Accessibility Desk case | deterministic, guarded write | `assistance_row` → `assistance_requests` + `trg_assistance_case` |
| Compensation, interim baggage expenses, confirming assistance, complaints, name changes | **human** (reviewer of the routed team) | `service_cases` → `review_decisions` + `trg_review_decision` |
| Email a confirmation | deterministic, guarded | `email_log_row` / `email_confirmation_payload` (executed rebooking or decided case only) |

## Rules and reason codes (each has a test in `test_rules.py`)

- Rebooking: `SESSION_INVALID`, `NOT_FOUND`, `ALREADY_REBOOKED`, `FLIGHT_UNKNOWN`, `SAME_FLIGHT`, `WRONG_ROUTE`,
  `TARGET_CANCELLED`, `NO_SEATS`, `DEPARTS_TOO_EARLY`, `ACTION_NOT_FOUND`, `EXPIRED`.
- Baggage claim: `NOT_FOUND` (flight not on the booking), `NOT_ARRIVED`, `DESCRIPTION_MISSING`, `CLAIM_TYPE_UNKNOWN`,
  `ALREADY_RECORDED`; rule notes `LOST_TOO_EARLY` (a bag is LOST only 5+ days after arrival, else DELAYED),
  `BAG_TAG` (no tag number in the description), `INTERIM_CAPPED` (interim expenses capped per claim type:
  DELAYED $300, LOST $500, DAMAGED $250, PILFERED $250). Codes the guide does not hold are recorded in
  `ignored_items` and never used.
- Assistance: `NOT_FOUND`, `NOT_UPCOMING`, `NEEDS_MISSING`, `NO_VALID_CODES`, `ALREADY_REQUESTED`; one wheelchair code
  per flight (the highest level wins: WCHC > WCHS > WCHR), desk-only codes (STCR) dropped, a medical code (OXYG) adds
  MEDA, which needs medical clearance by a person.
- Compensation parking: the most disrupted leg's band — `CANCELLED` $300, `DELAY_180` $250, `DELAY_60` $100;
  nothing parked after a compensation payment on the booking.
- Reviewer decision: `NOT_REVIEWER`, `NOT_YOUR_TEAM`, `NOT_FOUND`, `ALREADY_DECIDED`, `INVALID_DECISION`,
  `NOTE_REQUIRED`, `AMOUNT_INVALID`, `OVER_AUTHORITY` (case stays OPEN for a senior reviewer).
- Email: `SESSION_INVALID`, `ACTION_NOT_FOUND`, `NOT_EXECUTED`, `CASE_NOT_FOUND`, `NOT_DECIDED`.

## Human-owned routing (`service_teams`) and parked actions

| Request type | Team | SLA (business days) | Parked action on approval |
|---|---|---|---|
| COMPENSATION_CLAIM | Customer Care (compensation) | 7 | `COMPENSATION:<flight>` → `service_payments` (travel credit) |
| BAGGAGE_CLAIM | Baggage Services | 5 | `INTERIM_EXPENSE:<claim>` → `service_payments` (when interim expenses were asked for) |
| SPECIAL_ASSISTANCE | Accessibility Desk | 2 | `CONFIRM_SSR:<request>` → `ssr_confirmations` → segment SSRs CONFIRMED |
| COMPLAINT / OTHER | Customer Relations | 10 / 5 | none (the team completes it) |
| NAME_CHANGE | Ticketing | 3 | none |

Reviewers: `MER-7001` Dana Brooks (Baggage Services, $250 — the OVER_AUTHORITY demo), `MER-7002` Victor Hale (Baggage
Services, $2,000), `MER-7003` Marcus Lee (Accessibility Desk), `MER-7004` Elena Ruiz (Customer Care, $500), `MER-7005`
Nadia Karim (Customer Relations, $500), `MER-7006` Owen Price (Ticketing). Seeds keep 1–2 OPEN cases per team.

## Agents (A2A, read-only, no identity)

| Agent | Port | Input (minimised by the orchestrator) | Reference tool | Table-only text it must use |
|---|---|---|---|---|
| `rebooking_options_agent` (kept) | 9853 | route, earliest departure, cabin, preferences | `search_alternatives` over `flights` | the flights, times, seats |
| `baggage_claim_agent` | 9854 | the bag description in the traveler's words | `ref_baggage_guide` (34 rows: CLAIM_TYPE and REPORT_FIELD from the rule tables, BAG_TYPE, COLOUR, CONTENT, CLAIM_NOTE) | the bag-type chart codes, colour codes, the claim note |
| `special_assistance_agent` | 9855 | the needs in the traveler's words | `ref_assistance_codes` (18 rows: SSR_CODE from `ssr_codes`, HOW_TO_CHOOSE, STANDARD_LINE) | each code's plain-words meaning, the standard line |

## Demo logins

Travelers: Carlos `ABCDE1`/`4821`, Maria `PQRST4`/`7310`, Roberto `KLMNO3`/`9205`, Daniel `NPQRS5`/`6677`,
Sofia `MNOPQ0`/`5533`, Ana `FGHIJ2`/`1188`, Linda `WXYZA7`/`3046` (delayed bag), Kevin `TUVWX9`/`8152` (seeded lost bag +
WCHR), Rosa `HJKLM8`/`2468` (special assistance). Staff codes in the table above (`246810`, `135790`, `864209`,
`502468`, `719350`, `357911`).

## Adversarial acceptance

- A traveler claiming to be a gate agent or a baggage supervisor gets no rebooking and no decision (chat e2e).
- A traveler token cannot decide a case; a reviewer token cannot act as a traveler; another team's case is invisible.
- The agents never receive a name, PNR, email, phone or any id (chat e2e minimisation check on the Agents log).
