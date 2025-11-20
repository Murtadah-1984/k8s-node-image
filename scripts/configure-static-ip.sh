#!/bin/bash
# -------------------------------------------------------------------
# Script: configure-static-ip.sh
# Version: 1.0.0
# Description: Configure static IP address based on hostname from /etc/hosts
# -------------------------------------------------------------------

# ============================================================================
# STRICT MODE & SAFETY
# ============================================================================
set -euo pipefail
IFS=$'\n\t'

# ============================================================================
# GLOBAL CONFIGURATION
# ============================================================================
SCRIPT_NAME=$(basename "$0")
LOGFILE="/var/log/${SCRIPT_NAME%.sh}.log"
DEBUG=${DEBUG:-0}

# ============================================================================
# COLOR FUNCTIONS
# ============================================================================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
debug()   { [ "$DEBUG" = "1" ] && echo -e "${MAGENTA}[DEBUG]${RESET} $*"; }

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================
step() {
    echo -e "\n${BOLD}${CYAN}🚀 $*${RESET}"
}

run_or_die() {
    debug "Running: $*"
    if ! "$@"; then
        error "Failed: $*"
        exit 1
    fi
}

check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        debug "$1 not found"
        return 1
    fi
    return 0
}

# ============================================================================
# ERROR HANDLING
# ============================================================================
trap 'error "Script failed at line $LINENO: $BASH_COMMAND"' ERR

# ============================================================================
# NETWORK FUNCTIONS
# ============================================================================
detect_interface() {
    local interface
    interface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1)
    
    if [ -z "$interface" ]; then
        # Fallback: use first non-loopback interface with an IP
        interface=$(ip -o -4 addr show | grep -v ' lo ' | awk '{print $2}' | head -n1 | cut -d: -f1)
    fi
    
    if [ -z "$interface" ]; then
        error "Could not detect network interface"
        exit 1
    fi
    
    echo "$interface"
}

get_current_gateway() {
    ip route | grep default | awk '{print $3}' | head -n1
}

get_current_nameservers() {
    # Try to get nameservers from systemd-resolve or resolvectl
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl status | grep -A 10 "DNS Servers" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -2 | tr '\n' ' ' | xargs
    elif [ -f /etc/resolv.conf ]; then
        grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | head -2 | tr '\n' ' ' | xargs
    else
        echo "1.1.1.1 8.8.8.8"
    fi
}

calculate_network_prefix() {
    local ip="$1"
    local octets
    IFS='.' read -ra octets <<< "$ip"
    
    # Determine network based on first octet
    local first_octet="${octets[0]}"
    
    # Private network ranges
    if [ "$first_octet" -eq 10 ]; then
        # 10.0.0.0/8 - typically use /24
        echo "24"
    elif [ "$first_octet" -eq 172 ] && [ "${octets[1]}" -ge 16 ] && [ "${octets[1]}" -le 31 ]; then
        # 172.16.0.0/12 - typically use /24
        echo "24"
    elif [ "$first_octet" -eq 192 ] && [ "${octets[1]}" -eq 168 ]; then
        # 192.168.0.0/16 - typically use /24
        echo "24"
    else
        # Default to /24
        echo "24"
    fi
}

calculate_gateway() {
    local ip="$1"
    local prefix="$2"
    local octets
    IFS='.' read -ra octets <<< "$ip"
    
    # For /24 networks, gateway is typically .1
    if [ "$prefix" -eq 24 ]; then
        echo "${octets[0]}.${octets[1]}.${octets[2]}.1"
    else
        # For other prefixes, use .1 as default
        echo "${octets[0]}.${octets[1]}.${octets[2]}.1"
    fi
}

# ============================================================================
# HOSTS FILE PARSING
# ============================================================================
parse_hosts_file() {
    local hosts_file="${1:-/etc/hosts}"
    
    if [ ! -f "$hosts_file" ]; then
        error "Hosts file not found: $hosts_file"
        exit 1
    fi
    
    # Parse hosts file, excluding localhost entries and comments
    # Format: IP HOSTNAME [HOSTNAME2 ...]
    declare -A hostname_to_ip
    
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        # Skip localhost entries
        [[ "$line" =~ 127\.0\.0\.1 ]] && continue
        [[ "$line" =~ ::1 ]] && continue
        [[ "$line" =~ 127\.0\.1\.1 ]] && continue
        
        # Extract IP and hostnames
        read -r ip rest <<< "$line"
        
        # Validate IP address format
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # Extract all hostnames after the IP
            for hostname in $rest; do
                # Skip if it's a comment
                [[ "$hostname" =~ ^# ]] && break
                # Store mapping (hostname -> IP)
                hostname_to_ip["$hostname"]="$ip"
            done
        fi
    done < "$hosts_file"
    
    # Export the associative array (bash 4+)
    declare -p hostname_to_ip 2>/dev/null || {
        # Fallback: return as string for older bash
        for hostname in "${!hostname_to_ip[@]}"; do
            echo "${hostname}:${hostname_to_ip[$hostname]}"
        done
    }
}

get_available_hostnames() {
    local hosts_file="${1:-/etc/hosts}"
    local hostnames=()
    
    if [ ! -f "$hosts_file" ]; then
        error "Hosts file not found: $hosts_file"
        return 1
    fi
    
    debug "Reading hosts file: $hosts_file"
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim leading/trailing whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Skip comments and empty lines
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue
        
        # Skip localhost entries
        [[ "$line" =~ ^127\.0\.0\.1 ]] && continue
        [[ "$line" =~ ^::1 ]] && continue
        [[ "$line" =~ ^127\.0\.1\.1 ]] && continue
        
        # Extract IP and hostnames (handle multiple spaces/tabs)
        # Use awk to properly split on whitespace
        local ip=$(echo "$line" | awk '{print $1}')
        local rest=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^[[:space:]]*//')
        
        # Validate IP address format (more robust regex)
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            # Extract all hostnames after the IP
            for hostname in $rest; do
                # Skip if it's a comment
                [[ "$hostname" =~ ^# ]] && break
                # Skip empty strings
                [[ -z "$hostname" ]] && continue
                # Add hostname if not already in array
                local found=0
                for existing in "${hostnames[@]}"; do
                    if [ "$existing" = "$hostname" ]; then
                        found=1
                        break
                    fi
                done
                if [ $found -eq 0 ]; then
                    hostnames+=("$hostname")
                    debug "Found hostname: $hostname -> $ip"
                fi
            done
        else
            debug "Skipping line (invalid IP format): $line"
        fi
    done < "$hosts_file"
    
    if [ ${#hostnames[@]} -eq 0 ]; then
        debug "No hostnames found in hosts file"
        return 1
    fi
    
    printf '%s\n' "${hostnames[@]}" | sort -u
}

get_ip_for_hostname() {
    local hostname="$1"
    local hosts_file="${2:-/etc/hosts}"
    local ip=""
    
    if [ ! -f "$hosts_file" ]; then
        error "Hosts file not found: $hosts_file"
        return 1
    fi
    
    debug "Looking for IP address for hostname: $hostname"
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim leading/trailing whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Skip comments and empty lines
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue
        
        # Skip localhost entries
        [[ "$line" =~ ^127\.0\.0\.1 ]] && continue
        [[ "$line" =~ ^::1 ]] && continue
        [[ "$line" =~ ^127\.0\.1\.1 ]] && continue
        
        # Extract IP and hostnames (handle multiple spaces/tabs)
        local ip_addr=$(echo "$line" | awk '{print $1}')
        local rest=$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^[[:space:]]*//')
        
        # Validate IP address format
        if [[ "$ip_addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            # Check if hostname is in this line (exact match or word boundary)
            for h in $rest; do
                # Skip comments
                [[ "$h" =~ ^# ]] && break
                # Check for exact match
                if [ "$h" = "$hostname" ]; then
                    echo "$ip_addr"
                    debug "Found IP for $hostname: $ip_addr"
                    return 0
                fi
            done
        fi
    done < "$hosts_file"
    
    debug "IP address not found for hostname: $hostname"
    return 1
}

# ============================================================================
# NETPLAN CONFIGURATION
# ============================================================================
configure_netplan() {
    local interface="$1"
    local ip_address="$2"
    local gateway="$3"
    local nameservers="$4"
    local prefix="${5:-24}"
    
    step "Configuring netplan for static IP..."
    
    # Backup existing netplan files
    if [ -d /etc/netplan ]; then
        info "Backing up existing netplan configuration..."
        mkdir -p /etc/netplan/backup
        cp /etc/netplan/*.yaml /etc/netplan/backup/ 2>/dev/null || true
    else
        run_or_die mkdir -p /etc/netplan
    fi
    
    # Create netplan configuration
    local netplan_file="/etc/netplan/01-static-ip.yaml"
    info "Creating netplan configuration: $netplan_file"
    
    # Convert nameservers string to array format
    local nameserver_list=""
    for ns in $nameservers; do
        if [ -z "$nameserver_list" ]; then
            nameserver_list="      - $ns"
        else
            nameserver_list="$nameserver_list
      - $ns"
        fi
    done
    
    cat > "$netplan_file" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${interface}:
      addresses:
        - ${ip_address}/${prefix}
      gateway4: ${gateway}
      nameservers:
        addresses:
${nameserver_list}
EOF
    
    success "Netplan configuration created"
    
    # Validate netplan configuration
    step "Validating netplan configuration..."
    if netplan generate 2>&1; then
        success "Netplan configuration is valid"
    else
        error "Netplan configuration validation failed"
        exit 1
    fi
}

apply_netplan() {
    step "Applying netplan configuration..."
    warn "This will change the network configuration and may disconnect your SSH session!"
    warn "Make sure you have console access or are running this locally."
    echo ""
    read -p "Do you want to apply the configuration now? (yes/no): " confirm
    
    if [[ "$confirm" =~ ^[Yy][Ee][Ss]$ ]]; then
        info "Applying netplan configuration..."
        if netplan apply; then
            success "Netplan configuration applied successfully"
            info "Network interface will be reconfigured. You may lose SSH connection."
            info "If you lose connection, reconnect using the new IP address: $1"
        else
            error "Failed to apply netplan configuration"
            exit 1
        fi
    else
        warn "Configuration not applied. You can apply it later with: sudo netplan apply"
        info "Configuration file saved at: /etc/netplan/01-static-ip.yaml"
    fi
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================
main() {
    step "Static IP Configuration from /etc/hosts"
    
    # Root check
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Setup logging
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    
    # Check if /etc/hosts exists
    if [ ! -f /etc/hosts ]; then
        error "/etc/hosts file not found"
        exit 1
    fi
    
    # Get available hostnames
    step "Reading available hostnames from /etc/hosts..."
    local available_hostnames
    if ! available_hostnames=$(get_available_hostnames); then
        error "Failed to read hostnames from /etc/hosts"
        error "Please ensure /etc/hosts exists and contains valid hostname entries"
        info "Checking /etc/hosts file..."
        if [ -f /etc/hosts ]; then
            info "File exists. Showing first 20 lines:"
            head -20 /etc/hosts | sed 's/^/  /'
        else
            error "/etc/hosts file does not exist"
        fi
        exit 1
    fi
    
    if [ -z "$available_hostnames" ]; then
        error "No hostnames found in /etc/hosts (excluding localhost)"
        info "Please check that /etc/hosts contains entries like:"
        info "  10.0.20.11   cp-01"
        info "  10.0.30.41   worker-01"
        exit 1
    fi
    
    # Display available hostnames
    info "Available hostnames in /etc/hosts:"
    echo ""
    local count=1
    declare -a hostname_array
    declare -A hostname_to_ip_map
    
    while IFS= read -r hostname; do
        local ip
        ip=$(get_ip_for_hostname "$hostname")
        if [ -n "$ip" ]; then
            printf "  %2d. %-30s (%s)\n" "$count" "$hostname" "$ip"
            hostname_array+=("$hostname")
            hostname_to_ip_map["$hostname"]="$ip"
            count=$((count + 1))
        fi
    done <<< "$available_hostnames"
    echo ""
    
    # Check if hostname was provided via command line
    local selected_hostname="${SELECTED_HOSTNAME:-}"
    local selected_ip=""
    
    # Prompt for hostname selection if not provided
    while [ -z "$selected_hostname" ]; do
        read -p "Enter hostname (or number from list): " input
        
        # Check if input is a number
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            local index=$((input - 1))
            if [ $index -ge 0 ] && [ $index -lt ${#hostname_array[@]} ]; then
                selected_hostname="${hostname_array[$index]}"
            else
                error "Invalid number. Please try again."
            fi
        else
            # Check if input matches a hostname
            if echo "$available_hostnames" | grep -q "^${input}$"; then
                selected_hostname="$input"
            else
                error "Hostname '$input' not found in /etc/hosts. Please try again."
            fi
        fi
    done
    
    # Get IP address for selected hostname
    if [ -n "${hostname_to_ip_map[$selected_hostname]:-}" ]; then
        selected_ip="${hostname_to_ip_map[$selected_hostname]}"
    else
        selected_ip=$(get_ip_for_hostname "$selected_hostname")
    fi
    
    if [ -z "$selected_ip" ]; then
        error "Could not find IP address for hostname: $selected_hostname"
        exit 1
    fi
    
    success "Selected: $selected_hostname -> $selected_ip"
    
    # Detect network interface
    step "Detecting network interface..."
    local interface
    interface=$(detect_interface)
    info "Detected interface: $interface"
    
    # Calculate network prefix
    local prefix
    prefix=$(calculate_network_prefix "$selected_ip")
    info "Network prefix: /$prefix"
    
    # Get or calculate gateway
    local gateway
    gateway=$(get_current_gateway)
    if [ -z "$gateway" ]; then
        gateway=$(calculate_gateway "$selected_ip" "$prefix")
        warn "Could not detect current gateway, using calculated: $gateway"
    else
        info "Detected gateway: $gateway"
    fi
    
    # Get nameservers
    local nameservers
    nameservers=$(get_current_nameservers)
    if [ -z "$nameservers" ]; then
        nameservers="1.1.1.1 8.8.8.8"
        warn "Could not detect nameservers, using defaults: $nameservers"
    else
        info "Detected nameservers: $nameservers"
    fi
    
    # Display configuration summary
    echo ""
    echo "=============================================="
    echo "  Configuration Summary"
    echo "=============================================="
    echo "  Hostname:     $selected_hostname"
    echo "  IP Address:   $selected_ip/$prefix"
    echo "  Interface:    $interface"
    echo "  Gateway:      $gateway"
    echo "  Nameservers:  $nameservers"
    echo "=============================================="
    echo ""
    
    # Configure netplan
    configure_netplan "$interface" "$selected_ip" "$gateway" "$nameservers" "$prefix"
    
    # Apply netplan
    apply_netplan "$selected_ip"
    
    # Set hostname
    step "Setting system hostname..."
    hostnamectl set-hostname "$selected_hostname" 2>/dev/null || echo "$selected_hostname" > /etc/hostname
    success "Hostname set to: $selected_hostname"
    
    success "Static IP configuration completed! 🎉"
    info "Configuration file: /etc/netplan/01-static-ip.yaml"
    info "If configuration was applied, reconnect using: ssh user@$selected_ip"
}

# ============================================================================
# SCRIPT ENTRY POINT
# ============================================================================
# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug|-d)
            DEBUG=1
            set -x
            ;;
        --hostname|-h)
            SELECTED_HOSTNAME="$2"
            shift
            ;;
        --help)
            cat <<EOF
Usage: $0 [OPTIONS]

Configure static IP address based on hostname from /etc/hosts

Options:
  --hostname, -h HOSTNAME    Pre-select hostname (skips interactive prompt)
  --debug, -d                Enable debug mode
  --help                     Show this help message

Examples:
  # Interactive mode (recommended)
  sudo $0

  # Non-interactive mode
  sudo $0 --hostname worker-01

EOF
            exit 0
            ;;
        *)
            warn "Unknown option: $1"
            ;;
    esac
    shift
done

# Setup logging
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
exec > >(tee -a "$LOGFILE" 2>/dev/null || cat) 2>&1

# Run main function
main "$@"

# Required exit
exit 0

