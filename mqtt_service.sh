# ===== mqtt_service.sh =====
#!/bin/bash

# MQTT Configuration Variables
# Note: Update these values according to your setup

# MQTT Broker Configuration
export MQTT_BROKER="${MQTT_BROKER:-zr.txio.live}"
export MQTT_PORT="${MQTT_PORT:-1880}"
export MQTT_CLIENT_ID="${MQTT_CLIENT_ID:-CM4-11-debug}"
export MQTT_TOPIC="${MQTT_TOPIC:-EA/data/CM4-11-debug}"
export MQTT_SUBSCRIBE_TOPIC="${MQTT_SUBSCRIBE_TOPIC:-EA/${MQTT_CLIENT_ID}/relay/control}"

# Add new MQTT topic for mode control
export MQTT_MODE_TOPIC="${MQTT_MODE_TOPIC:-EA/${MQTT_CLIENT_ID}/mode/control}"

# Add new MQTT topic to set threshold 
export MQTT_THRESHOLD_TOPIC="${MQTT_THRESHOLD_TOPIC:-EA/${MQTT_CLIENT_ID}/threshold/set}"
export MQTT_DISTANCE_DEBUG_TOPIC="${MQTT_DISTANCE_DEBUG_TOPIC:-EA/${MQTT_CLIENT_ID}/distance/debug}"



# --- Multi-threshold Topics ---
export MQTT_THRESHOLD_NORMAL_TOPIC="${MQTT_THRESHOLD_NORMAL_TOPIC:-EA/${MQTT_CLIENT_ID}/threshold/normal/set}"
export MQTT_THRESHOLD_WARNING_TOPIC="${MQTT_THRESHOLD_WARNING_TOPIC:-EA/${MQTT_CLIENT_ID}/threshold/warning/set}"
export MQTT_THRESHOLD_ALERT_TOPIC="${MQTT_THRESHOLD_ALERT_TOPIC:-EA/${MQTT_CLIENT_ID}/threshold/alert/set}"
export MQTT_THRESHOLD_DANGER_TOPIC="${MQTT_THRESHOLD_DANGER_TOPIC:-EA/${MQTT_CLIENT_ID}/threshold/danger/set}"

export MQTT_MAX_HEIGHT_TOPIC="${MQTT_MAX_HEIGHT_TOPIC:-EA/${MQTT_CLIENT_ID}/maxheight/set}"
export MQTT_OFFSET_VALUE_TOPIC="${MQTT_OFFSET_VALUE_TOPIC:-EA/${MQTT_CLIENT_ID}/offsetvalue/set}"
export MQTT_OFFSET_OPERATION_TOPIC="${MQTT_OFFSET_OPERATION_TOPIC:-EA/${MQTT_CLIENT_ID}/offsetoperation/set}"
# export MQTT_THRESHOLD_NORMAL_TOPIC="ultrasonic/threshold/normal"
# export MQTT_THRESHOLD_WARNING_TOPIC="ultrasonic/threshold/warning"
# export MQTT_THRESHOLD_ALERT_TOPIC="ultrasonic/threshold/alert"
# export MQTT_THRESHOLD_DANGER_TOPIC="ultrasonic/threshold/danger"
export MQTT_DEBUG_TOPIC_SIREN="${MQTT_DEBUG_TOPIC_SIREN:-EA/${MQTT_CLIENT_ID}/debug/siren}"

# Add new MQTT topic to reboot pi 
export MQTT_REBOOT_TOPIC="${MQTT_REBOOT_TOPIC:-EA/${MQTT_CLIENT_ID}/reboot}"

# Default mode (can be overridden at runtime via MQTT)
CURRENT_MODE="AUTO"

# Distance threshold (meters) for triggering relay in AUTO mode
# DISTANCE_THRESHOLD=5.0
DISTANCE_THRESHOLD="${DISTANCE_THRESHOLD:-1.0}"  # fallback if /tmp not yet written

# Optional MQTT Authentication (uncomment and set if needed)
# export MQTT_USERNAME="your_username"
# export MQTT_PASSWORD="your_password"

# MQTT Quality of Service (0, 1, or 2)
export MQTT_QOS="${MQTT_QOS:-2}"

# Sensor Configuration
export SENSOR_DIR="${SENSOR_DIR:-/sys/bus/iio/devices/iio:device0}"
export OUTPUT_FILE="${OUTPUT_FILE:-/home/pi/ultrasonic.txt}"
export MEASUREMENT_INTERVAL="${MEASUREMENT_INTERVAL:-5}"

# Logging
log_mqtt_info() {
    echo "[MQTT-INFO] $1"
}

# Validation function
validate_mqtt_config() {
    if [[ -z "$MQTT_BROKER" ]]; then
        echo "[MQTT-ERROR] MQTT_BROKER not configured"
        return 1
    fi
    
    if [[ ! "$MQTT_PORT" =~ ^[0-9]+$ ]] || [[ "$MQTT_PORT" -lt 1 ]] || [[ "$MQTT_PORT" -gt 65535 ]]; then
        echo "[MQTT-ERROR] Invalid MQTT_PORT: $MQTT_PORT"
        return 1
    fi
    
    log_mqtt_info "MQTT configuration validated successfully"
    log_mqtt_info "Broker: $MQTT_BROKER:$MQTT_PORT"
    log_mqtt_info "Topic: $MQTT_TOPIC"
    log_mqtt_info "Client ID: $MQTT_CLIENT_ID"
    
    return 0
}

# Test MQTT connection
test_mqtt_connection() {
    log_mqtt_info "Testing MQTT connection..."
    if timeout 5 mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "$MQTT_TOPIC/test" -m "connection_test" -q "$MQTT_QOS"; then
        log_mqtt_info "MQTT connection test successful"
        return 0
    else
        echo "[MQTT-ERROR] MQTT connection test failed"
        return 1
    fi
}