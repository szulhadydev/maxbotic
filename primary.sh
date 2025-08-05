#!/bin/bash

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
readonly SERVICE_NAME="maxbotic_ultrasonic"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly START_SCRIPT="/home/pi/startUltrasonic.sh"
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
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        sudo systemctl stop "$SERVICE_NAME"
    fi
    
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        sudo systemctl disable "$SERVICE_NAME"
    fi
    
    # Remove created files
    [[ -f "$SERVICE_FILE" ]] && sudo rm -f "$SERVICE_FILE"
    [[ -f "$START_SCRIPT" ]] && sudo rm -f "$START_SCRIPT"
    
    exit 1
}

trap 'cleanup_on_error $LINENO' ERR

# Dependency check
check_dependencies() {
    local dependencies=("bc" "mosquitto_pub" "mosquitto_sub" "systemctl")
    local missing_deps=()
    
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Please install missing dependencies and retry"
        exit 1
    fi
    
    log_success "All dependencies satisfied"
}

# Load and validate MQTT configuration
load_mqtt_config() {
    if [[ -f "${SCRIPT_DIR}/mqtt_service.sh" ]]; then
        # shellcheck source=mqtt_service.sh
        source "${SCRIPT_DIR}/mqtt_service.sh"
        
        if ! validate_mqtt_config; then
            log_error "MQTT configuration validation failed"
            exit 1
        fi
    else
        log_error "MQTT configuration file not found: ${SCRIPT_DIR}/mqtt_service.sh"
        exit 1
    fi
}

# Create startup script
create_startup_script() {
    log_info "Creating ultrasonic sensor startup script"
    
    # Create the startup script with proper error handling
    sudo tee "$START_SCRIPT" > /dev/null << 'EOF'
#!/bin/bash

# Exit on error
set -euo pipefail

# Load MQTT configurations
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/mqtt_service.sh" ]]; then
    source "${SCRIPT_DIR}/mqtt_service.sh"
else
    echo "ERROR: MQTT configuration file not found" >&2
    exit 1
fi

# Validate configuration
if ! validate_mqtt_config; then
    echo "ERROR: MQTT configuration validation failed" >&2
    exit 1
fi

# Function to handle shutdown gracefully
cleanup() {
    echo "Shutting down ultrasonic sensor service..."
    # Kill all child processes
    pkill -P $$ || true
    exit 0
}

trap cleanup SIGTERM SIGINT

# Check if sensor device exists
if [[ ! -d "$SENSOR_DIR" ]]; then
    echo "ERROR: Sensor device not found at $SENSOR_DIR" >&2
    exit 1
fi

# Ensure output directory exists
OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
[[ ! -d "$OUTPUT_DIR" ]] && mkdir -p "$OUTPUT_DIR"

echo "Starting ultrasonic sensor monitoring..."
echo "Sensor: $SENSOR_DIR"
echo "MQTT Broker: $MQTT_BROKER:$MQTT_PORT"
echo "Publish Topic: $MQTT_TOPIC"
echo "Subscribe Topic: $MQTT_SUBSCRIBE_TOPIC"
echo "Measurement interval: ${MEASUREMENT_INTERVAL}s"

# Function to control relay based on MQTT messages
control_relay() {
    local message="$1"
    case "$message" in
        "ON"|"1")
            echo "$(date): Received command to turn relay ON"
            mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 1
            ;;
        "OFF"|"0")
            echo "$(date): Received command to turn relay OFF"
            mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 0
            ;;
        *)
            echo "$(date): Received unknown relay command: $message"
            ;;
    esac
}

(
    while true; do
        echo "$(date): Starting MQTT subscription to $MQTT_SUBSCRIBE_TOPIC..."
        if ! mosquitto_sub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "$MQTT_SUBSCRIBE_TOPIC" -q "$MQTT_QOS" -i "$MQTT_CLIENT_ID"_sub; then
            echo "$(date): ERROR: Failed to subscribe to $MQTT_SUBSCRIBE_TOPIC" >&2
            sleep 5
            continue
        fi
        
        mosquitto_sub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "$MQTT_SUBSCRIBE_TOPIC" -q "$MQTT_QOS" -i "$MQTT_CLIENT_ID"_sub | \
        while read -r message; do
            echo "$(date): Received message on $MQTT_SUBSCRIBE_TOPIC: $message"
            control_relay "$message"
        done
        
        echo "$(date): MQTT subscription ended, reconnecting in 5 seconds..."
        sleep 5
    done
) &

# Continuous measurement loop
while true; do
    if RAW_VALUE=$(cat "$SENSOR_DIR/in_voltage1_raw" 2>/dev/null); then
        # Calculate distance using bc for floating point arithmetic
        ULTRASONIC_DISTANCE=$(echo "scale=3; ($RAW_VALUE * 10) / 1303" | bc)
        
        # Create JSON payload with timestamp
        TIMESTAMP=$(date +"%Y-%m-%dT%H:%M:%S.%3N")
        JSON_PAYLOAD=$(cat << JSON_EOF
{
    "distance": $ULTRASONIC_DISTANCE,
    "unit": "meters",
    "timestamp": "$TIMESTAMP",
    "sensor_id": "$MQTT_CLIENT_ID",
    "raw_value": $RAW_VALUE
}
JSON_EOF
)
        
        # Save data locally with timestamp
        echo "$TIMESTAMP,$ULTRASONIC_DISTANCE" >> "$OUTPUT_FILE"

        # Publish to MQTT broker with error handling
        if mosquitto_pub -h "$MQTT_BROKER" \
                        -p "$MQTT_PORT" \
                        -t "$MQTT_TOPIC" \
                        -q "$MQTT_QOS" \
                        -m "$JSON_PAYLOAD" 2>/dev/null; then
            echo "$(date): Distance: ${ULTRASONIC_DISTANCE}m (published successfully)"
        else
            echo "$(date): Distance: ${ULTRASONIC_DISTANCE}m (MQTT publish failed)" >&2
        fi
        
    else
        echo "$(date): ERROR: Failed to read sensor data from $SENSOR_DIR/in_voltage1_raw" >&2
    fi
    
    sleep "$MEASUREMENT_INTERVAL"
done
EOF

    # Set proper permissions
    sudo chmod 755 "$START_SCRIPT"
    log_success "Startup script created at $START_SCRIPT"
}

# Create systemd service
create_systemd_service() {
    log_info "Creating systemd service: $SERVICE_NAME"
    
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Maxbotic Ultrasonic Sensor Service
Documentation=man:ultrasonic-sensor(1)
After=network.target mosquitto.service
Wants=mosquitto.service

[Service]
Type=simple
ExecStart=$START_SCRIPT
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=3
User=pi
Group=pi
WorkingDirectory=/home/pi

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/home/pi

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

[Install]
WantedBy=multi-user.target
EOF

    # Set correct permissions
    sudo chmod 644 "$SERVICE_FILE"
    log_success "Systemd service created"
}

# Setup and start service
setup_service() {
    log_info "Setting up systemd service"
    
    # Reload systemd daemon
    sudo systemctl daemon-reload
    
    # Enable and start service
    if sudo systemctl enable "$SERVICE_NAME"; then
        log_success "Service enabled successfully"
    else
        log_error "Failed to enable service"
        exit 1
    fi
    
    if sudo systemctl start "$SERVICE_NAME"; then
        log_success "Service started successfully"
    else
        log_warning "Service may have failed to start. Check logs for details."
    fi
    
    # Wait a moment and check service status
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_success "Service is running successfully"
    else
        log_warning "Service is not running. Check status with: systemctl status $SERVICE_NAME"
    fi
}

# Display usage information
show_usage_info() {
    echo
    echo "${_CYAN}=== Service Management Commands ===${_RESET}"
    echo "View logs:           ${_YELLOW}sudo journalctl -u $SERVICE_NAME -f${_RESET}"
    echo "Service status:      ${_YELLOW}sudo systemctl status $SERVICE_NAME${_RESET}"
    echo "Start service:       ${_YELLOW}sudo systemctl start $SERVICE_NAME${_RESET}"
    echo "Stop service:        ${_YELLOW}sudo systemctl stop $SERVICE_NAME${_RESET}"
    echo "Restart service:     ${_YELLOW}sudo systemctl restart $SERVICE_NAME${_RESET}"
    echo "Disable service:     ${_YELLOW}sudo systemctl disable $SERVICE_NAME${_RESET}"
    echo
    echo "${_CYAN}=== Configuration Files ===${_RESET}"
    echo "Startup script:      ${_YELLOW}$START_SCRIPT${_RESET}"
    echo "Service file:        ${_YELLOW}$SERVICE_FILE${_RESET}"
    echo "MQTT config:         ${_YELLOW}${SCRIPT_DIR}/mqtt_service.sh${_RESET}"
    echo
    echo "${_CYAN}=== MQTT Control ===${_RESET}"
    echo "To control the relay, publish to:"
    echo "${_YELLOW}mosquitto_pub -h [broker] -t [subscribe_topic] -m \"ON\"${_RESET}"
    echo "${_YELLOW}mosquitto_pub -h [broker] -t [subscribe_topic] -m \"OFF\"${_RESET}"
    echo
}

# Main function
main() {
    log_info "Maxbotic Ultrasonic Sensor service setup started"
    echo
    
    check_dependencies
    load_mqtt_config
    
    # Test MQTT connection before proceeding
    if ! test_mqtt_connection; then
        log_warning "MQTT connection test failed. Service will be created but may not work properly."
        log_info "Please verify MQTT broker configuration in mqtt_service.sh"
    fi
    
    create_startup_script
    create_systemd_service
    setup_service
    
    log_success "Maxbotic Ultrasonic service setup completed successfully!"
    show_usage_info
}

# Run main function
main "$@"