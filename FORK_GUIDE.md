# Agent Zero Fork Management Guide

## Overview

This repo is a personal fork of [Agent Zero](https://github.com/agent0ai/agent-zero) with custom modifications to fix memory/RAG retrieval and enable bidirectional iMessage routing via MCP.

**Branch structure:**
- `main` — clean mirror of upstream Agent Zero. Never modify this branch directly.
- `personalization` — your customizations on top of main. This is what you build and run.

**Remotes:**
- `origin` — your fork (`git@github.com:jgrooms/agent-zero.git`)
- `upstream` — official Agent Zero (`https://github.com/agent0ai/agent-zero.git`)

---

## What's Changed

### 1. Memory/RAG Fix (`python/tools/memory_load.py`)

- Default similarity threshold lowered from 0.7 to 0.4
- Threshold capped at 0.5 (prevents LLM from overriding with too-strict values)
- Invalid area filter sanitization (strips hallucinated area names like "personal", "credentials")

**Why:** Qwen3-Coder skips memory search or passes bad parameters to FAISS. These guardrails ensure memory retrieval actually works.

### 2. MCP Context ID Injection (`python/helpers/mcp_handler.py`)

- Injects `AgentContext.id` into MCP tool kwargs for iMessage tools
- Scoped to tools with "imessage" in the name to avoid breaking Pydantic-validated MCP servers

**Why:** Enables bidirectional iMessage routing — external tools can route replies back to the correct Agent Zero conversation.

### 3. Behaviour Rule (`a0-data/memory/default/behaviour.md`)

- Forces LLM to search memory before responding to any user request
- Lives in user data volume, survives all updates automatically

---

## Setup on a New Machine

### Prerequisites

- Docker and Docker Compose installed
- Tailscale installed and connected
- Git installed
- SSH key added to GitHub (see below)

### 1. Configure Git

```bash
git config --global user.name "jgrooms"
git config --global user.email "jason@grooms.org"
```

### 2. Set Up SSH Key for GitHub

If you don't have an SSH key:
```bash
ssh-keygen -t ed25519 -C "jason@grooms.org"
```

Add the public key to GitHub:
```bash
cat ~/.ssh/id_ed25519.pub
```
Copy the output, go to https://github.com/settings/keys, click "New SSH key", paste it.

Test:
```bash
ssh -T git@github.com
```

### 3. Clone the Fork

```bash
cd ~
git clone git@github.com:jgrooms/agent-zero.git agent-zero-fork
cd agent-zero-fork
```

### 4. Set Up Remotes

```bash
git remote add upstream https://github.com/agent0ai/agent-zero.git
```

Verify:
```bash
git remote -v
# origin    git@github.com:jgrooms/agent-zero.git (fetch/push)
# upstream  https://github.com/agent0ai/agent-zero.git (fetch/push)
```

### 5. Switch to the Personalization Branch

```bash
git checkout personalization
```

### 6. Create docker-compose.yml

```bash
cp docker-compose.template.yml docker-compose.yml
```

Edit `docker-compose.yml` and fill in:
- `TS_AUTHKEY` — your Tailscale auth key
- `host.docker.internal` IP — your host's Docker bridge or Tailscale IP

### 7. Create Data Directory

```bash
mkdir -p a0-data
```

Or if migrating from an existing install, symlink to existing data:
```bash
ln -s /path/to/existing/a0-data ~/agent-zero-fork/a0-data
```

### 8. Create Tailscale State Directory

```bash
mkdir -p tailscale-state
```

Or symlink to existing:
```bash
ln -s /path/to/existing/tailscale-state ~/agent-zero-fork/tailscale-state
```

### 9. Build and Run

```bash
docker compose up --build -d
```

First build takes ~3 minutes. Subsequent builds are faster due to Docker layer caching.

### 10. Verify

```bash
# Check containers are running
docker ps

# Verify memory fix is in place
docker exec <container_name> sed -n '1,5p' /a0/python/tools/memory_load.py
# Should show DEFAULT_THRESHOLD = 0.4

# Verify MCP fix is in place
docker exec <container_name> sed -n '111,116p' /a0/python/helpers/mcp_handler.py
# Should show the iMessage context_id injection
```

---

## Syncing with Upstream Updates

When the Agent Zero team releases an update, here's how to pull their changes while keeping your modifications.

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

This brings your `main` branch up to date with the official release, and pushes it to your GitHub fork. Since you never modify `main`, this should always be a clean fast-forward with no conflicts.

### Step 3: Merge Into Personalization

```bash
git checkout personalization
git merge main
```

This is where conflicts might happen. If the Agent Zero team modified the same files you changed (`memory_load.py` or `mcp_handler.py`), Git will flag a conflict.

### Step 4: Handle Conflicts (If Any)

If Git says "CONFLICT" for a file:

1. Open the file — Git marks conflicts like this:
   ```
   <<<<<<< HEAD
   your version of the code
   =======
   their version of the code
   >>>>>>> main
   ```

2. Edit the file to combine both changes (keep your modifications, incorporate their updates)

3. Remove the conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)

4. Stage and commit:
   ```bash
   git add <conflicted_file>
   git commit -m "Merge upstream update, resolved conflicts in <file>"
   ```

If there are NO conflicts, Git completes the merge automatically.

### Step 5: Push and Rebuild

```bash
git push origin personalization
```

Then rebuild the Docker image:

```bash
docker compose down
docker compose up --build -d
```

### Step 6: Verify After Update

```bash
# Check your changes survived
docker exec <container_name> sed -n '1,5p' /a0/python/tools/memory_load.py
docker exec <container_name> grep -A3 "imessage" /a0/python/helpers/mcp_handler.py

# Test memory retrieval
# Open Agent Zero in browser and ask "what is my email address?"
```

---

## If the Developers Incorporate Your Changes

If the Agent Zero team adds your fixes to the official codebase:

1. Do the normal upstream sync (Steps 1-3 above)
2. Git may auto-resolve since both sides now have the same code
3. If your version and theirs differ slightly, resolve the conflict by keeping their version (since it's now official)
4. Once confirmed working, your `personalization` branch may have fewer or zero differences from `main`

---

## Quick Reference

| Task | Command |
|------|---------|
| Check current branch | `git branch` |
| Switch branches | `git checkout <branch>` |
| See what's changed | `git status` / `git diff` |
| Fetch upstream | `git fetch upstream` |
| Rebuild after changes | `docker compose down && docker compose up --build -d` |
| View container logs | `docker compose logs -f` |
| Check running containers | `docker ps` |
| Verify memory fix | `docker exec <container> head -5 /a0/python/tools/memory_load.py` |
| Verify MCP fix | `docker exec <container> grep -A3 imessage /a0/python/helpers/mcp_handler.py` |

---

## File Locations

| Item | Path |
|------|------|
| Fork repo | `~/agent-zero-fork/` |
| Docker Compose (real, gitignored) | `~/agent-zero-fork/docker-compose.yml` |
| Docker Compose (template, in repo) | `~/agent-zero-fork/docker-compose.template.yml` |
| Agent Zero user data | `~/agent-zero-fork/a0-data/` (symlink) |
| Tailscale state | `~/agent-zero-fork/tailscale-state/` (symlink) |
| Memory fix | `~/agent-zero-fork/python/tools/memory_load.py` |
| MCP fix | `~/agent-zero-fork/python/helpers/mcp_handler.py` |
| Behaviour rules | `a0-data/memory/default/behaviour.md` |
