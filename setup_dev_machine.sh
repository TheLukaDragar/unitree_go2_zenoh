#!/bin/bash

# Setup script for zenoh-bridge-dds on development machine
# Author: Luka Dragar
# Version: 1.0

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Configuration
readonly ZENOH_VERSION="1.5.0"
readonly ZENOH_DIR="$HOME/zenoh"
readonly LISTEN_PORT="7447"
readonly REST_PORT="8001"
readonly DDS_DOMAIN="0"
readonly DDS_SCOPE="go2"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S'): $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S'): $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S'): $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S'): $*" >&2
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

show_usage() {
    cat << EOF
Usage: $(basename "$0") ROBOT_IP [OPTIONS]

Setup zenoh-bridge-dds on development machine (macOS/Linux)

Arguments:
  ROBOT_IP              Robot IP address (required)

Options:
  --tailscale           Use Tailscale IPs (auto-detect local Tailscale IP)
  --force               Force reinstall even if already installed
  --test                Test connection only, don't install
  -h, --help            Show this help message

Examples:
  $(basename "$0") 192.168.1.100
  $(basename "$0") 100.92.165.120 --tailscale
  $(basename "$0") --test

EOF
}

parse_arguments() {
    ROBOT_IP=""
    USE_TAILSCALE=false
    FORCE_INSTALL=false
    TEST_ONLY=false

    # First argument should be robot IP (unless it's a flag)
    if [[ $# -gt 0 && ! "$1" =~ ^-- && "$1" != "-h" ]]; then
        ROBOT_IP="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --tailscale)
                USE_TAILSCALE=true
                shift
                ;;
            --force)
                FORCE_INSTALL=true
                shift
                ;;
            --test)
                TEST_ONLY=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                log_error "Unexpected argument: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    if [[ "$TEST_ONLY" != "true" && -z "$ROBOT_IP" ]]; then
        log_error "Robot IP address is required as first argument"
        show_usage
        exit 1
    fi
}

check_requirements() {
    log_info "Checking system requirements..."

    # Check for required commands
    local required_commands=("unzip")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command '$cmd' not found"
            exit 1
        fi
    done

    # Check for download tools
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        log_error "Neither wget nor curl found. Please install one of them."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            log_error "On macOS, install with: brew install wget"
        fi
        exit 1
    fi

    log_info "System requirements check passed"
}

detect_platform() {
    log_info "Detecting platform..."

    local platform=""
    local arch=""

    case "$OSTYPE" in
        darwin*)
            platform="apple-darwin"
            if [[ "$(uname -m)" == "arm64" ]]; then
                arch="aarch64"
            else
                arch="x86_64"
            fi
            ;;
        linux*)
            platform="unknown-linux-gnu"
            case "$(uname -m)" in
                x86_64) arch="x86_64" ;;
                aarch64|arm64) arch="aarch64" ;;
                *) log_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
            esac
            ;;
        *)
            log_error "Unsupported OS: $OSTYPE"
            exit 1
            ;;
    esac

    PLATFORM_TARGET="${arch}-${platform}"
    log_info "Detected platform: $PLATFORM_TARGET"
}

get_local_ip() {
    log_info "Detecting local IP address..."

    local local_ip=""

    if [[ "$USE_TAILSCALE" == "true" ]]; then
        if command -v tailscale >/dev/null 2>&1; then
            local_ip=$(tailscale ip -4 2>/dev/null || echo "")
            if [[ -n "$local_ip" ]]; then
                log_info "Using Tailscale IP: $local_ip"
            else
                log_warn "Tailscale installed but no IP found, falling back to local IP"
                USE_TAILSCALE=false
            fi
        else
            log_warn "Tailscale not found, install from: https://tailscale.com/download"
            log_info "Falling back to local IP detection"
            USE_TAILSCALE=false
        fi
    fi

    if [[ -z "$local_ip" ]]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            local_ip=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | head -1 | awk '{print $2}')
        else
            local_ip=$(hostname -I | awk '{print $1}')
        fi
    fi

    if [[ -z "$local_ip" ]]; then
        log_error "Failed to detect local IP address"
        exit 1
    fi

    # Validate IP format
    if [[ ! $local_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "Invalid IP address format: $local_ip"
        exit 1
    fi

    log_info "Development machine IP: $local_ip"
    echo "$local_ip"
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

check_existing_installation() {
    log_info "Checking for existing installation..."

    if [[ -f "$ZENOH_DIR/zenoh-bridge-dds" ]]; then
        if [[ "$FORCE_INSTALL" == "true" ]]; then
            log_warn "Existing installation found, but --force specified. Will reinstall."
            return 1
        else
            log_warn "zenoh-bridge-dds appears to be already installed in $ZENOH_DIR"
            log_info "Use --force to reinstall"
            return 0
        fi
    fi

    return 1
}

download_zenoh_bridge() {
    log_info "Downloading zenoh-bridge-dds version $ZENOH_VERSION for $PLATFORM_TARGET..."

    local zip_file="zenoh-plugin-dds-${ZENOH_VERSION}-${PLATFORM_TARGET}-standalone.zip"
    local download_url="https://download.eclipse.org/zenoh/zenoh-plugin-dds/${ZENOH_VERSION}/${zip_file}"

    # Remove existing file if present
    [[ -f "$zip_file" ]] && rm -f "$zip_file"

    log_info "Download URL: $download_url"

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
        log_error "Download verification failed"
    if [[ ! -f "$zip_file" ]] || [[ ! -s "$zip_file" ]]; then
        exit 1
    fi

    log_info "Download completed successfully"
}

install_zenoh_bridge() {
    log_info "Installing zenoh-bridge-dds..."

    local zip_file="zenoh-plugin-dds-${ZENOH_VERSION}-${PLATFORM_TARGET}-standalone.zip"


    # Extract
    if ! unzip -oq "$zip_file"; then
        log_error "Failed to extract $zip_file"
        exit 1
    fi

    # Set permissions
    chmod +x zenoh-bridge-dds

    # Cleanup
    rm -f "$zip_file"

    log_info "Installation completed"
}

create_configuration() {
    local robot_ip="$1"
    local dev_ip="$2"

    log_info "Creating configuration file..."

    cat > "$ZENOH_DIR/config.json5" << EOF
{
  "mode": "peer",
  "connect": {
    "endpoints": [
      "tcp/${robot_ip}:${LISTEN_PORT}"
    ]
  },
  "listen": {
    "endpoints": [
      "tcp/${dev_ip}:${LISTEN_PORT}",
      "tcp/127.0.0.1:${LISTEN_PORT}"
    ]
  },
  "plugins": {
    "dds": {
      "domain": ${DDS_DOMAIN},
      "scope": "${DDS_SCOPE}"
    },
    "rest": {
      "http_port": "${REST_PORT}"
    }
  }
}
EOF

    log_info "Configuration file created at $ZENOH_DIR/config.json5"
}

create_start_script() {
    local robot_ip="$1"

    log_info "Creating start script..."

    cat > "$ZENOH_DIR/start_bridge.sh" << EOF
#!/bin/bash

echo "🚀 Starting zenoh-bridge-dds on development machine..."
echo "🔗 Connecting to Go2 robot at: $robot_ip:$LISTEN_PORT"
echo "🌐 REST API will be available at: http://localhost:$REST_PORT"
echo "📋 Using DDS scope: $DDS_SCOPE (matches robot)"
echo ""
echo "Press Ctrl+C to stop"
echo ""

# Use command line args for reliability
"\$(dirname "\$0")/zenoh-bridge-dds" \\
  --mode peer \\
  --connect tcp/$robot_ip:$LISTEN_PORT \\
  --listen tcp/127.0.0.1:$LISTEN_PORT \\
  --domain $DDS_DOMAIN \\
  --scope $DDS_SCOPE \\
  --rest-http-port $REST_PORT
EOF

    chmod +x "$ZENOH_DIR/start_bridge.sh"
    log_info "Start script created at $ZENOH_DIR/start_bridge.sh"
}

create_test_script() {
    log_info "Creating test script..."

    cat > "$ZENOH_DIR/test_connection.sh" << 'EOF'
#!/bin/bash

set -euo pipefail

readonly REST_PORT="8001"

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S'): $*"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S'): $*"
}

test_bridge_status() {
    log_info "Testing bridge status..."
    local response
    if response=$(curl -s --max-time 5 "http://localhost:${REST_PORT}/@/*/dds/version" 2>/dev/null); then
        echo "✅ Bridge responding: $response"
        return 0
    else
        echo "❌ Bridge not responding"
        return 1
    fi
}

test_active_routes() {
    log_info "Checking active DDS routes..."
    local routes
    if routes=$(curl -s --max-time 5 "http://localhost:${REST_PORT}/@/*/dds/route/**" 2>/dev/null); then
        local route_count
        route_count=$(echo "$routes" | wc -l)
        echo "✅ Active routes found: $route_count entries"
        echo "$routes" | head -10
        return 0
    else
        echo "❌ Failed to retrieve DDS routes"
        return 1
    fi
}

test_robot_topics() {
    log_info "Checking robot-specific topics..."
    local topics=("rt/lowstate" "rt/sportmodestate" "rt/servicestate")

    for topic in "${topics[@]}"; do
        local route
        if route=$(curl -s --max-time 5 "http://localhost:${REST_PORT}/@/*/dds/route/**/${topic}" 2>/dev/null); then
            if [[ -n "$route" && "$route" != "null" ]]; then
                echo "✅ Found topic: $topic"
            else
                echo "⚠️  Topic not found: $topic"
            fi
        else
            echo "❌ Failed to check topic: $topic"
        fi
    done
}

main() {
    log_info "Testing zenoh bridge connection..."
    echo "=========================================="
    echo

    local test_passed=0
    local test_failed=0

    # Run tests
    for test_func in test_bridge_status test_active_routes test_robot_topics; do
        echo "----------------------------------------"
        if $test_func; then
            ((test_passed++))
        else
            ((test_failed++))
        fi
        echo
    done

    # Summary
    echo "=========================================="
    log_info "Test Summary: $test_passed passed, $test_failed failed"

    if [[ $test_failed -eq 0 ]]; then
        log_info "All tests passed! Bridge is working correctly."
        echo
        echo "🎯 Your DDS subscribers should now receive data from:"
        echo "   - rt/lowstate (robot telemetry)"
        echo "   - rt/sportmodestate (sport mode)"
        echo "   - rt/servicestate (service status)"
        exit 0
    else
        log_error "Some tests failed. Make sure:"
        log_error "  - Bridge is running: ./start_bridge.sh"
        log_error "  - Robot bridge is running and accessible"
        log_error "  - Network connectivity to robot is working"
        exit 1
    fi
}

main "$@"
EOF

    chmod +x "$ZENOH_DIR/test_connection.sh"
    log_info "Test script created at $ZENOH_DIR/test_connection.sh"
}

run_tests() {
    log_info "Running connection tests..."

    if [[ -f "$ZENOH_DIR/test_connection.sh" ]]; then
        "$ZENOH_DIR/test_connection.sh"
    else
        log_error "Test script not found"
        return 1
    fi
}

print_summary() {
    local robot_ip="$1"
    local dev_ip="$2"

    cat << EOF

========================================
Development Machine Setup Complete
========================================

Configuration:
  - Installation directory: $ZENOH_DIR
  - Robot IP: $robot_ip
  - Development machine IP: $dev_ip
  - Listen port: $LISTEN_PORT
  - REST API port: $REST_PORT
  - DDS domain: $DDS_DOMAIN
  - DDS scope: $DDS_SCOPE

Usage:
  Start bridge:     cd $ZENOH_DIR && ./start_bridge.sh
  Test connection:  cd $ZENOH_DIR && ./test_connection.sh

REST API Access:
  Local:            http://localhost:$REST_PORT

Important Notes:
  - Make sure robot bridge is running first
  - Bridge connects to robot at tcp://$robot_ip:$LISTEN_PORT
  - DDS scope '$DDS_SCOPE' matches robot configuration
  - Use Ctrl+C to stop the bridge

Next Steps:
  1. Ensure robot bridge is running
  2. Start the development bridge: cd $ZENOH_DIR && ./start_bridge.sh
  3. Test the connection: cd $ZENOH_DIR && ./test_connection.sh
  4. Run your DDS applications

DDS Topics Available:
  - rt/lowstate (robot telemetry)
  - rt/sportmodestate (sport mode)
  - rt/servicestate (service status)

EOF
}

main() {
    log_info "Starting zenoh-bridge-dds setup for development machine..."

    # Parse arguments
    parse_arguments "$@"

    # Validate environment
    check_requirements
    detect_platform

    # Get local IP
    local dev_ip
    dev_ip=$(get_local_ip)

    if [[ "$TEST_ONLY" == "true" ]]; then
        log_info "Test mode - running connection tests..."
        if [[ -d "$ZENOH_DIR" ]]; then
            cd "$ZENOH_DIR"
            run_tests
        else
            log_error "zenoh directory not found. Run setup first."
            exit 1
        fi
        exit 0
    fi

    # Check existing installation
    if check_existing_installation; then
        log_info "Installation already exists and appears to be working"
        print_summary "$ROBOT_IP" "$dev_ip"
        exit 0
    fi

    # Setup process
    create_zenoh_directory
    download_zenoh_bridge
    install_zenoh_bridge
    create_configuration "$ROBOT_IP" "$dev_ip"
    create_start_script "$ROBOT_IP"
    create_test_script

    log_success "Setup completed successfully"
    print_summary "$ROBOT_IP" "$dev_ip"
}

# Execute main function
main "$@"