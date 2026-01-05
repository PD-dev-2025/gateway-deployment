#!/bin/bash

# =============================================================================
# Cassia Infrastructure - Crash Simulator
# =============================================================================
# This script forcefully kills a selected service using SIGKILL (-9).
# This simulates a critical software crash or OOM (Out of Memory) killer event.
#
# Purpose:
# 1. Verify that systemd automatically restarts the service (Resilience).
# 2. Verify that cassia-alert sends a notification to Telegram.
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root:${NC} sudo bash simulate-crash.sh"
    exit 1
fi

echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║             ⚠️  CASSIA CRASH SIMULATOR  ⚠️                       ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "This tool will send a ${BOLD}SIGKILL${NC} signal to a service."
echo -e "The system should detect this as a crash, restart the service,"
echo -e "and send an alert to your Telegram."
echo ""

# Function to get PID
get_pid() {
    systemctl show --property MainPID --value $1
}

# 1. Select Service
echo -e "  ${BOLD}Select service to crash:${NC}"
echo ""
echo "  1) MQTT Broker (cassia-mqtt)"
echo "  2) Orchestrator (cassia-orchestrator)"
echo "  3) Dashboard (cassia-dashboard)"
echo "  4) Cancel"
echo ""
read -p "  Choice: " CHOICE

case $CHOICE in
    1) SERVICE="cassia-mqtt" ;;
    2) SERVICE="cassia-orchestrator" ;;
    3) SERVICE="cassia-dashboard" ;;
    *) echo "Cancelled."; exit 0 ;;
esac

# 2. Verify it's running
PID=$(get_pid $SERVICE)

if [ "$PID" == "0" ] || [ -z "$PID" ]; then
    echo -e "\n  ${RED}Error:${NC} $SERVICE is not running. Start it first with 'cassia-start'."
    exit 1
fi

echo -e "\n  ${BLUE}Target:${NC} $SERVICE"
echo -e "  ${BLUE}PID:${NC}    $PID"
echo ""
read -p "  Are you ready to crash this service? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then exit 0; fi

# 3. Execute Crash
echo -e "\n  ${RED}💥 Sending SIGKILL to PID $PID...${NC}"
kill -9 $PID

# 4. Monitor Recovery
echo -e "  ${YELLOW}⏳ Waiting for systemd reaction...${NC}"
sleep 2

# Check new PID
NEW_PID=$(get_pid $SERVICE)

echo ""
if [ "$NEW_PID" != "0" ] && [ "$NEW_PID" != "$PID" ]; then
    echo -e "  ${GREEN}✅ RESILIENCE VERIFIED!${NC}"
    echo -e "     Service has automatically restarted (New PID: $NEW_PID)."
    echo ""
    echo -e "  ${BLUE}📢 CHECK TELEGRAM:${NC}"
    echo -e "     You should receive an alert momentarily."
    echo -e "     Reason reported should be: ${BOLD}signal${NC} (Exit Code: killed)"
else
    echo -e "  ${RED}❌ RECOVERY FAILED${NC}"
    echo -e "     Service is stopped. Check logs: journalctl -u $SERVICE"
fi
echo ""