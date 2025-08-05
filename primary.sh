#!/bin/bash

set -euo pipefail

readonly _RED=$(tput setaf 1)
readonly _GREEN=$(tput setaf 2)
readonly _YELLOW=$(tput setaf 3)
readonly _CYAN=$(tput setaf 6)
readonly _RESET=$(tput sgr0)

log_info() { echo "${_CYAN}[INFO] $*${_RESET}"; }
log_success() { echo "${_GREEN}[OK] $*${_RESET}"; }
log_error() { echo "${_RED}[ERROR] $*${_RESET}"; }

trap 'log_error "Error on line $LINENO"' ERR

MQTT_CONFIG="./mqtt_service.sh"
SERVICE_NAME="maxbotic_ultrasonic"
SCRIPT_NAME="startUltrasonic.sh"
SYSTEMD_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
STARTUP_PATH="/usr/local/bin/${SCRIPT_NAME}"

check_dependencies() {
  log_info "Checking dependencies..."
  local dependencies=("bc" "mosquitto_pub" "mosquitto_sub" "mbpoll" "systemctl")
  for dep in "${dependencies[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      log_error "$dep is not installed."
      exit 1
    fi
  done
  log_success "All dependencies found."
}

load_mqtt_config() {
  log_info "Loading MQTT configuration..."
  if [[ ! -f "$MQTT_CONFIG" ]]; then
    log_error "Missing config file: $MQTT_CONFIG"
    exit 1
  fi
  source "$MQTT_CONFIG"
  if [[ -z "${MQTT_BROKER:-}" || -z "${MQTT_PORT:-}" || -z "${MQTT_TOPIC:-}"]]; then
    log_error "Missing required MQTT config variables."
    exit 1
  fi
  log_success "MQTT configuration loaded."
}

create_startup_script() {
  log_info "Creating startup script..."
  cat <<EOF | sudo tee "$STARTUP_PATH" > /dev/null
#!/bin/bash

OUTPUT_FILE="/var/log/ultrasonic_readings.csv"
THRESHOLD=5.0

# Publish to MQTT
publish_mqtt() {
  mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "$MQTT_TOPIC" -m "\$1"
}

# MQTT Subscription for relay control
{
  echo "\$(date): Subscribing to MQTT topic: dtonggang/ultrasonic-01/relay/control"

  if mosquitto_pub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "dtonggang/ultrasonic-01/status" -m "relay-listener-online" 2>/dev/null; then
    echo "\$(date): MQTT connection to broker successful. Ready to receive control messages."
  else
    echo "\$(date): WARNING: Unable to connect to MQTT broker. Control messages may not work." >&2
  fi

  mosquitto_sub -h "$MQTT_BROKER" -p "$MQTT_PORT" -t "dtonggang/ultrasonic-01/relay/control" | while read -r message; do
    echo "\$(date): MQTT message received on relay/control topic: '\$message'"
    case "\$message" in
      "on")
        echo "\$(date): Received 'on' command. Turning relay ON."
        mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 1
        ;;
      "off")
        echo "\$(date): Received 'off' command. Turning relay OFF."
        mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 0
        ;;
      *)
        echo "\$(date): Unknown MQTT command: \$message" >&2
        ;;
    esac
  done
} &

# Reading loop
while true; do
  if RAW_VALUE=\$(cat /sys/bus/iio/devices/iio:device0/in_voltage1_raw 2>/dev/null); then
    DISTANCE=\$(echo "scale=2; \$RAW_VALUE * 0.00244" | bc)
    TIMESTAMP=\$(date '+%Y-%m-%d %H:%M:%S')
    echo "\$TIMESTAMP,\$DISTANCE" >> "\$OUTPUT_FILE"
    publish_mqtt "\$DISTANCE"

    # Trigger siren
    # if (( \$(echo "\$DISTANCE < \$THRESHOLD" | bc -l) )); then
    #   echo "\$(date): Distance \$DISTANCE < \$THRESHOLD, triggering siren."
    #   mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 1
    #   sleep 3
    #   mbpoll -m rtu -a 1 -b 9600 -P none -s 1 -t 0 -r 2 /dev/ttyAMA4 -- 0
    # fi
  else
    echo "\$(date): Could not read sensor value" >&2
  fi
  sleep 1
done
EOF

  sudo chmod +x "$STARTUP_PATH"
  log_success "Startup script created at $STARTUP_PATH"
}

create_systemd_service() {
  log_info "Creating systemd service..."
  cat <<EOF | sudo tee "$SYSTEMD_PATH" > /dev/null
[Unit]
Description=Maxbotix Ultrasonic Background Service
After=network.target

[Service]
Type=simple
ExecStart=$STARTUP_PATH
Restart=always
User=pi
EnvironmentFile=$MQTT_CONFIG
WorkingDirectory=/home/pi
StandardOutput=journal
StandardError=journal
SyslogIdentifier=maxbotic
PrivateTmp=true
ProtectSystem=strict
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reexec
  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"
  sudo systemctl restart "$SERVICE_NAME"
  log_success "Systemd service installed and started."
}

main() {
  check_dependencies
  load_mqtt_config
  create_startup_script
  create_systemd_service

  log_success "Installation completed successfully!"
  echo ""
  echo "${_YELLOW}To monitor the service logs:${_RESET}"
  echo "  sudo journalctl -u $SERVICE_NAME -f"
  echo ""
  echo "${_YELLOW}To stop the service:${_RESET}"
  echo "  sudo systemctl stop $SERVICE_NAME"
  echo ""
  echo "${_YELLOW}To disable and uninstall:${_RESET}"
  echo "  sudo systemctl disable $SERVICE_NAME"
  echo "  sudo rm $SYSTEMD_PATH $STARTUP_PATH"
  echo ""
}

main
