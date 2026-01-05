#!/bin/bash

# =============================================================================
# Cassia Infrastructure - Setup Script v2.6 (Final Stable)
# =============================================================================
# This script manages the complete Cassia infrastructure:
#   - MQTT Broker (Mosquitto) with custom config
#   - Go BLE Orchestrator
#   - Gateway Dashboard
#
# CHANGES (v2.6):
#   - FIX: Corrected 'lsof' crash when ports are already free.
#   - FIX: Moved dependency installation to start of script.
#   - UI: Fixed ASCII banner alignment.
#
# Usage: sudo bash cassia-setup-v2.sh
# =============================================================================

set -e
set -o pipefail

# --- Configuration ---
INSTALL_DIR="/opt/cassia"
LOG_DIR="/var/log/cassia"
ALERT_CONFIG="$INSTALL_DIR/alert_config.env"
ALERT_LOG="$LOG_DIR/crash_history.log"

# Service names
MQTT_SERVICE="cassia-mqtt"
ORCHESTRATOR_SERVICE="cassia-orchestrator"
DASHBOARD_SERVICE="cassia-dashboard"
STARTUP_SERVICE="cassia-startup"

# All services list
ALL_SERVICES="$MQTT_SERVICE $ORCHESTRATOR_SERVICE $DASHBOARD_SERVICE $STARTUP_SERVICE"

# Ports
MQTT_PORT=1883
ORCHESTRATOR_PORT=8083
DASHBOARD_PORT=8080

# --- GitHub Repository Configuration ---
DASHBOARD_REPO="PD-dev-2025/gateway-dashboard-release"
ORCHESTRATOR_REPO="PD-dev-2025/cassia-releases"

# Asset Patterns
DASHBOARD_ASSET_PATTERN="linux_amd64.zip" 
ORCHESTRATOR_ASSET_PATTERN="Linux_x86_64.tar.gz"

# Binary names (for process hunting)
ORCHESTRATOR_BIN_NAME="go-ble-orchestrator"
DASHBOARD_BIN_NAME="gateway-dashboard"

# Helper commands
HELPER_COMMANDS="cassia-start cassia-stop cassia-restart cassia-status cassia-logs cassia-files view-mqtt view-app view-dashboard logs-mqtt logs-app logs-dashboard cassia-alert"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# =============================================================================
# Output Functions
# =============================================================================

print_banner() {
    clear
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                                  ║${NC}"
    echo -e "${CYAN}║            ${BOLD}CASSIA INFRASTRUCTURE v2.6 - FINAL STABLE${NC}${CYAN}             ║${NC}"
    echo -e "${CYAN}║                                                                  ║${NC}"
    echo -e "${CYAN}║     Features: Port Cleaning | Config Editing | Deep Uninstall    ║${NC}"
    echo -e "${CYAN}║                                                                  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  ${BOLD}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_step() { echo -e "  ${CYAN}▸${NC} $1"; }
print_success() { echo -e "  ${GREEN}✓${NC} $1"; }
print_warning() { echo -e "  ${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "  ${RED}✗${NC} $1"; }
print_info() { echo -e "  ${BLUE}ℹ${NC} $1"; }

# =============================================================================
# Safety Checks
# =============================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root! (sudo bash $0)"
        exit 1
    fi
}

check_internet() {
    print_step "Checking internet connection..."
    if ! ping -c 1 github.com &> /dev/null; then
        print_error "No internet connection detected!"
        exit 1
    fi
    print_success "Internet connection OK"
}

# =============================================================================
# Dependencies
# =============================================================================

install_dependencies() {
    print_header "Step 1: Installing Dependencies"
    apt-get update -qq 2>/dev/null
    
    PKGS="mosquitto mosquitto-clients curl wget unzip jq lsof nano"
    for PKG in $PKGS; do
        if ! dpkg -l | grep -q "^ii  $PKG "; then
            echo -n "    Installing $PKG... "
            apt-get install -y "$PKG" > /dev/null 2>&1
            echo -e "${GREEN}Done${NC}"
        else
            echo -e "    $PKG: ${GREEN}Installed${NC}"
        fi
    done
}

# =============================================================================
# NUCLEAR PORT CLEANUP (The Port Conflict Fix)
# =============================================================================

nuclear_cleanup() {
    print_header "System Cleanup (Releasing Ports)"
    
    # 1. Stop Systemd Services
    print_step "Stopping managed services..."
    for SERVICE in $ALL_SERVICES; do
        if systemctl is-active --quiet $SERVICE 2>/dev/null; then
            systemctl stop $SERVICE 2>/dev/null || true
        fi
        systemctl disable $SERVICE 2>/dev/null || true
    done

    # 2. Kill Processes by Name (Catching unmanaged/zombie processes)
    print_step "Hunting lingering processes..."
    pkill -9 -f "$ORCHESTRATOR_BIN_NAME" 2>/dev/null || true
    pkill -9 -f "$DASHBOARD_BIN_NAME" 2>/dev/null || true
    pkill -9 -f "mosquitto" 2>/dev/null || true

    # 3. Kill Processes by Port (The Ultimate Fail-safe)
    print_step "Force-releasing ports (1883, 8083, 8080)..."
    
    for PORT in $MQTT_PORT $ORCHESTRATOR_PORT $DASHBOARD_PORT; do
        # BUG FIX: Added "|| true" to prevent script exit if lsof finds no process (exit code 1)
        PIDS=$(lsof -t -i :$PORT 2>/dev/null || true)
        
        if [ -n "$PIDS" ]; then
            echo -e "    ${YELLOW}Found process on port $PORT (PID: $PIDS) - KILLING${NC}"
            echo "$PIDS" | xargs -r kill -9 2>/dev/null || true
        fi
    done
    
    # 4. Cleanup Systemd Files
    rm -f /etc/systemd/system/cassia-*.service
    systemctl daemon-reload
    
    print_success "System cleanup complete. Ports are free."
}

# =============================================================================
# Setup Telegram Config
# =============================================================================

configure_alerts() {
    print_header "Step 2: Configure Telegram Alerts"
    
    if [ -f "$ALERT_CONFIG" ]; then
        source "$ALERT_CONFIG"
        echo -e "  ${GREEN}✓ Found existing configuration:${NC}"
        echo -e "    Hospital: $HOSPITAL_NAME"
        echo -e "    Region:   $HOSPITAL_REGION"
        echo ""
        read -p "  Do you want to re-configure this? (y/N): " RECONF
        if [[ ! "$RECONF" =~ ^[Yy]$ ]]; then return; fi
    fi
    
    echo -e "  ${BOLD}Remote Alert Configuration${NC}"
    read -p "  🏥 Enter Hospital Name (e.g., General Hospital): " HOSP_NAME
    read -p "  📍 Enter Region/City (e.g., London): " HOSP_REGION
    
    [ -z "$HOSP_NAME" ] && HOSP_NAME="Unknown Hospital"
    [ -z "$HOSP_REGION" ] && HOSP_REGION="Unknown Region"
    
    echo ""
    echo -e "  ${BOLD}Telegram Credentials${NC}"
    read -p "  🤖 Enter Telegram Bot Token: " BOT_TOKEN
    read -p "  🆔 Enter Telegram Chat ID: " CHAT_ID
    
    if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
        echo ""
        print_step "Sending test message..."
        TEST_MSG="✅ *CASSIA INSTALLATION TEST*%0A%0A🏥 Hospital: $HOSP_NAME%0A📍 Region: $HOSP_REGION%0A🚀 Setup is proceeding..."
        
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            -d parse_mode="Markdown" \
            -d text="$TEST_MSG")
            
        if [ "$HTTP_STATUS" -eq 200 ]; then
            print_success "Test message sent!"
        else
            print_error "Failed to send test message (HTTP $HTTP_STATUS)."
            read -p "    Retry configuration? (y/n): " RETRY
            if [[ "$RETRY" =~ ^[Yy]$ ]]; then
                configure_alerts
                return
            fi
        fi
    fi
    
    mkdir -p "$INSTALL_DIR"
    cat > "$ALERT_CONFIG" <<EOF
HOSPITAL_NAME="$HOSP_NAME"
HOSPITAL_REGION="$HOSP_REGION"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
EOF
    chmod 600 "$ALERT_CONFIG"
}

# =============================================================================
# Robust Downloader
# =============================================================================

download_release() {
    local REPO=$1
    local PATTERN=$2
    local OUTPUT_FILE=$3
    local COMPONENT_NAME=$4

    print_step "Fetching release info for $COMPONENT_NAME..."

    local API_URL="https://api.github.com/repos/$REPO/releases/latest"
    local HTTP_RESPONSE
    local HTTP_BODY
    local HTTP_STATUS
    
    HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -H "Accept: application/vnd.github.v3+json" -H "User-Agent: CassiaInstaller/2.6" "$API_URL")
    HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)
    HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')

    if [ "$HTTP_STATUS" -ne 200 ]; then
        print_error "GitHub API Request Failed (HTTP $HTTP_STATUS)"
        echo -e "    ${YELLOW}Response:${NC} $HTTP_BODY"
        return 1
    fi

    local DOWNLOAD_URL
    DOWNLOAD_URL=$(echo "$HTTP_BODY" | jq -r ".assets[] | select(.name | contains(\"$PATTERN\")) | .browser_download_url" | head -1)

    if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
        print_error "No asset found matching pattern: '$PATTERN'"
        return 1
    fi

    print_success "Found latest release: $(basename "$DOWNLOAD_URL")"
    print_step "Downloading..."
    curl -L -H "User-Agent: CassiaInstaller/2.6" "$DOWNLOAD_URL" -o "$OUTPUT_FILE" --progress-bar

    if [ ! -f "$OUTPUT_FILE" ] || [ ! -s "$OUTPUT_FILE" ]; then
        print_error "Download failed."
        return 1
    fi

    print_success "Download complete."
    return 0
}

# =============================================================================
# Installation & Configuration
# =============================================================================

setup_system() {
    print_header "Step 3: Preparing System"
    mkdir -p "$INSTALL_DIR"/{orchestrator,dashboard} "$LOG_DIR" "/var/lib/mosquitto"
    
    # --- Download Components ---
    print_header "Step 4: Downloading Components"
    
    if download_release "$DASHBOARD_REPO" "$DASHBOARD_ASSET_PATTERN" "/tmp/dash.zip" "Gateway Dashboard"; then
        unzip -o /tmp/dash.zip -d "$INSTALL_DIR/dashboard" >/dev/null
        chmod +x "$INSTALL_DIR/dashboard/"*dashboard*
    else
        print_error "CRITICAL: Dashboard download failed."
        exit 1
    fi
    
    echo ""
    if download_release "$ORCHESTRATOR_REPO" "$ORCHESTRATOR_ASSET_PATTERN" "/tmp/orch.tar.gz" "Orchestrator"; then
        tar -xzf /tmp/orch.tar.gz -C "$INSTALL_DIR/orchestrator"
        chmod +x "$INSTALL_DIR/orchestrator/"*orchestrator*
    else
        print_error "CRITICAL: Orchestrator download failed."
        exit 1
    fi

    # --- Config ---
    print_header "Step 5: Configuration"
    
    # MQTT
    cat > "$INSTALL_DIR/mqtt.conf" <<EOF
listener 1883
persistence true
persistence_location /var/lib/mosquitto/
log_dest file /var/log/cassia/mqtt.log
allow_anonymous true
EOF

    # Orchestrator
    ORCH_CONF=$(find "$INSTALL_DIR/orchestrator" -name "config.json" | head -1)
    if [ -f "$ORCH_CONF" ]; then
        cp "$ORCH_CONF" "$ORCH_CONF.bak"
        jq '.mqtt.broker = "tcp://localhost:1883"' "$ORCH_CONF" > "$ORCH_CONF.tmp" && mv "$ORCH_CONF.tmp" "$ORCH_CONF"
        
        echo ""
        print_info "Orchestrator Config ($ORCH_CONF)"
        read -p "    Edit Orchestrator config now? (y/N): " EDIT_ORCH
        if [[ "$EDIT_ORCH" =~ ^[Yy]$ ]]; then nano "$ORCH_CONF"; fi
    fi
    
    # Dashboard
    DASH_EX=$(find "$INSTALL_DIR/dashboard" -name "config.json.example" | head -1)
    DASH_CONF="$INSTALL_DIR/dashboard/config.json"
    
    if [ -f "$DASH_EX" ] && [ ! -f "$DASH_CONF" ]; then
        cp "$DASH_EX" "$DASH_CONF"
        print_info "Created config.json from example."
    fi
    
    if [ -f "$DASH_CONF" ]; then
        echo ""
        print_info "Dashboard Config ($DASH_CONF)"
        read -p "    Edit Dashboard config now? (y/N): " EDIT_DASH
        if [[ "$EDIT_DASH" =~ ^[Yy]$ ]]; then nano "$DASH_CONF"; fi
    fi
}

# =============================================================================
# Alert System
# =============================================================================

create_alert_system() {
    print_header "Step 6: Installing Alert System"
    
    cat > /usr/local/bin/cassia-alert << 'EOF'
#!/bin/bash
source /opt/cassia/alert_config.env
SERVICE_NAME=$1
LOG_FILE="/var/log/cassia/crash_history.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if [ "$SERVICE_RESULT" == "success" ] || [ -z "$BOT_TOKEN" ]; then exit 0; fi

echo "[$TIMESTAMP] FAILURE: $SERVICE_NAME ($SERVICE_RESULT)" >> $LOG_FILE

MSG="🚨 *CASSIA SYSTEM ALERT* 🚨%0A%0A🏥 *Hospital:* $HOSPITAL_NAME%0A📍 *Region:* $HOSPITAL_REGION%0A⚙️ *Service:* $SERVICE_NAME%0A⚠️ *Status:* CRASHED / RESTARTING%0A🔍 *Reason:* $SERVICE_RESULT (Exit: $EXIT_CODE)"

curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="$MSG" > /dev/null
EOF
    chmod +x /usr/local/bin/cassia-alert
    touch "$ALERT_LOG" && chmod 666 "$ALERT_LOG"
    print_success "Alert system installed"
}

# =============================================================================
# Services & Interactive Commands
# =============================================================================

create_services() {
    print_header "Step 7: Registering Services"
    
    ORCH_BIN=$(find "$INSTALL_DIR/orchestrator" -type f -executable ! -name "*.sh" | head -1)
    DASH_BIN=$(find "$INSTALL_DIR/dashboard" -type f -executable ! -name "*.sh" | head -1)
    [ -z "$ORCH_BIN" ] && { print_error "Orchestrator binary missing"; exit 1; }
    [ -z "$DASH_BIN" ] && { print_error "Dashboard binary missing"; exit 1; }
    
    create_svc() {
        NAME=$1; DESC=$2; EXEC=$3; DIR=$4; AFTER=$5
        cat > "/etc/systemd/system/$NAME.service" <<EOF
[Unit]
Description=$DESC
After=network.target $AFTER
[Service]
Type=simple
WorkingDirectory=$DIR
ExecStart=$EXEC
Restart=always
RestartSec=5
StartLimitIntervalSec=0
ExecStopPost=/usr/local/bin/cassia-alert %n
StandardOutput=append:$LOG_DIR/${NAME#cassia-}.log
StandardError=append:$LOG_DIR/${NAME#cassia-}.log
[Install]
WantedBy=multi-user.target
EOF
    }
    
    create_svc "$MQTT_SERVICE" "Cassia MQTT" "/usr/sbin/mosquitto -c $INSTALL_DIR/mqtt.conf" "/" ""
    create_svc "$ORCHESTRATOR_SERVICE" "Cassia Orchestrator" "$ORCH_BIN" "$(dirname "$ORCH_BIN")" "$MQTT_SERVICE.service"
    create_svc "$DASHBOARD_SERVICE" "Cassia Dashboard" "$DASH_BIN" "$(dirname "$DASH_BIN")" "$MQTT_SERVICE.service $ORCHESTRATOR_SERVICE.service"
    
    # Startup Override
    cat > "/etc/systemd/system/$STARTUP_SERVICE.service" <<EOF
[Unit]
Description=Cassia Startup
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cassia-start
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    print_success "Services registered"
}

create_commands() {
    # --- Interactive Start Script ---
    cat > /usr/local/bin/cassia-start << 'EOF'
#!/bin/bash
CYAN='\033[0;36m'; NC='\033[0m'
echo ""
echo -e "${CYAN}Starting Cassia Infrastructure...${NC}"
echo ""
read -p "Do you want to edit configuration files first? (y/N): " EDIT
if [[ "$EDIT" =~ ^[Yy]$ ]]; then
    ORCH_CFG=$(find /opt/cassia/orchestrator -name "config.json" | head -1)
    DASH_CFG=$(find /opt/cassia/dashboard -name "config.json" | head -1)
    [ -f "$ORCH_CFG" ] && nano "$ORCH_CFG"
    [ -f "$DASH_CFG" ] && nano "$DASH_CFG"
fi
systemctl start cassia-mqtt cassia-orchestrator cassia-dashboard
echo -e "${CYAN}Services started.${NC}"
EOF

    # --- Interactive Restart Script ---
    cat > /usr/local/bin/cassia-restart << 'EOF'
#!/bin/bash
CYAN='\033[0;36m'; NC='\033[0m'
echo ""
echo -e "${CYAN}Restarting Cassia Infrastructure...${NC}"
echo ""
read -p "Do you want to edit configuration files first? (y/N): " EDIT
if [[ "$EDIT" =~ ^[Yy]$ ]]; then
    ORCH_CFG=$(find /opt/cassia/orchestrator -name "config.json" | head -1)
    DASH_CFG=$(find /opt/cassia/dashboard -name "config.json" | head -1)
    [ -f "$ORCH_CFG" ] && nano "$ORCH_CFG"
    [ -f "$DASH_CFG" ] && nano "$DASH_CFG"
fi
systemctl restart cassia-mqtt cassia-orchestrator cassia-dashboard
echo -e "${CYAN}Services restarted.${NC}"
EOF

    # --- Stop Script ---
    echo -e "#!/bin/bash\nsystemctl stop cassia-dashboard cassia-orchestrator cassia-mqtt\necho 'Services stopped.'" > /usr/local/bin/cassia-stop
    
    # --- Status Script ---
    cat > /usr/local/bin/cassia-status << 'EOF'
#!/bin/bash
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
echo ""
echo "--- Service Status ---"
for SVC in cassia-mqtt cassia-orchestrator cassia-dashboard; do
    if systemctl is-active --quiet $SVC; then
        echo -e "  $SVC: ${GREEN}RUNNING${NC}"
    else
        echo -e "  $SVC: ${RED}STOPPED${NC}"
    fi
done
echo ""
source /opt/cassia/alert_config.env 2>/dev/null
echo "--- Configured for ---"
echo "  Hospital: $HOSPITAL_NAME"
echo "  Region:   $HOSPITAL_REGION"
echo ""
EOF

    # Logs
    echo "tail -f $LOG_DIR/mqtt.log" > /usr/local/bin/view-mqtt
    echo "tail -f $LOG_DIR/orchestrator.log" > /usr/local/bin/view-app
    echo "tail -f $LOG_DIR/dashboard.log" > /usr/local/bin/view-dashboard

    chmod +x /usr/local/bin/cassia-* /usr/local/bin/view-*
}

# =============================================================================
# Uninstall
# =============================================================================

uninstall_cassia() {
    print_banner
    echo -e "  ${MAGENTA}${BOLD}UNINSTALL MODE${NC}"
    echo "  This will stop all services, release ports, and delete files."
    read -p "  Are you sure? (yes/no): " CONFIRM
    [[ "$CONFIRM" != "yes" ]] && exit 0
    
    # Clean ports first
    install_dependencies # Ensure lsof is present
    nuclear_cleanup
    
    rm -rf "$INSTALL_DIR"
    for CMD in $HELPER_COMMANDS; do rm -f "/usr/local/bin/$CMD"; done
    
    echo ""
    read -p "  Do you want to DELETE log files ($LOG_DIR)? (y/N): " RM_LOGS
    if [[ "$RM_LOGS" =~ ^[Yy]$ ]]; then
        rm -rf "$LOG_DIR"
        print_success "Logs deleted."
    else
        print_info "Logs preserved in $LOG_DIR."
    fi
    
    print_success "Uninstallation Complete"
}

# =============================================================================
# Main
# =============================================================================

install_cassia() {
    print_banner
    check_internet
    
    # 1. Install Dependencies FIRST (Critical for lsof)
    install_dependencies
    
    # 2. Configure Alerts
    configure_alerts
    
    # 3. Clean Ports (Now safe as lsof is installed)
    nuclear_cleanup
    
    # 4. Proceed with Setup
    setup_system
    create_alert_system
    create_services
    create_commands
    
    print_header "Step 8: Launching"
    systemctl enable $MQTT_SERVICE $ORCHESTRATOR_SERVICE $DASHBOARD_SERVICE $STARTUP_SERVICE >/dev/null 2>&1
    systemctl start $MQTT_SERVICE $ORCHESTRATOR_SERVICE $DASHBOARD_SERVICE
    
    print_success "Installation Complete!"
    echo ""
    echo -e "  Dashboard: http://$(hostname -I | awk '{print $1}'):8080"
    echo -e "  Test Alerts: Configured for $HOSPITAL_NAME"
    echo ""
}

show_menu() {
    print_banner
    echo "  1) Install / Reinstall"
    echo "  2) Uninstall"
    echo "  3) Exit"
    echo ""
    read -p "  Choice: " OPT
    case $OPT in
        1) install_cassia ;;
        2) uninstall_cassia ;;
        3) exit 0 ;;
        *) exit 1 ;;
    esac
}

check_root
show_menu