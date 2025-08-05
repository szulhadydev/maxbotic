#!/bin/bash

# MQTT Configuration Variables
# Note: Update these values according to your setup

# ===== MQTT Broker Configuration =====
export MQTT_BROKER="${MQTT_BROKER:-xx.xxx.xxx}"          # Your MQTT broker IP/hostname
export MQTT_PORT="${MQTT_PORT:-1883}"                     # MQTT broker port
export MQTT_CLIENT_ID="${MQTT_CLIENT_ID:-cm4-1}"          # Unique client ID for this device
export MQTT_QOS="${MQTT_QOS:-2}"                         # Quality of Service (0, 1, or 2)

# Optional MQTT Authentication (uncomment and set if needed)
# export MQTT_USERNAME="your_username"
# export MQTT_PASSWORD="your_password"

# ===== Topic Configuration =====
export MQTT_TOPIC="${MQTT_TOPIC:-dtonggang/ultrasonic-01/data}"          # Sensor data publication
export MQTT_MODE_TOPIC="${MQTT_MODE_TOPIC:-dtonggang/ultrasonic-01/mode/set}"    # Mode control (auto/manual)
export MQTT_RELAY_TOPIC="${MQTT_RELAY_TOPIC:-dtonggang/ultrasonic-01/relay/set}" # Relay control (ON/OFF)
export MQTT_THRESHOLD_TOPIC="${MQTT_THRESHOLD_TOPIC:-dtonggang/ultrasonic-01/threshold/set}" # Threshold adjustment

# ===== Sensor Configuration =====
export SENSOR_DIR="${SENSOR_DIR:-/sys/bus/iio/devices/iio:device0}"  # Sensor device path
export OUTPUT_FILE="${OUTPUT_FILE:-/home/pi/ultrasonic.txt}"         # Local data storage
export MEASUREMENT_INTERVAL="${MEASUREMENT_INTERVAL:-2}"            # Seconds between measurements
export DEFAULT_THRESHOLD="${DEFAULT_THRESHOLD:-5.0}"                # Default threshold in meters (auto mode)

# ===== Logging Functions =====
log_mqtt_info() {
    echo "[MQTT-INFO] $1"
}

log_mqtt_warning() {
    echo "[MQTT-WARNING] $1" >&2
}

log_mqtt_error() {
    echo "[MQTT-ERROR] $1" >&2
}

# ===== Validation Function =====
validate_mqtt_config() {
    local valid=true
    
    # Validate broker configuration
    if [[ -z "$MQTT_BROKER" ]]; then
        log_mqtt_error "MQTT_BROKER not configured"
        valid=false
    fi
    
    if [[ ! "$MQTT_PORT" =~ ^[0-9]+$ ]] || [[ "$MQTT_PORT" -lt 1 ]] || [[ "$MQTT_PORT" -gt 65535 ]]; then
        log_mqtt_error "Invalid MQTT_PORT: $MQTT_PORT"
        valid=false
    fi
    
    # Validate topics
    if [[ -z "$MQTT_TOPIC" ]]; then
        log_mqtt_error "MQTT_TOPIC not configured"
        valid=false
    fi
    
    if [[ -z "$MQTT_MODE_TOPIC" ]]; then
        log_mqtt_error "MQTT_MODE_TOPIC not configured"
        valid=false
    fi
    
    if [[ -z "$MQTT_RELAY_TOPIC" ]]; then
        log_mqtt_error "MQTT_RELAY_TOPIC not configured"
        valid=false
    fi
    
    # Validate sensor directory (warning only as it might be created later)
    if [[ ! -d "$SENSOR_DIR" ]]; then
        log_mqtt_warning "Sensor directory not found: $SENSOR_DIR (may not exist yet)"
    fi
    
    if $valid; then
        log_mqtt_info "MQTT configuration validated successfully"
        log_mqtt_info "Broker: $MQTT_BROKER:$MQTT_PORT"
        log_mqtt_info "Client ID: $MQTT_CLIENT_ID"
        log_mqtt_info "Data Topic: $MQTT_TOPIC"
        log_mqtt_info "Mode Control Topic: $MQTT_MODE_TOPIC"
        log_mqtt_info "Relay Control Topic: $MQTT_RELAY_TOPIC"
        log_mqtt_info "Threshold: ${DEFAULT_THRESHOLD}m"
        return 0
    else
        return 1
    fi
}

# ===== Connection Test Function =====
test_mqtt_connection() {
    log_mqtt_info "Testing MQTT connection to $MQTT_BROKER:$MQTT_PORT..."
    
    if timeout 5 mosquitto_pub \
        -h "$MQTT_BROKER" \
        -p "$MQTT_PORT" \
        -i "$MQTT_CLIENT_ID" \
        -t "$MQTT_TOPIC/test" \
        -m "connection_test" \
        -q "$MQTT_QOS"; then
        log_mqtt_info "MQTT connection test successful"
        return 0
    else
        log_mqtt_error "MQTT connection test failed"
        return 1
    fi
}

# ===== Main Execution (for testing) =====
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Testing MQTT Configuration ==="
    validate_mqtt_config
    test_mqtt_connection
fi