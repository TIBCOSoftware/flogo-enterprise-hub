# Industry taxonomy: where a governed sample lives

Every governed sample goes in an `Industry/Sub_Category` folder:

```
samples/Agentic_AI/Industry_Use_Cases/<Industry>/<Sub_Category>/<UseCase>_Use_Case/
```

In Phase 0, pick the industry and sub-category from the table below. If that folder already exists, put
the new sample in it. If it doesn't, create it (folders are created only when a sample lands in them, so
the tree never has empty branches). If no row fits, propose a new slug in the plan and get the user's
approval before creating it.

The 16 industries are listed in priority order: the top rows are where a new sample is most useful.

| Industry folder | Sub-category folders |
|---|---|
| `Financial_Services` | `Banking` · `Consumer_Finance_Payments` · `Capital_Markets` · `Asset_Wealth_Management` · `Central_Banks_Public_Finance` |
| `Telecommunications` | `Mobile_Fixed_Cable_Operators` · `Fiber_Wholesale_Network` |
| `Energy_Utilities` | `Electric_Gas_Utilities_Grid` · `Oil_Gas` · `Water_Waste_Environmental` · `Energy_Services_Metering` |
| `Healthcare_Life_Sciences` | `Health_Payers` · `Providers_Health_Systems` · `Pharma_Biotech_CRO` · `MedTech_Diagnostics` · `Healthcare_IT_Data` · `Pharmacy_Distribution` |
| `Transportation_Logistics` | `Airlines_Aviation` · `Rail` · `Parcel_Postal_Logistics` · `Airports_Ports` · `Ocean_Shipping` · `Transport_Authorities` |
| `Retail_Consumer_Goods` | `Retail_Ecommerce` · `Grocery_Food_Wholesale` · `CPG_Food_Beverage` · `Apparel_Luxury` · `Automotive_Retail_Parts` · `Agribusiness` |
| `High_Tech_Software` | `Software_SaaS` · `Semiconductors_Electronics` · `IT_Services_Consulting` · `IT_Hardware_Distribution` |
| `Government_Public_Sector` | `Federal_National_Government` · `State_Local_Government` |
| `Insurance` | `PC_Multi_Line` · `Life_Pensions_Wealth` |
| `Manufacturing_Industrial` | `Industrial_Building_Materials` · `Automotive_Tyres` · `Industrial_Distribution` |
| `Media_Travel` | `Media_Publishing` · `Gaming_Betting` · `Travel_Cruise` |
| `Aerospace_Defense` | `Defense_Space` |
| `Professional_Services` | `Consulting_Engineering_HR` |
| `Education_Non_Profit` | `Education_Charities` |
| `Mining_Natural_Resources` | `Mining` |
| `Real_Estate` | `Residential_Brokerage` · `Commercial_Real_Estate` |

## Path rules (clone-safe on Windows, Linux and macOS)

- **Characters:** folder and file names use only `A-Z a-z 0-9 _` (plus `.` before an extension and `-` where
  a tool requires it). No spaces, `&`, `/`, `,`, `(`, `)`, `'`, accents or emoji.
- **Length:** at most 64 characters per folder name, at most 48 for the `<UseCase>_Use_Case` folder, and at
  most **160 characters** for every repo-relative path. That leaves room for a clone location of about 100
  characters before Windows' 260-character `MAX_PATH` limit (Git for Windows doesn't enable long paths by
  default).
- **Case and reserved names:** never create two names that differ only in case (Windows and macOS are
  case-insensitive), and never use Windows reserved names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`,
  `LPT1`–`LPT9`) or a trailing dot or space.
- **Check before handing over:** list the sample's files and confirm the longest repo-relative path is within
  160 characters and that no name has a forbidden character:

  ```bash
  find samples/Agentic_AI/Industry_Use_Cases -type f -not -path '*__pycache__*' | awk '{print length($0), $0}' | sort -rn | head -3
  find samples/Agentic_AI/Industry_Use_Cases | grep -E '[^A-Za-z0-9_./-]'   # must print nothing
  ```

  If a path is too long, shorten the deepest name you are creating (usually the use case folder), never an
  existing shared folder, and tell the user.

Relative links inside a sample (e.g. to `samples/Agentic_AI/Chatbot/`) are four
levels up: `../../../../Chatbot/`.
