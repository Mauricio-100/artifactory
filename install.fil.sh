#!/bin/bash

# SeaweedFS Component Startup Script with Auto-Installation
set -e

# Configuration
DATA_DIR="/tmp/seaweedfs-$(date +%Y%m%d-%H%M%S)"
MASTER_PORT=9333
VOLUME_PORT=8080
FILER_PORT=8888
WEED_BINARY="${WEED_BINARY:-weed}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Auto-install SeaweedFS if not found
install_seaweedfs() {
    log_step "SeaweedFS not found. Installing automatically..."
    
    local install_dir="/tmp/seaweedfs-install"
    mkdir -p "$install_dir"
    cd "$install_dir"
    
    # Detect architecture
    local arch
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) arch="amd64" ;;
    esac
    
    log_info "Downloading SeaweedFS for architecture: $arch"
    
    # Download latest release
    if command -v wget >/dev/null 2>&1; then
        wget -q "https://github.com/seaweedfs/seaweedfs/releases/latest/download/linux_${arch}.tar.gz" || {
            log_error "Failed to download SeaweedFS"
            return 1
        }
    elif command -v curl >/dev/null 2>&1; then
        curl -s -L -o "linux_${arch}.tar.gz" "https://github.com/seaweedfs/seaweedfs/releases/latest/download/linux_${arch}.tar.gz" || {
            log_error "Failed to download SeaweedFS"
            return 1
        }
    else
        log_error "Neither wget nor curl available. Please install one of them."
        return 1
    fi
    
    # Extract and install
    tar -xzf "linux_${arch}.tar.gz"
    chmod +x weed
    mv weed /usr/local/bin/weed
    
    # Verify installation
    if command -v weed >/dev/null 2>&1; then
        local version
        version=$(weed version 2>/dev/null | head -1 || echo "unknown")
        log_info "✅ SeaweedFS installed successfully: $version"
        return 0
    else
        log_error "❌ SeaweedFS installation failed"
        return 1
    fi
}

# Check and install SeaweedFS if needed
check_and_install_seaweedfs() {
    if command -v "$WEED_BINARY" >/dev/null 2>&1; then
        local version
        version=$("$WEED_BINARY" version 2>/dev/null | head -1 || echo "unknown")
        log_info "Using SeaweedFS: $version"
        return 0
    else
        log_warn "SeaweedFS binary '$WEED_BINARY' not found in PATH"
        
        # Try to install automatically
        if install_seaweedfs; then
            WEED_BINARY="weed"
            return 0
        else
            log_error "Please install SeaweedFS manually:"
            log_info "  wget https://github.com/seaweedfs/seaweedfs/releases/latest/download/linux_amd64.tar.gz"
            log_info "  tar -xzf linux_amd64.tar.gz && chmod +x weed && mv weed /usr/local/bin/"
            return 1
        fi
    fi
}

wait_for_service() {
    local service=$1 port=$2 timeout=30
    log_step "Waiting for $service on port $port..."
    
    local count=0
    while [ $count -lt $timeout ]; do
        if nc -z 127.0.0.1 $port 2>/dev/null; then
            log_info "✅ $service is ready"
            return 0
        fi
        sleep 2
        count=$((count + 1))
    done
    log_error "❌ $service failed to start"
    return 1
}

start_master() {
    log_step "Starting Master Server..."
    mkdir -p "$DATA_DIR/master"
    nohup $WEED_BINARY master -port=$MASTER_PORT -mdir="$DATA_DIR/master" -ip=127.0.0.1 > "$DATA_DIR/master.log" 2>&1 &
    echo $! > "$DATA_DIR/master.pid"
    wait_for_service "Master" $MASTER_PORT
}

start_volume() {
    log_step "Starting Volume Server..."
    mkdir -p "$DATA_DIR/volume"
    nohup $WEED_BINARY volume -port=$VOLUME_PORT -dir="$DATA_DIR/volume" -mserver="127.0.0.1:$MASTER_PORT" -ip=127.0.0.1 > "$DATA_DIR/volume.log" 2>&1 &
    echo $! > "$DATA_DIR/volume.pid"
    wait_for_service "Volume" $VOLUME_PORT
}

start_filer() {
    log_step "Starting Filer..."
    mkdir -p "$DATA_DIR/filer"
    nohup $WEED_BINARY filer -port=$FILER_PORT -master="127.0.0.1:$MASTER_PORT" -ip=127.0.0.1 > "$DATA_DIR/filer.log" 2>&1 &
    echo $! > "$DATA_DIR/filer.pid"
    wait_for_service "Filer" $FILER_PORT
}

stop_services() {
    log_step "Stopping services..."
    for component in filer volume master; do
        if [ -f "$DATA_DIR/$component.pid" ]; then
            pid=$(cat "$DATA_DIR/$component.pid")
            if kill -0 $pid 2>/dev/null; then
                kill $pid && log_info "Stopped $component (PID: $pid)" || log_warn "Failed to stop $component"
            fi
            rm -f "$DATA_DIR/$component.pid"
        fi
    done
}

show_status() {
    log_step "Cluster Status:"
    echo "Master:  http://127.0.0.1:$MASTER_PORT"
    echo "Volume:  http://127.0.0.1:$VOLUME_PORT" 
    echo "Filer:   http://127.0.0.1:$FILER_PORT"
    echo "Data:    $DATA_DIR"
    echo ""
    echo "Logs:    $DATA_DIR/*.log"
}

main() {
    log_info "🚀 Starting SeaweedFS Cluster..."
    
    # Check and install SeaweedFS if needed
    if ! check_and_install_seaweedfs; then
        exit 1
    fi
    
    mkdir -p "$DATA_DIR"
    log_info "Data directory: $DATA_DIR"
    
    # Set cleanup trap
    trap 'log_step "Cleaning up..."; stop_services; log_info "Cleanup completed"' EXIT INT TERM
    
    # Start components
    start_master
    start_volume
    start_filer
    
    # Show final status
    echo ""
    log_info "🎉 SeaweedFS cluster started successfully!"
    show_status
    
    log_info "Press Ctrl+C to stop all services"
    
    # Keep running
    while true; do sleep 60; done
}

# Parse arguments
case "${1:-}" in
    stop)
        stop_services
        ;;
    status)
        show_status
        ;;
    install)
        install_seaweedfs
        ;;
    *)
        main
        ;;
esac
