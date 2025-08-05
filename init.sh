# ===== init.sh =====
#!/bin/bash

# Exit on any error
set -euo pipefail

# Define colors
readonly _RED=$(tput setaf 1)
readonly _GREEN=$(tput setaf 2)
readonly _YELLOW=$(tput setaf 3)
readonly _BLUE=$(tput setaf 4)
readonly _MAGENTA=$(tput setaf 5)
readonly _CYAN=$(tput setaf 6)
readonly _RESET=$(tput sgr0)

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
error_exit() {
    log_error "Script failed on line $1"
    exit 1
}

# Set error trap
trap 'error_exit $LINENO' ERR

# Main initialization function
main() {
    log_info "Maxbotic data acquisition protocol setup started"
    echo
    
    # Check if running as root (some operations require sudo)
    if [[ $EUID -eq 0 ]]; then
        log_warning "Running as root. Consider running as regular user with sudo when needed."
    fi
    
    # Validate required files exist
    local required_files=("primary.sh" "mqtt_service.sh")
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "Required file '$file' not found in current directory"
            exit 1
        fi
    done
    
    # Set executable permissions
    log_info "Setting executable permissions for scripts"
    chmod +x primary.sh mqtt_service.sh
    cp mqtt_service.sh /home/pi/
    log_success "Permissions set successfully"
    
    # Set timezone
    log_info "Setting timezone to Asia/Kuala_Lumpur"
    if sudo timedatectl set-timezone Asia/Kuala_Lumpur; then
        log_success "Timezone configured successfully"
    else
        log_error "Failed to set timezone"
        exit 1
    fi
    
    # Install dependencies
    log_info "Updating package lists and installing dependencies"
    if sudo apt update && sudo apt install -y mbpoll mosquitto mosquitto-clients bc; then
        log_success "Dependencies installed successfully"
    else
        log_error "Failed to install dependencies"
        exit 1
    fi
    
    # Enable mosquitto service
    log_info "Enabling Mosquitto service"
    if sudo systemctl enable mosquitto && sudo systemctl start mosquitto; then
        log_success "Mosquitto service enabled and started"
    else
        log_error "Failed to enable Mosquitto service"
        exit 1
    fi
    
    # Execute primary setup
    log_info "Executing primary setup script"
    if bash primary.sh; then
        log_success "Primary setup completed successfully"
    else
        log_error "Primary setup failed"
        exit 1
    fi
    
    log_success "Installation completed successfully!"
    echo
    log_info "Next steps:"
    echo "  1. Configure MQTT broker settings in mqtt_service.sh"
    echo "  2. Test the ultrasonic sensor service"
    echo "  3. Monitor logs with: sudo journalctl -u maxbotic_ultrasonic -f"
}

# Run main function
main "$@"
