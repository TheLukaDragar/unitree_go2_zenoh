#!/bin/bash

# Remote setup script for zenoh-bridge-dds on Go2 robot via SSH
# Author: Luka Dragar
# Version: 1.0

set -euo pipefail

# Configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly INSTALL_SCRIPT="robot_install.sh"
readonly SERVICE_NAME="zenoh-bridge-dds"
readonly SSH_TIMEOUT="30"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S'): $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S'): $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S'): $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S'): $*"
}

show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] ROBOT_HOST

Setup zenoh-bridge-dds on Go2 robot via SSH

Arguments:
  ROBOT_HOST    SSH hostname or IP address of the robot
                (e.g., root@192.168.1.100 or robot.local)
                Default password: theroboverse

Options:
  -p, --port PORT       SSH port (default: 22)
  -k, --key KEY_FILE    SSH private key file
  -u, --user USER       SSH username (default: root)
  -t, --test            Test connection only, don't install
  --no-start            Install but don't start the service
  --force               Force reinstall even if already installed
  -h, --help            Show this help message

Examples:
  $SCRIPT_NAME root@192.168.1.100
  $SCRIPT_NAME -p 2222 -k ~/.ssh/robot_key root@robot.local
  $SCRIPT_NAME --user unitree --test 192.168.1.100

EOF
}

parse_arguments() {
    SSH_PORT="22"
    SSH_KEY=""
    SSH_USER="root"
    TEST_ONLY=false
    NO_START=false
    FORCE_INSTALL=false
    ROBOT_HOST=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--port)
                SSH_PORT="$2"
                shift 2
                ;;
            -k|--key)
                SSH_KEY="$2"
                shift 2
                ;;
            -u|--user)
                SSH_USER="$2"
                shift 2
                ;;
            -t|--test)
                TEST_ONLY=true
                shift
                ;;
            --no-start)
                NO_START=true
                shift
                ;;
            --force)
                FORCE_INSTALL=true
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
                if [[ -z "$ROBOT_HOST" ]]; then
                    ROBOT_HOST="$1"
                else
                    log_error "Multiple hosts specified"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$ROBOT_HOST" ]]; then
        log_error "Robot host not specified"
        show_usage
        exit 1
    fi

    # Parse user@host format
    if [[ "$ROBOT_HOST" == *"@"* ]]; then
        SSH_USER="${ROBOT_HOST%@*}"
        ROBOT_HOST="${ROBOT_HOST#*@}"
    fi
}

build_ssh_cmd() {
    local ssh_cmd="ssh"
    
    ssh_cmd+=" -p $SSH_PORT"
    
    if [[ -n "$SSH_KEY" ]]; then
        if [[ ! -f "$SSH_KEY" ]]; then
            log_error "SSH key file not found: $SSH_KEY"
            exit 1
        fi
        ssh_cmd+=" -i $SSH_KEY"
    fi
    
    ssh_cmd+=" -o ConnectTimeout=$SSH_TIMEOUT"
    ssh_cmd+=" -o StrictHostKeyChecking=no"
    ssh_cmd+=" -o UserKnownHostsFile=/dev/null"
    ssh_cmd+=" -o ControlMaster=auto"
    ssh_cmd+=" -o ControlPath=/tmp/ssh_mux_%h_%p_%r"
    ssh_cmd+=" -o ControlPersist=60s"
    ssh_cmd+=" -q"
    ssh_cmd+=" $SSH_USER@$ROBOT_HOST"
    
    echo "$ssh_cmd"
}

build_scp_cmd() {
    local scp_cmd="scp"
    
    scp_cmd+=" -P $SSH_PORT"
    
    if [[ -n "$SSH_KEY" ]]; then
        scp_cmd+=" -i $SSH_KEY"
    fi
    
    scp_cmd+=" -o ConnectTimeout=$SSH_TIMEOUT"
    scp_cmd+=" -o StrictHostKeyChecking=no"
    scp_cmd+=" -o UserKnownHostsFile=/dev/null"
    scp_cmd+=" -o ControlMaster=auto"
    scp_cmd+=" -o ControlPath=/tmp/ssh_mux_%h_%p_%r"
    scp_cmd+=" -o ControlPersist=60s"
    scp_cmd+=" -q"
    
    echo "$scp_cmd"
}

test_ssh_connection() {
    log_info "Testing SSH connection to $SSH_USER@$ROBOT_HOST:$SSH_PORT..."
    
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    if $ssh_cmd "echo 'SSH connection successful'" >/dev/null 2>&1; then
        log_success "SSH connection established"
        
        local system_info
        system_info=$($ssh_cmd "uname -a && whoami" 2>/dev/null || echo "Unable to get system info")
        log_info "Remote system: $system_info"
        
        return 0
    else
        log_error "SSH connection failed"
        log_error "Please check:"
        log_error "  - Robot is powered on and connected to network"
        log_error "  - SSH service is running on robot"
        log_error "  - Hostname/IP address is correct: $ROBOT_HOST"
        log_error "  - SSH port is correct: $SSH_PORT"
        log_error "  - Username is correct: $SSH_USER"
        log_error "  - Password is correct (default: theroboverse)"
        [[ -n "$SSH_KEY" ]] && log_error "  - SSH key is correct: $SSH_KEY"
        return 1
    fi
}

check_install_script() {
    if [[ ! -f "$INSTALL_SCRIPT" ]]; then
        log_error "Installation script not found: $INSTALL_SCRIPT"
        log_error "Make sure $INSTALL_SCRIPT is in the same directory as this script"
        exit 1
    fi
    log_info "Found installation script: $INSTALL_SCRIPT"
}

check_existing_installation() {
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    log_info "Checking for existing installation..."
    
    if $ssh_cmd "systemctl list-unit-files | grep -q $SERVICE_NAME && test -f /usr/local/bin/zenoh-bridge-dds" 2>/dev/null; then
        if [[ "$FORCE_INSTALL" == "true" ]]; then
            log_warn "Existing installation found, but --force specified. Will reinstall."
            return 1
        else
            log_warn "zenoh-bridge-dds appears to be already installed"
            log_info "Use --force to reinstall, or --test to check status"
            
            local status
            status=$($ssh_cmd "systemctl is-active $SERVICE_NAME 2>/dev/null || echo 'inactive'")
            log_info "Current service status: $status"
            
            return 0
        fi
    fi
    
    return 1
}

run_remote_installation() {
    log_info "Copying installation script to robot..."
    
    local ssh_cmd scp_cmd
    ssh_cmd=$(build_ssh_cmd)
    scp_cmd=$(build_scp_cmd)
    
    # Copy the installation script
    if ! $scp_cmd "$INSTALL_SCRIPT" "$SSH_USER@$ROBOT_HOST:/tmp/robot_install.sh"; then
        log_error "Failed to copy installation script"
        return 1
    fi
    
    log_info "Executing installation script on robot..."
    
    # Execute the script remotely
    if $ssh_cmd "chmod +x /tmp/robot_install.sh && sudo /tmp/robot_install.sh"; then
        log_success "Remote installation completed successfully"
        
        # Clean up
        $ssh_cmd "rm -f /tmp/robot_install.sh" 2>/dev/null || true
        
        return 0
    else
        log_error "Remote installation failed"
        return 1
    fi
}

start_service() {
    log_info "Starting zenoh-bridge-dds service..."
    
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    if $ssh_cmd "sudo systemctl start $SERVICE_NAME"; then
        log_success "Service started successfully"
        
        sleep 2
        local status
        status=$($ssh_cmd "systemctl is-active $SERVICE_NAME" 2>/dev/null || echo "failed")
        log_info "Service status: $status"
        
        local robot_ip
        robot_ip=$($ssh_cmd "hostname -I | awk '{print \$1}'" 2>/dev/null || echo "unknown")
        
        log_success "Setup complete! Service is running on $robot_ip"
        echo
        echo "REST API available at:"
        echo "  http://$robot_ip:8000"
        echo "  http://localhost:8000 (from robot)"
        echo
        echo "To test the installation:"
        echo "  ssh $SSH_USER@$ROBOT_HOST 'sudo /unitree/zenoh/test_bridge.sh'"
        
    else
        log_error "Failed to start service"
        return 1
    fi
}

run_remote_tests() {
    log_info "Running remote tests..."
    
    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd)
    
    $ssh_cmd "sudo /unitree/zenoh/test_bridge.sh 2>/dev/null || echo 'Tests failed or service not installed'"
}

main() {
    log_info "Remote Go2 Robot Setup - zenoh-bridge-dds"
    echo "=============================================="
    
    parse_arguments "$@"
    
    log_info "Configuration:"
    log_info "  Target: $SSH_USER@$ROBOT_HOST:$SSH_PORT"
    [[ -n "$SSH_KEY" ]] && log_info "  SSH Key: $SSH_KEY"
    log_info "  Test only: $TEST_ONLY"
    log_info "  Force install: $FORCE_INSTALL"
    echo
    
    # Check for installation script
    check_install_script
    
    # Test SSH connection
    if ! test_ssh_connection; then
        exit 1
    fi
    
    if [[ "$TEST_ONLY" == "true" ]]; then
        log_info "Test mode - running remote diagnostics..."
        run_remote_tests
        exit 0
    fi
    
    # Check existing installation
    if check_existing_installation; then
        log_info "Installation already exists and working"
        exit 0
    fi
    
    # Run installation
    if ! run_remote_installation; then
        exit 1
    fi
    
    # Start service unless --no-start specified
    if [[ "$NO_START" != "true" ]]; then
        start_service
    else
        log_info "Service installed but not started (--no-start specified)"
        log_info "To start manually: ssh $SSH_USER@$ROBOT_HOST 'sudo systemctl start $SERVICE_NAME'"
    fi
    
    log_success "Remote setup completed successfully!"
    
    # Clean up SSH connection
    cleanup_ssh_connection
}

# Clean up SSH multiplexing connection
cleanup_ssh_connection() {
    local control_path="/tmp/ssh_mux_${ROBOT_HOST}_${SSH_PORT}_${SSH_USER}"
    if [[ -S "$control_path" ]]; then
        ssh -o ControlPath="$control_path" -O exit "$SSH_USER@$ROBOT_HOST" 2>/dev/null || true
        log_info "SSH connection cleaned up"
    fi
}

main "$@" 