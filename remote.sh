#!/bin/bash

# Create Remote Control Service for Ultrasonic Sensor System
# This script creates a systemd service for remote.sh to run in the background

# Exit on any error
set -euo pipefail

# Define terminal colors
readonly _RED=$(tput setaf 1)
readonly _GREEN=$(tput setaf 2)
readonly _YELLOW=$(tput setaf 3)
readonly _BLUE=$(tput setaf 4)
readonly _MAGENTA=$(tput setaf 5)
readonly _CYAN=$(tput setaf 6)
readonly _RESET=$(tput sgr0)

# Configuration
readonly REMOTE_SERVICE_NAME="ultrasonic_remote_control"
readonly REMOTE_SERVICE_FILE="/etc/systemd/system/${REMOTE_SERVICE_NAME}.service"
readonly REMOTE_START_SCRIPT="/home/pi/startRemoteControl.sh"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging functions
log_info() {
    echo "${_MAGENTA}[INFO]${_RESET} $1"
}

log_success() {
    echo "${_GREEN}[SUCCESS]${_RESET} $1"
}

log_warning() {
    echo "${_YELLOW}[WARNING]${_RESET} $1"
}

log_error() {
    echo "${_RED}[ERROR]${_RESET} $1" >&2
}

# Error handler
cleanup_on_error() {
    log_error "Setup failed on line $1"
    log_info "Cleaning up partial installation..."
    
    # Stop and disable service if it was created
    if systemctl is-active --quiet "$REMOTE_SERVICE_NAME" 2>/dev/null; then
        sudo systemctl stop "$REMOTE_SERVICE_NAME"
    fi
    
    if systemctl is-enabled --quiet "$REMOTE_SERVICE_NAME" 2>/dev/null; then
        sudo systemctl disable "$REMOTE_SERVICE_NAME"
    fi
    
    # Remove created files
    [[ -f "$REMOTE_SERVICE_FILE" ]] && sudo rm -f "$REMOTE_SERVICE_FILE"
    [[ -f "$REMOTE_START_SCRIPT" ]] && sudo rm -f "$REMOTE_START_SCRIPT"
    
    exit 1
}

trap 'cleanup_on_error $LINENO' ERR

# Dependency check
check_dependencies() {
    local dependencies=("mosquitto_sub" "mosquitto_pub" "mbpoll" "systemctl")
    local missing_deps=()
    
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Install missing dependencies:"
        log_info "  sudo apt update"
        log_info "  sudo apt install mosquitto-clients mbpoll"
        exit 1
    fi
    
    log_success "All dependencies satisfied"
}

# Create enhanced startup script with debugging
create_remote_startup_script() {
    log_info "Creating remote control startup script"
    
    sudo tee "$REMOTE_START_SCRIPT" > /dev/null << 'EOF'
#!/bin/bash

# Enhanced Remote Control Listener with debugging
# Exit on error
set -euo pipefail

# Define terminal colors
readonly _RED=$(tput setaf 1)
readonly _GREEN=$(tput setaf 2)
readonly _YELLOW=$(tput setaf 3)
readonly _BLUE=$(tput setaf 4)
readonly _RESET=$(tput sgr0)

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly OVERRIDE_FLAG="/tmp/relay_manual_override"
readonly LOG_FILE="/var/log/remote_control.log"

# Logging functions
log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ${_BLUE}[REMOTE]${_RESET} $1"
    echo "$msg"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [REMOTE] $1" >> "$LOG_FILE"
}

log_success() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ${_GREEN}[REMOTE]${_RESET} $1"
    echo "$msg"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [REMOTE] SUCCESS: $1" >> "$LOG_FILE"
}

log_warning() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ${_YELLOW}[REMOTE]${_RESET} $1"
    echo "$msg"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [REMOTE] WARNING: $1" >> "$LOG_FILE"
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ${_RED}[REMOTE]${_RESET} $1"
    echo "$msg" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [REMOTE] ERROR: $1" >> "$LOG_FILE"
}

# Load MQTT configuration with error checking
load_mqtt_config() {
    if [[ -f "${SCRIPT_DIR}/mqtt_service.sh" ]]; then
        log_info "Loading MQTT configuration from ${SCRIPT_DIR}/mqtt_service.sh"
        source "${SCRIPT_DIR}/mqtt_service.sh"
        
        # Check if required variables are set
        local required_vars=("MQTT_BROKER" "MQTT_PORT" "MQTT_TOPIC" "MQTT_QOS")
        local missing_vars=()
        
        for var in "${required_vars[@]}"; do
            if [[ -z "${!var:-}" ]]; then
                missing_vars+=("$var")
            fi
        done
        
        if [[ ${#missing_vars[@]} -gt 0 ]]; then
            log_error "Missing MQTT configuration variables: ${missing_vars[*]}"
            return 1
        fi
        
        log_info "MQTT Config - Broker: $MQTT_BROKER:$MQTT_PORT, Topic: $MQTT_TOPIC, QoS: $MQTT_QOS"
        
        # Test MQTT configuration if test function exists
        if declare -f validate_mqtt_config >/dev/null; then
            if ! validate_mqtt_config; then
                log_error "MQTT configuration validation failed"
                return 1
            fi
        fi
        
        return 0
    else
        log_error "MQTT configuration file not found: ${SCRIPT_DIR}/mqtt_service.sh"
        return 1
    fi
}

# Enhanced MQTT connection test
test_mqtt_connection() {
    log_info "Testing MQTT connection..."
    
    # Test basic connectivity
    local test_topic="${MQTT_TOPIC}/test"
    local test_message="connection_test_$(date +%s)"
    
    # Try to publish a test message
    if timeout 10 mosquitto_pub -h "$MQTT_BROKER" \
                                -p "$MQTT_PORT" \
                                -t "$test_topic" \
                                -m "$test_message" \
                                -q "$MQTT_QOS" 2>/dev/null; then
        log_success "MQTT publish test successful"
    else
        log_error "MQTT publish test failed"
        log_info "Troubleshooting steps:"
        log_info "1. Check if MQTT broker is running: sudo systemctl status mosquitto"
        log_info "2. Check network connectivity: ping $MQTT_BROKER"
        log_info "3. Check if port $MQTT_PORT is open: telnet $MQTT_BROKER $MQTT_PORT"
        log_info "4. Check MQTT broker logs: sudo journalctl -u mosquitto -f"
        return 1
    fi
    
    # Test subscription (with timeout)
    log_info "Testing MQTT subscription..."
    if timeout 5 mosquitto_sub -h "$MQTT_BROKER" \
                               -p "$MQTT_PORT" \
                               -t "$test_topic" \
                               -C 1 \
                               -q "$MQTT_QOS" >/dev/null 2>&1; then
        log_success "MQTT subscription test successful"
        return 0
    else
        log_warning "MQTT subscription test failed (this might be normal if no messages are available)"
        return 0  # Don't fail here as this might be normal
    fi
}

# Function to control relay
control_relay() {
    local action="$1"
    local reason="$2"
    
    log_info "Attempting to control relay: $action ($reason)"
    
    if [[ "$action" == "on" ]]; then
        if timeout 10 mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 1 2>/dev/null; then
            log_success "Relay turned ON ($reason)"
            return 0
        else
            log_error "Failed to turn relay ON - check /dev/ttyAMA4 connection"
            return 1
        fi
    elif [[ "$action" == "off" ]]; then
        if timeout 10 mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 0 2>/dev/null; then
            log_success "Relay turned OFF ($reason)"
            return 0
        else
            log_error "Failed to turn relay OFF - check /dev/ttyAMA4 connection"
            return 1
        fi
    fi
    
    return 1
}

# Function to handle remote commands
process_command() {
    local command="$1"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    log_info "Received command: $command"
    
    case "$command" in
        *'"relay"*:*"on"'*|*"relay":*"on"*)
            echo "manual_on|$timestamp" > "$OVERRIDE_FLAG"
            if control_relay "on" "remote_command"; then
                log_info "Manual override: Relay ON"
            fi
            ;;
        *'"relay"*:*"off"'*|*"relay":*"off"*)
            echo "manual_off|$timestamp" > "$OVERRIDE_FLAG"
            if control_relay "off" "remote_command"; then
                log_info "Manual override: Relay OFF"
            fi
            ;;
        *'"mode"*:*"auto"'*|*"mode":*"auto"*)
            if [[ -f "$OVERRIDE_FLAG" ]]; then
                rm -f "$OVERRIDE_FLAG"
                log_info "Manual override DISABLED - returning to automatic control"
            else
                log_info "Already in automatic mode"
            fi
            ;;
        *'"status"*:*"request"'*|*"status":*"request"*)
            if [[ -f "$OVERRIDE_FLAG" ]]; then
                local override_info=$(cat "$OVERRIDE_FLAG")
                log_info "Status: Manual override active - $override_info"
            else
                log_info "Status: Automatic mode (no override)"
            fi
            ;;
        *)
            log_warning "Unknown command: $command"
            ;;
    esac
}

# Function to handle shutdown gracefully
cleanup() {
    log_info "Shutting down remote control listener..."
    
    # Remove override flag to return to automatic mode
    if [[ -f "$OVERRIDE_FLAG" ]]; then
        rm -f "$OVERRIDE_FLAG"
        log_info "Removed manual override - system returned to automatic mode"
    fi
    
    exit 0
}

trap cleanup SIGTERM SIGINT

# Main listener function with retry logic
start_listener() {
    log_info "Starting remote control listener..."
    
    local retry_count=0
    local max_retries=5
    local retry_delay=10
    
    while [[ $retry_count -lt $max_retries ]]; do
        log_info "Listening for commands on topic: ${MQTT_TOPIC}/control (attempt $((retry_count + 1)))"
        
        # Start MQTT listener with error handling
        if mosquitto_sub -h "$MQTT_BROKER" \
                          -p "$MQTT_PORT" \
                          -t "${MQTT_TOPIC}/control" \
                          -q "$MQTT_QOS" \
                          -k 60 \
                          -R 2>/dev/null | while read -r line; do
            if [[ -n "$line" ]]; then
                process_command "$line"
            fi
        done; then
            log_info "MQTT listener exited normally"
            break
        else
            retry_count=$((retry_count + 1))
            log_error "MQTT listener failed (attempt $retry_count/$max_retries)"
            
            if [[ $retry_count -lt $max_retries ]]; then
                log_info "Retrying in ${retry_delay} seconds..."
                sleep $retry_delay
                
                # Test connection before retry
                if ! test_mqtt_connection; then
                    log_warning "MQTT connection test failed, but will retry anyway"
                fi
            else
                log_error "Max retries reached, giving up"
                exit 1
            fi
        fi
    done
}

# Main execution
main() {
    log_info "Starting remote control service..."
    
    # Ensure log file exists
    sudo touch "$LOG_FILE"
    sudo chown pi:pi "$LOG_FILE"
    
    # Load configuration
    if ! load_mqtt_config; then
        log_error "Failed to load MQTT configuration"
        exit 1
    fi
    
    # Test MQTT connection
    if ! test_mqtt_connection; then
        log_error "MQTT connection test failed"
        log_info "Service will continue but may not work properly"
    fi
    
    # Start the listener
    start_listener
}

# Run main function
main "$@"
EOF

    # Set proper permissions
    sudo chmod 755 "$REMOTE_START_SCRIPT"
    log_success "Remote startup script created at $REMOTE_START_SCRIPT"
}

# Create systemd service for remote control
create_remote_systemd_service() {
    log_info "Creating systemd service: $REMOTE_SERVICE_NAME"
    
    sudo tee "$REMOTE_SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Ultrasonic Sensor Remote Control Service
Documentation=man:ultrasonic-remote(1)
After=network.target mosquitto.service maxbotic_ultrasonic.service
Wants=mosquitto.service
Requires=network.target

[Service]
Type=simple
ExecStart=$REMOTE_START_SCRIPT
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10
StartLimitIntervalSec=60
StartLimitBurst=5
User=pi
Group=pi
WorkingDirectory=/home/pi

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/home/pi /tmp /var/log

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$REMOTE_SERVICE_NAME

[Install]
WantedBy=multi-user.target
EOF

    # Set correct permissions
    sudo chmod 644 "$REMOTE_SERVICE_FILE"
    log_success "Remote systemd service created"
}

# Create MQTT diagnostic script
create_mqtt_diagnostic() {
    log_info "Creating MQTT diagnostic script"
    
    sudo tee "/home/pi/mqtt_diagnostic.sh" > /dev/null << 'EOF'
#!/bin/bash

# MQTT Connection Diagnostic Script
set -euo pipefail

readonly _RED=$(tput setaf 1)
readonly _GREEN=$(tput setaf 2)
readonly _YELLOW=$(tput setaf 3)
readonly _BLUE=$(tput setaf 4)
readonly _RESET=$(tput sgr0)

echo "${_BLUE}=== MQTT Connection Diagnostic ===${_RESET}"
echo

# Load MQTT configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/mqtt_service.sh" ]]; then
    source "${SCRIPT_DIR}/mqtt_service.sh"
    echo "${_GREEN}✓${_RESET} MQTT configuration loaded"
    echo "  Broker: $MQTT_BROKER:$MQTT_PORT"
    echo "  Topic: $MQTT_TOPIC"
    echo "  QoS: $MQTT_QOS"
else
    echo "${_RED}✗${_RESET} MQTT configuration file not found: ${SCRIPT_DIR}/mqtt_service.sh"
    exit 1
fi
echo

# Check mosquitto service
echo "${_BLUE}--- Checking Mosquitto Service ---${_RESET}"
if systemctl is-active --quiet mosquitto 2>/dev/null; then
    echo "${_GREEN}✓${_RESET} Mosquitto service is running"
else
    echo "${_RED}✗${_RESET} Mosquitto service is not running"
    echo "  Start it with: sudo systemctl start mosquitto"
fi
echo

# Check network connectivity
echo "${_BLUE}--- Testing Network Connectivity ---${_RESET}"
if ping -c 1 -W 5 "$MQTT_BROKER" >/dev/null 2>&1; then
    echo "${_GREEN}✓${_RESET} Can ping MQTT broker ($MQTT_BROKER)"
else
    echo "${_RED}✗${_RESET} Cannot ping MQTT broker ($MQTT_BROKER)"
    echo "  Check network connectivity and broker address"
fi

# Check port connectivity
if timeout 5 bash -c "</dev/tcp/$MQTT_BROKER/$MQTT_PORT" 2>/dev/null; then
    echo "${_GREEN}✓${_RESET} Port $MQTT_PORT is open on $MQTT_BROKER"
else
    echo "${_RED}✗${_RESET} Cannot connect to port $MQTT_PORT on $MQTT_BROKER"
    echo "  Check if MQTT broker is listening on this port"
fi
echo

# Test MQTT publish
echo "${_BLUE}--- Testing MQTT Publish ---${_RESET}"
test_message="diagnostic_test_$(date +%s)"
if timeout 10 mosquitto_pub -h "$MQTT_BROKER" \
                            -p "$MQTT_PORT" \
                            -t "${MQTT_TOPIC}/diagnostic" \
                            -m "$test_message" \
                            -q "$MQTT_QOS" 2>/dev/null; then
    echo "${_GREEN}✓${_RESET} MQTT publish successful"
else
    echo "${_RED}✗${_RESET} MQTT publish failed"
    echo "  Check broker configuration and authentication"
fi
echo

# Test MQTT subscribe
echo "${_BLUE}--- Testing MQTT Subscribe ---${_RESET}"
echo "Testing subscription (5 second timeout)..."
if timeout 5 mosquitto_sub -h "$MQTT_BROKER" \
                           -p "$MQTT_PORT" \
                           -t "${MQTT_TOPIC}/diagnostic" \
                           -C 1 \
                           -q "$MQTT_QOS" 2>/dev/null | grep -q "$test_message"; then
    echo "${_GREEN}✓${_RESET} MQTT subscribe successful"
else
    echo "${_YELLOW}!${_RESET} MQTT subscribe test inconclusive (timeout or no matching message)"
    echo "  This might be normal if there are no recent messages"
fi
echo

# Check device file for relay control
echo "${_BLUE}--- Checking Relay Device ---${_RESET}"
if [[ -e /dev/ttyAMA4 ]]; then
    echo "${_GREEN}✓${_RESET} Relay device /dev/ttyAMA4 exists"
    if [[ -r /dev/ttyAMA4 && -w /dev/ttyAMA4 ]]; then
        echo "${_GREEN}✓${_RESET} Relay device is readable/writable"
    else
        echo "${_RED}✗${_RESET} Relay device permissions issue"
        echo "  Check device permissions: ls -la /dev/ttyAMA4"
    fi
else
    echo "${_RED}✗${_RESET} Relay device /dev/ttyAMA4 not found"
    echo "  Check hardware connection and device tree configuration"
fi
echo

# Check service status
echo "${_BLUE}--- Service Status ---${_RESET}"
for service in "mosquitto" "maxbotic_ultrasonic" "ultrasonic_remote_control"; do
    if systemctl list-unit-files | grep -q "^$service.service"; then
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            echo "${_GREEN}✓${_RESET} $service is running"
        else
            echo "${_RED}✗${_RESET} $service is not running"
        fi
    else
        echo "${_YELLOW}!${_RESET} $service not installed"
    fi
done
echo

echo "${_BLUE}=== Diagnostic Complete ===${_RESET}"
echo
echo "If issues persist, check:"
echo "1. Remote service logs: sudo journalctl -u ultrasonic_remote_control -f"
echo "2. Mosquitto logs: sudo journalctl -u mosquitto -f"
echo "3. Network configuration: ip route show"
echo "4. MQTT broker configuration: sudo cat /etc/mosquitto/mosquitto.conf"
EOF

    sudo chmod 755 "/home/pi/mqtt_diagnostic.sh"
    log_success "MQTT diagnostic script created at /home/pi/mqtt_diagnostic.sh"
}

# Setup and start service
setup_remote_service() {
    log_info "Setting up remote control systemd service"
    
    # Reload systemd daemon
    sudo systemctl daemon-reload
    
    # Enable service
    if sudo systemctl enable "$REMOTE_SERVICE_NAME"; then
        log_success "Remote service enabled successfully"
    else
        log_error "Failed to enable remote service"
        exit 1
    fi
    
    # Start service
    if sudo systemctl start "$REMOTE_SERVICE_NAME"; then
        log_success "Remote service started successfully"
    else
        log_warning "Remote service may have failed to start. Check logs for details."
    fi
    
    # Wait a moment and check service status
    sleep 3
    if systemctl is-active --quiet "$REMOTE_SERVICE_NAME"; then
        log_success "Remote service is running successfully"
    else
        log_warning "Remote service is not running. Check status with: systemctl status $REMOTE_SERVICE_NAME"
    fi
}

# Display usage information
show_usage_info() {
    echo
    echo "${_CYAN}=== Remote Control Service Management ===${_RESET}"
    echo "View logs:           ${_YELLOW}sudo journalctl -u $REMOTE_SERVICE_NAME -f${_RESET}"
    echo "Service status:      ${_YELLOW}sudo systemctl status $REMOTE_SERVICE_NAME${_RESET}"
    echo "Start service:       ${_YELLOW}sudo systemctl start $REMOTE_SERVICE_NAME${_RESET}"
    echo "Stop service:        ${_YELLOW}sudo systemctl stop $REMOTE_SERVICE_NAME${_RESET}"
    echo "Restart service:     ${_YELLOW}sudo systemctl restart $REMOTE_SERVICE_NAME${_RESET}"
    echo "Disable service:     ${_YELLOW}sudo systemctl disable $REMOTE_SERVICE_NAME${_RESET}"
    echo
    echo "${_CYAN}=== MQTT Testing Commands ===${_RESET}"
    echo "Run diagnostics:     ${_YELLOW}/home/pi/mqtt_diagnostic.sh${_RESET}"
    echo "Manual test:         ${_YELLOW}mosquitto_pub -h [BROKER] -p [PORT] -t [TOPIC]/control -m '{\"relay\": \"on\"}'${_RESET}"
    echo "Monitor messages:    ${_YELLOW}mosquitto_sub -h [BROKER] -p [PORT] -t [TOPIC]/control${_RESET}"
    echo
    echo "${_CYAN}=== Configuration Files ===${_RESET}"
    echo "Remote startup:      ${_YELLOW}$REMOTE_START_SCRIPT${_RESET}"
    echo "Service file:        ${_YELLOW}$REMOTE_SERVICE_FILE${_RESET}"
    echo "Log file:            ${_YELLOW}/var/log/remote_control.log${_RESET}"
    echo "Override flag:       ${_YELLOW}/tmp/relay_manual_override${_RESET}"
    echo
    echo "${_CYAN}=== Remote Control Commands ===${_RESET}"
    echo "Turn relay ON:       ${_YELLOW}{\"relay\": \"on\"}${_RESET}"
    echo "Turn relay OFF:      ${_YELLOW}{\"relay\": \"off\"}${_RESET}"
    echo "Auto mode:           ${_YELLOW}{\"mode\": \"auto\"}${_RESET}"
    echo "Status request:      ${_YELLOW}{\"status\": \"request\"}${_RESET}"
    echo
}

# Main function
main() {
    log_info "Remote Control service setup started"
    echo
    
    check_dependencies
    create_remote_startup_script
    create_remote_systemd_service
    create_mqtt_diagnostic
    setup_remote_service
    
    log_success "Remote Control service setup completed successfully!"
    
    # Run diagnostics
    log_info "Running MQTT diagnostics..."
    /home/pi/mqtt_diagnostic.sh
    
    show_usage_info
}

# Run main function
main "$@"