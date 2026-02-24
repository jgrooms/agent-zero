# Google Workspace MCP Server Setup

## Overview

The Google Workspace MCP server (`workspace-mcp`) is a third-party MCP server that gives Agent Zero access to Gmail, Google Calendar, Google Drive, and Google Tasks. It runs on the **host machine** (not inside the Docker container) and Agent Zero reaches it via the host's Tailscale IP.

## Architecture

```
Docker: tailscale (sidecar) <-- shared network --> agent-zero
                |
                | Tailscale IP (100.x.x.x)
                v
Host:    workspace-mcp (port 8000)
                |
                v
         Google APIs (OAuth 2.0)
```

## Prerequisites

Before running the setup script, you need:

### 1. Google Cloud Project

1. Go to [console.cloud.google.com](https://console.cloud.google.com)
2. Create a new project (or use an existing one)
3. Enable these APIs under **APIs & Services > Library**:
   - Gmail API
   - Google Calendar API
   - Google Drive API
   - Google Tasks API

### 2. OAuth Consent Screen

1. Go to **APIs & Services > OAuth consent screen**
2. Select **External** user type
3. Add these scopes (use full access, not `.readonly`):

| Service  | Scope URI                                        |
|----------|--------------------------------------------------|
| Gmail    | `https://mail.google.com/`                       |
| Calendar | `https://www.googleapis.com/auth/calendar`       |
| Drive    | `https://www.googleapis.com/auth/drive`          |
| Tasks    | `https://www.googleapis.com/auth/tasks`          |

4. Add your Google email as a **Test User**

### 3. OAuth Client Credentials

1. Go to **APIs & Services > Credentials**
2. Click **Create Credentials > OAuth client ID**
3. Select **Desktop app**
4. Copy the **Client ID** and **Client Secret** — the setup script will ask for these

## Running the Setup Script

```bash
bash setup-workspace-mcp.sh
```

The script will:
- Install the UV package manager (if not present)
- Test that `workspace-mcp` runs
- Create a system service (systemd on Linux, launchd on macOS)
- Configure firewall rules (Linux only)
- Print instructions for the first-time OAuth flow

## First-Time OAuth Authentication

Since the host may be headless, the OAuth flow requires manual steps:

1. In Agent Zero, send: **"Check my Gmail inbox"**
2. Watch the MCP server logs for an OAuth URL
3. Copy the `https://accounts.google.com/o/oauth2/auth?...` URL
4. Open it in a browser on any machine and sign in to Google
5. Approve all permissions
6. Google redirects to `http://localhost:8000/oauth2callback?code=...`
7. If the page fails to load (because you're on a different machine), change `localhost` in the URL bar to the host's Tailscale IP
8. Press Enter — the MCP server saves the tokens
9. Go back to Agent Zero and try again

OAuth tokens are saved to `~/.google_workspace_mcp/credentials/` and persist across restarts. They auto-refresh, so this is a one-time process.

## Agent Zero MCP Configuration

In Agent Zero UI: **Settings > MCP/A2A**, paste:

```json
{
  "mcpServers": {
    "google-workspace": {
      "description": "Google Workspace API",
      "url": "http://<HOST_TAILSCALE_IP>:8000/mcp",
      "type": "streamable-http"
    }
  }
}
```

**Critical:** The `"type": "streamable-http"` field is required. Without it, Agent Zero sends GET requests instead of POST and the connection fails.

Find your host Tailscale IP with: `tailscale ip -4`

## Service Management

### Linux

```bash
sudo systemctl status workspace-mcp      # status
sudo systemctl start workspace-mcp       # start
sudo systemctl stop workspace-mcp        # stop
sudo systemctl restart workspace-mcp     # restart
journalctl -u workspace-mcp -f           # live logs
```

### macOS

```bash
# logs
tail -f ~/Library/Logs/workspace-mcp/stderr.log

# stop
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.workspace-mcp.plist

# start
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.workspace-mcp.plist

# restart
launchctl kickstart -k gui/$(id -u)/com.workspace-mcp
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Failed to initialize" in Agent Zero | Verify `"type": "streamable-http"` in MCP config |
| MCP server shows only GET requests | Missing `"type"` field in Agent Zero config |
| Connection timeout from container | Check UFW rules (Linux) or verify Tailscale IP |
| OAuth URL not appearing in logs | Restart the MCP service and try again |
| Port 8000 already in use | Stop existing service, check with `lsof -i :8000` |
| OAuth tokens expired | Tokens auto-refresh. Delete `~/.google_workspace_mcp/credentials/` to re-auth |

## File Locations

| Item | Linux | macOS |
|------|-------|-------|
| Service config | `/etc/systemd/system/workspace-mcp.service` | `~/Library/LaunchAgents/com.workspace-mcp.plist` |
| Logs | `journalctl -u workspace-mcp` | `~/Library/Logs/workspace-mcp/` |
| OAuth tokens | `~/.google_workspace_mcp/credentials/` | `~/.google_workspace_mcp/credentials/` |
| UV binary | `~/.local/bin/uvx` | `~/.local/bin/uvx` |
