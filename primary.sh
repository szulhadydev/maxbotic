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


# Initialize mode (default to AUTO if not set)
CURRENT_MODE="${CURRENT_MODE:-AUTO}"
# echo "Initialized mode: $CURRENT_MODE"

# THRESHOLD_PERSIST_FILE="/home/pi/thresholds.conf"

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
    

    # DISTANCE_THRESHOLD=${DISTANCE_THRESHOLD:-1.0}  # fallback to 1.0 meters
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



# Default mode is AUTO
echo "AUTO" > /tmp/current_mode
CURRENT_MODE=$(cat /tmp/current_mode 2>/dev/null || echo "AUTO")

# Default mode is AUTO
echo "5.0" > /tmp/current_threshold
CURRENT_THRESHOLD=$(cat /tmp/current_threshold 2>/dev/null || echo "5.0")


# Initialize thresholds for 4 levels
echo "8.0"  > /tmp/threshold_normal
echo "5.0"  > /tmp/threshold_warning
echo "3.0"  > /tmp/threshold_alert
echo "2.0"  > /tmp/threshold_danger
echo "5.0"  > /tmp/distance_debug


# --- Load thresholds from persistent file or initialize defaults ---
THRESHOLD_PERSIST_FILE="/home/pi/thresholds.conf"

if [[ -f "$THRESHOLD_PERSIST_FILE" ]]; then
  echo "$(date): Loading thresholds from $THRESHOLD_PERSIST_FILE"
  source "$THRESHOLD_PERSIST_FILE"
else
  echo "$(date): Threshold config not found, creating defaults..."
  echo "THRESHOLD_NORMAL=8.0" > "$THRESHOLD_PERSIST_FILE"
  echo "THRESHOLD_WARNING=5.0" >> "$THRESHOLD_PERSIST_FILE"
  echo "THRESHOLD_ALERT=3.0" >> "$THRESHOLD_PERSIST_FILE"
  echo "THRESHOLD_DANGER=2.0" >> "$THRESHOLD_PERSIST_FILE"
fi

# Write values into /tmp for runtime usage
echo "$THRESHOLD_NORMAL"  > /tmp/threshold_normal
echo "$THRESHOLD_WARNING" > /tmp/threshold_warning
echo "$THRESHOLD_ALERT"   > /tmp/threshold_alert
echo "$THRESHOLD_DANGER"  > /tmp/threshold_danger
echo "5.0" > /tmp/distance_debug

# State tracking for relay logic
PREVIOUS_STATE="UNKNOWN"

echo "Sensor: $SENSOR_DIR"
echo "MQTT Broker: $MQTT_BROKER:$MQTT_PORT"
echo "Publish Topic: $MQTT_TOPIC"
echo "Subscribe Topic: $MQTT_SUBSCRIBE_TOPIC"
echo "Measurement interval: ${MEASUREMENT_INTERVAL}s"

# Function to control relay based on MQTT messages
# Function to control relay based on MQTT messages (for MANUAL mode)
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

# --- Relay Pattern Controller for multi-thresholds ---
# --- Relay Pattern Controller for multi-thresholds ---
control_relay_pattern() {
    local level="$1"
    local relay_cmd_on="mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 1"
    local relay_cmd_off="mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 0"


    case "$level" in
        "NORMAL"|"SAFE")
            echo "$(date): Siren OFF (NORMAL/SAFE)"
            $relay_cmd_off
            ;;

        "WARNING")
            echo "$(date): Starting WARNING siren pattern..."
            (
                while true; do
                    echo "$(date): [WARNING] Siren ON (10s)"
                    $relay_cmd_on
                    sleep 10

                    echo "$(date): [WARNING] Siren OFF (5s)"
                    $relay_cmd_off
                    sleep 5

                    echo "$(date): [WARNING] Siren ON (10s)"
                    $relay_cmd_on
                    sleep 10

                    echo "$(date): [WARNING] Siren OFF (30s)"
                    $relay_cmd_off
                    sleep 30
                done
            ) &
            ;;

        "ALERT")
            echo "$(date): Starting ALERT siren pattern..."
            (
                while true; do
                    echo "$(date): [ALERT] Siren ON (10s)"
                    $relay_cmd_on
                    sleep 10

                    echo "$(date): [ALERT] Siren OFF (5s)"
                    $relay_cmd_off
                    sleep 5

                    echo "$(date): [ALERT] Siren ON (10s)"
                    $relay_cmd_on
                    sleep 10

                    echo "$(date): [ALERT] Siren OFF (1min)"
                    $relay_cmd_off
                    sleep 60
                done
            ) &
           
            ;;

        "DANGER")
            echo "$(date): Siren ON continuously (DANGER)"
            $relay_cmd_on
            ;;

        *)
            echo "$(date): Unknown level '$level' — Siren OFF"
            $relay_cmd_off
            ;;
    esac
}



# Start MQTT subscription in background with retry on failure
# Start MQTT subscription in background for control and mode
# Start MQTT subscription in background for control and mode with retry
(
    until mosquitto_sub -h "$MQTT_BROKER" -p "$MQTT_PORT" \
        -t "$MQTT_SUBSCRIBE_TOPIC" \
        -t "$MQTT_MODE_TOPIC" \
        -t "$MQTT_THRESHOLD_TOPIC" \
        -t "$MQTT_THRESHOLD_NORMAL_TOPIC" \
        -t "$MQTT_THRESHOLD_WARNING_TOPIC" \
        -t "$MQTT_THRESHOLD_ALERT_TOPIC" \
        -t "$MQTT_THRESHOLD_DANGER_TOPIC" \
        -t "$MQTT_DISTANCE_DEBUG_TOPIC" \
        -t "$MQTT_REBOOT_TOPIC" \
        -q "$MQTT_QOS" -v | while read -r full_message; do

        topic=$(cut -d' ' -f1 <<< "$full_message")
        message=$(cut -d' ' -f2- <<< "$full_message")

        if [[ "$topic" == "$MQTT_MODE_TOPIC" ]]; then
          if [[ "$message" =~ ^(AUTO|MANUAL)$ ]]; then
              echo "$message" > /tmp/current_mode
              echo "$(date): Switched mode to: $message"

              if [[ "$message" == "MANUAL" ]]; then
                  # Stop any running siren pattern when switching to MANUAL
                  local pattern_pid_file="/tmp/siren_pattern.pid"
                  if [[ -f "$pattern_pid_file" ]]; then
                      local old_pid
                      old_pid=$(cat "$pattern_pid_file")
                      if ps -p "$old_pid" > /dev/null 2>&1; then
                          echo "$(date): Stopping AUTO mode siren pattern (PID $old_pid)"
                          kill "$old_pid" 2>/dev/null
                      fi
                      rm -f "$pattern_pid_file"
                  fi
                  echo "$(date): MANUAL mode activated - siren patterns stopped"
                  
              elif [[ "$message" == "AUTO" ]]; then
                  # Immediately evaluate and trigger appropriate pattern using current distance from /tmp/distance_debug
                  THRESHOLD_DANGER=$(cat /tmp/threshold_danger 2>/dev/null || echo "2.0")
                  THRESHOLD_ALERT=$(cat /tmp/threshold_alert 2>/dev/null || echo "3.0")
                  THRESHOLD_WARNING=$(cat /tmp/threshold_warning 2>/dev/null || echo "5.0")
                  THRESHOLD_NORMAL=$(cat /tmp/threshold_normal 2>/dev/null || echo "8.0")
                  ULTRASONIC_DISTANCE=$(cat /tmp/distance_debug 2>/dev/null || echo "5.0")

                  if (( $(echo "$ULTRASONIC_DISTANCE <= $THRESHOLD_DANGER" | bc -l) )); then
                      LEVEL="DANGER"
                  elif (( $(echo "$ULTRASONIC_DISTANCE <= $THRESHOLD_ALERT" | bc -l) )); then
                      LEVEL="ALERT"
                  elif (( $(echo "$ULTRASONIC_DISTANCE <= $THRESHOLD_WARNING" | bc -l) )); then
                      LEVEL="WARNING"
                  elif (( $(echo "$ULTRASONIC_DISTANCE <= $THRESHOLD_NORMAL" | bc -l) )); then
                      LEVEL="NORMAL"
                  else
                      LEVEL="SAFE"
                  fi

                  echo "$(date): AUTO mode activated - triggering $LEVEL pattern (distance: $ULTRASONIC_DISTANCE)"
                  control_relay_pattern "$LEVEL"
                  echo "$LEVEL" > /tmp/previous_state
              fi
          else
              echo "$(date): Invalid mode received: $message"
          fi
          if [[ "$message" =~ ^(AUTO|MANUAL)$ ]]; then
              echo "$message" > /tmp/current_mode
              echo "$(date): Switched mode to: $message"

              if [[ "$message" == "MANUAL" ]]; then
                  # Stop any running siren pattern when switching to MANUAL
                  local pattern_pid_file="/tmp/siren_pattern.pid"
                  if [[ -f "$pattern_pid_file" ]]; then
                      local old_pid
                      old_pid=$(cat "$pattern_pid_file")
                      if ps -p "$old_pid" > /dev/null 2>&1; then
                          echo "$(date): Stopping AUTO mode siren pattern (PID $old_pid)"
                          kill "$old_pid" 2>/dev/null
                      fi
                      rm -f "$pattern_pid_file"
                  fi
                  echo "$(date): MANUAL mode activated - siren patterns stopped"
                  
              elif [[ "$message" == "AUTO" ]]; then
                  # Immediately evaluate and trigger appropriate pattern
                  THRESHOLD_DANGER=$(cat /tmp/threshold_danger 2>/dev/null || echo "2.0")
                  THRESHOLD_ALERT=$(cat /tmp/threshold_alert 2>/dev/null || echo "3.0")
                  THRESHOLD_WARNING=$(cat /tmp/threshold_warning 2>/dev/null || echo "5.0")
                  THRESHOLD_NORMAL=$(cat /tmp/threshold_normal 2>/dev/null || echo "8.0")
                  ULTRASONIC_DISTANCE=$(cat /tmp/distance_debug 2>/dev/null || echo "5.0")

                  if (( $(echo "$ULTRASONIC_DISTANCE <= $THRESHOLD_DANGER" | bc -l) )); then
                      LEVEL="DANGER"
                  elif (( $(echo "$ULTRASONIC_DISTANCE <= $THRESHOLD_ALERT" | bc -l) )); then
                      LEVEL="ALERT"
                  elif (( $(echo "$ULTRASONIC_DISTANCE <= $THRESHOLD_WARNING" | bc -l) )); then
                      LEVEL="WARNING"
                  elif (( $(echo "$ULTRASONIC_DISTANCE <= $THRESHOLD_NORMAL" | bc -l) )); then
                      LEVEL="NORMAL"
                  else
                      LEVEL="SAFE"
                  fi

                  echo "$(date): AUTO mode activated - triggering $LEVEL pattern"
                  control_relay_pattern "$LEVEL"
                  echo "$LEVEL" > /tmp/previous_state
              fi
          else
              echo "$(date): Invalid mode received: $message"
          fi
        elif [[ "$topic" == "$MQTT_SUBSCRIBE_TOPIC" ]]; then
            CURRENT_MODE=$(cat /tmp/current_mode 2>/dev/null || echo "AUTO")
            if [[ "$CURRENT_MODE" == "MANUAL" ]]; then
                echo "$(date): MANUAL mode - received relay command: $message"
                control_relay "$message"
            else
                echo "$(date): AUTO mode - ignoring manual command: $message"
            fi
        elif [[ "$topic" == "$MQTT_THRESHOLD_NORMAL_TOPIC" ]]; then
          echo "$message" > /tmp/threshold_normal
          sed -i "s/^THRESHOLD_NORMAL=.*/THRESHOLD_NORMAL=$message/" "$THRESHOLD_PERSIST_FILE"
          echo "$(date): NORMAL threshold updated to $message (saved)"
        elif [[ "$topic" == "$MQTT_THRESHOLD_WARNING_TOPIC" ]]; then
          echo "$message" > /tmp/threshold_warning
          sed -i "s/^THRESHOLD_WARNING=.*/THRESHOLD_WARNING=$message/" "$THRESHOLD_PERSIST_FILE"
          echo "$(date): WARNING threshold updated to $message (saved)"
        elif [[ "$topic" == "$MQTT_THRESHOLD_ALERT_TOPIC" ]]; then
          echo "$message" > /tmp/threshold_alert
          sed -i "s/^THRESHOLD_ALERT=.*/THRESHOLD_ALERT=$message/" "$THRESHOLD_PERSIST_FILE"
          echo "$(date): ALERT threshold updated to $message (saved)"
        elif [[ "$topic" == "$MQTT_THRESHOLD_DANGER_TOPIC" ]]; then
          echo "$message" > /tmp/threshold_danger
          sed -i "s/^THRESHOLD_DANGER=.*/THRESHOLD_DANGER=$message/" "$THRESHOLD_PERSIST_FILE"
          echo "$(date): DANGER threshold updated to $message (saved)"
        elif [[ "$topic" == "$MQTT_DISTANCE_DEBUG_TOPIC" ]]; then
          echo "$message" > /tmp/distance_debug

        # elif [[ "$topic" == "$MQTT_THRESHOLD_TOPIC" ]]; then
        #     if [[ "$message" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        #         echo "$message" > /tmp/current_threshold
        #         echo "$(date): Threshold updated to: $message"
        #     else
        #         echo "$(date): Invalid threshold received: $message"
        #     fi
        elif [[ "$topic" == "$MQTT_REBOOT_TOPIC" ]]; then
            if [[ "$message" == "1" || "$message" == "REBOOT" ]]; then
                echo "$(date): Reboot command received via MQTT"
                mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 1 /dev/ttyAMA4 -- 1
            else
                echo "$(date): Invalid reboot command received: $message"
            fi
        fi
    done
    do
        echo "$(date): mosquitto_sub crashed or disconnected. Retrying in 5 seconds..." >&2
        sleep 5
    done
) &

# Continuous measurement loop
# Continuous measurement loop
# Sensor loop
# --- Continuous monitoring loop ---
while true; do
    # --- Get latest readings from temp files ---
    ULTRASONIC_DISTANCE=$(cat /tmp/distance_debug 2>/dev/null || echo "5.0")
    CURRENT_MODE=$(cat /tmp/current_mode 2>/dev/null || echo "AUTO")

    # --- Read thresholds (individually updated from MQTT_DEBUG_TOPICMQTT) ---
    THRESHOLD_DANGER=$(cat /tmp/threshold_danger 2>/dev/null || echo "2.0")
    THRESHOLD_ALERT=$(cat /tmp/threshold_alert 2>/dev/null || echo "3.0")
    THRESHOLD_WARNING=$(cat /tmp/threshold_warning 2>/dev/null || echo "5.0")
    THRESHOLD_NORMAL=$(cat /tmp/threshold_normal 2>/dev/null || echo "8.0")

    TIMESTAMP=$(date +"%Y-%m-%dT%H:%M:%S.%3N")

    # --- Build JSON payload for MQTT ---
    JSON_PAYLOAD="{\"distance\": $ULTRASONIC_DISTANCE, \
\"unit\": \"meters\", \
\"timestamp\": \"$TIMESTAMP\", \
\"devEUI\": \"$MQTT_CLIENT_ID\", \
\"deviceType\": \"ultrasonic\", \
\"mode\": \"$CURRENT_MODE\", \
\"threshold_normal\": $THRESHOLD_NORMAL, \
\"threshold_warning\": $THRESHOLD_WARNING, \
\"threshold_alert\": $THRESHOLD_ALERT, \
\"threshold_danger\": $THRESHOLD_DANGER}"

    # --- Publish to MQTT ---
    mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" \
        -t "$MQTT_TOPIC" -q "$MQTT_QOS" -m "$JSON_PAYLOAD" \
        && echo "$(date): [MQTT] Distance: $ULTRASONIC_DISTANCE m (published)" \
        || echo "$(date): [MQTT] Publish failed" >&2

    # --- AUTO mode: compare against thresholds ---
    if [[ "$CURRENT_MODE" == "AUTO" ]]; then
        if (( $(echo "$ULTRASONIC_DISTANCE <= $THRESHOLD_DANGER" | bc -l) )); then
            LEVEL="DANGER"
        elif (( $(echo "$ULTRASONIC_DISTANCE <= $THRESHOLD_ALERT" | bc -l) )); then
            LEVEL="ALERT"
        elif (( $(echo "$ULTRASONIC_DISTANCE <= $THRESHOLD_WARNING" | bc -l) )); then
            LEVEL="WARNING"
        elif (( $(echo "$ULTRASONIC_DISTANCE <= $THRESHOLD_NORMAL" | bc -l) )); then
            LEVEL="NORMAL"
        else
            LEVEL="SAFE"
        fi

        # Load previous state
        PREVIOUS_STATE=$(cat /tmp/previous_state 2>/dev/null || echo "UNKNOWN")
        
        if [[ "$LEVEL" != "$PREVIOUS_STATE" ]]; then
            echo "$(date): Level changed → $LEVEL (distance: $ULTRASONIC_DISTANCE)"
            control_relay_pattern "$LEVEL"
            echo "$LEVEL" > /tmp/previous_state
        fi
    else
        # MANUAL mode - don't trigger any automatic patterns
        : # no-op
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
After=network-online.target mosquitto.service
Wants=network-online.target
Requires=mosquitto.service


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