#!/bin
set -euo pipefail

# Configuration (override via env or CLI)
RESOURCE_GROUP=${RESOURCE_GROUP:-"rg-billing-opt"}
LOCATION=${LOCATION:-"EastUS"}
STORAGE_ACCOUNT=${STORAGE_ACCOUNT:-"stbilling$(openssl rand -hex 4)"}
COSMOS_ACCOUNT=${COSMOS_ACCOUNT:-"cosmos-billing-$(openssl rand -hex 4)"}
FUNCTION_APP=${FUNCTION_APP:-"func-billing-$(openssl rand -hex 4)"}
APPINSIGHTS_NAME=${APPINSIGHTS_NAME:-"appi-billing-$(openssl rand -hex 4)"}

echo "⏳ Starting deployment..."
echo "• Resource Group: $RESOURCE_GROUP"
echo "• Location: $LOCATION"

# 1. Create Resource Group
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION \
  --tags Project=BillingOptimization Environment=Prod

# 2. Create Cosmos DB Account
az cosmosdb create \
  --name $COSMOS_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --locations regionName="$LOCATION" failoverPriority=0 isZoneRedundant=False \
  --default-consistency-level Session \
  --enable-automatic-failover true

# 3. Create SQL Database & Container
az cosmosdb sql database create \
  --account-name $COSMOS_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --name billing \
  --throughput 600
az cosmosdb sql container create \
  --account-name $COSMOS_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --database-name billing \
  --name records \
  --partition-key-path "/partitionKey" \
  --throughput 600

# 4. Create Storage Account & Container
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS \
  --tags Project=BillingOptimization
az storage container create \
  --account-name $STORAGE_ACCOUNT \
  --name archived-billing

# 5. Set Lifecycle Management
cat <<EOF > lifecycle-policy.json
{
  "rules":[
    {
      "name":"tiering",
      "enabled":true,
      "type":"Lifecycle",
      "definition":{
        "filters":{"prefixMatch":["archived-billing/"],"blobTypes":["blockBlob"]},
        "actions":{
          "baseBlob":{
            "tierToCool":{"daysAfterModificationGreaterThan":90},
            "tierToArchive":{"daysAfterModificationGreaterThan":180}
          }
        }
      }
    }
  ]
}
EOF
az storage account management-policy create \
  --account-name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --policy @lifecycle-policy.json

# 6. Create Application Insights
az monitor app-insights component create \
  --app $APPINSIGHTS_NAME \
  --location $LOCATION \
  --resource-group $RESOURCE_GROUP \
  --application-type web

# 7. Create Function App
az functionapp create \
  --resource-group $RESOURCE_GROUP \
  --consumption-plan-location $LOCATION \
  --name $FUNCTION_APP \
  --storage-account $STORAGE_ACCOUNT \
  --runtime node \
  --runtime-version 18 \
  --functions-version 4 \
  --application-insights $APPINSIGHTS_NAME

# 8. Configure App Settings
COSMOS_CONN=$(az cosmosdb keys list \
  --name $COSMOS_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --type connection-strings \
  --query "connectionStrings[0].connectionString" -o tsv)
STORAGE_CONN=$(az storage account show-connection-string \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --query connectionString -o tsv)
INSIGHTS_KEY=$(az monitor app-insights component show \
  --app $APPINSIGHTS_NAME \
  --resource-group $RESOURCE_GROUP \
  --query instrumentationKey -o tsv)

az functionapp config appsettings set \
  --name $FUNCTION_APP \
  --resource-group $RESOURCE_GROUP \
  --settings \
    "COSMOS_CONNECTION_STRING=$COSMOS_CONN" \
    "STORAGE_CONNECTION_STRING=$STORAGE_CONN" \
    "APPLICATION_INSIGHTS_KEY=$INSIGHTS_KEY" \
    "FUNCTIONS_WORKER_RUNTIME=node"

echo "✅ Deployment completed!"
echo "   Function URL: https://$FUNCTION_APP.azurewebsites.net"
