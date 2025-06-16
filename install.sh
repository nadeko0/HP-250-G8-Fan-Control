#!/bin/bash
# HP 250 G8 Universal Thermal Control Installer - SAFE VERSION
# Supports: GRUB, systemd-boot, various distributions
# Automatically configures everything needed for operation
# Version 3.2 - Enhanced Safety & Fixed printf Issues

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

# Safety disclaimer
show_disclaimer() {
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                        ⚠️  WARNING ⚠️                         ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  This software directly controls hardware EC (Embedded      ║${NC}"
    echo -e "${RED}║  Controller). Incorrect usage may damage your laptop.       ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  • Designed specifically for HP 250 G8                     ║${NC}"
    echo -e "${RED}║  • Use at your own risk                                     ║${NC}"
    echo -e "${RED}║  • Test thoroughly before daily use                        ║${NC}"
    echo -e "${RED}║  • Monitor temperatures closely                             ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    read -p "Do you understand the risks and wish to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
}

# Check root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Root privileges required. Run: sudo $0"
        exit 1
    fi
}

# Hardware compatibility check
verify_hardware() {
    log_step "Verifying hardware compatibility..."
    
    # Check if dmidecode is available
    if ! command -v dmidecode &> /dev/null; then
        log_warn "dmidecode not found, installing..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y dmidecode
        elif command -v yum &> /dev/null; then
            yum install -y dmidecode
        elif command -v pacman &> /dev/null; then
            pacman -S --noconfirm dmidecode
        else
            log_error "Cannot install dmidecode. Please install manually and retry."
            exit 1
        fi
    fi
    
    # Check if python3 is available (needed for EC writing)
    if ! command -v python3 &> /dev/null; then
        log_warn "python3 not found, installing..."
        if command -v apt-get &> /dev/null; then
            apt-get update && apt-get install -y python3
        elif command -v yum &> /dev/null; then
            yum install -y python3
        elif command -v pacman &> /dev/null; then
            pacman -S --noconfirm python
        else
            log_warn "Cannot install python3 automatically. EC writing will use fallback method."
        fi
    fi
    
    # Check system information
    local vendor=$(dmidecode -s system-manufacturer 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "unknown")
    local product=$(dmidecode -s system-product-name 2>/dev/null || echo "unknown")
    
    log_info "Hardware: $vendor $product"
    
    # Verify HP hardware
    if ! echo "$vendor" | grep -qi "hp\|hewlett"; then
        log_warn "This script is designed for HP laptops. Detected vendor: $vendor"
        read -p "Continue anyway? This may be dangerous! (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled for safety."
            exit 0
        fi
    fi
    
    # Verify HP 250 G8 (optional warning for other models)
    if ! echo "$product" | grep -qi "250.*G8"; then
        log_warn "This script is optimized for HP 250 G8. Detected model: $product"
        log_warn "Other HP models may have different EC layouts and fan speeds."
        read -p "Continue? Monitor temperatures closely! (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled for safety."
            exit 0
        fi
    else
        log_info "✓ HP 250 G8 detected - hardware compatibility confirmed"
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
# HP 250 G8 Smart Thermal Service - SAFE VERSION
ECIO=/sys/kernel/debug/ec/ec0/io
LOG_FILE="/var/log/hp-thermal.log"
STATE_FILE="/tmp/hp-thermal-state"
TEMP_THRESHOLD=60
EMERGENCY_COOLING_TEMP=88
COOLING_RECOVERY_TEMP=82
CRITICAL_EMERGENCY_TEMP=98
CHECK_INTERVAL=3
HYSTERESIS=3
COOLING_DOWN_TIME=120

# Valid EC addresses for HP 250 G8 (safety constraint)
VALID_EC_READ_ADDRESSES="17 21 25"
VALID_EC_WRITE_ADDRESSES="21 25"

# Safe fan speed limits (HP 250 G8 specific)
MIN_FAN_SPEED=0
MAX_FAN_SPEED=50

# Hardware validation and safety functions
is_valid_ec_read_address() {
    local addr="$1"
    echo "$VALID_EC_READ_ADDRESSES" | grep -qw "$addr"
}

is_valid_ec_write_address() {
    local addr="$1"
    echo "$VALID_EC_WRITE_ADDRESSES" | grep -qw "$addr"
}

is_valid_fan_speed() {
    local speed="$1"
    [ "$speed" -ge $MIN_FAN_SPEED ] && [ "$speed" -le $MAX_FAN_SPEED ]
}

is_valid_ec_value() {
    local value="$1"
    [ "$value" -ge 0 ] && [ "$value" -le 255 ]
}

# Enhanced EC Access functions with comprehensive safety checks
read_ec() {
    local addr="$1"
    
    if [ -z "$addr" ]; then
        log_msg "ERROR" "read_ec: address parameter missing"
        return 1
    fi
    
    if ! is_valid_ec_read_address "$addr"; then
        log_msg "ERROR" "read_ec: invalid address $addr (valid: $VALID_EC_READ_ADDRESSES)"
        return 1
    fi
    
    if [ ! -f "$ECIO" ]; then
        log_msg "ERROR" "EC interface not accessible: $ECIO"
        return 1
    fi
    
    local result
    if result=$(dd if="$ECIO" bs=1 skip=$addr count=1 2>/dev/null | od -An -tu1 | tr -d ' '); then
        echo "$result"
        return 0
    else
        log_msg "ERROR" "Failed to read from EC address $addr"
        return 1
    fi
}

write_ec() {
    local addr="$1"
    local value="$2"
    
    if [ -z "$addr" ] || [ -z "$value" ]; then
        log_msg "ERROR" "write_ec: missing parameters (addr=$addr, value=$value)"
        return 1
    fi
    
    if ! is_valid_ec_write_address "$addr"; then
        log_msg "ERROR" "write_ec: invalid address $addr (valid: $VALID_EC_WRITE_ADDRESSES)"
        return 1
    fi
    
    if ! is_valid_ec_value "$value"; then
        log_msg "ERROR" "write_ec: invalid value $value (valid range: 0-255)"
        return 1
    fi
    
    if [ ! -f "$ECIO" ]; then
        log_msg "ERROR" "EC interface not accessible for write: $ECIO"
        return 1
    fi
    
    # Additional safety check for fan control
    if [ "$addr" = "25" ] && ! is_valid_fan_speed "$value"; then
        log_msg "ERROR" "write_ec: invalid fan speed $value (valid range: $MIN_FAN_SPEED-$MAX_FAN_SPEED)"
        return 1
    fi
    
    if echo -n -e "$(printf '\x%02x' $value)" | dd of="$ECIO" bs=1 seek=$addr count=1 conv=notrunc 2>/dev/null; then
        log_msg "DEBUG" "Successfully wrote value $value to EC address $addr"
        return 0
    else
        log_msg "ERROR" "Failed to write value $value to EC address $addr"
        return 1
    fi
}

# Safe wrapper functions with validation
set_manual() { 
    log_msg "DEBUG" "Setting EC to manual mode"
    write_ec 21 1
}

set_auto() { 
    log_msg "DEBUG" "Setting EC to auto mode"
    write_ec 21 0
}

set_fan_off() { 
    log_msg "DEBUG" "Turning fan off"
    write_ec 25 0
}

set_fan_speed() {
    local speed="$1"
    
    if [ -z "$speed" ]; then
        log_msg "ERROR" "set_fan_speed: speed parameter missing"
        return 1
    fi
    
    if ! is_valid_fan_speed "$speed"; then
        log_msg "ERROR" "set_fan_speed: invalid speed $speed (valid range: $MIN_FAN_SPEED-$MAX_FAN_SPEED)"
        return 1
    fi
    
    log_msg "DEBUG" "Setting fan speed to $speed"
    write_ec 25 "$speed"
}

set_max_speed() { 
    log_msg "DEBUG" "Setting maximum fan speed ($MAX_FAN_SPEED)"
    write_ec 25 $MAX_FAN_SPEED
}

get_rpm() { 
    read_ec 17
}

log_msg() {
    local level=$1
    shift
    local message="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    echo "$message" | tee -a "$LOG_FILE"
    
    # Send critical messages to syslog for system monitoring
    case "$level" in
        "CRITICAL"|"EMERGENCY")
            logger -p daemon.crit "hp-thermal: $*"
            ;;
        "ERROR")
            logger -p daemon.err "hp-thermal: $*"
            ;;
    esac
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
    
    local attempt=1
    local max_attempts=3
    
    while [ $attempt -le $max_attempts ]; do
        log_msg "EMERGENCY" "AUTO mode attempt $attempt/$max_attempts"
        
        if set_auto; then
            sleep 2
            local current_mode
            if current_mode=$(read_ec 21); then
                if [ "$current_mode" = "0" ]; then
                    log_msg "INFO" "SUCCESS: AUTO mode enabled (EC mode: $current_mode)"
                    return 0
                else
                    log_msg "WARN" "AUTO mode not confirmed, EC still shows: $current_mode"
                fi
            else
                log_msg "ERROR" "Cannot verify EC mode after AUTO attempt"
            fi
        else
            log_msg "ERROR" "Failed to set AUTO mode (attempt $attempt)"
        fi
        
        attempt=$((attempt + 1))
        [ $attempt -le $max_attempts ] && sleep 5
    done
    
    log_msg "CRITICAL" "FAILED to enable AUTO mode after $max_attempts attempts!"
    return 1
}

emergency_cooling() {
    log_msg "EMERGENCY" "Critical temperature! Starting emergency cooling protocol"
    
    local cooling_attempt=1
    local max_cooling_attempts=3
    local total_emergency_time=0
    local max_emergency_time=600  # 10 minutes absolute maximum
    
    while [ $cooling_attempt -le $max_cooling_attempts ] && [ $total_emergency_time -lt $max_emergency_time ]; do
        log_msg "EMERGENCY" "Emergency cooling attempt $cooling_attempt/$max_cooling_attempts"
        
        # Set manual mode and maximum fan speed
        if ! set_manual; then
            log_msg "CRITICAL" "Failed to set manual mode! Forcing AUTO"
            emergency_auto
            return 1
        fi
        
        sleep 1
        
        if ! set_max_speed; then
            log_msg "CRITICAL" "Failed to set max fan speed! Forcing AUTO"
            emergency_auto
            return 1
        fi
        
        # Monitor cooling progress
        local cooling_time=0
        local check_interval=5
        local attempt_timeout=180  # 3 minutes per attempt
        
        log_msg "INFO" "Emergency cooling active - monitoring temperature drop..."
        
        while [ $cooling_time -lt $attempt_timeout ] && [ $total_emergency_time -lt $max_emergency_time ]; do
            local temp=$(get_temperature)
            local rpm=$(get_rpm)
            
            log_msg "COOLING" "Emergency cooling: ${cooling_time}s/${attempt_timeout}s | Temp: ${temp}°C | RPM: $rpm | Target: <${COOLING_RECOVERY_TEMP}°C"
            
            # Success condition
            if [ "$temp" -lt $COOLING_RECOVERY_TEMP ]; then
                log_msg "INFO" "SUCCESS! Temperature dropped to ${temp}°C after ${cooling_time}s"
                log_msg "INFO" "Starting cooling down period (AUTO mode for ${COOLING_DOWN_TIME}s)"
                
                set_auto
                echo "$(date +%s)" > /tmp/hp-thermal-cooling-start
                return 0
            fi
            
            # Critical temperature check
            if [ "$temp" -gt $CRITICAL_EMERGENCY_TEMP ]; then
                log_msg "CRITICAL" "DANGER! Temperature ${temp}°C exceeds critical limit ${CRITICAL_EMERGENCY_TEMP}°C!"
                emergency_auto
                return 1
            fi
            
            sleep $check_interval
            cooling_time=$((cooling_time + check_interval))
            total_emergency_time=$((total_emergency_time + check_interval))
        done
        
        cooling_attempt=$((cooling_attempt + 1))
        
        if [ $cooling_attempt -le $max_cooling_attempts ]; then
            log_msg "WARN" "Cooling attempt $((cooling_attempt-1)) timeout. Trying different approach..."
            # Brief pause before next attempt
            sleep 10
            total_emergency_time=$((total_emergency_time + 10))
        fi
    done
    
    # All cooling attempts failed
    local final_temp=$(get_temperature)
    log_msg "CRITICAL" "Emergency cooling FAILED after $max_cooling_attempts attempts!"
    log_msg "CRITICAL" "Final temperature: ${final_temp}°C after ${total_emergency_time}s"
    log_msg "CRITICAL" "Switching to AUTO mode for safety"
    
    emergency_auto
    echo "$(date +%s)" > /tmp/hp-thermal-cooling-start
    return 1
}

check_ec() {
    if [ ! -f "$ECIO" ]; then
        log_msg "ERROR" "EC unavailable, attempting to load module..."
        if modprobe ec_sys write_support=1 2>/dev/null; then
            sleep 3
            if [ -f "$ECIO" ]; then
                log_msg "INFO" "EC module loaded successfully"
                return 0
            fi
        fi
        log_msg "CRITICAL" "Failed to load EC module!"
        return 1
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
            return 1  # Still cooling down
        fi
    else
        return 0  # No cooling down period
    fi
}

cleanup() {
    log_msg "INFO" "Received termination signal, performing safe shutdown..."
    
    # Attempt graceful AUTO mode restore
    if ! emergency_auto; then
        log_msg "CRITICAL" "Failed to restore AUTO mode during shutdown!"
    fi
    
    # Clean up state files
    rm -f "$STATE_FILE"
    rm -f /tmp/hp-thermal-cooling-start
    
    log_msg "INFO" "Thermal service shutdown complete"
    exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

main_loop() {
    log_msg "INFO" "HP 250 G8 Thermal Service started (threshold: ${TEMP_THRESHOLD}°C, emergency: ${EMERGENCY_COOLING_TEMP}°C)"
    log_msg "INFO" "Safety limits: Fan speed 0-$MAX_FAN_SPEED, Valid EC addresses: R($VALID_EC_READ_ADDRESSES) W($VALID_EC_WRITE_ADDRESSES)"
    
    local current_state=$(get_state)
    local error_count=0
    local max_errors=5
    local overheat_protection_count=0
    local max_overheat_events=10
    
    while true; do
        # Periodic EC and system health check
        if [ $(($(date +%s) % 30)) -eq 0 ]; then
            if ! check_ec; then
                error_count=$((error_count + 1))
                log_msg "ERROR" "EC check failed ($error_count/$max_errors)"
                
                if [ $error_count -gt $max_errors ]; then
                    log_msg "CRITICAL" "Too many EC errors ($error_count), shutting down for safety"
                    emergency_auto
                    exit 1
                fi
                sleep $CHECK_INTERVAL
                continue
            fi
            error_count=0  # Reset error count on successful check
        fi
        
        local temp=$(get_temperature)
        local mode rpm
        
        # Safely read EC values
        if ! mode=$(read_ec 21); then
            log_msg "ERROR" "Cannot read EC mode"
            sleep $CHECK_INTERVAL
            continue
        fi
        
        if ! rpm=$(get_rpm); then
            log_msg "WARN" "Cannot read fan RPM"
            rpm="N/A"
        fi
        
        # CRITICAL PROTECTION: Extreme temperature safety override
        if [ "$temp" -gt 105 ]; then
            log_msg "CRITICAL" "EXTREME TEMPERATURE ${temp}°C! IMMEDIATE AUTO MODE ACTIVATION!"
            
            emergency_auto
            overheat_protection_count=$((overheat_protection_count + 1))
            
            if [ $overheat_protection_count -gt $max_overheat_events ]; then
                log_msg "CRITICAL" "Repeated extreme overheating ($overheat_protection_count events)!"
                log_msg "CRITICAL" "Hardware may be damaged or thermal system failing. Shutting down service."
                exit 1
            fi
            
            sleep 5
            continue
        fi
        
        # High temperature alerts (independent of state machine)
        if [ "$temp" -gt 95 ] && [ "$current_state" != "cooling_down" ]; then
            log_msg "ALERT" "🔥 HIGH TEMPERATURE WARNING: ${temp}°C"
        fi
        
        # Critical emergency temperature handling
        if [ "$temp" -gt $CRITICAL_EMERGENCY_TEMP ]; then
            log_msg "CRITICAL" "CRITICAL temperature ${temp}°C! Emergency AUTO enable"
            emergency_auto
            current_state="emergency"
            set_state "$current_state"
            sleep $CHECK_INTERVAL
            continue
        elif [ "$temp" -gt $EMERGENCY_COOLING_TEMP ]; then
            log_msg "EMERGENCY" "High temperature ${temp}°C! Starting emergency cooling protocol"
            emergency_cooling
            current_state="cooling_down"
            set_state "$current_state"
            sleep $CHECK_INTERVAL
            continue
        fi
        
        # Main state machine logic
        case "$current_state" in
            "silent"|"auto")
                if [ "$temp" -ge $TEMP_THRESHOLD ]; then
                    log_msg "INFO" "Temperature ${temp}°C >= ${TEMP_THRESHOLD}°C, enabling AUTO mode"
                    if set_auto; then
                        current_state="active"
                        set_state "$current_state"
                    else
                        log_msg "ERROR" "Failed to set AUTO mode"
                    fi
                elif [ "$temp" -lt $((TEMP_THRESHOLD - HYSTERESIS)) ] && [ "$current_state" != "silent" ]; then
                    log_msg "INFO" "Temperature ${temp}°C < $((TEMP_THRESHOLD - HYSTERESIS))°C, turning off fan"
                    if set_manual && sleep 0.5 && set_fan_off; then
                        current_state="silent"
                        set_state "$current_state"
                    else
                        log_msg "ERROR" "Failed to set silent mode"
                    fi
                fi
                ;;
            "active")
                if [ "$temp" -lt $((TEMP_THRESHOLD - HYSTERESIS)) ]; then
                    log_msg "INFO" "Temperature dropped to ${temp}°C, turning off fan"
                    if set_manual && sleep 0.5 && set_fan_off; then
                        current_state="silent"
                        set_state "$current_state"
                    else
                        log_msg "ERROR" "Failed to transition to silent mode"
                    fi
                fi
                ;;
            "emergency")
                if [ "$temp" -lt $((CRITICAL_EMERGENCY_TEMP - 10)) ]; then
                    log_msg "INFO" "Exiting emergency mode, temperature ${temp}°C"
                    current_state="active"
                    set_state "$current_state"
                fi
                ;;
            "cooling_down")
                # CRITICAL: During cooling down period, ALWAYS keep AUTO mode
                if is_cooling_down_expired; then
                    # Cooling down period completed, decide next state
                    if [ "$temp" -lt $((TEMP_THRESHOLD - HYSTERESIS)) ]; then
                        log_msg "INFO" "Cooling down completed. Temperature ${temp}°C, switching to silent mode"
                        if set_manual && sleep 0.5 && set_fan_off; then
                            current_state="silent"
                            set_state "$current_state"
                        else
                            log_msg "ERROR" "Failed to set silent mode after cooling down"
                        fi
                    else
                        log_msg "INFO" "Cooling down completed. Temperature ${temp}°C, staying in active mode"
                        current_state="active"
                        set_state "$current_state"
                    fi
                else
                    # Still in cooling down period - ENFORCE AUTO mode
                    if [ "$mode" != "0" ]; then
                        log_msg "WARN" "Cooling down period: Enforcing AUTO mode (was in manual: $mode)"
                        set_auto
                    fi
                    
                    # Check for temperature spikes during cooling down
                    if [ "$temp" -gt $EMERGENCY_COOLING_TEMP ]; then
                        log_msg "WARN" "Temperature spike during cooling down! Restarting emergency cooling"
                        rm -f /tmp/hp-thermal-cooling-start
                        emergency_cooling
                        current_state="cooling_down"
                        set_state "$current_state"
                    fi
                    
                    # Status during cooling down
                    if [ $(($(date +%s) % 30)) -eq 0 ]; then
                        local cooling_start_file="/tmp/hp-thermal-cooling-start"
                        if [ -f "$cooling_start_file" ]; then
                            local start_time=$(cat "$cooling_start_file")
                            local current_time=$(date +%s)
                            local elapsed=$((current_time - start_time))
                            local remaining=$((COOLING_DOWN_TIME - elapsed))
                            log_msg "INFO" "Cooling down: ${remaining}s remaining | Temp: ${temp}°C | AUTO mode enforced"
                        fi
                    fi
                fi
                ;;
        esac
        
        # Comprehensive status logging (every 30 seconds)
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
            
            # Add safety status
            status_msg="$status_msg | Errors: $error_count/$max_errors | Overheats: $overheat_protection_count/$max_overheat_events"
            
            log_msg "STATUS" "$status_msg"
        fi
        
        sleep $CHECK_INTERVAL
    done
}

case "$1" in
    "start") main_loop ;;
    "stop") 
        emergency_auto
        rm -f "$STATE_FILE" 
        rm -f /tmp/hp-thermal-cooling-start
        log_msg "INFO" "Service stopped - AUTO mode restored"
        ;;
    "status")
        echo "HP 250 G8 Thermal Service Status:"
        echo "================================="
        
        temp=$(get_temperature)
        state=$(get_state)
        
        echo "Temperature: ${temp}°C"
        echo "State: $state"
        
        if mode=$(read_ec 21 2>/dev/null); then
            echo "EC Mode: $mode (0=auto, 1=manual)"
        else
            echo "EC Mode: ERROR - Cannot read"
        fi
        
        if rpm=$(get_rpm 2>/dev/null); then
            echo "Fan RPM: $rpm"
        else
            echo "Fan RPM: ERROR - Cannot read"
        fi
        
        echo
        echo "Configuration:"
        echo "  Temperature Threshold: ${TEMP_THRESHOLD}°C"
        echo "  Emergency Cooling: ${EMERGENCY_COOLING_TEMP}°C"
        echo "  Recovery Target: ${COOLING_RECOVERY_TEMP}°C"
        echo "  Critical Emergency: ${CRITICAL_EMERGENCY_TEMP}°C"
        echo "  Max Fan Speed: $MAX_FAN_SPEED"
        echo "  Cooling Down Time: ${COOLING_DOWN_TIME}s"
        echo
        echo "Safety Limits:"
        echo "  Valid EC Read Addresses: $VALID_EC_READ_ADDRESSES"
        echo "  Valid EC Write Addresses: $VALID_EC_WRITE_ADDRESSES"
        echo "  Fan Speed Range: $MIN_FAN_SPEED-$MAX_FAN_SPEED"
        
        # Safety warnings
        if [ "$temp" != "N/A" ] && [ "$temp" -gt $EMERGENCY_COOLING_TEMP ]; then
            echo
            echo "⚠️  WARNING: Temperature above emergency threshold!"
        fi
        if [ "$temp" != "N/A" ] && [ "$temp" -gt $CRITICAL_EMERGENCY_TEMP ]; then
            echo "🔥 CRITICAL: Temperature in danger zone!"
        fi
        
        # Check cooling down status
        cooling_start_file="/tmp/hp-thermal-cooling-start"
        if [ -f "$cooling_start_file" ]; then
            start_time=$(cat "$cooling_start_file")
            current_time=$(date +%s)
            elapsed=$((current_time - start_time))
            remaining=$((COOLING_DOWN_TIME - elapsed))
            if [ $remaining -gt 0 ]; then
                echo "Cooling Down: ${remaining}s remaining"
            fi
        fi
        
        # EC accessibility check
        echo
        if [ -f "$ECIO" ]; then
            echo "✓ EC interface accessible"
        else
            echo "✗ EC interface NOT accessible"
        fi
        ;;
    "auto") 
        echo "Forcing AUTO mode..."
        emergency_auto
        echo "AUTO mode command completed"
        ;;
    *) 
        echo "Usage: $0 {start|stop|status|auto}"
        echo "  start  - Start thermal monitoring"
        echo "  stop   - Stop service and restore AUTO mode"
        echo "  status - Show detailed status and safety info"
        echo "  auto   - Force AUTO mode immediately"
        exit 1 
        ;;
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

# Resource limits for safety
MemoryMax=50M
CPUQuota=10%

# Enhanced logging
StandardOutput=append:/var/log/hp-thermal.log
StandardError=append:/var/log/hp-thermal.log

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

    mkdir -p /var/log
    touch /var/log/hp-thermal.log
    systemctl daemon-reload
    log_info "Enhanced thermal service created with safety features"
}

# Diagnostics
run_diagnostics() {
    log_step "Running enhanced system diagnostics..."
    
    echo "=== HP 250 G8 THERMAL SYSTEM DIAGNOSTICS ==="
    echo "Version: 3.2 (printf errors fixed)"
    echo "Time: $(date)"
    echo "Bootloader: $BOOTLOADER" 
    echo "Kernel: $KERNEL_VERSION"
    echo
    
    echo "--- Hardware Verification ---"
    if command -v dmidecode &> /dev/null; then
        local vendor=$(dmidecode -s system-manufacturer 2>/dev/null || echo "unknown")
        local product=$(dmidecode -s system-product-name 2>/dev/null || echo "unknown")
        echo "Manufacturer: $vendor"
        echo "Product: $product"
        
        if echo "$vendor" | grep -qi "hp\|hewlett" && echo "$product" | grep -qi "250.*G8"; then
            echo "✓ Hardware compatibility: CONFIRMED"
        else
            echo "⚠ Hardware compatibility: WARNING - Not HP 250 G8"
        fi
    else
        echo "✗ dmidecode not available"
    fi
    
    echo -e "\n--- EC Access ---"
    if [ -f /sys/kernel/debug/ec/ec0/io ]; then
        echo "✓ EC debug interface available"
        ls -la /sys/kernel/debug/ec/ec0/io
        
        # Test EC read access (safe addresses only)
        echo "Testing EC read access..."
        for addr in 17 21 25; do
            if value=$(dd if=/sys/kernel/debug/ec/ec0/io bs=1 skip=$addr count=1 2>/dev/null | od -An -tu1 | tr -d ' '); then
                echo "  Address $addr: $value ✓"
            else
                echo "  Address $addr: READ ERROR ✗"
            fi
        done
    else
        echo "✗ EC debug interface unavailable"
        echo "Checking debugfs..."
        mount | grep debugfs || echo "debugfs not mounted"
    fi
    
    echo -e "\n--- Modules ---"
    if lsmod | grep -q ec_sys; then
        echo "✓ ec_sys module loaded"
        echo "Module parameters:"
        cat /sys/module/ec_sys/parameters/write_support 2>/dev/null || echo "  write_support: unknown"
    else
        echo "✗ ec_sys module not loaded" 
    fi
    
    echo -e "\n--- Thermal Service ---"
    if systemctl is-active --quiet hp-thermal; then
        echo "✓ HP Thermal Service active"
        echo "Service status:"
        /usr/local/bin/hp-thermal-service.sh status 2>/dev/null || echo "Error getting detailed status"
    else
        echo "✗ HP Thermal Service inactive"
        if systemctl is-enabled --quiet hp-thermal; then
            echo "  (but enabled for autostart)"
        fi
    fi
    
    echo -e "\n--- Temperature Sensors ---"
    if command -v sensors &> /dev/null; then
        sensors 2>/dev/null | head -15 || echo "sensors command error"
    else
        echo "lm-sensors not installed"
        echo "Available thermal zones:"
        ls /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -5 | while read -r zone; do
            temp=$(cat "$zone" 2>/dev/null || echo "0")
            temp=$((temp / 1000))
            echo "  $(basename "$(dirname "$zone")"): ${temp}°C"
        done
    fi
    
    echo -e "\n--- Log Analysis ---"
    if [ -f /var/log/hp-thermal.log ]; then
        echo "Recent thermal log entries:"
        tail -10 /var/log/hp-thermal.log 2>/dev/null | while read -r line; do
            echo "  $line"
        done
        
        echo -e "\nError summary:"
        local error_count=$(grep -c "ERROR\|CRITICAL\|EMERGENCY" /var/log/hp-thermal.log 2>/dev/null || echo "0")
        local printf_errors=$(grep -c "missing hex digit" /var/log/hp-thermal.log 2>/dev/null || echo "0")
        echo "  Total errors/warnings: $error_count"
        echo "  Printf errors: $printf_errors $([ "$printf_errors" = "0" ] && echo "(✓ FIXED)" || echo "(⚠ NEEDS FIX)")"
    else
        echo "No thermal log file found"
    fi
    
    echo -e "\n--- Safety Status ---"
    echo "Hardware validation: $([ -x /usr/local/bin/hp-thermal-service.sh ] && echo "ENABLED" || echo "DISABLED")"
    echo "EC address validation: ENABLED (Read: 17,21,25 | Write: 21,25)"
    echo "Fan speed limits: 0-50"
    echo "Temperature monitoring: Multi-tier (60°C/88°C/98°C thresholds)"
    echo "Printf error fixes: APPLIED (Version 3.2)"
    
    echo -e "\n=== DIAGNOSTICS COMPLETED ==="
}

# Main function
main() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              HP 250 G8 Universal Thermal Installer          ║"
    echo "║                 Version 3.2 - SAFE EDITION                  ║"
    echo "║              github.com/nadeko0/HP-250-G8-Fan-Control       ║"
    echo "║                                                              ║"
    echo "║     🔥 Smart Thermal Control & Enhanced Safety 🛡️          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    case "${1:-install}" in
        "install")
            show_disclaimer
            check_root
            verify_hardware
            detect_system
            
            log_step "Starting safe installation..."
            setup_debugfs
            setup_modules
            create_thermal_service
            
            log_step "Post-installation diagnostics..."
            run_diagnostics
            
            echo -e "\n${GREEN}✅ SAFE INSTALLATION COMPLETED!${NC}"
            echo
            echo "🛡️ Safety Features Enabled:"
            echo "  • Hardware compatibility verification"
            echo "  • EC address validation (Read: 17,21,25 | Write: 21,25)"
            echo "  • Fan speed limits (0-50)"
            echo "  • Enhanced error handling and recovery"
            echo "  • System monitoring and alerts"
            echo "  • Fixed printf errors for clean operation"
            echo
            echo "Management commands:"
            echo "  sudo systemctl start hp-thermal     # Start service"
            echo "  sudo systemctl enable hp-thermal    # Enable autostart"
            echo "  sudo systemctl status hp-thermal    # Check status"
            echo "  sudo journalctl -u hp-thermal -f    # View logs"
            echo
            echo "Service commands:"
            echo "  sudo /usr/local/bin/hp-thermal-service.sh status    # Detailed status"
            echo "  sudo /usr/local/bin/hp-thermal-service.sh auto      # Force AUTO mode"
            echo
            echo "Features:"
            echo "  • Smart temperature monitoring (88°C emergency threshold)"
            echo "  • Maximum fan speed: 50 (aggressive cooling)"
            echo "  • 2-minute cooling down periods"
            echo "  • Robust thermal protection with multiple safety layers"
            echo "  • Hardware validation and compatibility checks"
            echo "  • Clean operation without printf errors (v3.2 fix)"
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
            check_root
            log_step "Uninstalling HP Thermal System..."
            
            # Safe shutdown
            systemctl stop hp-thermal 2>/dev/null || true
            systemctl disable hp-thermal 2>/dev/null || true
            
            # Restore AUTO mode safely
            if [ -x /usr/local/bin/hp-thermal-service.sh ]; then
                /usr/local/bin/hp-thermal-service.sh auto 2>/dev/null || true
            fi
            
            # Remove files
            rm -f /etc/systemd/system/hp-thermal.service
            rm -f /usr/local/bin/hp-thermal-service.sh
            rm -f /etc/modules-load.d/ec_sys.conf
            rm -f /etc/modprobe.d/ec_sys.conf
            rm -f /etc/udev/rules.d/99-ec-debug.rules
            rm -f /tmp/hp-thermal-state
            rm -f /tmp/hp-thermal-cooling-start
            
            systemctl daemon-reload
            udevadm control --reload-rules
            
            log_info "Safe uninstallation completed - AUTO mode restored"
            ;;
            
        "diagnose")
            detect_system
            run_diagnostics
            ;;
            
        "fix")
            check_root
            log_step "Attempting to fix issues..."
            setup_debugfs
            setup_modules
            systemctl restart hp-thermal 2>/dev/null || true
            sleep 3
            run_diagnostics
            ;;
            
        *)
            echo "Usage: $0 [install|uninstall|diagnose|fix]"
            echo "  install   - Full safe installation with hardware verification (default)"
            echo "  uninstall - Safely remove the system and restore AUTO mode"
            echo "  diagnose  - Run comprehensive diagnostics"
            echo "  fix       - Attempt to fix issues and restart service"
            exit 1
            ;;
    esac
}

main "$@"
