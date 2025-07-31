# Zenoh Bridge DDS Setup

## Overview

Bridges DDS communication between Go2 robot and development machine using Zenoh protocol.

**Tested Environment:**
- Development Machine: MacBook M1 (Apple Silicon)
- Robot: Unitree Go2 Pro (jailbroken)

## Architecture

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│   Go2 Robot     │         │     Network     │         │  Dev Machine    │
│                 │         │                 │         │                 │
│ DDS Domain 0    │◄────────┤                 ├────────►│ DDS Domain 0    │
│ zenoh-bridge    │         │                 │         │ zenoh-bridge    │
│ Port: 7447      │         │  TCP/IP Link    │         │ Port: 7447      │
│ REST: 8000      │         │                 │         │ REST: 8001      │
│ (all interfaces)│         │                 │         │ (dev IP + local)│
└─────────────────┘         └─────────────────┘         └─────────────────┘
        │                                                        │
        │                                                        │
        ▼                                                        ▼
┌─────────────────┐                                     ┌─────────────────┐
│ Robot Topics:   │                                     │ Client Apps:    │
│ rt/lowstate     │                                     │ DDS Subscribers │
│ rt/sportmode    │                                     │ REST Clients    │
│ rt/servicestate │                                     │ curl/browser    │
└─────────────────┘                                     └─────────────────┘
```

## Setup Commands

### Robot Setup (Remote)
```bash
# Basic setup with local network IP
./setup_robot_remote.sh root@<robot_ip>

# Setup with custom SSH port
./setup_robot_remote.sh -p 2222 root@<robot_ip>

# Setup with SSH key
./setup_robot_remote.sh -k ~/.ssh/robot_key root@<robot_ip>

# Test connection only (don't install)
./setup_robot_remote.sh --test root@<robot_ip>
```
This script will:
- Connect to the robot via SSH (user: root, password: theroboverse)
- Download and install zenoh-bridge-dds on the robot
- Create systemd service for auto-start on boot
- Configure the bridge to listen on port 7447 (all interfaces)
- Start the service automatically
- Provide REST API on port 8000

### Development Machine Setup

#### Local Network Setup
```bash
./setup_dev_machine.sh <robot_ip>
```

#### Extra: Tailscale Setup (for Remote Access)
```bash
./setup_dev_machine.sh <robot_tailscale_ip> --tailscale
```

These scripts will:
- Download zenoh-bridge-dds for your platform (macOS/Linux)
- Install to ~/zenoh directory
- Create start and test scripts
- Configure connection to robot at specified IP
- Set up REST API on port 8001
- Auto-detect Tailscale IPs when `--tailscale` flag is used

## Usage Commands

### Start Bridge (Dev Machine)
```bash
cd ~/zenoh
./start_bridge.sh
```
This script will:
- Start the zenoh-bridge-dds process in foreground
- Connect to robot at tcp://ROBOT_IP:7447
- Listen on both dev machine IP and localhost (tcp://DEV_IP:7447, tcp://127.0.0.1:7447)
- Enable REST API on http://localhost:8001
- Bridge all DDS topics with scope "go2"

### Test Connection
```bash
cd ~/zenoh
./test_connection.sh
```
This script will:
- Check if bridge is responding on REST API
- Verify connection to robot
- List active DDS routes
- Show available robot topics
- Display connection status and troubleshooting tips

### Manual Bridge Start
```bash
./zenoh-bridge-dds \
    --mode peer \
    --connect tcp/<robot_ip>:7447 \
    --listen tcp/<dev_ip>:7447 \
    --listen tcp/127.0.0.1:7447 \
    --domain 0 \
    --scope go2 \
    --rest-http-port 8001
```
This command will:
- Run bridge in peer mode (direct connection)
- Connect to robot's zenoh bridge
- Accept DDS connections on both dev machine IP and localhost
- Filter DDS topics by "go2" scope
- Provide REST monitoring on port 8001

## REST API Endpoints

### Local Access
```bash
# Bridge version - Shows zenoh-bridge-dds version info
curl http://localhost:8001/@/*/dds/version

# Active routes - Lists all DDS topics being bridged
curl http://localhost:8001/@/*/dds/route/**

# Bridge status - Shows zenoh router statistics
curl http://localhost:8001/@/router/*/stats
```
These endpoints will:
- Return JSON data about bridge status
- Show which robot topics are available
- Display connection health and performance metrics
- Help diagnose connectivity issues

## Robot Service Management

```bash
# Start service - Begins zenoh bridge on robot
sudo systemctl start zenoh-bridge-dds

# Stop service - Stops zenoh bridge on robot  
sudo systemctl stop zenoh-bridge-dds

# Check status - Shows if service is running and healthy
sudo systemctl status zenoh-bridge-dds

# View logs - Live stream of bridge activity and errors
sudo journalctl -u zenoh-bridge-dds -f

# Test bridge on robot - Run diagnostics and show status
sudo /unitree/zenoh/test_bridge.sh
```
These commands will:
- Control the robot-side zenoh bridge service
- Show service health and startup status
- Display real-time logs for debugging
- Manage auto-start behavior on robot boot
- Test bridge connectivity and show available DDS topics

## Configuration Files

### Robot: `/unitree/zenoh/config.json5`
```json5
{
  mode: "peer",
  listen: {
    endpoints: ["tcp/0.0.0.0:7447"]
  },
  plugins: {
    dds: {
      domain: 0,
      scope: "go2",
      localhost_only: false
    },
    rest: {
      http_port: 8000
    }
  }
}
```

### Development Machine: `~/zenoh/config.json5`
```json5
{
  "mode": "peer",
  "connect": {
    "endpoints": [
      "tcp/<robot_ip>:7447"
    ]
  },
  "listen": {
    "endpoints": [
      "tcp/<dev_ip>:7447",
      "tcp/127.0.0.1:7447"
    ]
  },
  "plugins": {
    "dds": {
      "domain": 0,
      "scope": "go2"
    },
    "rest": {
      "http_port": "8001"
    }
  }
}
```

## Port Configuration

### Robot vs Development Machine
- **Robot**: Listens on `0.0.0.0:7447` (all interfaces) with REST API on port 8000
- **Development Machine**: Listens on both dev IP and `127.0.0.1:7447` with REST API on port 8001
- **DDS Domain**: Both use domain 0 with scope "go2"

### Tailscale Considerations
- **Robot**: Automatically listens on all interfaces, so Tailscale IPs are accessible
- **Development Machine**: Must be configured with `--tailscale` flag to use Tailscale IPs
- **Connection**: Robot can be reached via local network IP or Tailscale IP

## Troubleshooting

### Check Network Connectivity
```bash
# Test basic connectivity to robot
ping <robot_ip>

# Test if zenoh port is accessible on robot
telnet <robot_ip> 7447
```
These commands will:
- Verify robot is reachable on network
- Check if zenoh bridge is listening on robot
- Identify network-level connectivity issues

### Tailscale Connectivity
```bash
# Check if Tailscale is installed and running
tailscale status

# Get your Tailscale IP
tailscale ip -4

# Test connectivity to robot's Tailscale IP
ping <robot_tailscale_ip>
```

## Demo - Camera Feed Test

After setting up the bridge infrastructure, you can test the connection with a camera feed demo:

```bash
cd demo
./setup.sh  # Install dependencies (one-time setup)
uv run test_dds.py  # Test camera feed via DDS bridge
uv run test_lowstate_imu.py  # Test IMU data via DDS bridge
```

This demo will:
- Connect to the Go2 robot's video service via DDS
- Display live camera feed in a window
- Save a snapshot as `front_image.jpg` when you exit (ESC key)
- Show proper error messages if robot/bridge is not connected

**Requirements:**
- Python 3.8+ (tested with 3.12) 
- CyclonDDS (automatically installed by setup script)
- OpenCV for video display
- unitree_sdk2py (automatically installed by setup script)
- **Working zenoh bridge setup** (follow setup instructions above first)

**Note:** This demo connects directly to the robot's DDS topics. Make sure the zenoh bridge is running on both robot and development machine before testing.
