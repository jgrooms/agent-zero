#!/bin/bash
#
# Google Workspace MCP Server Setup Script
# Works on Linux (systemd) and macOS (launchd)
#
# Usage: bash setup-workspace-mcp.sh
#
# Prerequisites:
#   - A Google Cloud project with Gmail, Calendar, Drive, and Tasks APIs enabled
#   - An OAuth 2.0 client ID (Desktop app type) from Google Cloud Console
#   - See GOOGLE_WORKSPACE_MCP_SETUP.md for full prerequisites
#

set -e

# Detect OS
OS="$(uname -s)"
case "$OS" in
    Linux*)  PLATFORM="linux";;
    Darwin*) PLATFORM="mac";;
    *)       echo "Unsupported OS: $OS"; exit 1;;
esac

echo "============================================"
echo "Google Workspace MCP Server Setup"
echo "Platform: $PLATFORM"
echo "============================================"
echo ""

# --- Step 1: Collect credentials ---
echo "You'll need your Google OAuth credentials."
echo "Get these from: Google Cloud Console > APIs & Services > Credentials"
echo ""

read -p "Google OAuth Client ID: " CLIENT_ID
if [ -z "$CLIENT_ID" ]; then
    echo "Error: Client ID is required."
    exit 1
fi

read -p "Google OAuth Client Secret: " CLIENT_SECRET
if [ -z "$CLIENT_SECRET" ]; then
    echo "Error: Client Secret is required."
    exit 1
fi

echo ""

# --- Step 2: Install UV package manager ---
echo "Checking for UV package manager..."

if command -v uvx &> /dev/null; then
    echo "UV is already installed at $(which uvx)"
else
    echo "Installing UV..."
    curl -LsSf https://astral.sh/uv/install.sh | sh

    # Source the env so uvx is available in this session
    if [ -f "$HOME/.local/bin/env" ]; then
        source "$HOME/.local/bin/env"
    fi
    export PATH="$HOME/.local/bin:$PATH"

    if ! command -v uvx &> /dev/null; then
        echo "Error: UV installation failed. Check https://docs.astral.sh/uv/"
        exit 1
    fi
    echo "UV installed at $(which uvx)"
fi

echo ""

# --- Step 3: Test MCP server ---
echo "Testing MCP server (will start briefly then stop)..."
echo "If this is the first run, it may download dependencies..."
echo ""

# Quick test - start and kill after a few seconds
timeout 10 env \
    GOOGLE_OAUTH_CLIENT_ID="$CLIENT_ID" \
    GOOGLE_OAUTH_CLIENT_SECRET="$CLIENT_SECRET" \
    OAUTHLIB_INSECURE_TRANSPORT=1 \
    uvx workspace-mcp --tools gmail drive calendar tasks \
        --single-user --transport streamable-http 2>&1 | head -20 || true

echo ""
echo "If you saw 'Ready for MCP connections' above, the server works."
echo ""

# --- Step 4: Install as a service ---
if [ "$PLATFORM" = "linux" ]; then
    # --- Linux: systemd service ---
    echo "Installing systemd service..."

    UVX_PATH=$(which uvx)
    USERNAME=$(whoami)

    sudo tee /etc/systemd/system/workspace-mcp.service > /dev/null << EOF
[Unit]
Description=Google Workspace MCP Server
After=network.target

[Service]
Type=simple
User=$USERNAME
Environment=GOOGLE_OAUTH_CLIENT_ID=$CLIENT_ID
Environment=GOOGLE_OAUTH_CLIENT_SECRET=$CLIENT_SECRET
Environment=OAUTHLIB_INSECURE_TRANSPORT=1
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$UVX_PATH workspace-mcp --tools gmail drive calendar tasks --single-user --transport streamable-http
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable workspace-mcp
    sudo systemctl start workspace-mcp

    echo ""
    echo "Checking service status..."
    sleep 2
    sudo systemctl status workspace-mcp --no-pager -l

elif [ "$PLATFORM" = "mac" ]; then
    # --- macOS: launchd plist ---
    echo "Installing launchd service..."

    UVX_PATH=$(which uvx)
    PLIST_PATH="$HOME/Library/LaunchAgents/com.workspace-mcp.plist"
    LOG_DIR="$HOME/Library/Logs/workspace-mcp"
    mkdir -p "$LOG_DIR"

    cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.workspace-mcp</string>
    <key>ProgramArguments</key>
    <array>
        <string>$UVX_PATH</string>
        <string>workspace-mcp</string>
        <string>--tools</string>
        <string>gmail</string>
        <string>drive</string>
        <string>calendar</string>
        <string>tasks</string>
        <string>--single-user</string>
        <string>--transport</string>
        <string>streamable-http</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>GOOGLE_OAUTH_CLIENT_ID</key>
        <string>$CLIENT_ID</string>
        <key>GOOGLE_OAUTH_CLIENT_SECRET</key>
        <string>$CLIENT_SECRET</string>
        <key>OAUTHLIB_INSECURE_TRANSPORT</key>
        <string>1</string>
        <key>PATH</key>
        <string>$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/stderr.log</string>
</dict>
</plist>
EOF

    # Stop if already running
    launchctl bootout gui/$(id -u) "$PLIST_PATH" 2>/dev/null || true

    # Load and start
    launchctl bootstrap gui/$(id -u) "$PLIST_PATH"

    echo ""
    echo "Checking service status..."
    sleep 2

    if launchctl print gui/$(id -u)/com.workspace-mcp 2>/dev/null | grep -q "state = running"; then
        echo "Service is running."
    else
        echo "Service may still be starting. Check logs:"
        echo "  tail -f $LOG_DIR/stderr.log"
    fi
fi

echo ""

# --- Step 5: Firewall (Linux only) ---
if [ "$PLATFORM" = "linux" ]; then
    echo "Configuring UFW firewall rules..."
    if command -v ufw &> /dev/null; then
        sudo ufw allow from 172.17.0.0/16 to any port 8000 comment "Docker to MCP"
        sudo ufw allow from 172.18.0.0/16 to any port 8000 comment "Docker to MCP"
        sudo ufw allow from 100.64.0.0/10 to any port 8000 comment "Tailscale to MCP"
        echo "Firewall rules added."
    else
        echo "UFW not found. If you have a firewall, allow port 8000 from Docker and Tailscale subnets."
    fi
    echo ""
fi

# --- Step 6: OAuth instructions ---
echo "============================================"
echo "SETUP COMPLETE"
echo "============================================"
echo ""
echo "The MCP server is running on port 8000."
echo ""
echo "NEXT STEP: First-time OAuth authentication"
echo ""
echo "1. In Agent Zero, send: 'Check my Gmail inbox'"
echo "2. Watch the MCP server logs for an OAuth URL:"
if [ "$PLATFORM" = "linux" ]; then
    echo "     journalctl -u workspace-mcp -f"
elif [ "$PLATFORM" = "mac" ]; then
    echo "     tail -f ~/Library/Logs/workspace-mcp/stderr.log"
fi
echo "3. Copy the https://accounts.google.com/o/oauth2/auth?... URL"
echo "4. Open it in a browser and sign in to Google"
echo "5. Approve all permissions"
echo "6. Google redirects to http://localhost:8000/oauth2callback?code=..."
echo "7. If the page fails to load (headless server), change 'localhost'"
echo "   in the URL bar to your host's Tailscale IP, then press Enter"
echo "8. The MCP server saves the tokens — you're done"
echo ""
echo "Agent Zero MCP config (paste into Settings > MCP/A2A):"
echo ""
echo "  {\"mcpServers\":{\"google-workspace\":{\"description\":\"Google Workspace API\",\"url\":\"http://<HOST_TAILSCALE_IP>:8000/mcp\",\"type\":\"streamable-http\"}}}"
echo ""
echo "Replace <HOST_TAILSCALE_IP> with this machine's Tailscale IP:"
if command -v tailscale &> /dev/null; then
    echo "  $(tailscale ip -4 2>/dev/null || echo '<run: tailscale ip -4>')"
fi
echo ""

# --- Service management reference ---
echo "SERVICE MANAGEMENT:"
if [ "$PLATFORM" = "linux" ]; then
    echo "  Status:  sudo systemctl status workspace-mcp"
    echo "  Logs:    journalctl -u workspace-mcp -f"
    echo "  Stop:    sudo systemctl stop workspace-mcp"
    echo "  Start:   sudo systemctl start workspace-mcp"
    echo "  Restart: sudo systemctl restart workspace-mcp"
elif [ "$PLATFORM" = "mac" ]; then
    echo "  Logs:    tail -f ~/Library/Logs/workspace-mcp/stderr.log"
    echo "  Stop:    launchctl bootout gui/$(id -u) $PLIST_PATH"
    echo "  Start:   launchctl bootstrap gui/$(id -u) $PLIST_PATH"
    echo "  Restart: launchctl kickstart -k gui/$(id -u)/com.workspace-mcp"
fi
echo ""

# --- File locations ---
echo "FILE LOCATIONS:"
if [ "$PLATFORM" = "linux" ]; then
    echo "  Service:      /etc/systemd/system/workspace-mcp.service"
    echo "  OAuth tokens: ~/.google_workspace_mcp/credentials/"
elif [ "$PLATFORM" = "mac" ]; then
    echo "  Service:      $PLIST_PATH"
    echo "  Logs:         $LOG_DIR/"
    echo "  OAuth tokens: ~/.google_workspace_mcp/credentials/"
fi
echo ""
