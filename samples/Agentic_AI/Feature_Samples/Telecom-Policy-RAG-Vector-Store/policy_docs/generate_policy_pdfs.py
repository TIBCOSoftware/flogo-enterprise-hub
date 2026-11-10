#!/usr/bin/env python3
"""
Generate the five dummy TeleCore policy PDFs that the RAG pipeline ingests.

    pip install fpdf2
    python generate_policy_pdfs.py

The figures the demo questions rely on (scripts/smoke_test.py and the README
chat script) are listed below. If you change one, update those too:

    TC-POL-001  zone rates 9/21/45/75 per GB, plan allowances, $200 cycle cap
    TC-POL-002  fair-use thresholds 200/120/80/50/20 GB and throttle speeds
    TC-POL-003  risk bands, TIER1/TIER2, 24h cooling-off, status lifecycle
    TC-POL-004  80%-elapsed upgrade bar, ETF formula, subsidy amounts
    TC-POL-005  4-hour qualifying outage, credit formula, 30-day claim window

Only core fonts are used, so the text layer extracts cleanly -- the Flogo
chunker reads these back out through its PDF path. That also means the content
must stay in latin-1; _ascii() below fails the build rather than let a stray
smart quote through.
"""

from pathlib import Path

from fpdf import FPDF
from fpdf.enums import XPos, YPos
from fpdf.fonts import FontFace

OUT_DIR = Path(__file__).resolve().parent
ISSUER = "TeleCore Communications"
EFFECTIVE = "1 September 2026"

GREY = (232, 232, 232)
RULE = (140, 140, 140)


def _ascii(s):
    """Core fonts are latin-1. Catch non-ASCII at build time, not in the PDF."""
    bad = sorted({c for c in s if ord(c) > 127})
    if bad:
        raise ValueError("non-ASCII character(s) %r in: %.80s" % (bad, s))
    return s


class PolicyPDF(FPDF):
    def __init__(self, doc_id, title, version):
        super().__init__(orientation="P", unit="mm", format="A4")
        self.doc_id = doc_id
        self.doc_title = title
        self.version = version
        self.set_auto_page_break(auto=True, margin=20)
        self.set_margins(20, 18, 20)
        self.set_title("%s %s" % (doc_id, title))
        self.set_author(ISSUER)
        self.set_subject("Customer policy document")

    def header(self):
        self.set_font("Helvetica", "B", 8)
        self.set_text_color(90, 90, 90)
        self.cell(0, 4, _ascii(ISSUER.upper()), new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.set_font("Helvetica", "", 8)
        self.cell(0, 4, _ascii("%s  |  %s  |  Version %s  |  Effective %s"
                               % (self.doc_id, self.doc_title, self.version, EFFECTIVE)),
                  new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.set_draw_color(*RULE)
        self.line(20, self.get_y() + 1, 190, self.get_y() + 1)
        self.ln(5)
        self.set_text_color(0, 0, 0)

    def footer(self):
        self.set_y(-15)
        self.set_font("Helvetica", "", 8)
        self.set_text_color(90, 90, 90)
        self.cell(0, 4, _ascii("%s -- Page %d" % (self.doc_id, self.page_no())),
                  align="C", new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.set_text_color(0, 0, 0)


def title_block(pdf, doc_id, title, summary):
    pdf.set_font("Helvetica", "B", 17)
    pdf.multi_cell(0, 8, _ascii(title), new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.ln(1)
    pdf.set_font("Helvetica", "", 9)
    pdf.set_text_color(70, 70, 70)
    pdf.multi_cell(0, 4.6, _ascii(
        "Document reference %s. Issued by %s. This document forms part of the "
        "customer agreement and is published in full at telecore.example/policies."
        % (doc_id, ISSUER)), new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.set_text_color(0, 0, 0)
    pdf.ln(3)
    pdf.set_font("Helvetica", "I", 10)
    pdf.multi_cell(0, 5, _ascii(summary), new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.ln(4)


def heading(pdf, text):
    if pdf.get_y() > 240:
        pdf.add_page()
    pdf.ln(2)
    pdf.set_font("Helvetica", "B", 12)
    pdf.multi_cell(0, 6, _ascii(text), new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.ln(1)


def subheading(pdf, text):
    pdf.set_font("Helvetica", "B", 10)
    pdf.multi_cell(0, 5, _ascii(text), new_x=XPos.LMARGIN, new_y=YPos.NEXT)


def para(pdf, text):
    pdf.set_font("Helvetica", "", 10)
    pdf.multi_cell(0, 5, _ascii(text), new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.ln(2)


def bullets(pdf, items):
    pdf.set_font("Helvetica", "", 10)
    for item in items:
        pdf.cell(5, 5, "-", new_x=XPos.RIGHT, new_y=YPos.TOP)
        pdf.multi_cell(0, 5, _ascii(item), new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.ln(2)


def table(pdf, headers, rows, widths, aligns=None):
    pdf.set_font("Helvetica", "", 9)
    aligns = aligns or ["LEFT"] * len(headers)
    style = FontFace(emphasis="BOLD", fill_color=GREY)
    with pdf.table(col_widths=widths, text_align=aligns, headings_style=style,
                   line_height=5, padding=1.2) as t:
        for record in [headers] + rows:
            row = t.row()
            for cell in record:
                row.cell(_ascii(str(cell)))
    pdf.ln(3)


def worked_example(pdf, lines):
    pdf.set_font("Helvetica", "B", 9)
    pdf.multi_cell(0, 5, "Worked example", new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.set_font("Courier", "", 9)
    for line in lines:
        pdf.multi_cell(0, 4.4, _ascii("    " + line), new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.ln(3)


# =============================================================================
# TC-POL-001  International Roaming
# =============================================================================
def doc_roaming():
    doc_id, ver = "TC-POL-001", "4.2"
    pdf = PolicyPDF(doc_id, "International Roaming Policy", ver)
    pdf.add_page()
    title_block(pdf, doc_id, "International Roaming Policy",
                "How data, voice and messaging are charged when you use your service outside "
                "your home country, what your plan already includes, and the protections that "
                "stop a roaming bill running away from you.")

    heading(pdf, "1. Purpose and scope")
    para(pdf, "This policy applies to every active consumer, premium and business subscription "
              "that has international roaming enabled. It governs charges raised while your "
              "device is registered on a partner network outside your home country. Roaming is "
              "enabled by default on postpaid plans and disabled by default on prepaid plans.")
    para(pdf, "Charges described here are additional to your monthly plan fee and appear on the "
              "bill for the cycle in which the roaming session ended.")

    heading(pdf, "2. Roaming zones and standard rates")
    para(pdf, "Every destination belongs to exactly one of four zones. The zone is determined by "
              "the network you register on, not by the country you bought your ticket to. Rates "
              "below are in USD and exclude tax.")
    # Labels are kept short so no row wraps. A wrapped row extracts as the rate
    # digits on one line and the territory names on the next, which separates
    # "Japan" from "45.00" and costs the retriever the association it needs.
    # The country list therefore lives in 2.1 as prose, which wraps harmlessly.
    table(pdf,
          ["Zone", "Region", "Data per GB", "Voice /min", "SMS each"],
          [["1", "Europe and the United Kingdom", "9.00", "0.25", "0.10"],
           ["2", "North America and the Caribbean", "21.00", "0.45", "0.15"],
           ["3", "Asia-Pacific and the Middle East", "45.00", "0.90", "0.25"],
           ["4", "Rest of world", "75.00", "1.95", "0.50"]],
          widths=(10, 46, 16, 16, 12),
          aligns=("CENTER", "LEFT", "RIGHT", "RIGHT", "RIGHT"))
    para(pdf, "2.1 Zone membership. Zone 1 covers the European Union and EEA, the United Kingdom "
              "and Switzerland. Zone 2 covers Canada, Mexico, the Caribbean and Central America. "
              "Zone 3 covers Japan, South Korea, Singapore, Australia, New Zealand and the Middle "
              "East. Zone 4 covers every other destination, including maritime, in-flight and "
              "satellite networks. The full country list is published at "
              "telecore.example/roaming-zones.")
    para(pdf, "2.2 Data is measured in decimal gigabytes, where 1 GB is 1000 MB, and is rounded "
              "to the nearest 0.01 GB at the end of each session.")
    para(pdf, "2.3 Incoming calls received while roaming are charged at the same per-minute rate "
              "as outgoing calls in the same zone. Incoming SMS is always free.")
    para(pdf, "2.4 Zone assignments are reviewed quarterly. A destination will never move to a "
              "more expensive zone during your minimum term without 30 days written notice.")

    heading(pdf, "3. Roaming included with your plan")
    para(pdf, "Each plan covers a range of zones and a data allowance that may be used inside "
              "those zones each billing cycle. Both conditions matter, and section 3.3 explains "
              "how they interact.")
    table(pdf,
          ["Plan", "Monthly fee", "Zones included", "Roaming allowance per cycle"],
          [["Business Pro", "110.00", "Zones 1 to 3", "3.00 GB"],
           ["Unlimited Max", "85.00", "Zones 1 to 2", "2.00 GB"],
           ["Unlimited Plus", "65.00", "Zone 1 only", "1.00 GB"],
           ["Flex 50GB", "45.00", "Zone 1 only", "0.50 GB"],
           ["Flex 20GB", "30.00", "None", "None"],
           ["Prepaid Pay-As-You-Go", "0.00", "None", "None"]],
          widths=(45, 22, 33, 45),
          aligns=("LEFT", "RIGHT", "LEFT", "LEFT"))

    subheading(pdf, "3.3 How a roaming charge is calculated")
    para(pdf, "The zone you actually used is compared against the zones your plan includes.")
    bullets(pdf, [
        "If you roam in a zone ABOVE the highest zone your plan includes, your roaming "
        "allowance does not apply at all. Every gigabyte is charged at the standard rate for "
        "the zone you used.",
        "If you roam in a zone your plan DOES include, only the data beyond your allowance is "
        "charged, and it is charged at the standard rate of the zone in which it was used.",
        "Where you roam in more than one zone in a cycle, the allowance is consumed in the "
        "order the sessions occurred, and the overage is priced at the zone of each session.",
    ])
    worked_example(pdf, [
        "Business Pro, 7.20 GB used in Japan (Zone 3)",
        "  Zone 3 is included by the plan, so the allowance applies",
        "  Chargeable  = 7.20 GB - 3.00 GB allowance = 4.20 GB",
        "  Charge      = 4.20 GB x 45.00 USD/GB      = 189.00 USD",
        "",
        "Flex 50GB, 0.90 GB used in Canada (Zone 2)",
        "  The plan includes Zone 1 only, so no allowance applies",
        "  Charge      = 0.90 GB x 21.00 USD/GB      =  18.90 USD",
        "",
        "Unlimited Max, 1.20 GB used in France (Zone 1)",
        "  Zone 1 is included and 1.20 GB is inside the 2.00 GB allowance",
        "  Charge                                    =   0.00 USD",
    ])
    para(pdf, "3.4 Roaming data is metered separately and does not count towards the domestic "
              "fair use threshold described in TC-POL-002. Being throttled at home does not "
              "reduce your roaming speed, and roaming heavily does not bring forward a domestic "
              "throttle.")
    para(pdf, "3.5 Unused roaming allowance expires at the end of each billing cycle and is not "
              "carried forward or refunded.")

    heading(pdf, "4. Daily roaming passes")
    para(pdf, "A pass is the cheaper option for anything more than light use, and may be bought "
              "before or during a trip. A pass is consumed only on a day you actually use data.")
    table(pdf,
          ["Zone", "Price per day", "Data included per day", "Voice and SMS"],
          [["1", "8.00", "1.00 GB", "Unlimited within the zone"],
           ["2", "12.00", "1.00 GB", "60 minutes, 60 SMS"],
           ["3", "15.00", "1.00 GB", "60 minutes, 60 SMS"],
           ["4", "20.00", "0.50 GB", "30 minutes, 30 SMS"]],
          widths=(12, 24, 38, 60),
          aligns=("CENTER", "RIGHT", "LEFT", "LEFT"))
    bullets(pdf, [
        "A pass day runs for 24 hours from the first data session, not from midnight.",
        "Data left over at the end of a pass day does not carry into the next day.",
        "Once the daily data is used the standard zone rate in section 2 resumes, unless you "
        "buy a further pass.",
        "Passes are consumed before any plan roaming allowance.",
    ])

    heading(pdf, "5. Bill shock protection")
    para(pdf, "5.1 Out-of-allowance roaming data charges are capped at 200.00 USD per billing "
              "cycle. The cap is applied automatically to every subscription and no opt-in is "
              "required.")
    para(pdf, "5.2 We send an SMS when you reach 50 percent, 80 percent and 100 percent of the "
              "cap. At 100 percent, roaming data is barred until you reply to the alert to "
              "continue at your own cost for the remainder of the cycle.")
    para(pdf, "5.3 The cap covers data only. Roaming voice, roaming SMS and premium numbers are "
              "outside it. Emergency calls are never barred for any reason.")
    para(pdf, "5.4 Business accounts may raise or remove the cap in writing through their account "
              "manager. Where the cap has been removed, alerts continue to be sent.")

    heading(pdf, "6. Roam-like-home in the European Union")
    para(pdf, "While roaming on an EU or EEA network on a plan that includes Zone 1, calls and "
              "SMS to numbers within the EU and EEA are charged at your domestic rate and draw "
              "on your domestic allowance instead of your roaming allowance. Data continues to "
              "draw on the roaming allowance in section 3, in line with the fair use limits the "
              "regulation permits.")

    heading(pdf, "7. Disputes and goodwill credits")
    para(pdf, "7.1 A roaming charge may be disputed within 60 days of the date of the bill on "
              "which it appeared. Raise a dispute through the assistant, the app, or by calling "
              "customer care.")
    para(pdf, "7.2 Where we cannot evidence that a zone entry alert was delivered to you, and the "
              "charge is the first of its kind on the account, a goodwill credit of up to 50.00 "
              "USD may be applied at our discretion.")
    para(pdf, "7.3 Partner networks may report usage to us up to 30 days late. A late-reported "
              "roaming charge may therefore appear on a cycle after the one in which you "
              "travelled, and is assessed against the allowances of the cycle in which the usage "
              "actually occurred.")

    heading(pdf, "8. Definitions")
    bullets(pdf, [
        "Billing cycle -- the monthly period ending on your invoice date.",
        "Roaming allowance -- data usable at no extra charge inside the zones your plan covers.",
        "Standard rate -- the per-unit price in section 2 for the zone actually used.",
        "Zone -- the tariff group of the partner network your device registers on.",
    ])
    return pdf, "TC-POL-001_International_Roaming_Policy.pdf"


# =============================================================================
# TC-POL-002  Fair Use and Network Management
# =============================================================================
def doc_fair_use():
    doc_id, ver = "TC-POL-002", "3.1"
    pdf = PolicyPDF(doc_id, "Fair Use and Network Management Policy", ver)
    pdf.add_page()
    title_block(pdf, doc_id, "Fair Use and Network Management Policy",
                "What unlimited means on our network, the point at which speed is reduced, how "
                "long a reduction lasts, and how capacity is shared when a cell is busy.")

    heading(pdf, "1. Purpose")
    para(pdf, "Plans sold as unlimited carry no hard stop on the amount of data you may use. To "
              "keep the network usable for everyone, a fair use threshold applies. Passing it "
              "reduces your speed for the rest of the cycle. It never stops your service, never "
              "adds a charge, and never triggers a penalty.")

    heading(pdf, "2. Fair use thresholds by plan")
    para(pdf, "The threshold counts domestic data only, measured in decimal gigabytes across the "
              "billing cycle. Roaming data is excluded and is governed by TC-POL-001.")
    table(pdf,
          ["Plan", "Monthly fee", "Data allowance", "Fair use threshold", "Reduced speed"],
          [["Business Pro", "110.00", "Unlimited", "200 GB", "2048 kbps"],
           ["Unlimited Max", "85.00", "Unlimited", "120 GB", "1024 kbps"],
           ["Unlimited Plus", "65.00", "Unlimited", "80 GB", "512 kbps"],
           ["Flex 50GB", "45.00", "50 GB", "50 GB (hard cap)", "256 kbps"],
           ["Flex 20GB", "30.00", "20 GB", "20 GB (hard cap)", "256 kbps"],
           ["Prepaid Pay-As-You-Go", "0.00", "Pay as you go", "Not applicable", "Not applicable"]],
          widths=(42, 20, 25, 33, 25),
          aligns=("LEFT", "RIGHT", "LEFT", "LEFT", "RIGHT"))
    para(pdf, "2.1 The reduced speed applies to both download and upload and is a ceiling, not a "
              "guarantee. Actual speed also depends on coverage, device and cell load.")
    para(pdf, "2.2 At 512 kbps, messaging, email, maps, music streaming and standard definition "
              "video continue to work. High definition video and large downloads will not.")

    heading(pdf, "3. What happens when you pass the threshold")
    bullets(pdf, [
        "Your speed is reduced to the rate in the table above for the remainder of the "
        "billing cycle.",
        "Full speed is restored automatically at 00:00 local time on the first day of the next "
        "billing cycle. You do not need to contact us and nothing needs to be reset.",
        "No overage charge is raised. Passing a fair use threshold on an unlimited plan never "
        "costs money.",
        "Your service is not suspended, your number is not affected, and voice and SMS are "
        "unchanged.",
        "You may request one courtesy restoration of full speed in any rolling 12-month "
        "period. Ask the assistant to raise a service request and the restoration applies from "
        "the next full hour.",
    ])
    para(pdf, "3.1 Moving to a higher plan mid-cycle lifts a reduction immediately, and the new "
              "threshold applies to the data you have already used in that cycle. Moving from "
              "Unlimited Plus to Unlimited Max after using 92 GB, for example, restores full "
              "speed at once because 92 GB is below the 120 GB threshold of the new plan.")

    heading(pdf, "4. Notification")
    para(pdf, "We send an SMS to the subscription when domestic usage reaches 80 percent of the "
              "threshold, and again at 100 percent when the reduction begins. Both messages are "
              "free and cannot be opted out of, because they are a condition of selling an "
              "unlimited plan.")

    heading(pdf, "5. Network congestion management")
    para(pdf, "Congestion management is applied per cell, only while that cell is congested, and "
              "is lifted the moment it is not. When a cell is congested, traffic is served in "
              "this order:")
    table(pdf,
          ["Priority", "Traffic class", "Treatment"],
          [["1", "Emergency calls and emergency SMS", "Never restricted under any condition"],
           ["2", "Voice and real-time communication", "Protected ahead of all data"],
           ["3", "Business Pro and Unlimited Max subscriptions", "Served ahead of other data"],
           ["4", "Subscriptions within their fair use threshold", "Normal treatment"],
           ["5", "Subscriptions past their fair use threshold", "Served last while congested"]],
          widths=(17, 68, 65),
          aligns=("CENTER", "LEFT", "LEFT"))
    para(pdf, "5.1 Congestion management is independent of the fair use threshold. A subscription "
              "within its threshold may still be slowed briefly on a busy cell, and that is not a "
              "fair use reduction.")

    heading(pdf, "6. Tethering and mobile hotspot")
    para(pdf, "Tethering is included at no extra cost on all postpaid plans and draws on the same "
              "data as the handset. Tethered data counts towards the fair use threshold in the "
              "same way as data used on the device itself. We do not restrict the type of device "
              "you connect.")

    heading(pdf, "7. Prohibited use")
    para(pdf, "A mobile subscription is sold for personal or business use by the account holder. "
              "The following are not permitted and may lead to suspension after written notice:")
    bullets(pdf, [
        "Reselling capacity, or operating the SIM as a permanent replacement for a fixed line "
        "in a commercial premises.",
        "Continuous automated traffic that serves no user, such as running a public server or "
        "traffic-generation software.",
        "Use in a SIM bank, gateway or similar device that terminates third party traffic.",
        "Any use that is unlawful or that materially degrades service for other customers.",
    ])
    para(pdf, "7.1 Suspension for prohibited use requires 10 days written notice and a chance to "
              "correct the behaviour, except where the traffic is unlawful or is actively "
              "damaging the network.")

    heading(pdf, "8. Capped plans")
    para(pdf, "Flex 50GB and Flex 20GB carry a hard cap rather than a fair use threshold. When the "
              "cap is reached, data stops and a message is sent. You may add a top-up of 5 GB for "
              "10.00 USD, as many times as you wish in a cycle. Top-up data expires at the end of "
              "the cycle in which it was bought. Voice and SMS are unaffected by a data cap.")

    heading(pdf, "9. Definitions")
    bullets(pdf, [
        "Fair use threshold -- the domestic data volume in a cycle beyond which speed is reduced.",
        "Throttling -- the speed reduction applied after the threshold is passed.",
        "Congestion -- the state of a cell whose demand exceeds the capacity available to it.",
        "Domestic data -- data used on our own network inside your home country.",
    ])
    return pdf, "TC-POL-002_Fair_Use_and_Network_Management_Policy.pdf"


# =============================================================================
# TC-POL-003  SIM Swap and Account Security
# =============================================================================
def doc_sim_swap():
    doc_id, ver = "TC-POL-003", "5.0"
    pdf = PolicyPDF(doc_id, "SIM Swap and Account Security Policy", ver)
    pdf.add_page()
    title_block(pdf, doc_id, "SIM Swap and Account Security Policy",
                "How we verify that a request to move your number to a new SIM really came from "
                "you, the delay we hold before it takes effect, and the controls that protect an "
                "account during and after a swap.")

    heading(pdf, "1. Purpose")
    para(pdf, "A SIM swap moves your number to a new SIM. It is a routine request when a handset "
              "is lost or a SIM is damaged, and it is also the single most valuable step for "
              "someone attempting to take over your accounts elsewhere, because so many services "
              "send a one-time passcode by SMS. This policy is deliberately slower and stricter "
              "than convenience alone would suggest.")

    heading(pdf, "2. Who may request a swap")
    bullets(pdf, [
        "The registered account holder.",
        "A named authorised contact recorded on a business account.",
        "A holder of a registered power of attorney, on production of the original document.",
    ])
    para(pdf, "A swap cannot be requested by a user of a line who is not the account holder, even "
              "where that user has physical possession of the handset.")

    heading(pdf, "3. Verification tiers")
    para(pdf, "Every request is verified at one of two tiers. The tier is decided by the risk "
              "score in section 4, not by the customer's preference.")
    table(pdf,
          ["Tier", "Where", "Evidence required"],
          [["TIER1", "In a retail store, in person",
            "Government photo identification matching the registered account name, plus the "
            "account holder present"],
           ["TIER2", "Remote, through the assistant or care line",
            "A one-time passcode delivered to the currently registered number, plus any two of: "
            "last four digits of the registered payment card, the amount of the most recent "
            "payment, three numbers called in the last seven days, the account creation month"]],
          widths=(18, 42, 90),
          aligns=("CENTER", "LEFT", "LEFT"))
    para(pdf, "3.1 A one-time passcode is never read back to an agent and is never sent to the "
              "new SIM. Any caller who asks you to share a passcode is not acting for us.")
    para(pdf, "3.2 Where the registered number cannot receive a passcode because the SIM is lost "
              "or stolen, the request must be verified at TIER1.")

    heading(pdf, "4. Risk scoring")
    para(pdf, "Each request is scored from 0 to 100. Indicators are cumulative and the score is "
              "capped at 100.")
    table(pdf,
          ["Indicator", "Points"],
          [["Account password or registered email changed in the last 7 days", "+20"],
           ["Registered address changed in the last 30 days", "+25"],
           ["A previous SIM swap on this account in the last 30 days", "+30"],
           ["Request originates outside the account's registered region", "+15"],
           ["Account holds a stored payment method or a balance above 500.00 USD", "+10"],
           ["Reason given is LOST or STOLEN without a police reference", "+10"],
           ["Two or more failed verification attempts in the last 24 hours", "+20"]],
          widths=(125, 25),
          aligns=("LEFT", "RIGHT"))
    subheading(pdf, "4.1 Bands")
    table(pdf,
          ["Score", "Outcome"],
          [["0 to 39", "Proceed at TIER2. The request may be completed remotely."],
           ["40 to 69", "TIER1 required. The account holder must attend a store in person."],
           ["70 and above",
            "Held for MANUAL_REVIEW by the fraud team. No swap is performed until a human "
            "reviewer releases it, and the reviewer will attempt to contact the account holder "
            "on a previously registered channel."]],
          widths=(30, 120),
          aligns=("LEFT", "LEFT"))
    para(pdf, "4.2 We do not disclose the score or the individual indicators to the caller, "
              "because doing so would tell an attacker which signal to remove. The assistant may "
              "say that a request needs further verification, and nothing more.")

    heading(pdf, "5. Cooling-off period")
    para(pdf, "5.1 Every approved swap is held for 24 hours before the new SIM is activated. The "
              "period runs from the moment verification completes.")
    para(pdf, "5.2 During the cooling-off period:")
    bullets(pdf, [
        "The existing SIM stays fully active for voice, SMS and data.",
        "An outbound port of the number to another operator is blocked.",
        "A notification is sent to the registered number, the registered email address, and by "
        "push to any signed-in app session.",
        "The account holder can cancel the swap from any of those notifications with a single "
        "action, at no charge and with no questions asked.",
    ])
    para(pdf, "5.3 The cooling-off period is waived only for a TIER1 in-store swap where the SIM "
              "is confirmed damaged and the handset and photo identification are both presented.")

    heading(pdf, "6. Porting lock after a swap")
    para(pdf, "For 72 hours after a swap completes, the number cannot be ported to another "
              "operator and a further swap cannot be requested. This window exists because a swap "
              "followed quickly by a port is the classic pattern of an account takeover.")

    heading(pdf, "7. Lost and stolen handsets")
    para(pdf, "Report a lost or stolen handset immediately and we will bar the SIM at once, "
              "before any verification, because barring a line can only ever protect the account "
              "holder. Restoring service afterwards still requires full verification under "
              "section 3. Charges raised after the time of the report are not your "
              "responsibility. Where a police reference is supplied within 14 days, the "
              "replacement SIM fee is waived.")

    heading(pdf, "8. Fees")
    table(pdf,
          ["Situation", "Fee"],
          [["Replacement SIM, standard", "10.00 USD"],
           ["Lost or stolen with a police reference supplied within 14 days", "Waived"],
           ["Damaged SIM within 12 months of activation", "Waived"],
           ["VIP and Business segment accounts", "Waived"],
           ["eSIM re-provision to a new device", "Free, unlimited"]],
          widths=(115, 35),
          aligns=("LEFT", "RIGHT"))

    heading(pdf, "9. Request lifecycle")
    para(pdf, "A swap request moves through the following states, and the assistant will tell you "
              "which one your request is in.")
    table(pdf,
          ["State", "Meaning"],
          [["PENDING_VERIFICATION", "Logged, waiting for the evidence in section 3"],
           ["COOLING_OFF", "Verified, inside the 24-hour hold in section 5"],
           ["APPROVED", "Hold elapsed, the new SIM is ready to be activated"],
           ["MANUAL_REVIEW", "Risk score 70 or above, held for the fraud team"],
           ["COMPLETED", "The new SIM is live and the old SIM is deactivated"],
           ["REJECTED", "Verification failed or the request was cancelled"]],
          widths=(48, 102),
          aligns=("LEFT", "LEFT"))

    heading(pdf, "10. Reporting suspected fraud")
    para(pdf, "If you receive a swap notification you did not request, treat it as an attack in "
              "progress. Cancel it using the link in the notification, then call us on the fraud "
              "line. We will place a security hold on the account, which blocks swaps and ports "
              "entirely until you attend a store. Contact your bank as well, because a swap "
              "attempt usually means your details are already known to someone.")
    return pdf, "TC-POL-003_SIM_Swap_and_Account_Security_Policy.pdf"


# =============================================================================
# TC-POL-004  Device Upgrade and Contract Terms
# =============================================================================
def doc_upgrade():
    doc_id, ver = "TC-POL-004", "2.6"
    pdf = PolicyPDF(doc_id, "Device Upgrade and Contract Terms", ver)
    pdf.add_page()
    title_block(pdf, doc_id, "Device Upgrade and Contract Terms",
                "When you may upgrade, what it costs to leave a contract early, how a device "
                "subsidy is repaid, and what a trade-in is worth.")

    heading(pdf, "1. Purpose")
    para(pdf, "A subsidised device is sold below its retail price in exchange for a minimum term. "
              "This document sets out how that bargain is unwound, whether you want to upgrade "
              "early, leave early, or simply know where you stand.")

    heading(pdf, "2. Upgrade eligibility")
    para(pdf, "You may upgrade to a new subsidised device when either condition is met:")
    bullets(pdf, [
        "At least 80 percent of your minimum term has elapsed, or",
        "You settle any remaining device subsidy in full, in which case you may upgrade on any "
        "day of the term.",
    ])
    para(pdf, "A subscription that is out of contract, or that never carried a minimum term, is "
              "always eligible and pays nothing to upgrade.")
    subheading(pdf, "2.1 Calculating the eligibility date")
    para(pdf, "The eligibility date is the activation date plus 80 percent of the term, rounded "
              "up to the next whole day:")
    worked_example(pdf, [
        "eligibility_date = activation_date + ceil(0.80 x term_days)",
        "",
        "12-month term activated on 1 December 2025",
        "  term_days        = 365",
        "  80 percent       = 292 days",
        "  eligibility date = 19 September 2026",
        "",
        "On 16 September 2026 that subscription is 79.2 percent elapsed,",
        "so it is 3 days short of eligibility.",
    ])
    para(pdf, "2.2 Eligibility is assessed on the day you ask. We do not reserve stock or hold a "
              "price against a future eligibility date.")
    para(pdf, "2.3 An upgrade starts a new minimum term on the date the new device is dispatched, "
              "not on the date it is delivered or activated.")

    heading(pdf, "3. Early termination fee")
    para(pdf, "If you cancel a subscription before the end of its minimum term, an early "
              "termination fee is payable:")
    worked_example(pdf, [
        "ETF = (remaining full months x 40% of monthly fee)",
        "      + outstanding device subsidy",
    ])
    bullets(pdf, [
        "A remaining full month is a whole calendar month between the cancellation date and the "
        "contract end date. Part months are not counted.",
        "The 40 percent reflects the cost we avoid by no longer carrying your traffic, and is "
        "the same on every plan.",
        "The outstanding device subsidy is charged in full and is not discounted, because it is "
        "money already spent on your behalf.",
    ])
    worked_example(pdf, [
        "Flex 50GB at 45.00 USD/month, cancelling with 2 full months",
        "remaining and 180.00 USD of device subsidy outstanding:",
        "",
        "  Airtime element = 2 x (0.40 x 45.00) = 2 x 18.00 =  36.00 USD",
        "  Device element  =                                  180.00 USD",
        "  ETF total                                        = 216.00 USD",
    ])
    para(pdf, "3.1 No early termination fee is payable where you cancel within the 14-day change "
              "of mind window in section 6, where you are exercising a right to cancel after we "
              "have increased prices mid-term, or where the subscription is out of contract.")
    para(pdf, "3.2 The fee appears on your final bill and is payable within 14 days of it.")

    heading(pdf, "4. Device subsidy")
    para(pdf, "The subsidy is the difference between the retail price of the device and what you "
              "paid at the point of sale. It reduces in equal parts across the minimum term, one "
              "part for each full month served, and reaches zero on the contract end date.")
    worked_example(pdf, [
        "monthly_reduction = initial_subsidy / term_months",
        "outstanding       = initial_subsidy - (full_months_served x monthly_reduction)",
    ])
    para(pdf, "4.1 The outstanding subsidy is shown against your subscription and is the figure "
              "used in both section 2 and section 3. It is the single number that decides what an "
              "early upgrade or an early exit costs.")

    heading(pdf, "5. Trade-in")
    para(pdf, "A working device may be traded in against an upgrade. The grade is set on "
              "inspection after we receive the device, and you have 7 days to reject a regrade "
              "and have the device returned free of charge.")
    table(pdf,
          ["Grade", "Condition", "Credit"],
          [["A", "Fully working, no visible wear, battery health 85 percent or above", "220.00 USD"],
           ["B", "Fully working, light scratches, battery health 70 percent or above", "140.00 USD"],
           ["C", "Working, heavy wear or cracked back glass", "60.00 USD"],
           ["F", "Not powering on, cracked screen, or water damage", "No credit, free recycling"]],
          widths=(16, 89, 45),
          aligns=("CENTER", "LEFT", "RIGHT"))
    bullets(pdf, [
        "A trade-in credit may be set against an outstanding device subsidy, which is often the "
        "quickest route to early upgrade eligibility.",
        "Trading in while recontracting for 24 months adds a 40.00 USD bonus to grades A, B "
        "and C.",
        "A device reported lost or stolen, or locked to another account, cannot be traded in.",
    ])

    heading(pdf, "6. Change of mind and returns")
    para(pdf, "A device bought remotely may be returned within 14 days of delivery for a full "
              "refund, provided it is undamaged, complete with its accessories, and has used less "
              "than 2 GB of data. The subscription is cancelled with no early termination fee. A "
              "device bought in a store may be exchanged within 14 days but is not refundable "
              "once unsealed, unless it is faulty.")

    heading(pdf, "7. End of the minimum term")
    para(pdf, "7.1 We write to you 30 days before your minimum term ends to set out your options.")
    para(pdf, "7.2 If you do nothing, the subscription continues month to month at the same "
              "monthly fee, with no minimum term, and may be cancelled with 30 days notice at any "
              "time and at no cost.")
    para(pdf, "7.3 An out-of-contract subscription may change plan freely, up or down, with the "
              "change taking effect at the start of the next billing cycle.")

    heading(pdf, "8. Porting your number out")
    para(pdf, "You may take your number to another operator at any time. Request a porting "
              "authorisation code through the assistant or the app and we will issue it within "
              "one working day. Porting out does not waive an early termination fee, and a "
              "porting lock under TC-POL-003 section 6 will delay it.")

    heading(pdf, "9. Definitions")
    bullets(pdf, [
        "Minimum term -- the number of months the subscription must run, set at activation.",
        "Device subsidy -- the unrepaid part of the discount given on the device.",
        "Out of contract -- a subscription whose contract end date has passed.",
        "Recontract -- accepting a new minimum term on an existing number.",
    ])
    return pdf, "TC-POL-004_Device_Upgrade_and_Contract_Terms.pdf"


# =============================================================================
# TC-POL-005  Service Outage and Compensation
# =============================================================================
def doc_outage():
    doc_id, ver = "TC-POL-005", "3.4"
    pdf = PolicyPDF(doc_id, "Service Outage and Compensation Policy", ver)
    pdf.add_page()
    title_block(pdf, doc_id, "Service Outage and Compensation Policy",
                "The availability we commit to, which outages attract a credit, how that credit "
                "is worked out, and how long you have to claim it.")

    heading(pdf, "1. Service level commitment")
    para(pdf, "We commit to 99.5 percent network availability per calendar month, measured per "
              "region across our own radio and core network. That allows roughly 3 hours 39 "
              "minutes of unavailability in a 30-day month. Availability is measured from our "
              "network management systems and is published monthly by region.")

    heading(pdf, "2. What qualifies for a credit")
    para(pdf, "An incident qualifies when all of the following are true:")
    bullets(pdf, [
        "The incident was unplanned.",
        "It caused a total loss of service, meaning neither voice nor data was usable.",
        "It lasted more than 4 continuous hours.",
        "It affected the area registered against your account.",
        "Your account was active, and not suspended for non-payment, for the whole of the "
        "incident.",
    ])
    para(pdf, "2.1 The 4 hours must be continuous. Two separate 3-hour incidents in one day do "
              "not combine into a qualifying incident, although a pattern of repeat incidents can "
              "be escalated under section 7.")

    heading(pdf, "3. What does not qualify")
    table(pdf,
          ["Situation", "Reason"],
          [["Planned maintenance notified at least 5 days in advance",
            "Notified work is excluded however long it runs"],
           ["Degraded performance without total loss of service",
            "Slow service is managed under TC-POL-002, not here"],
           ["A fault in your own handset, SIM or settings",
            "Not a network incident"],
           ["Loss of service outside your registered area",
            "Credits follow the area the account is registered to"],
           ["Service barred for non-payment or under a security hold",
            "The account was not in service at the time"],
           ["Events outside our reasonable control, such as a natural disaster or the loss of "
            "grid power to a wide area",
            "Force majeure, though goodwill may still be offered"]],
          widths=(78, 72),
          aligns=("LEFT", "LEFT"))

    heading(pdf, "4. How the credit is calculated")
    worked_example(pdf, [
        "daily_rate    = monthly_fee / 30",
        "credited_days = ceil(outage_hours / 24), minimum 1",
        "credit        = (daily_rate x credited_days) + goodwill",
    ])
    para(pdf, "4.1 A goodwill amount is added for any incident graded Major or Critical, by "
              "account segment:")
    table(pdf,
          ["Segment", "Goodwill for a Major or Critical incident"],
          [["VIP", "25.00 USD"],
           ["Business", "15.00 USD"],
           ["Premium", "10.00 USD"],
           ["Consumer", "10.00 USD"],
           ["Prepaid", "Credit given as 1 day of added validity, no cash amount"]],
          widths=(35, 115),
          aligns=("LEFT", "LEFT"))
    worked_example(pdf, [
        "VIP account on Unlimited Max at 85.00 USD/month, affected by a",
        "Major unplanned outage lasting 9 hours 20 minutes:",
        "",
        "  daily_rate    = 85.00 / 30          =  2.83 USD",
        "  credited_days = ceil(9.33 / 24) = 1, minimum 1 applies",
        "  airtime credit= 2.83 x 1            =  2.83 USD",
        "  goodwill, VIP                       = 25.00 USD",
        "  total credit                        = 27.83 USD",
    ])
    para(pdf, "4.2 Amounts are rounded to the nearest cent. Where an incident spans two billing "
              "cycles, the credit is applied to the cycle in which the incident was resolved.")
    para(pdf, "4.3 Credits are capped at one month of your monthly fee per calendar month, "
              "excluding goodwill.")

    heading(pdf, "5. Making a claim")
    para(pdf, "5.1 A claim must be made within 30 days of the date the incident was resolved. "
              "Claims outside that window are not paid, because the network records used to "
              "verify them are not retained beyond it.")
    para(pdf, "5.2 Ask the assistant to raise a service request of type OUTAGE_CREDIT. Quote the "
              "incident reference if you have it. You do not need to prove you were affected: we "
              "check your registered area against the incident record.")
    para(pdf, "5.3 Where an incident is graded Critical and affected more than 10,000 customers, "
              "the credit is applied automatically to every affected account within two billing "
              "cycles and no claim is needed. An incident graded Major always requires a claim, "
              "however many customers it affected.")
    para(pdf, "5.4 We respond to a claim within 5 working days. An approved credit appears on "
              "your next bill.")

    heading(pdf, "6. How credits appear")
    para(pdf, "A credit is shown as a separate line on your bill, described as Service Credit with "
              "the incident reference. Credits reduce the amount you owe and are not paid out in "
              "cash, except on closing an account, when any remaining balance is refunded to your "
              "registered payment method within 30 days.")

    heading(pdf, "7. Escalation")
    para(pdf, "If you are not satisfied with the outcome of a claim, ask for it to be escalated to "
              "the network service team, who will respond within 10 working days with the "
              "measurement data behind the decision. Three or more qualifying incidents in a "
              "rolling 90-day period entitle you to cancel the subscription without an early "
              "termination fee, regardless of how much of the minimum term remains.")

    heading(pdf, "8. Definitions")
    bullets(pdf, [
        "Outage -- a total loss of voice and data service.",
        "Degraded -- service is usable but below normal performance. Not an outage.",
        "Planned maintenance -- work notified at least 5 days in advance.",
        "Severity -- Minor, Major or Critical, graded by us from the scale and duration of the "
        "incident.",
        "Registered area -- the city and region recorded against your account.",
        "Incident reference -- the identifier of the form INC-YYYY-NNNN we give each incident.",
    ])
    return pdf, "TC-POL-005_Service_Outage_and_Compensation_Policy.pdf"


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for build in (doc_roaming, doc_fair_use, doc_sim_swap, doc_upgrade, doc_outage):
        pdf, filename = build()
        path = OUT_DIR / filename
        pdf.output(str(path))
        print("%-58s %2d pages  %6.1f KB" % (filename, pdf.page_no(),
                                             path.stat().st_size / 1024))


if __name__ == "__main__":
    main()
