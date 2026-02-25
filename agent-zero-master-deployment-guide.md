# Agent Zero Master Deployment Guide

**A complete, step-by-step guide to deploying Agent Zero with Tailscale VPN, custom code fixes, Google Workspace integration, and ongoing maintenance.**

*Last updated: February 2026*

---

## Overview

[Agent Zero](https://github.com/agent0ai/agent-zero) is an open-source AI agent framework that runs inside a Docker container. This guide walks you through the entire deployment process from scratch — including putting it on a private VPN (Tailscale), forking the code on GitHub so you can apply custom fixes, connecting it to Google Workspace (Gmail, Calendar, Drive, Tasks), and keeping everything up to date.

By the end of this guide you will have:

- Agent Zero running in Docker on your server, accessible only through your private Tailscale VPN
- A personal GitHub fork with custom code fixes for memory retrieval and MCP tool routing
- Google Workspace integration so Agent Zero can read your email, manage your calendar, and more
- A documented process for pulling upstream updates without losing your customizations

### How This Guide Is Organized

| Part | What It Covers |
|------|----------------|
| **Part 1** | Prerequisites — accounts, tools, and system requirements |
| **Part 2** | Tailscale VPN setup for Docker containers |
| **Part 3** | Forking Agent Zero on GitHub for custom modifications |
| **Part 4** | Code fixes — memory/RAG retrieval and MCP context injection |
| **Part 5** | Building and launching the Docker container |
| **Part 6** | Google Workspace MCP server integration |
| **Part 7** | Adding knowledge files (with known path workaround) |
| **Part 8** | Syncing with upstream updates |
| **Part 9** | Troubleshooting reference |
| **Part 10** | Quick-reference cheat sheet |

---

## Part 1: Prerequisites

Before you begin, make sure you have the following accounts, tools, and system access ready.

### Accounts You Need

| Account | Purpose | Where to Sign Up |
|---------|---------|------------------|
| **GitHub** | Host your fork of Agent Zero's source code | [github.com](https://github.com) |
| **Tailscale** | Private VPN so only your devices can reach Agent Zero | [tailscale.com](https://tailscale.com) |
| **Google Cloud** | OAuth credentials for Google Workspace integration | [console.cloud.google.com](https://console.cloud.google.com) |

### System Requirements

- **Operating system:** Ubuntu 24.04 LTS (server or desktop) or macOS
- **RAM:** 4 GB minimum (8 GB recommended)
- **Disk:** 10 GB free for Docker images and data
- **Network:** Internet access for pulling Docker images and reaching APIs

### Software That Must Be Installed

The sections below walk you through installing each of these. This checklist is here so you can see what's coming.

| Software | What It Does |
|----------|-------------|
| **Docker** | Runs Agent Zero in an isolated container |
| **Docker Compose** | Orchestrates multiple containers (Agent Zero + Tailscale) from one config file |
| **Tailscale** | Private mesh VPN — makes your container accessible only to your devices |
| **Git** | Version control — lets you manage your fork of Agent Zero's source code |
| **UV** (optional) | Python package runner — needed only if you set up Google Workspace integration |

### Install Docker (Ubuntu)

Docker is the software that runs Agent Zero in a container. Install it from the official Docker repository (not the Ubuntu Snap store, which can cause issues):

```bash
# Add Docker's official GPG key and repository
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

Now add your user to the `docker` group so you can run Docker commands without `sudo`:

```bash
sudo usermod -aG docker $USER
```

> **Important:** On Ubuntu, logging out and back in may not be sufficient due to systemd session caching. A **full reboot** is the reliable way to pick up the new group membership.

After rebooting, verify:

```bash
groups
```

You should see `docker` in the list. Also verify Docker Compose is available:

```bash
docker compose version
```

### Install Docker (macOS)

Download and install [Docker Desktop for Mac](https://www.docker.com/products/docker-desktop/). Docker Compose is included automatically.

### Install Tailscale

Tailscale creates a private VPN mesh between all your devices. Once installed, your devices can reach each other by Tailscale IP addresses (100.x.x.x) no matter where they are physically.

**Ubuntu:**
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

**macOS:**

Download from the [Mac App Store](https://apps.apple.com/app/tailscale/id1475387142) or from [tailscale.com/download](https://tailscale.com/download).

After installing, verify Tailscale is connected:

```bash
tailscale ip -4
```

This prints your machine's Tailscale IP (e.g., `100.90.48.48`). Write it down — you'll need it later.

### Install Git

Git is version control software. You'll use it to manage your personal copy (fork) of Agent Zero's source code.

**Ubuntu:**
```bash
sudo apt install -y git
```

**macOS:**
```bash
xcode-select --install
```

### Enable Docker to Start at Boot (Ubuntu)

This ensures your containers come back up automatically after a server reboot:

```bash
sudo systemctl enable docker
```

Verify:

```bash
sudo systemctl is-enabled docker
# Should print: enabled
```

---

## Part 2: Tailscale VPN Configuration for Docker

Agent Zero will run inside a Docker container. Instead of exposing it on your local network (where anyone nearby could access it), you'll put it on your **Tailscale VPN** so only your devices can reach it.

This uses a pattern called a **sidecar**: two containers run side by side — one is Tailscale (handling the VPN connection) and the other is Agent Zero (your actual application). Agent Zero shares Tailscale's network stack, so it automatically gets a Tailscale IP address with zero configuration.

### Step 1: Configure Tailscale ACL Tags

Tailscale uses Access Control Lists (ACLs) to manage permissions. You need to create a "tag" that identifies your Docker containers.

1. Go to [https://login.tailscale.com/admin/acls/file](https://login.tailscale.com/admin/acls/file)
2. Find the `tagOwners` section (or create one) and add a `tag:container` entry:

```json
"tagOwners": {
  "tag:container": ["autogroup:admin"]
},
```

3. Save the ACL policy.

**Why:** Tags let you apply firewall rules to specific types of nodes. The `tag:container` tag will identify all your Docker containers on the tailnet.

### Step 2: Create a Tailscale OAuth Client

You need an authentication credential so the Docker container can join your Tailscale network. OAuth client secrets are preferred over auth keys because **OAuth secrets never expire**, while auth keys have a maximum lifetime of 90 days.

1. Go to [https://login.tailscale.com/admin/settings/oauth](https://login.tailscale.com/admin/settings/oauth)
2. Click **Generate OAuth client**
3. Configure:
   - **Description:** `Agent Zero` (or any name you like)
   - **Scopes:** Auth Keys — Read & Write
   - **Tag:** Select `tag:container`
4. Click **Generate client**
5. **Copy both the Client ID and Client Secret** — the secret will not be shown again

The secret looks like: `tskey-client-XXXXX-XXXXXXXXXXXXXXXXXXXXXXXXXXXXX`

> **Save this somewhere secure.** You'll paste it into your Docker Compose file later. If you lose it, you'll need to generate a new one.

---

## Part 3: Forking Agent Zero on GitHub

Rather than running Agent Zero's official Docker image directly, you'll create a **fork** — your own personal copy of the source code on GitHub. This lets you apply custom fixes (covered in Part 4) and still pull official updates when the developers release them.

### Branch Strategy

Your fork uses two branches:

| Branch | Purpose | Rule |
|--------|---------|------|
| `main` | Clean mirror of the official Agent Zero repository | **Never modify this branch directly** |
| `personalization` | Your customizations on top of `main` | This is what you build and run |

### Step 1: Configure Git Identity

Tell Git who you are (this is attached to your commits):

```bash
git config --global user.name "YOUR_GITHUB_USERNAME"
git config --global user.email "YOUR_EMAIL"
```

### Step 2: Set Up an SSH Key for GitHub

SSH keys let you push and pull code from GitHub without typing your password every time.

Generate a key (if you don't already have one):

```bash
ssh-keygen -t ed25519 -C "YOUR_EMAIL"
```

Press Enter to accept the default file location. You can optionally set a passphrase.

Now copy the public key:

```bash
cat ~/.ssh/id_ed25519.pub
```

Add it to GitHub:

1. Go to [https://github.com/settings/keys](https://github.com/settings/keys)
2. Click **New SSH key**
3. Paste the public key and save

Test the connection:

```bash
ssh -T git@github.com
```

You should see a message like: `Hi YOUR_USERNAME! You've successfully authenticated...`

### Step 3: Fork the Repository on GitHub

1. Go to [https://github.com/agent0ai/agent-zero](https://github.com/agent0ai/agent-zero)
2. Click the **Fork** button (top right)
3. GitHub creates your copy at `https://github.com/YOUR_USERNAME/agent-zero`

### Step 4: Clone Your Fork Locally

```bash
cd ~
git clone git@github.com:YOUR_USERNAME/agent-zero.git agent-zero-fork
cd agent-zero-fork
```

**What this does:** Downloads your fork to `~/agent-zero-fork/` on your machine.

### Step 5: Add the Upstream Remote

The "upstream" remote points to the official Agent Zero repository so you can pull their updates later:

```bash
git remote add upstream https://github.com/agent0ai/agent-zero.git
```

Verify both remotes exist:

```bash
git remote -v
```

Expected output:

```
origin    git@github.com:YOUR_USERNAME/agent-zero.git (fetch)
origin    git@github.com:YOUR_USERNAME/agent-zero.git (push)
upstream  https://github.com/agent0ai/agent-zero.git (fetch)
upstream  https://github.com/agent0ai/agent-zero.git (push)
```

### Step 6: Create the Personalization Branch

```bash
git checkout -b personalization
git push -u origin personalization
```

**What this does:** Creates a new branch called `personalization` based on `main` and pushes it to your GitHub fork. All your custom code changes will live on this branch.

---

## Part 4: Applying Code Fixes

Agent Zero has two bugs that need to be fixed before it works well with certain LLM models (particularly Qwen3-Coder). These fixes live on your `personalization` branch.

Make sure you're on the right branch:

```bash
cd ~/agent-zero-fork
git checkout personalization
```

### Fix 1: Memory/RAG Retrieval (`python/tools/memory_load.py`)

#### What's Broken

Agent Zero's memory system lets it remember things from previous conversations. But when using certain LLM models, three problems compound to make memory completely useless:

1. The LLM decides "I don't have personal info" and never searches memory at all
2. When it does search, it invents filter names (`area=='personal'`, `area=='credentials'`) that don't exist in the database — returning zero results
3. The default similarity threshold (0.7) is too strict, filtering out valid semantic matches

#### The Fix

Open the file:

```bash
nano python/tools/memory_load.py
```

Replace the **entire contents** of the file with:

```python
from python.helpers.memory import Memory
from python.helpers.tool import Tool, Response

DEFAULT_THRESHOLD = 0.4
DEFAULT_LIMIT = 10

class MemoryLoad(Tool):
    async def execute(self, query="", threshold=DEFAULT_THRESHOLD, limit=DEFAULT_LIMIT, filter="", **kwargs):
        db = await Memory.get(self.agent)

        # Override LLM threshold — never go above 0.5
        if threshold > 0.5:
            threshold = DEFAULT_THRESHOLD

        # Ignore area filters that reference non-standard areas
        if filter and any(x in filter.lower() for x in ["personal", "user", "credentials", "private"]):
            filter = ""

        docs = await db.search_similarity_threshold(query=query, limit=limit, threshold=threshold, filter=filter)
        if len(docs) == 0:
            result = self.agent.read_prompt("fw.memories_not_found.md", query=query)
        else:
            text = "\n\n".join(Memory.format_docs_plain(docs))
            result = str(text)
        return Response(message=result, break_loop=False)
```

**What each change does:**

| Change | Why |
|--------|-----|
| `DEFAULT_THRESHOLD = 0.4` (was 0.7) | The original 0.7 is too strict for semantic search — valid matches get filtered out |
| Threshold capped at 0.5 | Even after changing the default, some LLMs explicitly pass 0.7 as an argument, overriding it. This cap prevents that. |
| Invalid area filter stripping | LLMs invent area names that don't exist (like "personal" or "credentials"). The only valid areas are `main`, `fragments`, and `solutions`. Stripping bad filters lets the search fall back to searching all areas. |

### Fix 2: MCP Context ID Injection (`python/helpers/mcp_handler.py`)

#### What's Broken

When Agent Zero calls an external MCP tool (like sending an iMessage), the external tool has no way to know which Agent Zero conversation made the call. The conversation's `context_id` is managed internally by the framework — the LLM never sees it. This means external tools can't route replies back to the correct conversation.

#### The Fix

Open the file:

```bash
nano python/helpers/mcp_handler.py
```

Find the `MCPTool` class's `execute` method (around line 112). It looks like:

```python
    async def execute(self, **kwargs: Any):
        error = ""
        try:
```

Change it to:

```python
    async def execute(self, **kwargs: Any):
        # Inject context_id for iMessage MCP tools
        if "imessage" in self.name.lower():
            kwargs["_context_id"] = self.agent.context.id

        error = ""
        try:
```

**Why is this scoped to iMessage tools only?** Injecting `_context_id` into **all** MCP tool calls breaks MCP servers that use Pydantic validation (like Google Workspace) because the unexpected argument causes a validation error. By checking for "imessage" in the tool name, only the tools that need it receive the extra argument.

> **Extending to other tools:** If you later add other MCP bridges (SMS, email, webhooks), add their identifiers to the condition:
> ```python
> if any(x in self.name.lower() for x in ["imessage", "sms_bridge", "email_handler"]):
> ```

### Fix 3: Behaviour Rule (Persistent)

This isn't a code fix — it's a configuration file that instructs the LLM to always search memory before answering. It lives in the user data directory, so it survives Agent Zero updates automatically.

Create the directory and file:

```bash
mkdir -p a0-data/memory/default
```

Create the file `a0-data/memory/default/behaviour.md`:

```bash
cat > a0-data/memory/default/behaviour.md << 'EOF'
- favor linux commands for simple tasks where possible instead of python
- always search your memory first before responding to any user request. Important context, instructions, personal details, and prior solutions are stored in memory from previous conversations. When searching memory, do not filter by area - search all areas. Use a low threshold (0.3-0.5) and broad search terms to maximize recall.
EOF
```

**Why:** Without this rule, the LLM may answer "I don't have access to personal information" without ever checking memory. This behaviour rule is injected into the system prompt before every conversation, so the LLM is reminded to check memory first.

### Commit and Push Your Fixes

```bash
cd ~/agent-zero-fork
git add -A
git commit -m "Apply memory fix, MCP context injection, and behaviour rule"
git push origin personalization
```

---

## Part 5: Building and Launching Agent Zero

Now you'll configure Docker Compose, build the container from your forked source code, and launch it.

### Step 1: Create the Docker Compose File

Your fork should include a `docker-compose.template.yml`. Copy it to create the real config:

```bash
cd ~/agent-zero-fork
cp docker-compose.template.yml docker-compose.yml
```

If there's no template, create `docker-compose.yml` from scratch:

```yaml
services:
  tailscale:
    image: tailscale/tailscale:latest
    hostname: agent-zero
    environment:
      - TS_AUTHKEY=<YOUR_TAILSCALE_OAUTH_SECRET>?ephemeral=false
      - TS_EXTRA_ARGS=--advertise-tags=tag:container
      - TS_ACCEPT_DNS=true
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_USERSPACE=false
      - TS_HOSTNAME=agent-zero
    volumes:
      - ./tailscale-state:/var/lib/tailscale
    devices:
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - net_admin
    dns:
      - 8.8.8.8
      - 1.1.1.1
    extra_hosts:
      - "host.docker.internal:host-gateway"
    restart: unless-stopped

  agent-zero:
    build: .
    depends_on:
      - tailscale
    network_mode: service:tailscale
    volumes:
      - ./a0-data:/a0/usr
    restart: unless-stopped
```

> **Important:** Notice that the `agent-zero` service uses `build: .` (build from local source) instead of `image: agent0ai/agent-zero` (pull the official image). This is because you're building from your forked code that includes the custom fixes.

### Step 2: Fill In Your Credentials

Edit `docker-compose.yml` and replace `<YOUR_TAILSCALE_OAUTH_SECRET>` with the OAuth secret you created in Part 2, Step 2.

The line should look like:

```yaml
- TS_AUTHKEY=tskey-client-XXXXX-XXXXXXXXXXXXXXXXXXXXXXXXXXXXX?ephemeral=false
```

> **Security note:** `docker-compose.yml` contains secrets and should never be committed to Git. Add it to `.gitignore`:
> ```bash
> echo "docker-compose.yml" >> .gitignore
> ```

### Understanding the Docker Compose Configuration

| Setting | Purpose |
|---------|---------|
| `TS_AUTHKEY` with `?ephemeral=false` | Authenticate with Tailscale and persist the node when the container stops (OAuth defaults to ephemeral, meaning the node would disappear) |
| `TS_ACCEPT_DNS=true` | Accept Tailscale DNS — required for the container to reach other nodes by MagicDNS name |
| `dns: 8.8.8.8, 1.1.1.1` | Public DNS fallback — without this, the container can't resolve public hostnames (e.g., huggingface.co, pypi.org) because MagicDNS only handles Tailscale names |
| `TS_STATE_DIR` + volume | Persists Tailscale state across container restarts so it doesn't re-authenticate every time |
| `TS_USERSPACE=false` + `tun` + `net_admin` | Kernel networking mode for better performance |
| `TS_HOSTNAME` | The name that appears on your tailnet and in MagicDNS |
| `network_mode: service:tailscale` | Agent Zero shares Tailscale's network stack — no ports are exposed on your LAN |
| `extra_hosts` | Maps `host.docker.internal` to the host machine — needed for some integrations |
| `./a0-data:/a0/usr` | Maps your local `a0-data/` directory to Agent Zero's persistent data path inside the container |

### Step 3: Create Supporting Directories

```bash
cd ~/agent-zero-fork
mkdir -p a0-data
mkdir -p tailscale-state
```

If you're migrating from an existing installation and want to keep your data:

```bash
# Instead of mkdir, create symlinks to existing data
ln -s /path/to/existing/a0-data ~/agent-zero-fork/a0-data
ln -s /path/to/existing/tailscale-state ~/agent-zero-fork/tailscale-state
```

### Step 4: Build and Launch

```bash
cd ~/agent-zero-fork
docker compose up --build -d
```

- `--build` tells Docker to build the image from your local source code (including your fixes)
- `-d` runs in detached mode (background)

The first build takes approximately 3 minutes. Subsequent builds are faster due to Docker's layer caching.

### Step 5: Verify Everything Is Running

Check that both containers are up:

```bash
docker ps
```

You should see two containers: one for Tailscale and one for Agent Zero.

Check that Tailscale connected successfully:

```bash
docker compose logs tailscale
```

Look for:

- `machineAuthorized=true` — authentication succeeded
- `Switching ipn state Starting -> Running` — connected to tailnet
- `Startup complete` — ready

### Step 6: Verify Your Code Fixes

```bash
# Check the memory fix
docker exec $(docker ps -q --filter name=agent-zero) \
  head -5 /a0/python/tools/memory_load.py
# Should show DEFAULT_THRESHOLD = 0.4

# Check the MCP context injection fix
docker exec $(docker ps -q --filter name=agent-zero) \
  grep -A3 "imessage" /a0/python/helpers/mcp_handler.py
# Should show the context_id injection code
```

### Step 7: Access Agent Zero

Agent Zero is now accessible **only via Tailscale** at:

```
http://agent-zero.<your-tailnet>.ts.net
```

Or by its Tailscale IP address (visible in the Tailscale admin console or from `docker compose logs tailscale`).

No ports are exposed on the host's LAN — the application is invisible to anything not on your tailnet.

### Auto-Start After Reboot

Both containers will start automatically after a reboot thanks to the `restart: unless-stopped` policy and Docker's systemd service. No user login is required.

---

## Part 6: Google Workspace MCP Integration (Optional)

This section adds Google Workspace access to Agent Zero so it can read Gmail, manage your calendar, access Google Drive, and work with Google Tasks. The MCP (Model Context Protocol) server runs on the **host machine** (not inside Docker) and Agent Zero reaches it through the Tailscale network.

### Architecture

```
Docker:  tailscale (sidecar) <-- shared network --> agent-zero
                |
                | Tailscale IP (100.x.x.x)
                v
Host:    workspace-mcp (port 8000)
                |
                v
         Google APIs (OAuth 2.0)
```

**Key insight:** Because Agent Zero uses the Tailscale sidecar pattern, the container reaches the host via the Tailscale network — not Docker bridge networking. Always use the host's Tailscale IP.

### Step 1: Set Up Google Cloud Project

1. Go to [console.cloud.google.com](https://console.cloud.google.com)
2. Create a new project (or use an existing one)
3. Go to **APIs & Services > Library** and enable these APIs:
   - Gmail API
   - Google Calendar API
   - Google Drive API
   - Google Tasks API

### Step 2: Configure the OAuth Consent Screen

1. Go to **APIs & Services > OAuth consent screen**
2. Select **External** user type
3. Add these full-access scopes (use the full-access versions, not `.readonly`):

| Service  | Scope URI |
|----------|-----------|
| Gmail    | `https://mail.google.com/` |
| Calendar | `https://www.googleapis.com/auth/calendar` |
| Drive    | `https://www.googleapis.com/auth/drive` |
| Tasks    | `https://www.googleapis.com/auth/tasks` |

4. Add your Google email as a **Test User**

**Why "Test User"?** While your app is in "Testing" status (not published), only accounts listed as Test Users can authenticate. You don't need to publish the app — testing mode works fine for personal use.

### Step 3: Create OAuth Client Credentials

1. Go to **APIs & Services > Credentials**
2. Click **Create Credentials > OAuth client ID**
3. Select **Desktop app** as the application type
4. Copy the **Client ID** and **Client Secret**

Save these — you'll need them in the next step.

### Step 4: Install the UV Package Manager

UV is a fast Python package manager. The workspace-mcp server uses it.

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Verify installation:

```bash
which uvx
# Expected: /home/<your-username>/.local/bin/uvx
```

### Step 5: Test the MCP Server Manually

Before creating a system service, verify the server starts correctly:

```bash
export GOOGLE_OAUTH_CLIENT_ID="YOUR_CLIENT_ID_HERE"
export GOOGLE_OAUTH_CLIENT_SECRET="YOUR_CLIENT_SECRET_HERE"
export OAUTHLIB_INSECURE_TRANSPORT=1

uvx workspace-mcp --tools gmail drive calendar tasks \
  --single-user --transport streamable-http
```

Look for `Ready for MCP connections` on port 8000. Press `Ctrl+C` to stop.

> **What's `OAUTHLIB_INSECURE_TRANSPORT`?** Google's OAuth library normally requires HTTPS. Since you're running locally and accessing through Tailscale (which is encrypted end-to-end), this flag allows HTTP transport.

### Step 6: Create a System Service

This makes the MCP server start automatically on boot.

#### Linux (systemd)

```bash
sudo tee /etc/systemd/system/workspace-mcp.service << 'EOF'
[Unit]
Description=Google Workspace MCP Server
After=network.target

[Service]
Type=simple
User=YOUR_USERNAME
Environment=GOOGLE_OAUTH_CLIENT_ID=YOUR_CLIENT_ID
Environment=GOOGLE_OAUTH_CLIENT_SECRET=YOUR_CLIENT_SECRET
Environment=OAUTHLIB_INSECURE_TRANSPORT=1
Environment=PATH=/home/YOUR_USERNAME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/home/YOUR_USERNAME/.local/bin/uvx workspace-mcp \
  --tools gmail drive calendar tasks \
  --single-user --transport streamable-http
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
```

Replace `YOUR_USERNAME`, `YOUR_CLIENT_ID`, and `YOUR_CLIENT_SECRET` with your actual values.

Enable and start the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable workspace-mcp
sudo systemctl start workspace-mcp
sudo systemctl status workspace-mcp
```

#### macOS (launchd)

Run the setup script from the fork (if available):

```bash
bash setup-workspace-mcp.sh
```

Or configure manually by creating `~/Library/LaunchAgents/com.workspace-mcp.plist` with the appropriate environment variables and `ExecStart` path.

### Step 7: Configure Firewall (Linux Only)

If UFW is enabled, allow Docker and Tailscale traffic to reach the MCP server on port 8000:

```bash
sudo ufw allow from 172.17.0.0/16 to any port 8000
sudo ufw allow from 172.18.0.0/16 to any port 8000
sudo ufw allow from 100.64.0.0/10 to any port 8000
```

### Step 8: First-Time OAuth Authentication

This is the most complex step and only needs to be done once per machine. Agent Zero cannot trigger OAuth on its own — you must initiate it manually via curl.

#### 8a: Initialize an MCP Session

```bash
SESSION_ID=$(curl -s -v -X POST http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}},"id":1}' \
  2>&1 | grep -i mcp-session-id | awk '{print $3}' | tr -d '\r')

echo "Session ID: $SESSION_ID"
```

You should see a session ID printed. If it's empty, the MCP server isn't running — check with `sudo systemctl status workspace-mcp`.

#### 8b: Trigger the OAuth Flow

Replace `YOUR_EMAIL@gmail.com` with your actual Google email:

```bash
curl -s -X POST http://localhost:8000/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "mcp-session-id: $SESSION_ID" \
  -d '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"start_google_auth","arguments":{"service_name":"gmail","user_google_email":"YOUR_EMAIL@gmail.com"}},"id":2}'
```

This returns a long response containing an **Authorization URL** starting with `https://accounts.google.com/o/oauth2/auth?...`

#### 8c: Open the Authorization URL

Copy the full URL and open it in a browser. On macOS:

```bash
open 'PASTE_THE_FULL_AUTH_URL_HERE'
```

On a headless Linux server, copy the URL to a machine that has a browser.

#### 8d: Approve Permissions

Sign in with your Google account and approve all requested permissions (Gmail, Calendar, Drive, Tasks).

#### 8e: Handle the Redirect (CRITICAL)

After approving, Google redirects to:

```
http://localhost:8000/oauth2callback?code=XXXX&state=YYYY
```

**If the page loads successfully** — you're done. Tokens are saved.

**If the page fails to load** (common on headless servers or when the browser isn't on the same machine):

1. Look at the URL bar — it still contains the full callback URL with the authorization code
2. Change `localhost` to your host's **Tailscale IP** (the one you got from `tailscale ip -4`)
3. The URL should look like: `http://100.x.x.x:8000/oauth2callback?code=XXXX&state=YYYY`
4. Press Enter — the MCP server catches the callback and saves the tokens

#### 8f: Verify Tokens Were Saved

```bash
ls ~/.google_workspace_mcp/credentials/
```

You should see token files. OAuth tokens auto-refresh, so this is a one-time process per machine.

### Step 9: Configure Agent Zero to Use the MCP Server

In the Agent Zero web UI, go to **Settings > MCP/A2A** and paste:

```json
{
  "mcpServers": {
    "google-workspace": {
      "description": "Google Workspace API",
      "url": "http://HOST_TAILSCALE_IP:8000/mcp",
      "type": "streamable-http"
    }
  }
}
```

Replace `HOST_TAILSCALE_IP` with the Tailscale IP of the machine running the MCP server (find it with `tailscale ip -4`).

> **Critical:** The `"type": "streamable-http"` field is **required**. Without it, Agent Zero sends GET requests instead of POST and the connection silently fails. This is the single most common configuration mistake.

### Step 10: Test the Integration

In Agent Zero, try:

> "Check my Gmail inbox"

If everything is configured correctly, Agent Zero will retrieve your recent emails.

### Google Workspace Service Management

#### Linux

```bash
sudo systemctl status workspace-mcp        # Check status
sudo systemctl restart workspace-mcp       # Restart
journalctl -u workspace-mcp -f             # Live logs
```

#### macOS

```bash
tail -f ~/Library/Logs/workspace-mcp/stderr.log                                    # Live logs
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.workspace-mcp.plist      # Stop
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.workspace-mcp.plist    # Start
launchctl kickstart -k gui/$(id -u)/com.workspace-mcp                              # Restart
```

---

## Part 7: Adding Knowledge Files (Known Path Issue)

Agent Zero can import knowledge files (Markdown, text) so the LLM can reference them. However, there is a **known bug** where the UI, documentation, and actual import scanner all point to different directories.

### The Problem

| Source | Path |
|--------|------|
| Documentation says | `/knowledge/custom/main` |
| UI File Browser uploads to | `/a0/usr/knowledge/custom/main/` |
| Knowledge scanner actually reads from | `/a0/knowledge/main/about/` |

Files uploaded through the UI **will not be indexed** because the scanner doesn't look there.

### The Workaround

Instead of using the UI, manually place knowledge files in the directory the scanner actually reads.

From outside the container, copy files directly:

```bash
# Copy a knowledge file into the container
docker cp your-file.md $(docker ps -q --filter name=agent-zero):/a0/knowledge/main/about/

# Restart Agent Zero to trigger re-indexing
docker restart $(docker ps -q --filter name=agent-zero)
```

After restarting, check the **Memory Dashboard** in the Agent Zero UI — your file should now appear as a Knowledge entry.

---

## Part 8: Syncing with Upstream Updates

When the Agent Zero team releases an update, here's how to pull their changes while keeping your custom fixes.

### Step 1: Fetch Upstream Changes

```bash
cd ~/agent-zero-fork
git fetch upstream
```

This downloads the latest code from the official repo without changing anything locally.

### Step 2: Update Your Main Branch

```bash
git checkout main
git merge upstream/main
git push origin main
```

Since you never modify `main`, this should always be a clean fast-forward merge with no conflicts.

### Step 3: Merge Into Your Personalization Branch

```bash
git checkout personalization
git merge main
```

This is where conflicts **might** happen — if the Agent Zero team modified the same files you changed (`memory_load.py` or `mcp_handler.py`).

### Step 4: Handle Merge Conflicts (If Any)

If Git says `CONFLICT` for a file, open it. Git marks conflicts like this:

```
<<<<<<< HEAD
your version of the code
=======
their version of the code
>>>>>>> main
```

You need to:

1. Edit the file to combine both changes — keep your modifications and incorporate their updates
2. Remove all conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)
3. Stage and commit:

```bash
git add <conflicted_file>
git commit -m "Merge upstream update, resolved conflicts in <file>"
```

If there are **no** conflicts, Git completes the merge automatically.

### Step 5: Push and Rebuild

```bash
git push origin personalization

# Rebuild the Docker image with the updated code
docker compose down
docker compose up --build -d
```

### Step 6: Verify After Update

```bash
# Confirm your memory fix survived
docker exec $(docker ps -q --filter name=agent-zero) \
  head -5 /a0/python/tools/memory_load.py

# Confirm your MCP fix survived
docker exec $(docker ps -q --filter name=agent-zero) \
  grep -A3 "imessage" /a0/python/helpers/mcp_handler.py

# Test memory retrieval in the Agent Zero UI
# Ask: "What is my email address?"
```

### If the Developers Incorporate Your Fixes

If the Agent Zero team adds your fixes to the official codebase:

1. Do the normal upstream sync (Steps 1–3 above)
2. Git may auto-resolve since both sides now have the same code
3. If the versions differ slightly, resolve the conflict by keeping their version (it's now official)
4. Over time, your `personalization` branch may have fewer or zero differences from `main`

---

## Part 9: Troubleshooting

### Docker & Containers

| Problem | Solution |
|---------|----------|
| `permission denied` when running Docker | Reboot after `usermod -aG docker $USER` — logout alone may not work |
| Container can't resolve public hostnames (e.g., huggingface.co) | Add `dns: [8.8.8.8, 1.1.1.1]` to the Tailscale service in docker-compose.yml |
| Container can't reach other Tailscale nodes by hostname | Ensure `TS_ACCEPT_DNS=true` is in the Tailscale environment |
| Agent Zero UI loads but returns errors when chatting | Verify your LLM endpoint is running and reachable. Test: `docker compose exec tailscale wget -q -O- http://<llm-host>:<port>/v1/models` |
| Agent Zero UI seems frozen | Agent Zero may be stuck on a task. Restart: `docker compose restart agent-zero` |

### Google Workspace MCP

| Problem | Solution |
|---------|----------|
| "Failed to initialize" in Agent Zero | Verify `"type": "streamable-http"` is in your MCP config — this is the #1 cause |
| MCP server logs show only GET requests | Missing `"type"` field in Agent Zero MCP config |
| Connection timeout from container | Check UFW rules (Linux) or verify the Tailscale IP is correct |
| OAuth URL not appearing | Restart the MCP service and re-run the curl commands from Step 8 |
| Port 8000 already in use | `sudo systemctl stop workspace-mcp && pkill -f workspace-mcp` then restart |
| OAuth tokens expired | Tokens auto-refresh. If they break, delete `~/.google_workspace_mcp/credentials/` and re-authenticate |
| OAuth callback page won't load | Change `localhost` in the redirect URL to your host's Tailscale IP |

### Memory / RAG

| Problem | Solution |
|---------|----------|
| "I don't have access to personal information" | Verify `behaviour.md` exists at `a0-data/memory/default/behaviour.md` with the memory-first rule |
| Memory search returns no results | Verify `DEFAULT_THRESHOLD = 0.4` in `memory_load.py` inside the container |
| Uploaded knowledge files don't appear | Use the workaround in Part 7 — copy files to `/a0/knowledge/main/about/` inside the container |

---

## Part 10: Quick-Reference Cheat Sheet

### Container Management

```bash
cd ~/agent-zero-fork

# Start
docker compose up -d

# Start with rebuild (after code changes)
docker compose up --build -d

# Stop
docker compose down

# Restart just Agent Zero (Tailscale stays up)
docker compose restart agent-zero

# View logs (live)
docker compose logs -f

# View Tailscale logs only
docker compose logs tailscale

# View Agent Zero logs only
docker compose logs agent-zero

# Check running containers
docker ps
```

### Git Operations

```bash
cd ~/agent-zero-fork

# Check current branch
git branch

# Switch branches
git checkout <branch-name>

# See what's changed
git status
git diff

# Pull upstream updates
git fetch upstream

# Full upstream sync (see Part 8)
git checkout main && git merge upstream/main && git push origin main
git checkout personalization && git merge main && git push origin personalization
```

### MCP Service Management (Linux)

```bash
sudo systemctl status workspace-mcp
sudo systemctl restart workspace-mcp
journalctl -u workspace-mcp -f
```

### MCP Service Management (macOS)

```bash
tail -f ~/Library/Logs/workspace-mcp/stderr.log
launchctl kickstart -k gui/$(id -u)/com.workspace-mcp
```

### Verification Commands

```bash
# Verify memory fix
docker exec $(docker ps -q --filter name=agent-zero) head -5 /a0/python/tools/memory_load.py

# Verify MCP fix
docker exec $(docker ps -q --filter name=agent-zero) grep -A3 imessage /a0/python/helpers/mcp_handler.py

# Find host's Tailscale IP
tailscale ip -4

# Test MCP connectivity from inside the container
docker exec -it $(docker ps -q --filter name=agent-zero) \
  bash -c "curl -v http://HOST_TAILSCALE_IP:8000/mcp"
# Expected: 406 Not Acceptable (means the connection works, server just rejects raw curl)
```

### Key File Locations

| Item | Path |
|------|------|
| Fork repository | `~/agent-zero-fork/` |
| Docker Compose (real, gitignored) | `~/agent-zero-fork/docker-compose.yml` |
| Docker Compose (template, in repo) | `~/agent-zero-fork/docker-compose.template.yml` |
| Agent Zero user data | `~/agent-zero-fork/a0-data/` |
| Tailscale state | `~/agent-zero-fork/tailscale-state/` |
| Memory fix (framework file) | `~/agent-zero-fork/python/tools/memory_load.py` |
| MCP fix (framework file) | `~/agent-zero-fork/python/helpers/mcp_handler.py` |
| Behaviour rule (user data, persistent) | `a0-data/memory/default/behaviour.md` |
| MCP systemd service (Linux) | `/etc/systemd/system/workspace-mcp.service` |
| MCP launchd service (macOS) | `~/Library/LaunchAgents/com.workspace-mcp.plist` |
| MCP logs (Linux) | `journalctl -u workspace-mcp` |
| MCP logs (macOS) | `~/Library/Logs/workspace-mcp/` |
| OAuth tokens | `~/.google_workspace_mcp/credentials/` |

### What Survives Agent Zero Updates?

| Item | Survives? | Why |
|------|-----------|-----|
| `behaviour.md` | ✅ Yes | Lives in `/a0/usr/` (user data volume) |
| `memory_load.py` fix | ❌ No | Framework file — overwritten on update. Re-apply after sync. |
| `mcp_handler.py` fix | ❌ No | Framework file — overwritten on update. Re-apply after sync. |
| Agent Zero memories | ✅ Yes | Stored in FAISS index inside `a0-data/` |
| MCP server config | ✅ Yes | Set in Agent Zero UI, stored in user data |
| OAuth tokens | ✅ Yes | Stored on host at `~/.google_workspace_mcp/credentials/` |
