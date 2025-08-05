#!/bin/bash

# Quick fix for ultrasonic remote control service
# This addresses the tput terminal color issue

set -euo pipefail

SERVICE_NAME="ultrasonic_remote_control"
START_SCRIPT="/home/pi/startRemoteControl.sh"

echo "=== Quick Fix for Remote Control Service ==="
echo

# Create a simplified startup script without terminal colors
echo "Creating fixed startup script..."

sudo tee "$START_SCRIPT" > /dev/null << 'EOF'
#!/bin/bash

# Remote Control Listener - Fixed version without terminal colors
set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly OVERRIDE_FLAG="/tmp/relay_manual_override"
readonly LOG_FILE="/var/log/remote_control.log"

# Simple logging functions (no colors)
log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [REMOTE] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [REMOTE] ERROR: $1"
    echo "$msg" >&2
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# Load MQTT configuration with error checking
load_mqtt_config() {
    if [[ -f "${SCRIPT_DIR}/mqtt_service.sh" ]]; then
        log_info "Loading MQTT configuration from ${SCRIPT_DIR}/mqtt_service.sh"
        
        # Source with error handling
        if source "${SCRIPT_DIR}/mqtt_service.sh" 2>/dev/null; then
            # Check if required variables are set
            if [[ -z "${MQTT_BROKER:-}" ]] || [[ -z "${MQTT_PORT:-}" ]] || [[ -z "${MQTT_TOPIC:-}" ]]; then
                log_error "Required MQTT variables not set in configuration"
                return 1
            fi
            log_info "MQTT Config loaded - Broker: $MQTT_BROKER:$MQTT_PORT, Topic: $MQTT_TOPIC"
            return 0
        else
            log_error "Failed to load MQTT configuration"
            return 1
        fi
    else
        log_error "MQTT configuration file not found: ${SCRIPT_DIR}/mqtt_service.sh"
        return 1
    fi
}

# Test MQTT connection
test_mqtt_connection() {
    log_info "Testing MQTT connection..."
    
    local test_topic="${MQTT_TOPIC}/test"
    local test_message="connection_test_$(date +%s)"
    
    if timeout 10 mosquitto_pub -h "$MQTT_BROKER" \
                                -p "$MQTT_PORT" \
                                -t "$test_topic" \
                                -m "$test_message" \
                                -q "${MQTT_QOS:-1}" 2>/dev/null; then
        log_info "MQTT connection test successful"
        return 0
    else
        log_error "MQTT connection test failed"
        return 1
    fi
}

# Function to control relay
control_relay() {
    local action="$1"
    local reason="$2"
    
    log_info "Controlling relay: $action ($reason)"
    
    if [[ "$action" == "on" ]]; then
        if timeout 10 mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 1 2>/dev/null; then
            log_info "Relay turned ON ($reason)"
            return 0
        else
            log_error "Failed to turn relay ON"
            return 1
        fi
    elif [[ "$action" == "off" ]]; then
        if timeout 10 mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 0 2>/dev/null; then
            log_info "Relay turned OFF ($reason)"
            return 0
        else
            log_error "Failed to turn relay OFF"
            return 1
        fi
    fi
    return 1
}

# Function to handle remote commands
process_command() {
    local command="$1"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    log_info "Processing command: $command"
    
    case "$command" in
        *"relay"*"on"*)
            echo "manual_on|$timestamp" > "$OVERRIDE_FLAG"
            control_relay "on" "remote_command"
            ;;
        *"relay"*"off"*)
            echo "manual_off|$timestamp" > "$OVERRIDE_FLAG"
            control_relay "off" "remote_command"
            ;;
        *"mode"*"auto"*)
            if [[ -f "$OVERRIDE_FLAG" ]]; then
                rm -f "$OVERRIDE_FLAG"
                log_info "Manual override disabled - returning to automatic control"
            else
                log_info "Already in automatic mode"
            fi
            ;;
        *"status"*"request"*)
            if [[ -f "$OVERRIDE_FLAG" ]]; then
                local override_info=$(cat "$OVERRIDE_FLAG" 2>/dev/null || echo "unknown")
                log_info "Status: Manual override active - $override_info"
            else
                log_info "Status: Automatic mode (no override)"
            fi
            ;;
        *)
            log_info "Unknown command received: $command"
            ;;
    esac
}

# Function to handle shutdown gracefully
cleanup() {
    log_info "Shutting down remote control listener..."
    
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
    local max_retries=3
    local retry_delay=15
    
    while [[ $retry_count -lt $max_retries ]]; do
        log_info "Listening on topic: ${MQTT_TOPIC}/control (attempt $((retry_count + 1)))"
        
        # Start MQTT listener
        if mosquitto_sub -h "$MQTT_BROKER" \
                          -p "$MQTT_PORT" \
                          -t "${MQTT_TOPIC}/control" \
                          -q "${MQTT_QOS:-1}" \
                          -k 60 2>/dev/null | while IFS= read -r line; do
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
            else
                log_error "Max retries reached, giving up"
                exit 1
            fi
        fi
    done
}

# Main execution
main() {
    log_info "Remote control service starting..."
    
    # Ensure log directory exists
    sudo mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    sudo touch "$LOG_FILE" 2>/dev/null || touch "$LOG_FILE" 2>/dev/null || true
    
    # Load configuration
    if ! load_mqtt_config; then
        log_error "Failed to load MQTT configuration, exiting"
        exit 1
    fi
    
    # Test MQTT connection
    if ! test_mqtt_connection; then
        log_error "MQTT connection test failed, but continuing anyway"
    fi
    
    # Start the listener
    start_listener
}

# Run main function
main "$@"
EOF

# Set proper permissions
sudo chmod 755 "$START_SCRIPT"
echo "✓ Fixed startup script created"

# Reload systemd and restart service
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Restarting service..."
sudo systemctl restart "$SERVICE_NAME" 2>/dev/null || true

# Wait a moment and check status
sleep 3

echo
echo "=== Service Status ==="
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "✓ Service is now running successfully!"
    echo
    echo "View logs with: sudo journalctl -u $SERVICE_NAME -f"
    echo "Test with: mosquitto_pub -h localhost -p 1883 -t sensors/ultrasonic/control -m '{\"status\": \"request\"}'"
else
    echo "✗ Service is still not running"
    echo
    echo "Check detailed status:"
    sudo systemctl status "$SERVICE_NAME" --no-pager || true
    echo
    echo "Check recent logs:"
    sudo journalctl -u "$SERVICE_NAME" -n 20 --no-pager || true
fi