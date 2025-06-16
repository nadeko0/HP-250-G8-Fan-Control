#!/bin/bash
# HP 250 G8 Universal Thermal Control Installer
# Supports: GRUB, systemd-boot, various distributions
# Automatically configures everything necessary for operation

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

# Check for root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Root privileges are required. Run: sudo $0"
        exit 1
    fi
}

# System detection
detect_system() {
    log_step "Detecting system..."

    # Operating System
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_ID="$ID"
        log_info "OS: $OS_NAME"
    else
        log_warn "Failed to detect OS"
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

    # Check debugfs mount
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
    log_info "Setting up ec_sys module..."
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
EMERGENCY_TEMP=95
CHECK_INTERVAL=3
HYSTERESIS=3

read_ec() { dd if="$ECIO" bs=1 skip=$1 count=1 2>/dev/null | od -An -tu1 | tr -d ' '; }
write_ec() { echo -n -e "$(printf '\x%02x' $2)" | dd of="$ECIO" bs=1 seek=$1 count=1 conv=notrunc 2>/dev/null; }

set_manual() { write_ec 21 1; }
set_auto() { write_ec 21 0; }
set_fan_off() { write_ec 25 0; }
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
    log_msg "EMERGENCY" "Activating emergency AUTO mode!"
    set_auto
    sleep 1
    # Check if EC mode is still manual (1). If so, it means ec_sys might be stuck.
    # We re-load the module in this case.
    if [ $(read_ec 21) -ne 0 ]; then
        log_msg "EMERGENCY" "Reloading ec_sys module due to EC access issue..."
        # Safely remove and re-insert the module
        rmmod ec_sys 2>/dev/null || true
        sleep 1
        modprobe ec_sys write_support=1 2>/dev/null || true
        sleep 2
        set_auto
    fi
    log_msg "INFO" "AUTO mode restored. Mode=$(read_ec 21)"
}

check_ec() {
    if [ ! -f "$ECIO" ]; then
        log_msg "ERROR" "EC debug interface not accessible. Attempting to load module..."
        modprobe ec_sys write_support=1 2>/dev/null || true
        sleep 2
        if [ ! -f "$ECIO" ]; then
            log_msg "CRITICAL" "Failed to load EC module or access interface!"
            return 1
        fi
    fi
    return 0
}

get_state() { [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "auto"; }
set_state() { echo "$1" > "$STATE_FILE"; }

cleanup() {
    log_msg "INFO" "Termination signal received, restoring AUTO mode for safety..."
    emergency_auto
    rm -f "$STATE_FILE" 2>/dev/null || true # Attempt to remove state file
    exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

main_loop() {
    log_msg "INFO" "HP 250 G8 Thermal Service started (threshold: ${TEMP_THRESHOLD}°C, emergency: ${EMERGENCY_TEMP}°C)"
    local current_state=$(get_state)
    local error_count=0

    while true; do
        # Periodically check EC access to ensure module is still working
        if [ $(($(date +%s) % 30)) -eq 0 ]; then # Check every 30 seconds
            if ! check_ec; then
                error_count=$((error_count + 1))
                if [ $error_count -gt 3 ]; then
                    log_msg "CRITICAL" "Too many consecutive EC access errors, shutting down service."
                    emergency_auto # Attempt to set auto mode before exiting
                    exit 1
                fi
                sleep $CHECK_INTERVAL
                continue
            fi
            error_count=0 # Reset error count on successful check
        fi

        local temp=$(get_temperature)
        local mode=$(read_ec 21) # Read current EC mode (0=auto, 1=manual)
        local rpm=$(get_rpm) # Read current fan RPM

        # Emergency override: if critical temp, force AUTO mode
        if [ $temp -gt $EMERGENCY_TEMP ]; then
            log_msg "EMERGENCY" "Critical temperature ${temp}°C! Forcing emergency AUTO mode."
            emergency_auto
            set_state "emergency"
            sleep $CHECK_INTERVAL
            continue # Skip normal logic for this cycle
        fi

        case "$current_state" in
            "silent") # Fan is off, waiting for temperature to rise
                if [ $temp -ge $TEMP_THRESHOLD ]; then
                    log_msg "INFO" "Temperature ${temp}°C reached threshold. Activating AUTO fan mode."
                    set_auto
                    current_state="active"
                    set_state "$current_state"
                fi
                ;;
            "active") # Fan is on (in auto mode), waiting for temperature to drop
                if [ $temp -lt $((TEMP_THRESHOLD - HYSTERESIS)) ]; then
                    log_msg "INFO" "Temperature ${temp}°C dropped below threshold. Turning off fan."
                    set_manual # Switch to manual to turn off
                    sleep 0.5
                    set_fan_off
                    current_state="silent"
                    set_state "$current_state"
                fi
                ;;
            "emergency") # In emergency mode, stay here until temperature is significantly lower
                if [ $temp -lt $((EMERGENCY_TEMP - 10)) ]; then
                    log_msg "INFO" "Exiting emergency mode, temperature ${temp}°C is now safe."
                    set_auto # Ensure auto mode is active upon leaving emergency
                    current_state="active" # Go back to active state
                    set_state "$current_state"
                fi
                ;;
            *) # Default state or unknown, assume auto
                if [ $temp -ge $TEMP_THRESHOLD ]; then
                    log_msg "INFO" "Temperature ${temp}°C reached threshold. Setting AUTO fan mode."
                    set_auto
                    current_state="active"
                    set_state "$current_state"
                elif [ $temp -lt $((TEMP_THRESHOLD - HYSTERESIS)) ]; then
                    log_msg "INFO" "Temperature ${temp}°C is low. Turning off fan."
                    set_manual
                    sleep 0.5
                    set_fan_off
                    current_state="silent"
                    set_state "$current_state"
                fi
                ;;
        esac

        # Periodically log current status for debugging
        if [ $(($(date +%s) % 10)) -eq 0 ]; then # Log every 10 seconds
            log_msg "STATUS" "Temp: ${temp}°C | State: $current_state | EC Mode: $mode | Fan RPM: $rpm"
        fi

        sleep $CHECK_INTERVAL
    done
}

case "$1" in
    "start") main_loop ;;
    "stop") emergency_auto; rm -f "$STATE_FILE" 2>/dev/null || true; log_msg "INFO" "Service stopped and fan set to auto." ;;
    "status")
        temp=$(get_temperature)
        mode=$(read_ec 21)
        rpm=$(get_rpm)
        state=$(get_state)
        echo "HP 250 G8 Thermal Service Status:"
        echo "  Temperature: ${temp}°C"
        echo "  Service State: $state"
        echo "  EC Fan Mode: $mode (0=auto, 1=manual)"
        echo "  Fan RPM: $rpm"
        echo "  Configured Threshold: ${TEMP_THRESHOLD}°C"
        ;;
    "auto") emergency_auto ;; # Forces fan to auto mode, useful for service restart/reload
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

    mkdir -p /var/log 2>/dev/null || true # Ensure log directory exists
    touch /var/log/hp-thermal.log 2>/dev/null || true # Create log file if it doesn't exist
    systemctl daemon-reload
    log_info "Thermal service created and systemd reloaded."
}

# Diagnostics
run_diagnostics() {
    log_step "Running system diagnostics..."

    echo "=== HP 250 G8 THERMAL SYSTEM DIAGNOSTICS ==="
    echo "Time: $(date)"
    echo "OS: $OS_NAME ($OS_ID)"
    echo "Bootloader: $BOOTLOADER"
    echo "Kernel: $KERNEL_VERSION"
    echo

    echo "--- EC Access ---"
    if [ -f /sys/kernel/debug/ec/ec0/io ]; then
        echo "✓ EC debug interface accessible."
        ls -la /sys/kernel/debug/ec/ec0/io
    else
        echo "✗ EC debug interface not accessible."
        echo "Checking debugfs mount status..."
        mount | grep debugfs || echo "debugfs is NOT mounted."
        echo "Checking udev rules for EC..."
        cat /etc/udev/rules.d/99-ec-debug.rules 2>/dev/null || echo "udev rule file not found."
    fi

    echo -e "\n--- Kernel Modules ---"
    if lsmod | grep -q ec_sys; then
        echo "✓ ec_sys module loaded."
        modinfo ec_sys | grep "parm:.*write_support" || echo "Warning: ec_sys loaded but write_support option not visible."
    else
        echo "✗ ec_sys module NOT loaded."
        echo "Check /etc/modules-load.d/ec_sys.conf and /etc/modprobe.d/ec_sys.conf."
    fi

    echo -e "\n--- HP Thermal Service Status ---"
    if systemctl is-active --quiet hp-thermal; then
        echo "✓ HP Thermal Service is ACTIVE."
        /usr/local/bin/hp-thermal-service.sh status 2>/dev/null || echo "Error getting service status."
    else
        echo "✗ HP Thermal Service is INACTIVE."
    fi
    echo "Service logs (last 20 lines):"
    journalctl -u hp-thermal --no-pager -n 20 2>/dev/null || echo "No logs found or error accessing journal."


    echo -e "\n--- Temperature Readings ---"
    sensors 2>/dev/null | head -10 || echo "lm_sensors not available or no readings."
    echo "Falling back to /sys/class/thermal/thermal_zone* temp:"
    cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -5 | xargs -I {} echo $(( {} / 1000 ))"°C" || echo "No thermal zone temperatures found."

    echo -e "\n=== DIAGNOSTICS COMPLETE ==="
}

# Main function
main() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              HP 250 G8 Universal Thermal Installer          ║"
    echo "║                    Version 2.0 - 2025                        ║"
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

            log_step "Running diagnostics after installation attempt..."
            run_diagnostics

            echo -e "\n${GREEN}✅ INSTALLATION PROCESS COMPLETE!${NC}"
            echo "Please check the diagnostics output above for any warnings or errors."
            echo
            echo "To manage the service:"
            echo "  sudo systemctl start hp-thermal     # Start the service"
            echo "  sudo systemctl enable hp-thermal    # Enable autostart on boot"
            echo "  sudo systemctl status hp-thermal    # Check current service status"
            echo "  sudo journalctl -u hp-thermal -f    # View real-time service logs"
            echo

            read -p "Enable service autostart on boot? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                systemctl enable hp-thermal
                log_info "Autostart enabled."

                read -p "Start service now? (y/N): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    systemctl start hp-thermal
                    sleep 3 # Give it a moment to start
                    systemctl status hp-thermal --no-pager # Show status without paging
                fi
            else
                log_info "Autostart not enabled. You can manually enable it later with: sudo systemctl enable hp-thermal"
            fi
            ;;

        "uninstall")
            log_step "Uninstalling HP Thermal System..."
            systemctl stop hp-thermal 2>/dev/null || true
            systemctl disable hp-thermal 2>/dev/null || true
            /usr/local/bin/hp-thermal-service.sh auto 2>/dev/null || true # Ensure fan is set to auto before removal

            rm -f /etc/systemd/system/hp-thermal.service
            rm -f /usr/local/bin/hp-thermal-service.sh
            rm -f /etc/modules-load.d/ec_sys.conf
            rm -f /etc/modprobe.d/ec_sys.conf
            rm -f /etc/udev/rules.d/99-ec-debug.rules
            rm -f /tmp/hp-thermal-state
            rm -f /var/log/hp-thermal.log # Remove log file too

            systemctl daemon-reload # Reload systemd configs
            udevadm control --reload-rules # Reload udev rules

            # Optional: Attempt to unload ec_sys if no longer needed by other processes
            # This is tricky as other things might use it. Better to leave it to next reboot.
            # modprobe -r ec_sys 2>/dev/null || true

            log_info "Uninstallation complete. A reboot might be beneficial to fully apply changes."
            ;;

        "diagnose")
            detect_system
            run_diagnostics
            ;;

        "fix")
            log_step "Attempting to fix issues..."
            # Re-run setup steps which should fix common misconfigurations
            setup_debugfs
            setup_modules
            # Attempt to restart the service if it exists
            systemctl daemon-reload
            systemctl restart hp-thermal 2>/dev/null || true
            log_step "Running diagnostics after fix attempt..."
            run_diagnostics
            ;;

        *) # Default case for invalid arguments
            echo "Usage: $0 [install|uninstall|diagnose|fix]"
            echo "  install   - Performs a full installation (default action if no argument is given)."
            echo "  uninstall - Removes all installed components of the thermal system."
            echo "  diagnose  - Runs a diagnostic check to verify system components."
            echo "  fix       - Attempts to reconfigure/restart components to resolve issues."
            exit 1
            ;;
    esac
}

# Execute the main function with all arguments passed to the script
main "$@"
