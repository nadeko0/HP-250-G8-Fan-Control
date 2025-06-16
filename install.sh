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

# Setup desktop notifications
setup_notifications() {
    log_step "Setting up desktop notifications..."
    
    # Check if notification tools are available
    local notification_tools_available=false
    
    if command -v notify-send &> /dev/null; then
        log_info "notify-send found"
        notification_tools_available=true
    fi
    
    if command -v kdialog &> /dev/null; then
        log_info "kdialog found (KDE)"
        notification_tools_available=true
    fi
    
    if command -v zenity &> /dev/null; then
        log_info "zenity found"
        notification_tools_available=true
    fi
    
    # Install notification support if needed
    if [ "$notification_tools_available" = false ]; then
        log_info "Installing notification support..."
        
        case "$OS_ID" in
            "ubuntu"|"debian"|"linuxmint")
                apt-get update -qq && apt-get install -y libnotify-bin zenity
                ;;
            "fedora"|"rhel"|"centos")
                dnf install -y libnotify zenity || yum install -y libnotify zenity
                ;;
            "arch"|"manjaro"|"endeavouros")
                pacman -S --noconfirm libnotify zenity
                ;;
            "opensuse"|"suse")
                zypper install -y libnotify-tools zenity
                ;;
            *)
                log_warn "Unknown distribution. Please install notification tools manually:"
                log_warn "  - For GNOME/XFCE: libnotify-bin or notify-send"
                log_warn "  - For KDE: kdialog (usually pre-installed)"
                log_warn "  - Universal: zenity"
                ;;
        esac
    fi
    
    # Test notification support
    if command -v notify-send &> /dev/null || command -v kdialog &> /dev/null || command -v zenity &> /dev/null; then
        log_info "Desktop notifications enabled"
        
        # Detect desktop environment for optimal support
        if [ -n "$KDE_SESSION_VERSION" ] || [ "$XDG_CURRENT_DESKTOP" = "KDE" ]; then
            log_info "KDE Plasma detected - using kdialog for notifications"
        elif [ "$XDG_CURRENT_DESKTOP" = "GNOME" ] || [ -n "$GNOME_DESKTOP_SESSION_ID" ]; then
            log_info "GNOME detected - using notify-send for notifications"
        elif [ "$XDG_CURRENT_DESKTOP" = "XFCE" ]; then
            log_info "XFCE detected - using notify-send for notifications"
        else
            log_info "Using available notification tools"
        fi
    else
        log_warn "Desktop notifications not available - manual installation may be required"
    fi
}
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
NOTIFICATION_COOLDOWN_FILE="/tmp/hp-thermal-notif-cooldown"
TEMP_THRESHOLD=60
EMERGENCY_COOLING_TEMP=88
COOLING_RECOVERY_TEMP=82
CRITICAL_EMERGENCY_TEMP=98
CHECK_INTERVAL=3
HYSTERESIS=3
COOLING_DOWN_TIME=120

read_ec() { dd if="$ECIO" bs=1 skip=$1 count=1 2>/dev/null | od -An -tu1 | tr -d ' '; }
write_ec() { echo -n -e "$(printf '\x%02x' $2)" | dd of="$ECIO" bs=1 seek=$1 count=1 conv=notrunc 2>/dev/null; }

set_manual() { write_ec 21 1; }
set_auto() { write_ec 21 0; }
set_fan_off() { write_ec 25 0; }
set_fan_speed() { write_ec 25 $1; }
set_max_speed() { write_ec 25 50; }
get_rpm() { read_ec 17; }

log_msg() {
    local level=$1
    shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" | tee -a "$LOG_FILE"
}

send_notification() {
    local urgency=$1
    local title=$2
    local message=$3
    local icon=$4
    local cooldown_key=$5
    local cooldown_time=${6:-300}  # 5 minutes default cooldown
    
    # Check cooldown to avoid spam
    local cooldown_file="${NOTIFICATION_COOLDOWN_FILE}-${cooldown_key}"
    if [ -f "$cooldown_file" ]; then
        local last_notif=$(cat "$cooldown_file")
        local current_time=$(date +%s)
        local elapsed=$((current_time - last_notif))
        if [ $elapsed -lt $cooldown_time ]; then
            return 0  # Skip notification (still in cooldown)
        fi
    fi
    
    # Try multiple methods to find active user and display
    local user_display=""
    local target_user=""
    
    # Method 1: Check who's logged in with a display (X11)
    for line in $(who | grep "([:]0[)]"); do
        target_user=$(echo "$line" | awk '{print $1}')
        user_display=":0"
        break
    done
    
    # Method 2: Check active sessions via loginctl
    if [ -z "$target_user" ]; then
        target_user=$(loginctl list-sessions --no-legend 2>/dev/null | grep "seat0" | head -1 | awk '{print $3}')
        user_display=":0"
    fi
    
    # Method 3: Check WAYLAND_DISPLAY for Wayland sessions
    if [ -z "$target_user" ]; then
        for user in $(ls /home 2>/dev/null); do
            if [ -n "$(pgrep -u "$user" "kwin_wayland\|gnome-shell\|sway")" ]; then
                target_user="$user"
                user_display="wayland-0"
                break
            fi
        done
    fi
    
    # Method 4: Fallback to first user with active X session
    if [ -z "$target_user" ]; then
        for user in $(ls /home 2>/dev/null); do
            if [ -n "$(pgrep -u "$user" Xorg)" ]; then
                target_user="$user"
                user_display=":0"
                break
            fi
        done
    fi
    
    # Method 5: Ultimate fallback - first user in /home
    if [ -z "$target_user" ]; then
        target_user=$(ls /home 2>/dev/null | head -1)
        user_display=":0"
    fi
    
    if [ -n "$target_user" ]; then
        local notification_sent=false
        
        # Try KDE notifications first (kdialog)
        if command -v kdialog &> /dev/null; then
            sudo -u "$target_user" DISPLAY="$user_display" kdialog \
                --title "HP Thermal Control" \
                --passivepopup "$title\n\n$message" 8 2>/dev/null && notification_sent=true
        fi
        
        # Try notify-send if kdialog failed
        if [ "$notification_sent" = false ] && command -v notify-send &> /dev/null; then
            sudo -u "$target_user" DISPLAY="$user_display" \
                XDG_RUNTIME_DIR="/run/user/$(id -u "$target_user")" \
                notify-send \
                --urgency="$urgency" \
                --icon="$icon" \
                --app-name="HP Thermal Control" \
                --expire-time=8000 \
                "$title" \
                "$message" 2>/dev/null && notification_sent=true
        fi
        
        # Try zenity as fallback
        if [ "$notification_sent" = false ] && command -v zenity &> /dev/null; then
            sudo -u "$target_user" DISPLAY="$user_display" zenity \
                --notification \
                --text="$title: $message" \
                --timeout=8 2>/dev/null && notification_sent=true
        fi
        
        # Try direct KDE notification via dbus
        if [ "$notification_sent" = false ]; then
            sudo -u "$target_user" DISPLAY="$user_display" \
                XDG_RUNTIME_DIR="/run/user/$(id -u "$target_user")" \
                dbus-send --session --dest=org.freedesktop.Notifications \
                /org/freedesktop/Notifications \
                org.freedesktop.Notifications.Notify \
                string:"HP Thermal Control" uint32:0 string:"$icon" \
                string:"$title" string:"$message" \
                array:string: dict:string,variant: int32:8000 2>/dev/null && notification_sent=true
        fi
        
        if [ "$notification_sent" = true ]; then
            # Update cooldown
            echo "$(date +%s)" > "$cooldown_file"
            log_msg "NOTIF" "Sent notification to $target_user: $title"
        else
            log_msg "WARN" "Failed to send notification to $target_user"
        fi
    else
        log_msg "WARN" "Could not send notification - no active user found"
    fi
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
    log_msg "EMERGENCY" "Critical temperature! Starting aggressive cooling (max speed 50)"
    
    # Send immediate notification
    send_notification "critical" \
        "🔥 High Temperature Alert" \
        "CPU temperature is critical! Emergency cooling activated.\nFan running at maximum speed." \
        "dialog-warning" \
        "emergency_start" \
        180  # 3 minute cooldown
    
    set_manual
    sleep 0.5
    set_max_speed
    
    total_time=0
    check_interval=2
    max_cooling_time=300  # 5 minutes max emergency cooling
    
    log_msg "INFO" "Holding maximum cooling until temperature drops below ${COOLING_RECOVERY_TEMP}°C"
    
    while [ $total_time -lt $max_cooling_time ]; do
        temp=$(get_temperature)
        rpm=$(get_rpm)
        
        log_msg "COOLING" "Emergency cooling: ${total_time}s | Temp: ${temp}°C | RPM: $rpm | Target: <${COOLING_RECOVERY_TEMP}°C"
        
        # Check if temperature dropped sufficiently
        if [ $temp -lt $COOLING_RECOVERY_TEMP ]; then
            log_msg "INFO" "SUCCESS! Temperature dropped to ${temp}°C after ${total_time}s of emergency cooling"
            log_msg "INFO" "Starting 2-minute AUTO cooling down period"
            
            # Send success notification
            send_notification "normal" \
                "✅ Temperature Stabilized" \
                "Emergency cooling successful! Temperature: ${temp}°C\nSwitching to normal cooling mode." \
                "dialog-information" \
                "emergency_success" \
                600  # 10 minute cooldown
            
            set_auto
            echo "$(date +%s)" > /tmp/hp-thermal-cooling-start
            return 0
        fi
        
        # Critical temperature check
        if [ $temp -gt $CRITICAL_EMERGENCY_TEMP ]; then
            log_msg "CRITICAL" "DANGER! Temperature ${temp}°C > ${CRITICAL_EMERGENCY_TEMP}°C! Switching to system AUTO"
            
            # Send critical notification
            send_notification "critical" \
                "🚨 CRITICAL TEMPERATURE!" \
                "CPU temperature reached ${temp}°C!\nSwitching to emergency system cooling." \
                "dialog-error" \
                "critical_temp" \
                60  # 1 minute cooldown for critical alerts
            
            emergency_auto
            return 1
        fi
        
        sleep $check_interval
        total_time=$((total_time + check_interval))
    done
    
    # If we reach here, emergency cooling took too long
    temp=$(get_temperature)
    log_msg "EMERGENCY" "Emergency cooling timeout (${max_cooling_time}s)! Temperature still ${temp}°C. Switching to AUTO"
    
    # Send timeout notification
    send_notification "critical" \
        "⚠️ Cooling Timeout" \
        "Emergency cooling took too long.\nTemperature: ${temp}°C - Switching to auto mode." \
        "dialog-warning" \
        "cooling_timeout" \
        300  # 5 minute cooldown
    
    set_auto
    echo "$(date +%s)" > /tmp/hp-thermal-cooling-start
    return 1
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
    rm -f /tmp/hp-thermal-notif-cooldown-*
    exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

main_loop() {
    log_msg "INFO" "HP 250 G8 Thermal Service started (threshold: ${TEMP_THRESHOLD}°C, emergency: ${EMERGENCY_COOLING_TEMP}°C)"
    current_state=$(get_state)
    error_count=0
    overheat_protection_count=0
    
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
        
        temp=$(get_temperature)
        mode=$(read_ec 21)
        rpm=$(get_rpm)
        
        # CRITICAL PROTECTION: If temperature is extremely high, force immediate action
        if [ $temp -gt 100 ]; then
            log_msg "CRITICAL" "EXTREME TEMPERATURE ${temp}°C! FORCING IMMEDIATE AUTO MODE!"
            
            # Send immediate extreme temperature notification
            send_notification "critical" \
                "🆘 EXTREME TEMPERATURE!" \
                "CPU reached ${temp}°C - IMMEDIATE ACTION REQUIRED!\nForcing emergency cooling now!" \
                "dialog-error" \
                "extreme_temp" \
                30  # 30 second cooldown for extreme alerts
            
            emergency_auto
            overheat_protection_count=$((overheat_protection_count + 1))
            if [ $overheat_protection_count -gt 5 ]; then
                log_msg "CRITICAL" "Repeated extreme overheating! System may be damaged. Shutting down service."
                
                # Final critical notification
                send_notification "critical" \
                    "🚨 THERMAL PROTECTION SHUTDOWN" \
                    "Repeated extreme overheating detected!\nThermal service stopping for safety." \
                    "dialog-error" \
                    "thermal_shutdown" \
                    0  # No cooldown for shutdown notification
                
                exit 1
            fi
            sleep 1
            continue
        fi
        
        if [ $temp -gt $CRITICAL_EMERGENCY_TEMP ]; then
            log_msg "CRITICAL" "CRITICAL temperature ${temp}°C! Emergency AUTO enable"
            emergency_auto
            set_state "emergency"
            sleep $CHECK_INTERVAL
            continue
        elif [ $temp -gt $EMERGENCY_COOLING_TEMP ]; then
            log_msg "EMERGENCY" "High temperature ${temp}°C! Starting emergency cooling"
            emergency_cooling
            current_state="cooling_down"
            set_state "$current_state"
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
                if [ $temp -lt $((CRITICAL_EMERGENCY_TEMP - 10)) ]; then
                    log_msg "INFO" "Exiting emergency mode, temperature ${temp}°C"
                    current_state="active"
                    set_state "$current_state"
                fi
                ;;
            "cooling_down")
                # CRITICAL: During cooling down period, ALWAYS keep AUTO mode regardless of temperature!
                if is_cooling_down_expired; then
                    # Only after cooling down period ends, decide next state
                    if [ $temp -lt $((TEMP_THRESHOLD - HYSTERESIS)) ]; then
                        log_msg "INFO" "Cooling down completed. Temperature ${temp}°C, switching to silent mode"
                        set_manual
                        sleep 0.5
                        set_fan_off
                        current_state="silent"
                        set_state "$current_state"
                    else
                        log_msg "INFO" "Cooling down completed. Temperature ${temp}°C, staying in active mode"
                        current_state="active"
                        set_state "$current_state"
                    fi
                else
                    # Still in cooling down period - FORCE AUTO mode and prevent any other changes!
                    if [ $(read_ec 21) -ne 0 ]; then
                        log_msg "WARN" "Cooling down period: Forcing AUTO mode (was in manual)"
                        set_auto
                    fi
                    
                    cooling_start_file="/tmp/hp-thermal-cooling-start"
                    if [ -f "$cooling_start_file" ]; then
                        start_time=$(cat "$cooling_start_file")
                        current_time=$(date +%s)
                        elapsed=$((current_time - start_time))
                        remaining=$((COOLING_DOWN_TIME - elapsed))
                        if [ $(($(date +%s) % 30)) -eq 0 ]; then
                            log_msg "INFO" "Cooling down: ${remaining}s remaining | Temp: ${temp}°C | Keeping AUTO mode"
                        fi
                    fi
                    
                    # Check if temperature spikes again during cooling down
                    if [ $temp -gt $EMERGENCY_COOLING_TEMP ]; then
                        log_msg "WARN" "Temperature spike during cooling down! Restarting emergency cooling"
                        rm -f /tmp/hp-thermal-cooling-start
                        emergency_cooling
                        current_state="cooling_down"
                        set_state "$current_state"
                    fi
                fi
                ;;
        esac
        
        if [ $(($(date +%s) % 30)) -eq 0 ]; then
            status_msg="Temp: ${temp}°C | State: $current_state | Mode: $mode | RPM: $rpm"
            # Add cooling down info if active
            cooling_start_file="/tmp/hp-thermal-cooling-start"
            if [ -f "$cooling_start_file" ] && [ "$current_state" = "cooling_down" ]; then
                start_time=$(cat "$cooling_start_file")
                current_time=$(date +%s)
                elapsed=$((current_time - start_time))
                remaining=$((COOLING_DOWN_TIME - elapsed))
                status_msg="$status_msg | CoolDown: ${remaining}s"
            fi
            log_msg "STATUS" "$status_msg"
        fi
        
        sleep $CHECK_INTERVAL
    done
}

case "$1" in
    "start") main_loop ;;
    "stop") emergency_auto; rm -f "$STATE_FILE"; rm -f /tmp/hp-thermal-cooling-start; rm -f /tmp/hp-thermal-notif-cooldown-*; log_msg "INFO" "Service stopped" ;;
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
        echo "Emergency Cooling: ${EMERGENCY_COOLING_TEMP}°C"
        echo "Recovery Target: ${COOLING_RECOVERY_TEMP}°C"
        echo "Max Fan Speed: 50"
        echo "Desktop Notifications: Enabled"
        
        # Safety warnings
        if [ "$temp" != "N/A" ] && [ $temp -gt $EMERGENCY_COOLING_TEMP ]; then
            echo "⚠️  WARNING: Temperature above emergency threshold!"
        fi
        if [ "$temp" != "N/A" ] && [ $temp -gt $CRITICAL_EMERGENCY_TEMP ]; then
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
        
        # Show notification cooldowns (for debugging)
        notif_files=$(ls /tmp/hp-thermal-notif-cooldown-* 2>/dev/null | wc -l)
        if [ $notif_files -gt 0 ]; then
            echo "Active notification cooldowns: $notif_files"
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
    echo "║                    Version 3.0 - 2025                       ║"
    echo "║              github.com/nadeko0/HP-250-G8-Fan-Control       ║"
    echo "║                                                              ║"
    echo "║    🔥 Smart Thermal Control  📱 Desktop Notifications       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_root
    detect_system
    
    case "${1:-install}" in
        "install")
            log_step "Starting installation..."
            setup_debugfs
            setup_modules
            setup_notifications
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
            echo "Features:"
            echo "  • Smart temperature monitoring (88°C emergency threshold)"
            echo "  • Desktop notifications for critical temperatures"
            echo "  • Maximum fan speed: 50 (aggressive cooling)"
            echo "  • 2-minute cooling down periods"
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
                    
                    # Test notification if user is available
                    read -p "Test desktop notification? (y/N): " -n 1 -r
                    echo
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        # Find user for test notification
                        test_user=""
                        for line in $(who | grep "([:]0[)]"); do
                            test_user=$(echo "$line" | awk '{print $1}')
                            break
                        done
                        
                        if [ -z "$test_user" ]; then
                            test_user=$(loginctl list-sessions --no-legend 2>/dev/null | grep "seat0" | head -1 | awk '{print $3}')
                        fi
                        
                        if [ -z "$test_user" ]; then
                            test_user=$(ls /home 2>/dev/null | head -1)
                        fi
                        
                        if [ -n "$test_user" ]; then
                            log_info "Testing notification for user: $test_user"
                            
                            # Try KDE first
                            if command -v kdialog &> /dev/null; then
                                sudo -u "$test_user" DISPLAY=":0" kdialog \
                                    --title "HP Thermal Control" \
                                    --passivepopup "✅ Installation Complete!\n\nHP 250 G8 thermal management is now active.\nYou'll receive notifications for critical temperatures." 5 2>/dev/null && {
                                    log_info "KDE notification test successful!"
                                } || {
                                    log_warn "KDE notification test failed"
                                }
                            fi
                            
                            # Try notify-send as fallback
                            if command -v notify-send &> /dev/null; then
                                sudo -u "$test_user" DISPLAY=":0" \
                                    XDG_RUNTIME_DIR="/run/user/$(id -u "$test_user")" \
                                    notify-send \
                                    --urgency="normal" \
                                    --icon="dialog-information" \
                                    --app-name="HP Thermal Control" \
                                    --expire-time=5000 \
                                    "✅ Installation Complete!" \
                                    "HP 250 G8 thermal management is now active.\nYou'll receive notifications for critical temperatures." \
                                    2>/dev/null && {
                                    log_info "notify-send test successful!"
                                } || {
                                    log_warn "notify-send test failed"
                                }
                            fi
                        else
                            log_warn "No active user found for notification test"
                        fi
                    fi
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
            rm -f /tmp/hp-thermal-cooling-start
            rm -f /tmp/hp-thermal-notif-cooldown-*
            
            systemctl daemon-reload
            udevadm control --reload-rules
            
            log_info "Uninstallation completed (notification preferences preserved)"
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
