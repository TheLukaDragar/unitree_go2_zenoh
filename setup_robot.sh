#!/bin/bash

# Setup script for zenoh-bridge-dds on Go2 robot
# Author: Luka Dragar
# Version: 1.0

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Configuration
readonly ZENOH_VERSION="1.4.0"
readonly ZENOH_DIR="/unitree/zenoh"
readonly SERVICE_NAME="zenoh-bridge-dds"
readonly SERVICE_USER="root"
readonly LISTEN_PORT="7447"
readonly REST_PORT="8000"
readonly DDS_DOMAIN="0"
readonly DDS_SCOPE="go2"

# Logging functions
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S'): $*" >&2
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S'): $*" >&2
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S'): $*" >&2
}

# Error handling
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script failed with exit code $exit_code"
        log_info "Check logs above for details"
    fi
    exit $exit_code
}

trap cleanup EXIT

# Validation functions
check_requirements() {
    log_info "Checking system requirements..."
    
    # Check if running as root or with sudo
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
    
    # Check for required commands
    local required_commands=("unzip" "systemctl" "curl")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command '$cmd' not found"
            exit 1
        fi
    done
    
    # Check for download tools
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        log_error "Neither wget nor curl found. Please install one of them."
        exit 1
    fi
    
    log_info "System requirements check passed"
}

get_local_ip() {
    log_info "Detecting local IP address..."
    
    local ip
    ip=$(hostname -I | awk '{print $1}')
    
    if [[ -z "$ip" ]]; then
        log_error "Failed to detect local IP address"
        exit 1
    fi
    
    # Validate IP format
    if [[ ! $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "Invalid IP address format: $ip"
        exit 1
    fi
    
    log_info "Robot local IP: $ip"
    echo "$ip"
}

create_zenoh_directory() {
    log_info "Creating zenoh directory structure..."
    
    if [[ ! -d "$ZENOH_DIR" ]]; then
        mkdir -p "$ZENOH_DIR"
        log_info "Created directory: $ZENOH_DIR"
    else
        log_info "Directory already exists: $ZENOH_DIR"
    fi
    
    cd "$ZENOH_DIR"
}

download_zenoh_bridge() {
    log_info "Downloading zenoh-bridge-dds version $ZENOH_VERSION for ARM64..."
    
    local zip_file="zenoh-bridge-dds-${ZENOH_VERSION}-aarch64-unknown-linux-gnu.zip"
    local download_url="https://download.eclipse.org/zenoh/zenoh-plugin-dds/latest/aarch64-unknown-linux-gnu/${zip_file}"
    
    # Remove existing file if present
    [[ -f "$zip_file" ]] && rm -f "$zip_file"
    
    # Download with fallback to curl if wget fails
    if command -v wget >/dev/null 2>&1; then
        if ! wget -q --show-progress "$download_url"; then
            log_error "Download failed with wget"
            exit 1
        fi
    else
        if ! curl -L --progress-bar -o "$zip_file" "$download_url"; then
            log_error "Download failed with curl"
            exit 1
        fi
    fi
    
    # Verify download
    if [[ ! -f "$zip_file" ]] || [[ ! -s "$zip_file" ]]; then
        log_error "Download verification failed"
        exit 1
    fi
    
    log_info "Download completed successfully"
}

install_zenoh_bridge() {
    log_info "Installing zenoh-bridge-dds..."
    
    local zip_file="zenoh-bridge-dds-${ZENOH_VERSION}-aarch64-unknown-linux-gnu.zip"
    
    # Extract
    if ! unzip -oq "$zip_file"; then
        log_error "Failed to extract $zip_file"
        exit 1
    fi
    
    # Set permissions
    chmod +x zenoh-bridge-dds
    
    # Create symlink
    ln -sf "$ZENOH_DIR/zenoh-bridge-dds" /usr/local/bin/zenoh-bridge-dds
    
    # Cleanup
    rm -f "$zip_file"
    
    log_info "Installation completed"
}

create_configuration() {
    local robot_ip="$1"
    
    log_info "Creating configuration file..."
    
    cat > "$ZENOH_DIR/config.json5" << EOF
{
  "mode": "peer",
  "listen": {
    "endpoints": [
      "tcp/${robot_ip}:${LISTEN_PORT}",
      "tcp/127.0.0.1:${LISTEN_PORT}",
      "tcp/0.0.0.0:${LISTEN_PORT}"
    ]
  },
  "plugins": {
    "dds": {
      "domain": ${DDS_DOMAIN},
      "scope": "${DDS_SCOPE}",
      "localhost_only": false,
      "allow": ".*"
    },
    "rest": {
      "http_port": "${REST_PORT}"
    }
  }
}
EOF
    
    log_info "Configuration file created at $ZENOH_DIR/config.json5"
}

create_systemd_service() {
    log_info "Creating systemd service..."
    
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Zenoh DDS Bridge for Go2 Robot
Documentation=https://zenoh.io/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=/usr/local/bin/zenoh-bridge-dds \\
    --mode peer \\
    --listen tcp/0.0.0.0:${LISTEN_PORT} \\
    --domain ${DDS_DOMAIN} \\
    --scope ${DDS_SCOPE} \\
    --rest-http-port ${REST_PORT}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
StartLimitInterval=60
StartLimitBurst=3
WorkingDirectory=${ZENOH_DIR}
Environment=PATH=/usr/local/bin:/usr/bin:/bin
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

# Security settings
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${ZENOH_DIR}

[Install]
WantedBy=multi-user.target
EOF
    
    log_info "Systemd service created"
}

create_test_script() {
    local robot_ip="$1"
    
    log_info "Creating test script..."
    
    cat > "$ZENOH_DIR/test_bridge.sh" << 'EOF'
#!/bin/bash

set -euo pipefail

readonly SERVICE_NAME="zenoh-bridge-dds"
readonly REST_PORT="8000"
readonly LISTEN_PORT="7447"

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S'): $*"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S'): $*"
}

test_service_status() {
    log_info "Checking service status..."
    systemctl status "$SERVICE_NAME" --no-pager --lines=10
}

test_rest_api() {
    log_info "Testing REST API..."
    local response
    if response=$(curl -s --max-time 5 "http://localhost:${REST_PORT}/@/*/dds/version" 2>/dev/null); then
        echo "REST API Response: $response"
    else
        log_error "REST API not responding"
        return 1
    fi
}

test_network_listening() {
    log_info "Checking network listeners..."
    if ss -tlnp | grep ":${LISTEN_PORT}" >/dev/null; then
        echo "Service is listening on port $LISTEN_PORT"
    else
        log_error "Service not listening on port $LISTEN_PORT"
        return 1
    fi
}

test_dds_routes() {
    log_info "Checking DDS routes..."
    local routes
    if routes=$(curl -s --max-time 5 "http://localhost:${REST_PORT}/@/*/dds/route/**" 2>/dev/null); then
        echo "Active routes found: $(echo "$routes" | wc -l) entries"
        echo "$routes" | head -5
    else
        log_error "Failed to retrieve DDS routes"
        return 1
    fi
}

main() {
    log_info "Testing zenoh bridge on Go2 robot..."
    echo
    
    local test_passed=0
    local test_failed=0
    
    # Run tests
    for test_func in test_service_status test_rest_api test_network_listening test_dds_routes; do
        echo "----------------------------------------"
        if $test_func; then
            ((test_passed++))
        else
            ((test_failed++))
        fi
        echo
    done
    
    # Summary
    echo "========================================"
    log_info "Test Summary: $test_passed passed, $test_failed failed"
    
    if [[ $test_failed -eq 0 ]]; then
        log_info "All tests passed! Bridge is working correctly."
        exit 0
    else
        log_error "Some tests failed. Check the output above."
        exit 1
    fi
}

main "$@"
EOF
    
    chmod +x "$ZENOH_DIR/test_bridge.sh"
    log_info "Test script created at $ZENOH_DIR/test_bridge.sh"
}

setup_service() {
    log_info "Setting up systemd service..."
    
    # Reload systemd
    systemctl daemon-reload
    
    # Enable service
    systemctl enable "$SERVICE_NAME"
    
    log_info "Service enabled for auto-start on boot"
}

print_summary() {
    local robot_ip="$1"
    
    cat << EOF

========================================
Zenoh Bridge Setup Complete
========================================

Configuration:
  - Installation directory: $ZENOH_DIR
  - Service name: $SERVICE_NAME
  - Listen port: $LISTEN_PORT
  - REST API port: $REST_PORT
  - DDS domain: $DDS_DOMAIN
  - DDS scope: $DDS_SCOPE
  - Robot IP: $robot_ip

Service Management:
  Start service:    sudo systemctl start $SERVICE_NAME
  Stop service:     sudo systemctl stop $SERVICE_NAME
  Check status:     sudo systemctl status $SERVICE_NAME
  View logs:        sudo journalctl -u $SERVICE_NAME -f

Testing:
  Run tests:        $ZENOH_DIR/test_bridge.sh

REST API Access:
  Local:            http://localhost:$REST_PORT
  Network:          http://$robot_ip:$REST_PORT

Important Notes:
  - Service auto-starts on boot
  - Solves CycloneDX interface switching crashes
  - Robot can safely switch between network interfaces
  - Service automatically restarts on failure

Next Steps:
  1. Start the service: sudo systemctl start $SERVICE_NAME
  2. Test the setup: $ZENOH_DIR/test_bridge.sh
  3. Configure your development machine
  4. Test DDS communication

EOF
}

main() {
    log_info "Starting zenoh-bridge-dds setup for Go2 robot..."
    
    # Validate environment
    check_requirements
    
    # Get robot IP
    local robot_ip
    robot_ip=$(get_local_ip)
    
    # Setup process
    create_zenoh_directory
    download_zenoh_bridge
    install_zenoh_bridge
    create_configuration "$robot_ip"
    create_systemd_service
    create_test_script "$robot_ip"
    setup_service
    
    log_info "Setup completed successfully"
    print_summary "$robot_ip"
}

# Execute main function
main "$@" 