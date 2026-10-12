# Connector prerequisites (designtime) — detect and tell the user

Some Flogo connectors need a **prerequisite** (a native driver / client library) installed on the
developer machine for **design-time metadata fetching** — the designer uses it to read schemas,
tables and columns for the connector's activities and to validate the connection. Several of them
(Oracle, IBM DB2, TIBCO EMS / FTL / ActiveSpaces, IBM MQ, SAP Solutions) also need the client
library to **build and run** the app. The connector guide's wording for each of these is: *"Before
designing, testing, or running a Flogo app with this connector in Visual Studio Code, ensure that
you install the prerequisites required at design time."* Both agentic skills (FDA and clone) run
this check at the end of every build and list the result in the hand-off.

Source: **TIBCO Flogo® Connectors User Guide 2.26.8** (September 2026) — "Prerequisites for
Connectors" (pp. 13–32) and each connector's chapter. Page numbers below are that PDF's pages.

## Which connectors need a prerequisite (detection)

| Connector | Import root to grep for in the `.flogo` |
|---|---|
| PostgreSQL (also Amazon Redshift and Greenplum — connection *Database Type*) | `github.com/tibco/wi-postgres` |
| Oracle MySQL | `github.com/tibco/wi-mysql` |
| Microsoft SQL Server | `github.com/tibco/wi-mssql` |
| Oracle Database | `github.com/tibco/wi-oracledb` |
| IBM MQ | `github.com/tibco/wi-ibmmq` |
| SAP Solutions (RFC/BAPI) | `github.com/tibco/wi-sapsolutions` |
| TIBCO EMS | `github.com/tibco/flogo-ems` |
| TIBCO FTL | `github.com/tibco/flogo-ftl-connector` |
| TIBCO ActiveSpaces | `github.com/tibco/flogo-activespaces` |
| gRPC | `github.com/project-flogo/grpc` |
| IBM DB2, Snowflake, TIBCO Data Virtualization, SAP HANA Database, Apache Pulsar | name match under `github.com/tibco/` (`db2`, `snowflake`, `tdv`/`datavirtualization`, `hana`, `pulsar`) — no sample in this repo uses them yet, so the exact import root is unconfirmed |

The agentic use cases always use **PostgreSQL** (MCP server + A2A agents), so at least that one
always applies.

## Detect (read-only)

```bash
while IFS='|' read -r name re; do
  hits=$(grep -liE "github\.com/$re" <UseCaseDir>/*.flogo 2>/dev/null | tr '\n' ' ')
  [ -n "$hits" ] && echo "$name -> $hits"
done <<'EOF'
PostgreSQL / Redshift / Greenplum|tibco/wi-postgres/
Oracle MySQL|tibco/wi-mysql/
Microsoft SQL Server|tibco/wi-mssql/
Oracle Database|tibco/wi-oracledb/
IBM MQ|tibco/wi-ibmmq/
SAP Solutions|tibco/wi-sapsolutions/
TIBCO EMS|tibco/flogo-ems/
TIBCO FTL|tibco/flogo-ftl-connector/
TIBCO ActiveSpaces|tibco/flogo-activespaces/
gRPC|project-flogo/grpc/
IBM DB2|tibco/[^"/]*db2
Snowflake|tibco/[^"/]*snowflake
TIBCO Data Virtualization|tibco/[^"/]*(tdv|datavirtualization)
SAP HANA Database|tibco/[^"/]*hana
Apache Pulsar|tibco/[^"/]*pulsar
EOF
```

Imports may carry an alias prefix (`"postgresql github.com/tibco/wi-postgres/…"`), so match the path without a leading quote. `grep` only reads the files — never "fix" a missing prerequisite by editing the `.flogo`. For a
PostgreSQL hit, the connection's *Database Type* (PostgreSQL / Redshift / Greenplum) decides which
ODBC driver row below applies.

## What to install, per connector

**First, for every ODBC-based database connector** (PostgreSQL/Redshift/Greenplum, MySQL, SQL Server,
Oracle, Snowflake, TDV) install the **ODBC Driver Manager** (p. 15–16):
Windows — built in (ODBC Data Source Administrator) · macOS — `brew install unixodbc` (creates
`/usr/local/etc/odbcinst.ini`; if not, `touch $(brew --prefix)/etc/odbcinst.ini`); **Snowflake on
macOS needs the iODBC driver manager instead** (`iODBC-SDK.pkg`) · Ubuntu — `apt install unixodbc`
(TDV: `apt-get install unixodbc unixodbc-dev`; if `/etc/odbcinst.ini` is missing, `touch` it).
The VS Code installer below installs the driver manager together with the selected driver (p. 15).

| Connector | What to install (design time / run time) | OSes documented | Env vars / copy steps | Download source | Doc page |
|---|---|---|---|---|---|
| **PostgreSQL / Greenplum** | Design: PostgreSQL ODBC driver (psqlODBC). Run: nothing extra documented | Windows, macOS, Ubuntu | Win: MSI → driver appears in ODBC Data Source Administrator (x64). macOS: `brew install psqlodbc`, then add `[PostgreSQL]` / `Driver=<…>/lib/psqlodbcw.so` to `odbcinst.ini`. Ubuntu: `apt install odbc-postgresql` | [odbc.postgresql.org](https://odbc.postgresql.org/) / Homebrew / apt | 21–22, 451 |
| **Amazon Redshift** (PostgreSQL connector) | Design: Amazon Redshift ODBC driver | Windows, macOS, Ubuntu | Win: MSI. macOS: install pkg → `/opt/amazon/redshift/lib/libamazonredshiftodbc.dylib`; add `[Amazon Redshift]` / `Driver=<path>` to `odbcinst.ini`. Ubuntu: Amazon's installer | Amazon Redshift website | 22–23 |
| **Oracle MySQL** | Design: MySQL ODBC driver | Windows, Ubuntu (macOS not documented) | Win: MSI. Ubuntu: Debian installer; before Ubuntu 22.04 extract the `.tar` and run `./myodbc-installer -d -a -n "MySQL ODBC Unicode Driver" -t "DRIVER=/path/to/driver/libmyodbc8w.so;"` | Oracle MySQL website | 20, 397 |
| **Microsoft SQL Server** | Design: Microsoft ODBC Driver for SQL Server | Windows, macOS, Ubuntu | Win: MSI. macOS / Ubuntu: follow Microsoft's "ODBC driver for SQL Server" install page; driver then appears in `odbcinst.ini` | Microsoft website | 20–21, 350 |
| **Oracle Database** | Design **and** run: Oracle Instant Client **Basic + ODBC** packages (client libraries are required "to function"). Supported client for supplements: Oracle 21.x; DB 19c / RDS 19c | Windows, macOS, Ubuntu | Unzip Basic and ODBC into the **same** directory. Win: run `odbc_install.exe` as administrator. macOS: `brew tap InstantClientTap/instantclient`, `brew install instantclient-basic instantclient-odbc`, add `[Oracle ODBC Driver]` / `Driver=<…>/libsqora.dylib.<ver>` to `odbcinst.ini`. Ubuntu: `apt install libaio1`, then `odbc_update_ini.sh`. **Control Plane:** Instant Client Linux x86-64 21.11.0.0.0 Basic + ODBC merged into `instantclient_21_11`, renamed `oracle`, `zip --symlinks -r oracle.zip oracle`, upload as supplement `oracle.zip`. Restrictions: no Windows/macOS executables for TIBCO Cloud Integration / Control Plane runtime; no cross-platform local builds; use a custom application image for `flogobuild` Control Plane builds | [Oracle Instant Client](https://www.oracle.com/database/technologies/instant-client.html) | 17–18, 423–426 |
| **IBM DB2** | Design **and** run: IBM Data Server Driver (`clidriver`, DS Driver package) | Windows, Linux (Ubuntu) | Win: extract to e.g. `C:\IBM\clidriver`; set `IBM_DB_HOME=C:\IBM\clidriver`; add `C:\IBM\clidriver\bin` to system `PATH`. Linux: `export IBM_DB_HOME=/opt/ibm/clidriver`, `export LD_LIBRARY_PATH=$IBM_DB_HOME/lib` (persist in `~/.bashrc`). **Restart VS Code** after either. **Control Plane:** upload `linuxx64_odbc_cli.tar.gz` as the DB2 supplement — do not rename it | [IBM ODBC/CLI drivers](https://public.dhe.ibm.com/ibmdl/export/pub/software/data/db2/drivers/odbc_cli) | 25–26, 266, 279–280 |
| **Snowflake** | Design: Snowflake ODBC driver (`SnowflakeDSIIDriver`) | Windows, macOS, Ubuntu | Win: MSI, then create a DSN in ODBC Data Source Administrator (x64). macOS: install pkg (default `/opt/snowflake/snowflakeodbc`) + iODBC; create a DSN in `odbc.ini`; test with `iodbctest`. Ubuntu: extract the TGZ, run `./unixodbc_setup.sh` (writes `/etc/odbc.ini`, `/etc/odbcinst.ini`, `simba.snowflake.ini`; no env vars needed); test with `isql` | Snowflake ODBC download page | 16, 23–25, 547 |
| **TIBCO Data Virtualization** | Design **and** run: TDV ODBC driver | Windows, Ubuntu | Win: run the installer; verify under ODBC Data Sources (64-bit). Ubuntu: set `ODBCINI` and `ODBCINSTINI` to your `odbc.ini` / `odbcinst.ini`, run `bin/driverConfig`, give it `lib/libcomposite.so`. Restrictions: no Windows/macOS executables for TCI / Control Plane runtime; no cross-platform local builds | TIBCO eDelivery | 16, 19–20, 605–606 |
| **SAP HANA Database** | Design: SAP HANA ODBC driver, installed with the **SAP HANA Client** | Not OS-specific in the guide | Add the SAP HANA Client install path to the system `PATH` | SAP (SAP HANA Client) | 515–516 |
| **SAP Solutions** (RFC/BAPI) | Design **and** run: **SAP NW RFC SDK 7.50 PL17 or later**, plus `gcc`; Windows also needs the **Visual C++ Redistributable for Visual Studio 2013 or later** | Windows, Linux, macOS | Extract the SDK (with `lib` and `include`), e.g. `C:\nwrfcsdk`; in VS Code **Settings → Flogo → Extensions: SAPNWRFC Home** = that path. To run the built app: Win `PATH += <sdk>\lib`; Linux `LD_LIBRARY_PATH=<sdk>/lib`; macOS `DYLD_LIBRARY_PATH=<sdk>/lib`. Restrictions: no Windows/macOS executables for Control Plane runtime; no cross-platform local builds | SAP Support Portal (NW RFC SDK) | 29–30, 532 |
| **TIBCO EMS** | Design **and** run: **TIBCO EMS Client 10.3.0 or later**, plus `gcc` and `pkg-config` | Windows, macOS, Linux — **x86_64 only (not ARM)** | Win: set `EMS_HOME`, add `<EMS>\<ver>\bin` to `PATH`; in PowerShell, if `Get-ExecutionPolicy` is `Restricted` run `Set-ExecutionPolicy AllSigned`; then the VS Code installer option **TIBCO EMS/FTL/ActiveSpaces** (gcc + pkg-config). macOS: `export EMS_HOME=…`, `xcode-select --install`, `export DYLD_LIBRARY_PATH=<EMS>/lib`. Linux: as root `for f in tar/*; do tar -C / -xvf $f; done`, set `EMS_HOME` and `LD_LIBRARY_PATH=<EMS>/<ver>/lib` in `~/.bashrc`, then the installer option for pkg-config. Restrictions: no ARM (no binary, Docker image or unit tests); no Alpine (glibc) — use Debian/Ubuntu images; 64-bit only; no Windows/macOS executables for TCI / Control Plane; no cross-platform local builds; custom application image recommended for Control Plane | TIBCO eDelivery | 27–28, 179–180 |
| **TIBCO FTL** | Design / build: **TIBCO FTL 7.1.x** installed on the build machine (runtime can talk to an FTL 7.2.x server); `gcc` on Windows | Windows, Linux | Win: run the FTL installer; `TIBFTL_ROOT=<ftl>\ftl\<x.x>` (e.g. `C:\tibco\ftl\7.1`); `PATH += <ftl>\ftl\<x.x>\bin`; gcc via the installer option. Linux: extract tars as root; `TIBFTL_ROOT=/opt/tibco/ftl/7.1`, `LD_LIBRARY_PATH=/opt/tibco/ftl/7.1/lib:$LD_LIBRARY_PATH`, `PATH=$PATH:/opt/tibco/ftl/7.1/bin`. Reload VS Code | TIBCO eDelivery | 30–31, 596 |
| **TIBCO ActiveSpaces** | Design / run: TIBCO ActiveSpaces **and** TIBCO FTL installed, plus GCC | Windows paths shown | `TIBDG_ROOT=<as>\as\<x.x>`, `TIBFTL_ROOT=<ftl>\ftl\<x.x>`, add both `bin` folders to `PATH`; GCC on `PATH` (e.g. `C:\ProgramData\mingw64\mingw64\bin`, or the installer option). Reload VS Code | TIBCO eDelivery | 32, 568 |
| **IBM MQ** | Design / local run: **IBM MQ client** | Windows, Linux | Win: extract the client `.zip`; set **IBM MQ Home** to `<MQ>\bin64`. Linux: extract the `.tar.gz`; set IBM MQ Home to `<MQ>` (`IBM_MQ_HOME=<MQ>` in a Dockerfile). **Control Plane:** Linux client only, uploaded as supplement `IBM-MQ.tar.gz`. App-executable build in the web UI works only for Linux/amd64 | IBM MQ redistributable client (IBM) | 243–244, 266 |
| **Apache Pulsar** | Build: GCC on Windows to build a Windows executable; 64-bit only (don't use the Linux/x86 build option) | Windows note | — | — | 136 |
| **gRPC** | Design / build: `protoc` + `protoc-gen-go` / `protoc-gen-go-grpc` (the extension's installer option `grpc`; not covered by the connector guide) | — | — | VS Code installer | — |

**No local prerequisite** in the guide for: Agentic AI, Model Context Protocol (MCP), WebSockets,
HTTP, File, Apache Kafka, AMQP, MQTT, Redis, MongoDB, Salesforce, Amazon S3 / SNS / SQS / Kinesis,
Google Cloud Pub/Sub / Storage / Sheets, Microsoft Azure (Data Factory / Service Bus / Storage),
Mail, Mailchimp, OData, SAP S/4HANA OData, SFTP, DocuSign, Databricks, AuditSafe, TIBCO eFTL (needs
an FTL 6.4.0+ / eFTL server to connect to, p. 584). Only accounts / credentials are needed. Two
platform notes: **AWS Lambda is supported on Linux only** (p. 153); connectors using **OAuth 2.0**
need the callback / redirect URL `https://vscode.dev/redirect` (p. 14).

**Dev Containers:** for EMS, Oracle and similar connectors inside a VS Code Dev Container, install
the client libraries in the container and set `LD_LIBRARY_PATH` (Flogo 2.26.8 Installation guide,
pp. 10, 12).

## What to tell the user (paste into the hand-off and the README)

> **Install the connector prerequisites before opening these apps in the designer.** They are
> required for design-time metadata fetching (schemas, tables and columns for the activities, and
> connection validation).
> This use case uses: **<PostgreSQL, …>**.
> In VS Code, open the **Flogo** sidebar → **Help And Feedback** → **Install Prerequisites for
> Flogo Connectors…**, select the connectors listed above, finish the install, then **reload
> VS Code**. The picker only shows prerequisites that apply to your OS.

The VS Code installer (pp. 14–15) installs the ODBC Driver Manager plus the selected driver, and can
also install Go and the Flogo Go dependencies. On **Windows** it runs without admin rights; on
**Linux and macOS** it needs admin privileges. Connectors it does not cover (for example the SAP NW
RFC SDK, the IBM DB2 `clidriver`, the TIBCO EMS / FTL / ActiveSpaces / TDV packages) are manual
installs — paste the matching row from the table above into the hand-off.

If the designer can't list schemas/tables for a connector's activity, or its connection won't
validate, check that the prerequisite is installed (and VS Code reloaded) first.
