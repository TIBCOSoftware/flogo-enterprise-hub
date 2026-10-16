#!/usr/bin/env python3
"""
Generate the fictional Copperleaf Auto Insurance policy-wording PDFs used as the RAG corpus.

These are specimen documents for a TIBCO Flogo Agentic AI demo (US personal auto). They deliberately
contain the exact clauses the demo prompts ask about (Full Glass deductible and the claims-free
discount, the flood-water ingestion exclusion, driving other cars, the policy territory, Claims-Free
Discount Protection, rental reimbursement, new car replacement) so the RAG pipeline
(OpenAI vector store -> vectorSearch) demonstrably retrieves them.

Usage:
    pip install fpdf2
    python generate_policy_pdfs.py

Output: ./policy_docs/*.pdf (paths are relative to this script; output is deterministic).
"""

import datetime
import os

from fpdf import FPDF

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "policy_docs")

INSURER = "Copperleaf Auto Insurance"
FIXED_DATE = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)   # deterministic PDF metadata
DISCLAIMER = (
    "This is a fictional specimen policy wording created solely for a software demonstration. "
    "Copperleaf Auto Insurance is not a real company. This document is not an insurance contract "
    "and provides no coverage."
)

TERRITORY = (
    "This policy applies only to accidents and losses that happen during the policy period within the "
    "policy territory. The policy territory is the United States of America, its territories and "
    "possessions, Puerto Rico and Canada. This policy also applies to loss to, or accidents involving, "
    "your covered auto while it is being transported between their ports. There is no coverage for "
    "accidents or losses that happen outside the policy territory, for example in Mexico."
)


class PolicyPDF(FPDF):
    def __init__(self, doc_title, doc_ref):
        super().__init__(orientation="P", unit="mm", format="Letter")
        self.doc_title = doc_title
        self.doc_ref = doc_ref
        self.set_auto_page_break(auto=True, margin=18)
        self.set_margins(20, 20, 20)
        self.set_creation_date(FIXED_DATE)
        self.set_title(doc_title)
        self.set_author(INSURER)
        self.set_subject("Specimen policy wording (fictional)")
        self.set_creator("generate_policy_pdfs.py")
        self.set_producer("fpdf2")

    def header(self):
        self.set_font("Helvetica", "B", 9)
        self.set_text_color(90, 90, 90)
        half = self.epw / 2
        self.cell(half, 6, INSURER, align="L")
        self.cell(half, 6, self.doc_ref, align="R", new_x="LMARGIN", new_y="NEXT")
        self.set_draw_color(200, 200, 200)
        self.line(20, 27, self.w - 20, 27)
        self.ln(6)
        self.set_text_color(0, 0, 0)

    def footer(self):
        self.set_y(-15)
        self.set_font("Helvetica", "I", 8)
        self.set_text_color(120, 120, 120)
        self.cell(0, 6, f"{self.doc_title}  |  Specimen wording  |  Page {self.page_no()}", align="C")
        self.set_text_color(0, 0, 0)

    def title_block(self, subtitle):
        self.set_font("Helvetica", "B", 18)
        self.multi_cell(0, 9, self.doc_title, new_x="LMARGIN", new_y="NEXT")
        self.ln(1)
        self.set_font("Helvetica", "I", 11)
        self.set_text_color(80, 80, 80)
        self.multi_cell(0, 6, subtitle, new_x="LMARGIN", new_y="NEXT")
        self.set_text_color(0, 0, 0)
        self.ln(3)
        self.set_font("Helvetica", "I", 8)
        self.set_text_color(130, 130, 130)
        self.multi_cell(0, 4.5, DISCLAIMER, new_x="LMARGIN", new_y="NEXT")
        self.set_text_color(0, 0, 0)
        self.ln(4)

    def section(self, heading):
        if self.get_y() > 235:
            self.add_page()
        self.ln(2)
        self.set_font("Helvetica", "B", 13)
        self.set_text_color(20, 90, 60)
        self.multi_cell(0, 7, heading, new_x="LMARGIN", new_y="NEXT")
        self.set_text_color(0, 0, 0)
        self.ln(1)

    def subheading(self, text):
        self.set_font("Helvetica", "B", 11)
        self.multi_cell(0, 6, text, new_x="LMARGIN", new_y="NEXT")

    def body(self, text):
        self.set_font("Helvetica", "", 10.5)
        self.multi_cell(0, 5.6, text, new_x="LMARGIN", new_y="NEXT")
        self.ln(1.5)

    def bullets(self, items):
        self.set_font("Helvetica", "", 10.5)
        for it in items:
            self.multi_cell(0, 5.6, f"  -  {it}", new_x="LMARGIN", new_y="NEXT")
        self.ln(1.5)


def build(doc_title, doc_ref, subtitle, blocks, filename):
    pdf = PolicyPDF(doc_title, doc_ref)
    pdf.add_page()
    pdf.title_block(subtitle)
    for kind, content in blocks:
        {"section": pdf.section, "sub": pdf.subheading, "body": pdf.body, "bullets": pdf.bullets}[kind](content)
    path = os.path.join(OUT_DIR, filename)
    pdf.output(path)
    print(f"  wrote {path}")


# =====================================================================
# 1. Full Coverage Auto Policy Wording
# =====================================================================
full_coverage = [
    ("section", "1. About This Policy"),
    ("body", "This is your Copperleaf Personal Auto Policy. Full Coverage means the declarations page shows "
             "Bodily Injury Liability, Property Damage Liability, Medical Payments, Uninsured Motorist, Collision "
             "and Comprehensive (other than collision) coverage. Optional coverages such as Full Glass, Roadside "
             "Assistance, Rental Reimbursement and New Car Replacement apply only when they are shown on your "
             "declarations page. The policy term is 12 months."),
    ("section", "2. Definitions"),
    ("bullets", [
        "\"You\" and \"your\" mean the named insured shown on the declarations page and a spouse or domestic "
        "partner who lives in the same household. \"We\", \"us\" and \"our\" mean Copperleaf Auto Insurance.",
        "\"Covered auto\" means the vehicle shown on the declarations page (identified by its vehicle "
        "identification number and license plate), a newly acquired auto reported to us within 30 days, and a "
        "temporary substitute auto used while your covered auto is out of service for repair.",
        "\"Actual cash value\" means the market value of the vehicle immediately before the loss, taking into "
        "account its age, mileage, condition and depreciation.",
        "\"Deductible\" means the amount you pay toward each covered physical damage loss. The deductible for "
        "each coverage is shown on your declarations page. We pay the covered amount above the deductible.",
        "\"Collision\" means the upset or rollover of your covered auto, or its impact with another vehicle or "
        "object, including a pothole, curb, guardrail or tree.",
        "\"Comprehensive\" (also called other than collision) means direct and accidental loss to your covered "
        "auto that is not caused by collision.",
        "\"Non-owned auto\" means a private passenger auto, pickup or van that is not owned by, furnished to or "
        "available for the regular use of you or a family member.",
    ]),
    ("section", "3. Part A - Liability Coverage (Bodily Injury and Property Damage)"),
    ("body", "We will pay damages for bodily injury or property damage for which you become legally responsible "
             "because of an auto accident, up to the Bodily Injury and Property Damage limits on your declarations "
             "page. We will settle or defend, as we consider appropriate, any claim or suit asking for these "
             "damages, and we pay defense costs in addition to the limits of liability."),
    ("sub", "Driving other cars"),
    ("body", "Liability coverage extends to you while you drive a non-owned auto, such as a friend's car or a "
             "relative's car, with the owner's permission. Your Liability coverage pays for injury to other people "
             "and damage to their property. Damage to the non-owned auto itself is NOT covered by your Collision or "
             "Comprehensive coverage; the owner's own auto policy is expected to respond first for damage to their "
             "car. A rental car you rent for 30 days or less is treated as a temporary substitute auto."),
    ("section", "4. Part B - Medical Payments Coverage"),
    ("body", "We will pay reasonable expenses for necessary medical and funeral services because of bodily injury "
             "caused by an accident and sustained by you, a family member or any other person while occupying your "
             "covered auto, up to the Medical Payments limit per person shown on the declarations page, regardless "
             "of who is at fault."),
    ("section", "5. Part C - Uninsured Motorist Coverage"),
    ("body", "We will pay damages that you are legally entitled to recover from the owner or driver of an uninsured "
             "motor vehicle because of bodily injury caused by an accident. An uninsured motor vehicle includes a "
             "hit-and-run vehicle whose owner or driver cannot be identified. A hit-and-run accident must be "
             "reported to the police within 24 hours."),
    ("section", "6. Part D - Coverage for Damage to Your Auto"),
    ("sub", "Collision"),
    ("body", "We will pay for direct and accidental loss to your covered auto caused by collision, minus the "
             "Collision deductible shown on the declarations page. This includes single-vehicle accidents and "
             "rollovers. Our limit of liability is the lesser of the actual cash value of the damaged property or "
             "the amount necessary to repair or replace it with parts of like kind and quality."),
    ("sub", "Comprehensive (other than collision)"),
    ("body", "We will pay for direct and accidental loss to your covered auto not caused by collision, minus the "
             "Comprehensive deductible shown on the declarations page. Comprehensive losses include:"),
    ("bullets", [
        "Fire, lightning and explosion.",
        "Theft or larceny of the covered auto or its parts, and damage caused by an attempted theft.",
        "Vandalism or malicious mischief.",
        "Hail, windstorm and wind-blown debris.",
        "Flood damage, rising water or a storm surge reaching your covered auto while it is parked or "
        "stationary (flood damage to a parked car is covered).",
        "Falling objects, such as a tree limb, rocks or debris.",
        "Contact with a bird or an animal, such as hitting a deer.",
        "Glass breakage, including a chipped or cracked windshield or a broken window.",
    ]),
    ("sub", "Glass coverage and the Full Glass deductible"),
    ("body", "If Full Glass coverage is shown on your declarations page, repair or replacement of the windshield, "
             "side windows, rear window or glass sunroof is subject to the Full Glass deductible shown there "
             "(typically $100) instead of your Comprehensive deductible, for a chip repair as well as a "
             "replacement. Without Full Glass coverage, glass breakage is paid "
             "under Comprehensive, subject to the Comprehensive deductible. Glass-only claims do not count against "
             "your claims-free discount."),
    ("sub", "Transportation expenses"),
    ("body", "If your covered auto is stolen, we will pay up to $25 a day, to a maximum of $750, for transportation "
             "expenses beginning 48 hours after the theft is reported to us and to the police. Rental Reimbursement "
             "coverage, if shown on the declarations page, replaces this amount with higher limits."),
    ("section", "7. Exclusions - What Is Not Covered"),
    ("sub", "Water ingestion when driving into flood water"),
    ("body", "We do not pay for damage to the engine, transmission or electrical system caused by water ingestion "
             "when the covered auto is knowingly driven into standing or moving flood water, including a flooded "
             "road, ford or underpass. This exclusion applies even when the flooded road or underpass was open to "
             "traffic. Flood damage to a parked or stationary car is still covered under Comprehensive; this "
             "exclusion applies only when the car is driven into the water."),
    ("sub", "Other exclusions"),
    ("bullets", [
        "Wear and tear, freezing, rust, corrosion and gradual deterioration.",
        "Mechanical or electrical breakdown or failure that is not caused by a covered collision or "
        "comprehensive loss.",
        "Damage to tires alone, unless caused by fire, theft or vandalism or occurring at the same time as "
        "another covered loss.",
        "Racing, speed contests, track days or any organized timed driving event.",
        "Using the covered auto to carry people or property for a fee, including rideshare or delivery use "
        "through a transportation network app, unless the Rideshare endorsement is shown on the declarations "
        "page.",
        "Intentional damage caused by you or at your direction.",
        "Loss to a non-owned auto you are driving (see Driving other cars in Part A).",
        "Personal belongings left in the vehicle or the trunk, and custom equipment not listed on the "
        "declarations page.",
    ]),
    ("section", "8. Policy Territory"),
    ("body", TERRITORY + " A road trip to Canada is within the policy territory, and your coverages apply there "
                         "exactly as they do in the United States."),
    ("section", "9. Claims-Free Discount and Claims-Free Discount Protection"),
    ("body", "You earn a claims-free discount on your premium after 3 consecutive years without an at-fault or "
             "paid physical damage claim. The discount grows with each additional claims-free year, as shown on "
             "your declarations page. Glass-only claims do not count against your claims-free discount."),
    ("body", "Claims-Free Discount Protection: if Claims-Free Discount Protection is shown on your declarations page, "
             "up to 2 claims in any 36-month period do not remove your claims-free discount. A third claim within "
             "36 months may remove the discount at renewal. Your premium may still change at renewal for other "
             "reasons, such as rate changes, a new driver, a new address or a different vehicle."),
    ("section", "10. Duties After an Accident or Loss"),
    ("bullets", [
        "Report the accident or loss to us promptly, as soon as practicable. Late reports can delay a claim.",
        "Report a theft or a hit-and-run to the police within 24 hours and give us the police report number.",
        "Cooperate with us in the handling of the claim, including a claims specialist review if requested, and "
        "send us copies of any notices or legal papers you receive.",
        "Take reasonable steps to protect your covered auto from further damage. We will pay reasonable expenses "
        "you incur to do so, such as towing to a safe place.",
        "Allow us to inspect and appraise the damaged vehicle before it is repaired or disposed of.",
        "Provide photos of the damage, the date, time and location of the loss, and the names and insurers of "
        "any other parties involved.",
    ]),
    ("section", "11. Appraisal"),
    ("body", "If you and we do not agree on the amount of a physical damage loss, either may demand an appraisal. "
             "Each party selects a competent and impartial appraiser; the two appraisers select an umpire. A "
             "decision agreed to by any two of them is binding. Each party pays its own appraiser and shares the "
             "umpire's expenses equally."),
    ("section", "12. Other Insurance"),
    ("body", "If there is other applicable insurance, we pay only our share of the loss. Our share is the "
             "proportion that our limit of liability bears to the total of all applicable limits. For a non-owned "
             "auto or a temporary substitute auto, our insurance applies only after any other collectible "
             "insurance has paid."),
]


# =====================================================================
# 2. Liability + Comprehensive and Liability Only Policy Wording
# =====================================================================
liability_comprehensive = [
    ("section", "1. About These Coverage Tiers"),
    ("body", "This wording applies to Copperleaf Personal Auto Policies issued at the Liability + Comprehensive tier "
             "or the Liability Only tier. Your declarations page shows which tier you have. Definitions, Liability "
             "(Part A), Uninsured Motorist (Part C), the policy territory, duties after an accident or loss, "
             "appraisal and other insurance follow the Copperleaf Personal Auto Policy (Full Coverage) wording."),
    ("section", "2. Liability + Comprehensive"),
    ("body", "The Liability + Comprehensive tier includes Bodily Injury Liability, Property Damage Liability, "
             "Uninsured Motorist and Comprehensive (other than collision) coverage."),
    ("sub", "What is covered for your own car"),
    ("body", "Comprehensive covers direct and accidental loss to your covered auto not caused by collision, minus "
             "the Comprehensive deductible: fire, theft, vandalism, hail, wind, flood damage to a parked car, falling "
             "objects, contact with an animal such as a deer, and glass breakage."),
    ("sub", "No Collision coverage"),
    ("body", "The Liability + Comprehensive tier has no Collision coverage. Damage from colliding with another "
             "vehicle or object, or from a rollover, is not covered - you can ask about adding Collision. Your "
             "Liability coverage still pays for injury to other people and damage to their property when you are "
             "legally responsible for an accident."),
    ("section", "3. Liability Only"),
    ("body", "The Liability Only tier includes Bodily Injury Liability, Property Damage Liability and Uninsured "
             "Motorist coverage. Liability Only gives no physical damage coverage for your own car: there is no "
             "Collision coverage and no Comprehensive coverage. Damage to your own car from a collision, theft, "
             "vandalism, weather, an animal or glass breakage is not covered."),
    ("body", "Liability Only meets state minimum financial responsibility requirements when the limits shown on the "
             "declarations page are at least the state minimums. You can ask about adding Comprehensive or "
             "upgrading to Full Coverage at any time; changes take effect from the date we confirm them."),
    ("section", "4. Exclusions"),
    ("bullets", [
        "Any physical damage to your own car that is not covered by a coverage shown on your declarations page.",
        "We do not pay for damage to the engine, transmission or electrical system caused by water ingestion "
        "when the covered auto is knowingly driven into standing or moving flood water, including a flooded "
        "road, ford or underpass.",
        "Wear and tear, mechanical breakdown, racing, and intentional damage.",
        "Rideshare or delivery use without the Rideshare endorsement.",
    ]),
    ("section", "5. Policy Territory"),
    ("body", TERRITORY),
    ("section", "6. Upgrading Your Coverage"),
    ("body", "To add Collision or Comprehensive coverage, or to move to Full Coverage, contact us for a quote. A "
             "person on our Customer Care team reviews coverage changes. New coverage never applies to an accident "
             "or loss that happened before the change took effect."),
]


# =====================================================================
# 3. Auto Endorsements and Add-Ons
# =====================================================================
addons = [
    ("section", "1. How Endorsements Work"),
    ("body", "An endorsement adds to or changes your Copperleaf Personal Auto Policy. An endorsement applies only "
             "when it is shown on your declarations page. All other terms of the policy continue to apply."),
    ("section", "2. Full Glass"),
    ("body", "Full Glass replaces your Comprehensive deductible for glass losses with the Full Glass deductible shown "
             "on your declarations page (typically $100). It covers repair or replacement of the windshield, side "
             "windows, rear window and glass sunroof, including chip repairs. We arrange "
             "glass repair within 2 business days of the claim. Glass-only claims do not count against your "
             "claims-free discount."),
    ("section", "3. Roadside Assistance"),
    ("body", "We pay for roadside service when your covered auto is disabled: towing to the nearest qualified "
             "repair shop (up to 15 miles), jump-starts, flat tire changes using your spare, lockout service and "
             "delivery of fuel, oil or water (you pay for the fuel itself). Up to 4 service calls per policy term. "
             "Using Roadside Assistance is not a claim and does not affect your claims-free discount."),
    ("section", "4. Rental Reimbursement"),
    ("body", "If your covered auto cannot be driven because of a covered Collision or Comprehensive loss, we pay for "
             "a rental car of similar size, up to $40 a day and up to $1,200 per claim. Coverage begins when the car "
             "is taken to a repair shop (or, for theft, 24 hours after the theft is reported) and ends when the "
             "repairs are complete, when we offer a settlement for a total loss, or when the $1,200 limit is "
             "reached, whichever comes first."),
    ("section", "5. New Car Replacement"),
    ("body", "If your covered auto is a total loss within the first 2 model years and has fewer than 24,000 miles, "
             "we will pay for a new car of the same make and model, with similar equipment, minus your deductible, "
             "instead of its actual cash value. If the same make and model is no longer available, we pay for the "
             "closest comparable new model. After 2 model years or 24,000 miles, a total loss is settled at actual "
             "cash value."),
    ("section", "6. Claims-Free Discount Protection"),
    ("body", "With Claims-Free Discount Protection, up to 2 claims in any 36-month period do not remove your "
             "claims-free discount. A third claim within 36 months may remove the discount at renewal. Glass-only "
             "claims never count against the discount, with or without this protection. Your premium may still "
             "change for other reasons, such as rate changes, a new driver, a new address or a different vehicle."),
    ("section", "7. Rideshare"),
    ("body", "The Rideshare endorsement extends your coverages to the time you are logged in to a transportation "
             "network app and waiting for a ride request, until a request is accepted. Once a request is accepted, "
             "the transportation network company's insurance applies first. Without this endorsement, there is no "
             "coverage while the covered auto is being used for rideshare or delivery for a fee."),
]


# =====================================================================
# 4. Claims Procedure Guide
# =====================================================================
claims_guide = [
    ("section", "1. How to Report a Claim"),
    ("body", "You can report a claim 24 hours a day through any of these channels:"),
    ("bullets", [
        "Riley, our chat assistant, on the Copperleaf website or in the Copperleaf app.",
        "By phone with a Copperleaf claims representative.",
        "In the Copperleaf mobile app (upload photos directly).",
    ]),
    ("body", "Report as soon as practicable after the accident or loss. Late reports can delay a claim and may make "
             "it harder to confirm what happened."),
    ("section", "2. First Notice of Loss - What We Ask For"),
    ("bullets", [
        "Date and time of the accident or loss.",
        "Location (street, city and state).",
        "Other parties involved - names, phone numbers, license plates and their insurers.",
        "Injuries to anyone involved.",
        "Police report number, if the police attended or a report was filed.",
        "Photos of the damage and the scene.",
        "Damage areas (for example front bumper, windshield, driver-side door, trunk).",
        "Whether the car is drivable.",
        "Your preferred repair shop, if you have one.",
        "A repair estimate, if you already have one.",
    ]),
    ("section", "3. What Happens Next"),
    ("sub", "Glass claims"),
    ("body", "For a chipped or cracked windshield or a broken window, glass repair or replacement is arranged within "
             "2 business days. Glass-only claims do not count against your claims-free discount."),
    ("sub", "Standard claims"),
    ("body", "For other claims, an adjuster contacts you within 2 business days to review the damage, arrange an "
             "inspection and explain your coverage and deductible."),
    ("sub", "Claims specialist review"),
    ("body", "Some claims are reviewed by a claims specialist before payment, for example larger claims or claims "
             "where the policy wording needs a closer look. If we ask you for information during a claims specialist "
             "review, please reply within 10 business days. You will receive a reference number and can check the "
             "status at any time."),
    ("sub", "Theft"),
    ("body", "A police report is required for every theft claim. If the car is not recovered, there is a 30-day "
             "waiting period before a total-loss settlement. If the car is recovered within the 30 days, we pay for "
             "covered damage caused by the theft."),
    ("section", "4. Settlement and Payment"),
    ("bullets", [
        "Your deductible is applied at settlement: we pay the covered amount above the deductible, up to the "
        "applicable limit.",
        "You may choose any licensed repair shop. We may inspect the damage and the repair estimate before work "
        "begins.",
        "Payment is made within 5 business days after the claim is approved.",
        "If your car is a total loss, we pay its actual cash value (or a new car under New Car Replacement, if "
        "shown on your declarations page), minus the deductible.",
    ]),
    ("section", "5. Claim Status Meanings"),
    ("bullets", [
        "Submitted - we have your claim and an adjuster will contact you.",
        "Under Review - an adjuster or claims specialist is reviewing the claim before payment.",
        "Approved - the claim is approved and payment is being issued.",
        "Denied - the claim is not covered; we explain the reason in writing.",
        "Settled - payment has been made and the claim is closed.",
    ]),
    ("section", "6. If You Disagree With a Settlement"),
    ("body", "If you disagree with a settlement amount or a decision about fault, ask us to review it. A person on "
             "our claims team reviews every dispute; it is never decided automatically. You may also use the "
             "Appraisal condition in your policy for disputes about the amount of a physical damage loss."),
]


DOCS = [
    ("Copperleaf Personal Auto Policy - Full Coverage", "Ref: CAI-PAP-FC-2026",
     "Liability, Medical Payments, Uninsured Motorist, Collision and Comprehensive coverage for your covered auto.",
     full_coverage, "Full_Coverage_Auto_Policy_Wording.pdf"),
    ("Liability + Comprehensive and Liability Only Wording", "Ref: CAI-PAP-LC-2026",
     "Liability coverage for others, with or without Comprehensive coverage for your own car. No Collision coverage.",
     liability_comprehensive, "Liability_Comprehensive_Policy_Wording.pdf"),
    ("Auto Endorsements and Add-Ons", "Ref: CAI-END-2026",
     "Optional coverages: Full Glass, Roadside Assistance, Rental Reimbursement, New Car Replacement, "
     "Claims-Free Discount Protection and Rideshare.",
     addons, "Auto_Endorsements_and_AddOns.pdf"),
    ("Claims Procedure Guide", "Ref: CAI-CLM-2026",
     "How to report a claim, what we ask for, what happens next, settlement, payment and disputes.",
     claims_guide, "Claims_Procedure_Guide.pdf"),
]


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print("Generating policy PDFs into", OUT_DIR)
    for title, ref, subtitle, blocks, filename in DOCS:
        build(title, ref, subtitle, blocks, filename)
    print(f"Done. {len(DOCS)} PDFs generated.")


if __name__ == "__main__":
    main()
