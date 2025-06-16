#!/bin/bash
# HP 250 G8 Universal Thermal Control Installer
# Supports: GRUB, systemd-boot, various distributions
# Automatically configures everything needed for operation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Output functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }
log_step() { echo -e "${PURPLE}[STEP]${NC} $1"; }

# Check root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Root privileges required. Run: sudo $0"
        exit 1
    fi
}

# System detection
detect_system() {
    log_step "Detecting system..."
    
    # Operating system
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_ID="$ID"
        log_info "OS: $OS_NAME"
    else
        log_warn "Could not determine OS"
        OS_ID="unknown"
    fi
    
    # Bootloader type
    if [ -d /sys/firmware/efi ]; then
        UEFI_MODE=true
        log_info "Mode: UEFI"
        
        if command -v bootctl &> /dev/null && bootctl status 2>/dev/null | grep -q "systemd-boot"; then
            BOOTLOADER="systemd-boot"
            BOOT_DIR="/efi"
            ENTRIES_DIR="/efi/loader/entries"
        elif [ -f /boot/grub/grub.cfg ] || [ -f /etc/default/grub ]; then
            BOOTLOADER="grub"
            BOOT_DIR="/boot"
        else
            BOOTLOADER="unknown"
        fi
    else
        UEFI_MODE=false
        BOOTLOADER="grub"
        BOOT_DIR="/boot"
        log_info "Mode: Legacy BIOS"
    fi
    
    log_info "Bootloader: $BOOTLOADER"
    
    # Kernel version
    KERNEL_VERSION=$(uname -r)
    log_info "Kernel: $KERNEL_VERSION"
}

# Setup debugfs
setup_debugfs() {
    log_step "Setting up debugfs..."
    
    # Check debugfs mounting
    if ! mount | grep -q debugfs; then
        log_info "Mounting debugfs..."
        mount -t debugfs none /sys/kernel/debug
    fi
    
    # Add to fstab if not present
    if ! grep -q debugfs /etc/fstab; then
        log_info "Adding debugfs to fstab..."
        echo "debugfs /sys/kernel/debug debugfs defaults 0 0" >> /etc/fstab
    fi
    
    # Create udev rule for EC access
    log_info "Creating udev rule for EC access..."
    cat > /etc/udev/rules.d/99-ec-debug.rules << 'UDEV_EOF'
# HP EC Debug Access
SUBSYSTEM=="acpi", KERNEL=="PNP0C09:*", MODE="0666"
KERNEL=="ec0", MODE="0666"
ACTION=="add", KERNEL=="ec0", RUN+="/bin/chmod 666 /sys/kernel/debug/ec/ec0/io"
UDEV_EOF
    
    # Reload udev rules
    udevadm control --reload-rules
    udevadm trigger
}

# Setup modules
setup_modules() {
    log_step "Setting up kernel modules..."
    
    # ec_sys module
    log_info "Configuring ec_sys module..."
    echo "ec_sys" > /etc/modules-load.d/ec_sys.conf
    echo "options ec_sys write_support=1" > /etc/modprobe.d/ec_sys.conf
    
    # Load module now
    modprobe -r ec_sys 2>/dev/null || true
    modprobe ec_sys write_support=1
    
    log_info "Modules configured"
}

# Create thermal service
create_thermal_service() {
    log_step "Creating HP Thermal Service..."
    
    # Main script
    cat > /usr/local/bin/hp-thermal-service.sh << 'THERMAL_EOF'
#!/bin/bash
# HP 250 G8 Smart Thermal Service
ECIO=/sys/kernel/debug/ec/ec0/io
LOG_FILE="/var/log/hp-thermal.log"
STATE_FILE="/tmp/hp-thermal-state"
TEMP_THRESHOLD=60
EMERGENCY_COOLING_TEMP=90
COOLING_RECOVERY_TEMP=85
EMERGENCY_TEMP=95
CHECK_INTERVAL=3
HYSTERESIS=3
COOLING_DOWN_TIME=120

read_ec() { dd if="$ECIO" bs=1 skip=$1 count=1 2>/dev/null | od -An -tu1 | tr -d ' '; }
write_ec() { echo -n -e "$(printf '\x%02x' $2)" | dd of="$ECIO" bs=1 seek=$1 count=1 conv=notrunc 2>/dev/null; }

set_manual() { write_ec 21 1; }
set_auto() { write_ec 21 0; }
set_fan_off() { write_ec 25 0; }
set_fan_speed() { write_ec 25 $1; }
set_max_speed() { write_ec 25 45; }
get_rpm() { read_ec 17; }

log_msg() {
    local level=$1
    shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" | tee -a "$LOG_FILE"
}

get_temperature() {
    local temp=$(sensors 2>/dev/null | grep "Package id 0" | grep -o "+[0-9]*" | head -1 | tr -d '+')
    if [ -z "$temp" ]; then
        temp=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -1)
        [ -n "$temp" ] && temp=$((temp / 1000))
    fi
    echo ${temp:-0}
}

emergency_auto() {
    log_msg "EMERGENCY" "Enabling emergency AUTO mode!"
    set_auto
    sleep 1
    if [ $(read_ec 21) -ne 0 ]; then
        log_msg "EMERGENCY" "Reloading ec_sys module..."
        rmmod ec_sys 2>/dev/null
        sleep 1
        modprobe ec_sys write_support=1
        sleep 2
        set_auto
    fi
    log_msg "INFO" "AUTO mode restored. Mode=$(read_ec 21)"
}

emergency_cooling() {
    log_msg "EMERGENCY" "Critical temperature! Starting emergency cooling at max speed"
    set_manual
    sleep 0.5
    set_max_speed
    log_msg "INFO" "Max cooling for 5 seconds..."
    
    for i in {1..5}; do
        local temp=$(get_temperature)
        local rpm=$(get_rpm)
        log_msg "COOLING" "[$i/5] Temp: ${temp}°C | RPM: $rpm"
        sleep 1
    done
    
    local temp=$(get_temperature)
    log_msg "INFO" "Emergency cooling complete. Temperature: ${temp}°C"
    
    if [ $temp -lt $COOLING_RECOVERY_TEMP ]; then
        log_msg "INFO" "Temperature below ${COOLING_RECOVERY_TEMP}°C, starting 2-minute cooling down period"
        set_auto
        echo "$(date +%s)" > /tmp/hp-thermal-cooling-start
        return 0
    else
        log_msg "WARN" "Temperature still high (${temp}°C), keeping max cooling"
        return 1
    fi
}

check_ec() {
    if [ ! -f "$ECIO" ]; then
        log_msg "ERROR" "EC unavailable, loading module..."
        modprobe ec_sys write_support=1 2>/dev/null
        sleep 2
        if [ ! -f "$ECIO" ]; then
            log_msg "CRITICAL" "Failed to load EC module!"
            return 1
        fi
    fi
    return 0
}

get_state() { [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "auto"; }
set_state() { echo "$1" > "$STATE_FILE"; }

is_cooling_down_expired() {
    local cooling_start_file="/tmp/hp-thermal-cooling-start"
    if [ -f "$cooling_start_file" ]; then
        local start_time=$(cat "$cooling_start_file")
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        if [ $elapsed -ge $COOLING_DOWN_TIME ]; then
            rm -f "$cooling_start_file"
            return 0  # Cooling down period expired
        else
            local remaining=$((COOLING_DOWN_TIME - elapsed))
            return 1  # Still cooling down (return remaining time via global var)
        fi
    else
        return 0  # No cooling down period
    fi
}

cleanup() {
    log_msg "INFO" "Received termination signal, restoring AUTO mode..."
    emergency_auto
    rm -f "$STATE_FILE"
    rm -f /tmp/hp-thermal-cooling-start
    exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

main_loop() {
    log_msg "INFO" "HP 250 G8 Thermal Service started (threshold: ${TEMP_THRESHOLD}°C)"
    local current_state=$(get_state)
    local error_count=0
    
    while true; do
        if [ $(($(date +%s) % 30)) -eq 0 ]; then
            if ! check_ec; then
                error_count=$((error_count + 1))
                if [ $error_count -gt 3 ]; then
                    log_msg "CRITICAL" "Too many EC errors, shutting down"
                    emergency_auto
                    exit 1
                fi
                sleep $CHECK_INTERVAL
                continue
            fi
            error_count=0
        fi
        
        local temp=$(get_temperature)
        local mode=$(read_ec 21)
        local rpm=$(get_rpm)
        
        if [ $temp -gt $EMERGENCY_TEMP ]; then
            log_msg "EMERGENCY" "Critical temperature ${temp}°C! Emergency AUTO enable"
            emergency_auto
            set_state "emergency"
            sleep $CHECK_INTERVAL
            continue
        elif [ $temp -gt $EMERGENCY_COOLING_TEMP ]; then
            log_msg "EMERGENCY" "High temperature ${temp}°C! Starting emergency cooling"
            if emergency_cooling; then
                current_state="cooling_down"
                set_state "$current_state"
            else
                current_state="emergency_cooling"
                set_state "$current_state"
            fi
            sleep $CHECK_INTERVAL
            continue
        fi
        
        case "$current_state" in
            "silent"|"auto")
                if [ $temp -ge $TEMP_THRESHOLD ]; then
                    log_msg "INFO" "Temperature ${temp}°C >= ${TEMP_THRESHOLD}°C, enabling AUTO mode"
                    set_auto
                    current_state="active"
                    set_state "$current_state"
                elif [ $temp -lt $((TEMP_THRESHOLD - HYSTERESIS)) ] && [ "$current_state" != "silent" ]; then
                    log_msg "INFO" "Temperature ${temp}°C < $((TEMP_THRESHOLD - HYSTERESIS))°C, turning off fan"
                    set_manual
                    sleep 0.5
                    set_fan_off
                    current_state="silent"
                    set_state "$current_state"
                fi
                ;;
            "active")
                if [ $temp -lt $((TEMP_THRESHOLD - HYSTERESIS)) ]; then
                    log_msg "INFO" "Temperature dropped to ${temp}°C, turning off fan"
                    set_manual
                    sleep 0.5
                    set_fan_off
                    current_state="silent"
                    set_state "$current_state"
                fi
                ;;
            "emergency")
                if [ $temp -lt $((EMERGENCY_TEMP - 10)) ]; then
                    log_msg "INFO" "Exiting emergency mode, temperature ${temp}°C"
                    current_state="active"
                    set_state "$current_state"
                fi
                ;;
            "emergency_cooling")
                if [ $temp -lt $COOLING_RECOVERY_TEMP ]; then
                    log_msg "INFO" "Emergency cooling successful, temperature ${temp}°C"
                    set_auto
                    current_state="active"
                    set_state "$current_state"
                elif [ $temp -gt $EMERGENCY_TEMP ]; then
                    log_msg "EMERGENCY" "Temperature still critical! Switching to emergency AUTO"
                    emergency_auto
                    current_state="emergency"
                    set_state "$current_state"
                fi
                ;;
            "cooling_down")
                if is_cooling_down_expired; then
                    if [ $temp -lt $((TEMP_THRESHOLD - HYSTERESIS)) ]; then
                        log_msg "INFO" "Cooling down period completed. Temperature ${temp}°C, switching to silent mode"
                        set_manual
                        sleep 0.5
                        set_fan_off
                        current_state="silent"
                        set_state "$current_state"
                    else
                        log_msg "INFO" "Cooling down period completed. Temperature ${temp}°C, staying in active mode"
                        current_state="active"
                        set_state "$current_state"
                    fi
                else
                    # Still in cooling down period, keep AUTO mode
                    local cooling_start_file="/tmp/hp-thermal-cooling-start"
                    if [ -f "$cooling_start_file" ]; then
                        local start_time=$(cat "$cooling_start_file")
                        local current_time=$(date +%s)
                        local elapsed=$((current_time - start_time))
                        local remaining=$((COOLING_DOWN_TIME - elapsed))
                        if [ $(($(date +%s) % 30)) -eq 0 ]; then
                            log_msg "INFO" "Cooling down period: ${remaining}s remaining, keeping AUTO mode"
                        fi
                    fi
                    # Check if temperature spikes again
                    if [ $temp -gt $EMERGENCY_COOLING_TEMP ]; then
                        log_msg "WARN" "Temperature spike during cooling down! Restarting emergency cooling"
                        rm -f /tmp/hp-thermal-cooling-start
                        if emergency_cooling; then
                            current_state="cooling_down"
                            set_state "$current_state"
                        else
                            current_state="emergency_cooling"
                            set_state "$current_state"
                        fi
                    fi
                fi
                ;;
        esac
        
        if [ $(($(date +%s) % 30)) -eq 0 ]; then
            local status_msg="Temp: ${temp}°C | State: $current_state | Mode: $mode | RPM: $rpm"
            # Add cooling down info if active
            local cooling_start_file="/tmp/hp-thermal-cooling-start"
            if [ -f "$cooling_start_file" ] && [ "$current_state" = "cooling_down" ]; then
                local start_time=$(cat "$cooling_start_file")
                local current_time=$(date +%s)
                local elapsed=$((current_time - start_time))
                local remaining=$((COOLING_DOWN_TIME - elapsed))
                status_msg="$status_msg | CoolDown: ${remaining}s"
            fi
            log_msg "STATUS" "$status_msg"
        fi
        
        sleep $CHECK_INTERVAL
    done
}

case "$1" in
    "start") main_loop ;;
    "stop") emergency_auto; rm -f "$STATE_FILE"; rm -f /tmp/hp-thermal-cooling-start; log_msg "INFO" "Service stopped" ;;
    "status")
        temp=$(get_temperature)
        mode=$(read_ec 21)
        rpm=$(get_rpm)
        state=$(get_state)
        echo "HP 250 G8 Thermal Service Status:"
        echo "Temperature: ${temp}°C"
        echo "State: $state" 
        echo "EC Mode: $mode (0=auto, 1=manual)"
        echo "Fan RPM: $rpm"
        echo "Threshold: ${TEMP_THRESHOLD}°C"
        
        # Check cooling down status
        local cooling_start_file="/tmp/hp-thermal-cooling-start"
        if [ -f "$cooling_start_file" ]; then
            local start_time=$(cat "$cooling_start_file")
            local current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            local remaining=$((COOLING_DOWN_TIME - elapsed))
            if [ $remaining -gt 0 ]; then
                echo "Cooling Down: ${remaining}s remaining"
            fi
        fi
        ;;
    "auto") emergency_auto ;;
    *) echo "Usage: $0 {start|stop|status|auto}"; exit 1 ;;
esac
THERMAL_EOF

    chmod +x /usr/local/bin/hp-thermal-service.sh
    
    # systemd unit  
    cat > /etc/systemd/system/hp-thermal.service << 'SYSTEMD_EOF'
[Unit]
Description=HP 250 G8 Smart Thermal Management Service
After=multi-user.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hp-thermal-service.sh start
ExecStop=/usr/local/bin/hp-thermal-service.sh stop
ExecReload=/usr/local/bin/hp-thermal-service.sh auto

Restart=on-failure
RestartSec=10
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30

WorkingDirectory=/tmp
User=root
Group=root

Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MemoryMax=50M
CPUQuota=10%

StandardOutput=append:/var/log/hp-thermal.log
StandardError=append:/var/log/hp-thermal.log

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

    mkdir -p /var/log
    touch /var/log/hp-thermal.log
    systemctl daemon-reload
    log_info "Thermal service created"
}

# Diagnostics
run_diagnostics() {
    log_step "Running system diagnostics..."
    
    echo "=== HP 250 G8 THERMAL SYSTEM DIAGNOSTICS ==="
    echo "Time: $(date)"
    echo "Bootloader: $BOOTLOADER" 
    echo "Kernel: $KERNEL_VERSION"
    echo
    
    echo "--- EC Access ---"
    if [ -f /sys/kernel/debug/ec/ec0/io ]; then
        echo "✓ EC debug interface available"
        ls -la /sys/kernel/debug/ec/ec0/io
    else
        echo "✗ EC debug interface unavailable"
        echo "Checking debugfs..."
        mount | grep debugfs || echo "debugfs not mounted"
    fi
    
    echo -e "\n--- Modules ---"
    if lsmod | grep -q ec_sys; then
        echo "✓ ec_sys module loaded"
    else
        echo "✗ ec_sys module not loaded" 
    fi
    
    echo -e "\n--- Thermal Service ---"
    if systemctl is-active --quiet hp-thermal; then
        echo "✓ HP Thermal Service active"
        /usr/local/bin/hp-thermal-service.sh status 2>/dev/null || echo "Error getting status"
    else
        echo "✗ HP Thermal Service inactive"
    fi
    
    echo -e "\n--- Sensors ---"
    sensors 2>/dev/null | head -10 || echo "sensors unavailable"
    
    echo -e "\n=== DIAGNOSTICS COMPLETED ==="
}

# Main function
main() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              HP 250 G8 Universal Thermal Installer          ║"
    echo "║                    Version 2.0 - 2025                       ║"
    echo "║              github.com/nadeko0/HP-250-G8-Fan-Control       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_root
    detect_system
    
    case "${1:-install}" in
        "install")
            log_step "Starting installation..."
            setup_debugfs
            setup_modules
            create_thermal_service
            
            log_step "Post-installation diagnostics..."
            run_diagnostics
            
            echo -e "\n${GREEN}✅ INSTALLATION COMPLETED!${NC}"
            echo
            echo "Management commands:"
            echo "  sudo systemctl start hp-thermal     # Start service"
            echo "  sudo systemctl enable hp-thermal    # Enable autostart"
            echo "  sudo systemctl status hp-thermal    # Check status"
            echo "  sudo journalctl -u hp-thermal -f    # View logs"
            echo
            
            read -p "Enable service autostart? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                systemctl enable hp-thermal
                log_info "Autostart enabled"
                
                read -p "Start service now? (y/N): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    systemctl start hp-thermal
                    sleep 3
                    systemctl status hp-thermal --no-pager
                fi
            fi
            ;;
            
        "uninstall")
            log_step "Uninstalling HP Thermal System..."
            systemctl stop hp-thermal 2>/dev/null || true
            systemctl disable hp-thermal 2>/dev/null || true
            /usr/local/bin/hp-thermal-service.sh auto 2>/dev/null || true
            
            rm -f /etc/systemd/system/hp-thermal.service
            rm -f /usr/local/bin/hp-thermal-service.sh
            rm -f /etc/modules-load.d/ec_sys.conf
            rm -f /etc/modprobe.d/ec_sys.conf
            rm -f /etc/udev/rules.d/99-ec-debug.rules
            rm -f /tmp/hp-thermal-state
            
            systemctl daemon-reload
            udevadm control --reload-rules
            
            log_info "Uninstallation completed"
            ;;
            
        "diagnose")
            detect_system
            run_diagnostics
            ;;
            
        "fix")
            log_step "Attempting to fix issues..."
            setup_debugfs
            setup_modules
            systemctl restart hp-thermal 2>/dev/null || true
            run_diagnostics
            ;;
            
        *)
            echo "Usage: $0 [install|uninstall|diagnose|fix]"
            echo "  install   - Full installation (default)"
            echo "  uninstall - Remove the system"
            echo "  diagnose  - Run diagnostics"
            echo "  fix       - Attempt to fix issues"
            exit 1
            ;;
    esac
}

main "$@"
