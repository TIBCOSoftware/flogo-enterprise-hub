<?xml version="1.0" encoding="ASCII"?>
<emulation:EmulationData xmlns:emulation="http:///emulation.ecore" isBW="true" location="Retail.Policy.API">
  <ProcessNode Id="retail.policy.api.Process" Name="retail.policy.api.Process" ModelType="BW" moduleName="Retail.Policy.API">
    <restNode Name="Policy">
      <Operation Name="/api/policy/resources" serviceName="/api/policy/resources" restOperationName="GET">
        <Inputs Id="Retail.Policy.API_retail.policy.api.Process_/api/policy/resources_getInput" Name="getInput" isDefault="true" restURL="http://0.0.0.0:18083"/>
      </Operation>
      <Operation Name="/api/policy/resources/{id}" serviceName="/api/policy/resources/{id}" restOperationName="GET">
        <Inputs Id="Retail.Policy.API_retail.policy.api.Process_/api/policy/resources/{id}_getInput" Name="getInput" isDefault="true" restURL="http://0.0.0.0:18083"/>
      </Operation>
      <Operation Name="/api/policy/resources/read?uri={uri}" serviceName="/api/policy/resources/read?uri={uri}" restOperationName="GET">
        <Inputs Id="Retail.Policy.API_retail.policy.api.Process_/api/policy/resources/read?uri={uri}_getInput" Name="getInput" isDefault="true" restURL="http://0.0.0.0:18083"/>
      </Operation>
      <Operation Name="/api/ingest" serviceName="/api/ingest" restOperationName="POST">
        <Inputs Id="Retail.Policy.API_retail.policy.api.Process_/api/ingest_postInput" Name="postInput" isDefault="true" restURL="http://0.0.0.0:18083"/>
      </Operation>
    </restNode>
  </ProcessNode>
</emulation:EmulationData>
