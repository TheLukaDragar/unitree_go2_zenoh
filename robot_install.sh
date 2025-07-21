#!/bin/bash

# Installation script for zenoh-bridge-dds on Go2 robot
# Author: Luka Dragar
# Version: 1.0
# This script runs ON the robot after being copied via SSH

set -euo pipefail

# Configuration
readonly ZENOH_VERSION="1.4.0"
readonly ZENOH_DIR="/unitree/zenoh"
readonly SERVICE_NAME="zenoh-bridge-dds"
readonly LISTEN_PORT="7447"
readonly REST_PORT="8000"
readonly DDS_DOMAIN="0"
readonly DDS_SCOPE="go2"

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S'): $*"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S'): $*"
}

check_requirements() {
    log_info "Checking system requirements..."
    
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    local required_commands=("unzip" "systemctl" "curl" "wget")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command '$cmd' not found"
            exit 1
        fi
    done
    
    log_info "System requirements check passed"
}

get_local_ip() {
    local ip
    ip=$(hostname -I | awk '{print $1}')
    
    if [[ -z "$ip" ]]; then
        log_error "Failed to detect local IP address"
        exit 1
    fi
    
    if [[ ! $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "Invalid IP address format: $ip"
        exit 1
    fi
    
    log_info "Robot local IP: $ip"
    echo "$ip"
}

setup_directories() {
    log_info "Setting up directories..."
    mkdir -p "$ZENOH_DIR"
    cd "$ZENOH_DIR"
}

download_and_install() {
    log_info "Downloading zenoh-bridge-dds version $ZENOH_VERSION..."
    
    # Test internet connectivity
    log_info "Testing internet connectivity..."
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        log_error "No internet connectivity detected"
        log_error "Please check network connection"
        exit 1
    fi
    
    local zip_file="zenoh-plugin-dds-${ZENOH_VERSION}-aarch64-unknown-linux-gnu-standalone.zip"
    local download_url="https://download.eclipse.org/zenoh/zenoh-plugin-dds/latest/${zip_file}"
    
    # Remove existing file if present
    [[ -f "$zip_file" ]] && rm -f "$zip_file"
    
    log_info "Download URL: $download_url"
    
    # Try wget first, then curl as fallback
    if command -v wget >/dev/null 2>&1; then
        log_info "Using wget to download..."
        if ! wget --progress=bar:force --show-progress "$download_url"; then
            log_error "Download failed with wget (HTTP error), trying curl..."
            if command -v curl >/dev/null 2>&1; then
                if ! curl -L --fail --progress-bar -o "$zip_file" "$download_url"; then
                    log_error "Download failed with both wget and curl"
                    log_error "URL may be incorrect or file not available"
                    exit 1
                fi
            else
                log_error "Download failed and curl not available"
                exit 1
            fi
        fi
    elif command -v curl >/dev/null 2>&1; then
        log_info "Using curl to download..."
        if ! curl -L --fail --progress-bar -o "$zip_file" "$download_url"; then
            log_error "Download failed with curl"
            log_error "URL may be incorrect or file not available"
            exit 1
        fi
    else
        log_error "Neither wget nor curl found"
        exit 1
    fi
    
    # Verify the downloaded file is actually a zip file
    if [[ ! -f "$zip_file" ]]; then
        log_error "Download failed - file not found after download"
        exit 1
    fi
    
    # Check if file is actually a zip file (should start with 'PK')
    if ! file "$zip_file" | grep -q "Zip archive"; then
        log_error "Downloaded file is not a valid zip archive"
        log_error "This usually means the URL returned an error page"
        log_error "File content:"
        head -3 "$zip_file" || true
        rm -f "$zip_file"
        exit 1
    fi
    
    # Extract and install
    log_info "Installing zenoh-bridge-dds..."
    unzip -oq "$zip_file"
    
    # The standalone version contains zenoh-bridge-dds executable
    if [[ -f "zenoh-bridge-dds" ]]; then
        chmod +x zenoh-bridge-dds
    else
        log_error "zenoh-bridge-dds executable not found in zip"
        exit 1
    fi
    
    ln -sf "$ZENOH_DIR/zenoh-bridge-dds" /usr/local/bin/zenoh-bridge-dds
    rm -f "$zip_file"
    
    log_info "Installation completed"
}

create_configuration() {
    log_info "Creating configuration..."
    
    cat > "$ZENOH_DIR/config.json5" << EOF
{
  mode: "peer",
  listen: {
    endpoints: ["tcp/0.0.0.0:${LISTEN_PORT}"]
  },
  plugins: {
    dds: {
      domain: ${DDS_DOMAIN},
      scope: "${DDS_SCOPE}",
      localhost_only: false
    },
    rest: {
      http_port: ${REST_PORT}
    }
  }
}
EOF
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
User=root
Group=root
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
    
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    log_info "Service created and enabled"
}

create_test_script() {
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

echo "Testing zenoh bridge on Go2 robot..."
echo "======================================"

# Test service status
echo "Service Status:"
systemctl status "$SERVICE_NAME" --no-pager --lines=5 || true
echo

# Test network listening
echo "Network Listeners:"
if ss -tlnp | grep ":${LISTEN_PORT}"; then
    echo "✓ Service listening on port $LISTEN_PORT"
else
    echo "✗ Service not listening on port $LISTEN_PORT"
fi
echo

# Test REST API
echo "REST API Test:"
if response=$(curl -s --max-time 5 "http://localhost:${REST_PORT}/@/*/dds/version" 2>/dev/null); then
    echo "✓ REST API responding: $response"
else
    echo "✗ REST API not responding"
fi
echo

# Test DDS routes
echo "DDS Routes:"
if routes=$(curl -s --max-time 5 "http://localhost:${REST_PORT}/@/*/dds/route/**" 2>/dev/null); then
    route_count=$(echo "$routes" | wc -l)
    echo "✓ Active routes: $route_count entries"
    echo "$routes" | head -3
else
    echo "✗ Failed to retrieve DDS routes"
fi

echo
echo "Test completed."
EOF
    
    chmod +x "$ZENOH_DIR/test_bridge.sh"
}

main() {
    log_info "Starting zenoh-bridge-dds setup..."
    
    check_requirements
    local robot_ip
    robot_ip=$(get_local_ip)
    
    setup_directories
    download_and_install
    create_configuration
    create_systemd_service
    create_test_script
    
    log_info "Setup completed successfully"
    echo "Robot IP: $robot_ip"
    echo "Installation directory: $ZENOH_DIR"
    echo "Service name: $SERVICE_NAME"
    echo "Listen port: $LISTEN_PORT"
    echo "REST API port: $REST_PORT"
}

main "$@" 