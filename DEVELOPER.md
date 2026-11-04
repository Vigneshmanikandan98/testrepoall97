# Allocator deployment: Developer tasks (Vignesh)

Your part covers the code, the GitHub repo, and the handoffs to the architect.
Anything in Azure that creates resources or grants permissions is in ARCHITECT.md.

The work goes back and forth in this order:

| Step | Who | What |
|---|---|---|
| Part 1 | You | Get the code ready and CI green |
| Part 2 | You | Send the architect the details he needs |
| Part 3 | Architect | Create Azure resources and the GitHub login |
| Part 4 | You | Configure GitHub and run the first pipeline |
| Part 5 | Architect | Create the Container App |
| Part 6 | You | Verify, protect main, prove CI/CD |
| Part 7 | Architect | Sign-in, monitoring, access |

---

## Part 1: Get the code ready (prerequisites)

### 1.1 Review pending Copilot changes
- [ ] In VS Code, review the "92 files changed" bar. Keep or undo those changes before starting, so they don't mix with these.

### 1.2 Add the new files (same paths in the repo)
- [ ] `Dockerfile` (repo root)
- [ ] `.dockerignore` (repo root)
- [ ] `backend-v2/requirements-dev.txt`
- [ ] `.github/workflows/ci.yml`
- [ ] `.github/workflows/deploy.yml`

### 1.3 Make the code changes
- [ ] Paste the Copilot prompt from the appendix at the end of this file (agent mode). It changes three things: `client.js`, `requirements.txt`, `.gitignore`.
- [ ] Confirm Copilot reports all tests passing and `npm run build` succeeding.

### 1.4 Push through a pull request and get CI green
```bash
git checkout -b feature/cicd-setup
git add .
git commit -m "Add Docker, CI and deploy workflows"
git push -u origin feature/cicd-setup
```
- [ ] On GitHub, open a pull request into `main`.
- [ ] Wait for the `backend`, `frontend`, and `docker` checks to show green.
- [ ] If one is red: click Details, fix, push again to the same branch.
- [ ] **Don't merge yet.** Merging starts the deploy, and Azure isn't ready.

### 1.5 Answer the open questions (ask the DBA or the team)
- [ ] Does the Oracle connection need wallet files? (If yes, tell the architect; it adds a step.)
- [ ] Do the tracked `.xlsx` files contain real employee data? (If yes, remove them from the repo.)
- [ ] Is ignoring `migrations/` and `scripts/` in `.gitignore` intentional?
- [ ] Get the Oracle user, password, and DSN for the app. Ask for an account limited to Allocator's schema.

---

## Part 2: Send the architect what he needs

### 2.1 Get the exact GitHub login string
Your repo's numeric IDs must be included exactly. Open this in a browser (or use `gh` if the repo is private):
```
https://api.github.com/repos/<OWNER>/<REPO>
```
- Top-level `"id"` = REPO_ID
- `"id"` inside `"owner"` = OWNER_ID

For a private repo, on your laptop:
```bash
gh api repos/<OWNER>/<REPO> --jq '"repo:\(.owner.login)@\(.owner.id)/\(.name)@\(.id):environment:production"'
```

The string to send looks like:
```
repo:<OWNER>@<OWNER_ID>/<REPO>@<REPO_ID>:environment:production
```
It ends in `environment:production` (not `ref:refs/heads/main`) because the deploy job uses a protected environment.

### 2.2 Send the architect
- [ ] The login string from 2.1
- [ ] ARCHITECT.md
- [ ] Answers to the wallet and network questions (1.5)
- [ ] Your request for access (2.3)

### 2.3 Ask for read access for yourself
You have Cloud Shell, but Cloud Shell only lets you do what your Azure role allows. Ask for:
- **Reader** on the Allocator resource group: lets you check app status and revisions yourself.
- **Log Analytics Reader** on the Container Apps environment's workspace: lets you read app logs.

With these you can troubleshoot deploys without waiting on the architect. See "What you can check yourself" at the end.

---

## Part 3: Wait for the architect

He creates the Azure resources and sends you back these values. Write them down:

| Value | Example |
|---|---|
| AZURE_CLIENT_ID | a1b2c3d4-... |
| AZURE_TENANT_ID | ... |
| AZURE_SUBSCRIPTION_ID | ... |
| ACR_NAME | allocatoracr |
| RESOURCE_GROUP | rg-allocator-prod |
| CONTAINER_APP_NAME | allocator |

---

## Part 4: Configure GitHub and run the first pipeline

### 4.1 Repo secrets and variables
Settings -> Secrets and variables -> Actions

| Tab | Name | Value |
|---|---|---|
| Secrets | AZURE_CLIENT_ID | from architect |
| Secrets | AZURE_TENANT_ID | from architect |
| Secrets | AZURE_SUBSCRIPTION_ID | from architect |
| Variables | ACR_NAME | from architect |
| Variables | RESOURCE_GROUP | from architect |
| Variables | CONTAINER_APP_NAME | from architect |

### 4.2 Create the `production` environment
Settings -> Environments -> New environment -> name it `production`
- [ ] Deployment branches: **Selected branches** -> add `main`
- [ ] Optional: add yourself as a required reviewer (every production deploy then waits for your click)
- [ ] Add **environment secrets** (inside the environment, not repo secrets):

| Name | Value |
|---|---|
| ORACLE_USER | from DBA |
| ORACLE_PASSWORD | from DBA |
| ORACLE_DSN | from DBA |
| ALLOCATOR_JWT_SECRET | a new long random string (not the dev one) |

Generate a JWT secret in Cloud Shell or on your laptop:
```bash
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

### 4.3 Merge and run the first pipeline
- [ ] Merge your pull request from Part 1.
- [ ] Watch Actions -> Deploy Allocator. Expected result: CI passes, the image is built and pushed, then a **yellow warning** says the Container App doesn't exist yet. That's correct for the first run.
- [ ] Copy the **full commit hash** of that merge (40 characters, from the commit page). Send it to the architect for Part 5.

If the run fails at "Log in to Azure" with `AADSTS700213`: the login string doesn't match. Compare the subject in the error with what you sent in 2.1, and ask the architect to add the exact one.

---

## Part 5: Wait for the architect

He creates the Container App from your image and sends you the app URL.

---

## Part 6: Verify and lock down

### 6.1 Check the app
- [ ] Open the URL. The app loads and you can log in.
- [ ] Open `<URL>/api/health`. It shows `{"status":"ok"}`.
- [ ] Check a page that reads from Oracle. Real data appears.

### 6.2 Protect main
Settings -> Branches -> Add rule -> branch name `main`
- [ ] Require a pull request before merging (approvals: 0 while you're the only developer, 1 once someone joins)
- [ ] Require status checks: `backend`, `frontend`, `docker`
- [ ] Do not allow bypassing the above settings

Test it: a direct `git push` to `main` should now be rejected.

### 6.3 Prove CI/CD end to end
- [ ] Make a small visible change on a new branch, open a PR, wait for green, merge.
- [ ] Watch the deploy run (all green, including "Smoke test /api/health").
- [ ] Refresh the app. Your change is live.

---

## Ongoing: what you do on your own

| Task | How |
|---|---|
| Ship a change | Branch -> PR -> green -> merge. The pipeline deploys |
| Roll back a bad deploy | On GitHub, open the merged PR -> **Revert** -> merge the revert PR. The previous code redeploys |
| Change an Oracle or JWT secret | Update the environment secret in GitHub, then Actions -> Deploy Allocator -> **Run workflow** |
| Re-run a failed deploy | Actions -> the run -> Re-run jobs |

## Ongoing: when to involve the architect

| Situation | Why |
|---|---|
| Renaming or moving the repo | The GitHub login string changes; Azure must be updated first or deploys fail |
| Adding a new environment (e.g. staging) | New Container App and login string |
| Changing scaling, port, sign-in, or networking | Container App settings outside the pipeline |
| Adding a brand-new secret name | You add it in GitHub and `deploy.yml`; no Azure change needed unless Key Vault is used |
| A deploy fails with an Azure permission error | His role assignments |
| An urgent rollback | He can switch traffic to the previous revision in seconds, faster than a revert |

## What you can check yourself (once you have Reader)

In Cloud Shell:
```bash
RG=<resource group>; APP=<container app name>

# Is the app healthy? Which version is live?
az containerapp show -n $APP -g $RG --query "{state:properties.runningStatus, image:properties.template.containers[0].image}" -o table
az containerapp revision list -n $APP -g $RG --query "[].{revision:name, active:properties.active, health:properties.healthState}" -o table
```
Logs: Azure portal -> the Container App -> **Log stream** (needs Log Analytics Reader for history).

## Things to keep an eye on

- **Oracle reachability from Azure.** The app queries Oracle on startup. If Azure can't reach it, every deploy fails at the health check. This is the most likely first blocker.
- **The login string.** Any repo rename, move, or new environment changes it.
- **Don't cancel a deploy halfway.** Azure keeps working and the next run hits a lock. Let it finish or time out.
- **Secrets stay out of the repo.** No `.env`, wallet, or passwords committed, ever. If one was committed in the past, tell the DBA so the password is changed.
- **Docker Desktop isn't needed** for any of this. The builds run on GitHub.
- **Cloud Shell disconnects** after about 20 idle minutes. A frozen screen usually means that, not a stuck command.

---

## Appendix: Copilot prompt for Part 1.3

```text
Make exactly these changes. Do not modify any other files.

1. frontend-v2/src/api/client.js, function resolveBase (lines ~27-35):
   - If VITE_API_BASE is set, use it (unchanged).
   - Else if import.meta.env.PROD is true, return "" so API calls go to the same origin
     (production serves the frontend and API from one container on one URL).
   - Else keep the current development fallback (port 8001) unchanged.
   Do not change any other API code.

2. backend-v2/requirements.txt: remove pytest and httpx. They now live in
   backend-v2/requirements-dev.txt, which already exists.

3. .gitignore: add these lines if missing:
   backend-v2/static/
   build/
   wallet/
   *.sso
   *.p12
   cwallet*
   ewallet*
   tnsnames.ora
   sqlnet.ora
   Do not change the existing migrations/ and scripts/ lines.

4. Delete the root package-lock.json only if there is no package.json at the repo root.

Then verify and report results:
- In backend-v2 with USE_SQLITE=true and ALLOCATOR_JWT_SECRET=test set:
  python -m pip install -r requirements-dev.txt; python -m pytest -q   (expect all tests passing)
- In frontend-v2: npm ci; npm run build   (expect success)
```
