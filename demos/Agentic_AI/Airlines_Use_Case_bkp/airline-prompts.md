# Airline Use Case — All Prompts

All 7 prompts you gave to generate the Airline Passenger Services
AI Agent demo apps. Chronological order across both sessions.

**Total prompts:** 7
**First prompt:** 2026-05-21 12:53:58 UTC
**Last prompt:** 2026-05-21 14:55:17 UTC
**Sessions:**
- Session A — c--Work-github-cp-integration-pm (`d56aaef5-f5dd-4540-9ae5-85ec139f6b68`) — 2 prompts
- Session B — c--Work-VsCode (`0b9f9652-a8fe-45e2-8e9b-92e4a774c0f2`) — 5 prompts

---

## Prompt #1

- **Timestamp:** 2026-05-21 12:53:58 UTC
- **Session:** A (Session A — c--Work-github-cp-integration-pm)

> I have meeting with Airline in 1 hour and I want to introduce flogo to them and show them quick demo ...so can you help me build a very simple use cases relevant to airline industry/vertical which makes them relate to the use case .... for eg you can generate a swagger api spec ...then generate a rest service from that api spec ..then we can expose those api as mcp server tools using flogo MCP server and then finally use flogo agentic ai connector to build some agentic workflow/orchestration .... first just come up with a very simple / real world use case ...then once i approve the use case ..then you start creating api spec, schema, apps etc after my approval

## Prompt #2

- **Timestamp:** 2026-05-21 12:59:40 UTC
- **Session:** A (Session A — c--Work-github-cp-integration-pm)

> yes .... looks good ... now you can refer to Hospital AI Agent use case - C:\Work\VsCode\Agentic_AI\Hospital_AI-Agent_Use_Case ... create a similar readme first on the workflow like this C:\Work\VsCode\Agentic_AI\Hospital_AI-Agent_Use_Case\hospital-poc.md ... then create database scripts with dummy data like this one ... "C:\Work\VsCode\Agentic_AI\Hospital_AI-Agent_Use_Case\database.sql" and "C:\Work\VsCode\Agentic_AI\Hospital_AI-Agent_Use_Case\reset_data.sql" ...then create api spec .... flogo rest app, mcp server app, agentic ai app ..... you can also use these skills C:\Work\VsCode\FDA\.claude or bring in relevant skills here which ever is easier to you .....first plan then once i approve start building

## Prompt #3

- **Timestamp:** 2026-05-21 13:37:59 UTC
- **Session:** B (Session B — c--Work-VsCode)

> Create a flogo rest service app -  airline-rest-api-demo from this api spec - C:\Work\VsCode\Agentic_AI\Airline_Passenger_Services_Use_Case\swagger.json ... use dummy values in return/reply activities wherever required

## Prompt #4

- **Timestamp:** 2026-05-21 13:45:51 UTC
- **Session:** B (Session B — c--Work-VsCode)

> I do not see schemas created ...nor schemas configured in REST Trigger request/reply settings ... Return activity flow output message field is also not mapped .... pls check for all the missing configurations .... this app is not at all usable .....look at how rest trigger, return activity is configured C:\Work\VsCode\Agentic_AI\Hospital_AI-Agent_Use_Case\endevour-api.flogo

## Prompt #5

- **Timestamp:** 2026-05-21 13:54:57 UTC
- **Session:** B (Session B — c--Work-VsCode)

> you have set path as incorrect in rest trigger settings .... you have set it like - 
> 
> /api/flights/:flightNumber
> 
> it should be - /api/flights/{flightNumber} ... pls fix it for all the rest triggers

## Prompt #6

- **Timestamp:** 2026-05-21 13:59:26 UTC
- **Session:** B (Session B — c--Work-VsCode)

> remember this ..if i ask you create another app from api spec ..you have to make sure you configure it correctly

## Prompt #7

- **Timestamp:** 2026-05-21 14:55:17 UTC
- **Session:** B (Session B — c--Work-VsCode)

> Create a flogo rest service app airline-rest-service-demo2 from this API Spec C:\Work\VsCode\Agentic_AI\Airline_Passenger_Services_Use_Case\swagger.json
