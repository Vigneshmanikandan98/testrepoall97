# Allocator deployment: Azure tasks (Solution Architect)

Allocator is an internal capacity-planning tool: React frontend and FastAPI backend in **one
container**, using the existing **Oracle** database. Code is in GitHub. GitHub Actions runs CI on
pull requests and, on merge to `main`, builds the image, pushes it to Azure Container Registry,
and updates an Azure Container App.

Your part: create the Azure resources, set up GitHub's passwordless login to Azure, create the
Container App once, then configure sign-in and access. After that, routine deploys need nothing
from you.

| Part | When | What |
|---|---|---|
| 1 | Before anything | Decisions that can't easily change later |
| 2 | Pre-deployment | Create Azure resources and GitHub login, hand values to Vignesh |
| 3 | During first deployment | Create the Container App from the first image |
| 4 | Post-deployment | Sign-in, access, scaling, alerts |
| 5 | Ongoing | Changes that need you |

All commands run in **Azure Cloud Shell (Bash)**. Run them one at a time.

---

## Part 1: Decisions before creating anything

| Decision | Options | Why it matters now |
|---|---|---|
| **Network path to Oracle** | (a) Public Oracle endpoint with an allowlist, (b) Container Apps environment in a VNet, with a NAT gateway for a fixed outbound IP or private connectivity | The app queries Oracle on startup. If Azure can't reach it, every deploy fails. **VNet integration must be chosen when the environment is created; it can't be added later.** |
| **Who can open the app** | (a) Public URL plus Microsoft Entra sign-in, (b) internal-only ingress on the corporate network | Affects ingress settings and Part 4 |
| **Where app secrets live** | (a) GitHub `production` environment secrets, copied to the Container App on each deploy (current setup), (b) Azure Key Vault (see appendix) | Key Vault keeps DB credentials out of GitHub entirely |
| **Oracle wallet** | Ask Vignesh whether the connection needs wallet files | If yes, they must be mounted into the container (extra step; tell Vignesh) |
| **Names and region** | Fill in the table below | Used in every command |

| Setting | Value |
|---|---|
| Subscription | |
| Region (LOC) | e.g. eastus |
| Resource group (RG) | e.g. rg-allocator-prod |
| Container registry (ACR, globally unique, lowercase) | e.g. flallocatoracr |
| Container Apps environment (ENV) | e.g. allocator-env |
| Container App (APP) | allocator |

Check company standards first: an existing shared registry, Key Vault, VNet, or naming
convention may already be required.

---

## Part 2: Pre-deployment

### 2.1 Set variables
```bash
RG=rg-allocator-prod
LOC=eastus
ACR=<registry name>
ENV=allocator-env
APP=allocator
SUB=$(az account show --query id -o tsv)
TENANT=$(az account show --query tenantId -o tsv)
```
If Cloud Shell restarts (it disconnects after ~20 idle minutes), set these again before continuing.

### 2.2 Register resource providers (once per subscription; safe to repeat)
```bash
az provider register -n Microsoft.ContainerRegistry --wait
az provider register -n Microsoft.App --wait
az provider register -n Microsoft.OperationalInsights --wait
```

### 2.3 Create the resource group, registry, and environment
```bash
az group create -n $RG -l $LOC
az acr create -n $ACR -g $RG --sku Basic
az containerapp env create -n $ENV -g $RG -l $LOC
```
For VNet integration (decision in Part 1), create the environment with your infrastructure
subnet instead of the last command.

The registry's admin user stays **disabled**. Nothing in this setup uses passwords.

### 2.4 Create GitHub's login to Azure (OIDC, no stored secret)
Vignesh sends you the subject string. It looks like:
`repo:<OWNER>@<OWNER_ID>/<REPO>@<REPO_ID>:environment:production`
```bash
SUBJECT="<paste exactly from Vignesh>"

APP_ID=$(az ad app create --display-name allocator-github --query appId -o tsv)
echo $APP_ID          # must print an ID before continuing
az ad sp create --id $APP_ID

az role assignment create --assignee $APP_ID --role Contributor \
  --scope /subscriptions/$SUB/resourceGroups/$RG

az ad app federated-credential create --id $APP_ID --parameters "{
  \"name\": \"github-production\",
  \"issuer\": \"https://token.actions.githubusercontent.com\",
  \"subject\": \"$SUBJECT\",
  \"audiences\": [\"api://AzureADTokenExchange\"]
}"
```
Notes:
- If the role assignment says the principal doesn't exist, wait 30 seconds and rerun it.
- If `az ad app create` reports "Timeout waiting for token", run `az login --scope "https://graph.microsoft.com//.default"` and retry.
- Contributor is scoped to **this resource group only**. The pipeline can deploy here and nowhere else.

### 2.5 Give Vignesh read access (lets him troubleshoot without you)
```bash
az role assignment create --assignee <vignesh@company.com> --role Reader \
  --scope /subscriptions/$SUB/resourceGroups/$RG
az role assignment create --assignee <vignesh@company.com> --role "Log Analytics Reader" \
  --scope /subscriptions/$SUB/resourceGroups/$RG
```

### 2.6 Send Vignesh these values
```bash
echo "AZURE_CLIENT_ID=$APP_ID"
echo "AZURE_TENANT_ID=$TENANT"
echo "AZURE_SUBSCRIPTION_ID=$SUB"
echo "ACR_NAME=$ACR"
echo "RESOURCE_GROUP=$RG"
echo "CONTAINER_APP_NAME=$APP"
```
None of these are passwords. He adds them to GitHub, merges, and the first pipeline run pushes
the image. He then sends you the **commit hash** of that run.

---

## Part 3: During the first deployment

### 3.1 Create the Container App from Vignesh's image
The app must start with its database settings, or it falls back to a default backend and crashes.
Values are entered with `read -s`, so they're not stored in shell history. If you don't hold the
Oracle credentials, have the DBA enter them during a screen-share.

```bash
TAG=<full commit hash from Vignesh>
az acr repository show-tags -n $ACR --repository allocator -o table   # confirm the tag exists

read -p  "Oracle user: " ORA_USER
read -s -p "Oracle password: " ORA_PW; echo
read -p  "Oracle DSN: " ORA_DSN
read -s -p "JWT secret (same value Vignesh put in GitHub): " JWT; echo

az containerapp create -n $APP -g $RG --environment $ENV \
  --image $ACR.azurecr.io/allocator:$TAG \
  --ingress external --target-port 8000 \
  --min-replicas 1 --max-replicas 2 \
  --registry-server $ACR.azurecr.io --registry-identity system \
  --secrets oracle-user="$ORA_USER" oracle-password="$ORA_PW" oracle-dsn="$ORA_DSN" jwt-secret="$JWT" \
  --env-vars DB_BACKEND=oracle ORACLE_USER=secretref:oracle-user ORACLE_PASSWORD=secretref:oracle-password \
             ORACLE_DSN=secretref:oracle-dsn ALLOCATOR_JWT_SECRET=secretref:jwt-secret
```
- For internal-only access (Part 1), use `--ingress internal`.
- `--registry-identity system` gives the app its own identity and permission to pull from the registry. This is why you run it: it grants a role, which the pipeline can't.
- Expect 2-5 minutes.

### 3.2 Check it started
```bash
az containerapp show -n $APP -g $RG --query properties.provisioningState -o tsv     # Succeeded
URL=$(az containerapp show -n $APP -g $RG --query properties.configuration.ingress.fqdn -o tsv)
curl -s https://$URL/api/health     # {"status":"ok"}
echo https://$URL
```
If it doesn't become healthy:
```bash
az containerapp logs show -n $APP -g $RG --type console --tail 50
```
Oracle connection errors in the log almost always mean the network path (Part 1) isn't open.

### 3.3 Send Vignesh the URL
He verifies the app and turns on branch protection. From now on, every merge to `main` deploys
automatically and updates the secrets from GitHub on each run.

---

## Part 4: Post-deployment

### 4.1 Restrict sign-in to company users (if using a public URL)
Portal -> the Container App -> **Authentication** -> **Add identity provider** -> **Microsoft**
- Tenant: workforce (your company tenant)
- Restrict access: **Require authentication**
- Unauthenticated requests: **HTTP 302 redirect** (sends users to sign-in)

Allocator also has its own login (JWT). Decide with Vignesh whether Entra sign-in replaces it
or sits in front of it.

### 4.2 Review access
- Only the people who need it should have Contributor or Owner on the resource group.
  Anyone with Contributor can read the app's secrets.
- The pipeline identity (`allocator-github`) has Contributor on this resource group only.

### 4.3 Alerts (recommended)
Portal -> the Container App -> **Alerts** -> create alerts for:
- Replica restarts above 0 in 5 minutes (the app is crashing)
- No running replicas

### 4.4 Cost check
`--min-replicas 1` keeps one instance always running, so users never wait for a cold start.
Lower it to 0 if cost matters more than first-load speed.

---

## Part 5: Ongoing

### Changes that need you

| Situation | What to do |
|---|---|
| Repo renamed, moved, or recreated | Add a new federated credential with the new subject (Vignesh sends it) **before** the next deploy |
| New environment (e.g. staging) | New Container App plus a federated credential for that environment's subject |
| Scaling, port, ingress, sign-in, or networking changes | Update the Container App settings |
| Oracle password rotated | If secrets are in GitHub, Vignesh updates them and reruns the deploy. If in Key Vault, update Key Vault |
| Urgent rollback | Portal -> the Container App -> **Revisions** -> activate the previous revision and send it 100% of traffic. (Vignesh can also roll back by reverting the PR; it takes a few minutes longer) |
| Pipeline fails with a permission error | Check the `allocator-github` role assignment on the resource group |

### Routine deploys
Nothing to do. Vignesh merges, GitHub builds, tests, deploys, and health-checks.

### Before any change to the Container App
Tell Vignesh first. The pipeline updates the image, environment variables, and secrets on every
deploy, so a manual change to those three is overwritten on the next merge. Other settings
(scaling, ingress, auth) are not touched by the pipeline.

---

## Appendix: Key Vault instead of GitHub secrets (recommended for production)

```bash
KV=<key vault name>
az keyvault create -n $KV -g $RG
az keyvault secret set --vault-name $KV -n oracle-password --value "<password>"
# repeat for oracle-user, oracle-dsn, jwt-secret

PRINCIPAL=$(az containerapp show -n $APP -g $RG --query identity.principalId -o tsv)
KV_ID=$(az keyvault show -n $KV --query id -o tsv)
az role assignment create --assignee $PRINCIPAL --role "Key Vault Secrets User" --scope $KV_ID

az containerapp secret set -n $APP -g $RG --secrets \
  "oracle-password=keyvaultref:https://$KV.vault.azure.net/secrets/oracle-password,identityref:system"
# repeat for the other three
```
Then tell Vignesh to remove the "Sync app secrets" step from `deploy.yml` and delete the Oracle
and JWT secrets from GitHub. Rotations then happen in Key Vault only.
