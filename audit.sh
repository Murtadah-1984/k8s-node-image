#!/usr/bin/env bash
# -------------------------------------------------------------------
# Script: audit.sh
# Version: 1.0.0
# Description: CIS-style baseline & security audit for Ubuntu Linux
#              - Read-only: DOES NOT CHANGE THE SYSTEM
#              - Prints PASS/FAIL/WARN with suggested remediations
#
# Usage:
#   sudo bash audit.sh
#
# Target:
#   - Optimized/tested for Ubuntu 22.04 with systemd
# -------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# ============== COLORS & HELPERS ======================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
BOLD="\e[1m"
RESET="\e[0m"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

section() { echo -e "\n${BOLD}${BLUE}▶ $*${RESET}"; }
pass()    { PASS_COUNT=$((PASS_COUNT+1)); echo -e "${GREEN}[PASS]${RESET} $*"; }
fail()    { FAIL_COUNT=$((FAIL_COUNT+1)); echo -e "${RED}[FAIL]${RESET} $*"; }
warn()    { WARN_COUNT=$((WARN_COUNT+1)); echo -e "${YELLOW}[WARN]${RESET} $*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR]${RESET} This script must be run as root (use sudo)."
    exit 1
  fi
}

# ============== CHECK FUNCTIONS =======================

check_os_version() {
  section "OS Version"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    echo "Detected: ${PRETTY_NAME:-unknown}"
    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "22.04" ]]; then
      pass "Running on Ubuntu 22.04 (target platform)"
    else
      warn "Not Ubuntu 22.04; CIS baseline may differ for ${PRETTY_NAME:-unknown}"
    fi
  else
    fail "/etc/os-release not found – cannot determine OS version."
  fi
}

check_ufw() {
  section "Firewall (UFW)"
  if ! command -v ufw >/dev/null 2>&1; then
    fail "ufw is not installed."
    echo "  Suggested fix: apt-get install -y ufw && ufw enable"
    return
  fi

  local status
  status=$(ufw status verbose || true)

  if echo "$status" | grep -qi "Status: active"; then
    pass "UFW is active."
  else
    fail "UFW is not active."
    echo "  Suggested fix: ufw --force enable"
  fi

  if echo "$status" | grep -qi "Default: deny (incoming)"; then
    pass "Default incoming policy is DENY."
  else
    warn "Default incoming policy is not 'deny'."
    echo "  Suggested fix: ufw default deny incoming"
  fi

  if echo "$status" | grep -qi "Default: allow (outgoing)"; then
    pass "Default outgoing policy is ALLOW."
  else
    warn "Default outgoing policy is not 'allow'."
    echo "  Suggested fix: ufw default allow outgoing"
  fi
}

check_ssh() {
  section "SSH Hardening (/etc/ssh/sshd_config)"
  local cfg="/etc/ssh/sshd_config"
  [[ -f "$cfg" ]] || { fail "SSH config not found at $cfg"; return; }

  # Small helper
  has_val() {
    grep -Eiq "^[[:space:]]*$1[[:space:]]+$2" "$cfg"
  }

  if has_val "PermitRootLogin" "no"; then
    pass "PermitRootLogin no"
  else
    fail "PermitRootLogin is not set to 'no'."
    echo "  Fix: set 'PermitRootLogin no' and restart sshd"
  fi

  if has_val "Protocol" "2"; then
    pass "SSH protocol set to 2"
  else
    warn "SSH Protocol is not explicitly set to 2."
  fi

  if has_val "PermitEmptyPasswords" "no"; then
    pass "PermitEmptyPasswords no"
  else
    fail "PermitEmptyPasswords is not set to 'no'."
  fi

  if has_val "X11Forwarding" "no"; then
    pass "X11Forwarding no"
  else
    warn "X11Forwarding is not explicitly disabled."
  fi

  if has_val "AllowTcpForwarding" "no"; then
    pass "AllowTcpForwarding no"
  else
    warn "AllowTcpForwarding not set to 'no'."
  fi

  if has_val "ClientAliveInterval" "300"; then
    pass "ClientAliveInterval 300"
  else
    warn "ClientAliveInterval is not set to 300."
  fi

  if has_val "ClientAliveCountMax" "2"; then
    pass "ClientAliveCountMax 2"
  else
    warn "ClientAliveCountMax is not set to 2."
  fi
}

check_swap() {
  section "Swap Disabled (Kubernetes requirement + CIS recommendation)"
  if swapon --show | grep -q .; then
    fail "Swap is still enabled."
    echo "  Fix: swapoff -a && comment out swap lines in /etc/fstab"
  else
    pass "No active swap devices."
  fi
}

check_sysctl_cis() {
  section "Sysctl – Network Security (CIS-style)"
  local -A EXPECT=(
    ["net.ipv4.conf.all.rp_filter"]="1"
    ["net.ipv4.conf.default.rp_filter"]="1"
    ["net.ipv4.conf.all.accept_redirects"]="0"
    ["net.ipv4.conf.default.accept_redirects"]="0"
    ["net.ipv4.conf.all.secure_redirects"]="0"
    ["net.ipv4.conf.default.secure_redirects"]="0"
    ["net.ipv6.conf.all.accept_redirects"]="0"
    ["net.ipv6.conf.default.accept_redirects"]="0"
    ["net.ipv4.conf.all.send_redirects"]="0"
    ["net.ipv4.conf.default.send_redirects"]="0"
    ["net.ipv4.conf.all.log_martians"]="1"
    ["net.ipv4.conf.default.log_martians"]="1"
    ["net.ipv4.icmp_echo_ignore_broadcasts"]="1"
    ["net.ipv4.tcp_syncookies"]="1"
    ["net.ipv4.conf.all.accept_source_route"]="0"
    ["net.ipv4.conf.default.accept_source_route"]="0"
    ["net.ipv6.conf.all.accept_source_route"]="0"
    ["net.ipv6.conf.default.accept_source_route"]="0"
  )

  for key in "${!EXPECT[@]}"; do
    local expected="${EXPECT[$key]}"
    local value
    value=$(sysctl -n "$key" 2>/dev/null || echo "MISSING")
    if [[ "$value" == "$expected" ]]; then
      pass "$key = $value"
    else
      fail "$key = $value (expected $expected)"
      echo "  Fix: echo '$key = $expected' >> /etc/sysctl.d/k8s-cis.conf && sysctl --system"
    fi
  done
}

check_file_perms() {
  section "Sensitive File Permissions"
  local ok=true

  check_perm() {
    local path="$1" expected="$2"
    if [[ ! -e "$path" ]]; then
      warn "$path does not exist."
      return
    fi
    local actual
    actual=$(stat -c "%a" "$path" 2>/dev/null || echo "???")
    if [[ "$actual" == "$expected" ]]; then
      pass "$path has permission $actual"
    else
      fail "$path has permission $actual (expected $expected)"
      echo "  Fix: chmod $expected $path"
      ok=false
    fi
  }

  check_perm /etc/passwd 644
  check_perm /etc/shadow 640
  check_perm /etc/group  644
  check_perm /etc/gshadow 640

  $ok || true
}

check_services() {
  section "Unnecessary Services Disabled"
  check_unit() {
    local svc="$1"
    if systemctl list-unit-files | grep -q "^$svc"; then
      local state
      state=$(systemctl is-enabled "$svc" 2>/dev/null || echo "unknown")
      if [[ "$state" == "disabled" || "$state" == "masked" ]]; then
        pass "Service $svc is $state"
      else
        warn "Service $svc is enabled ($state)."
        echo "  Fix: systemctl disable --now $svc"
      fi
    else
      pass "Service $svc not installed."
    fi
  }

  check_unit snapd.service
  check_unit bluetooth.service
  check_unit avahi-daemon.service
}

check_auditd() {
  section "Auditd"
  if ! command -v auditctl >/dev/null 2>&1; then
    fail "auditd is not installed."
    echo "  Fix: apt-get install -y auditd audispd-plugins"
    return
  fi

  local state
  state=$(systemctl is-active auditd 2>/dev/null || echo "unknown")
  if [[ "$state" == "active" ]]; then
    pass "auditd service is active."
  else
    fail "auditd service is not active (state: $state)."
    echo "  Fix: systemctl enable --now auditd"
  fi

  # Basic check for any audit rules present
  if auditctl -l 2>/dev/null | grep -q .; then
    pass "Audit rules are present."
  else
    warn "No audit rules configured."
    echo "  Fix: add /etc/audit/rules.d/*.rules according to CIS benchmark."
  fi
}

check_time_sync() {
  section "Time Synchronization"
  if systemctl list-unit-files | grep -q "^chronyd.service"; then
    local state
    state=$(systemctl is-active chronyd 2>/dev/null || echo "unknown")
    if [[ "$state" == "active" ]]; then
      pass "chronyd is active."
    else
      warn "chronyd is installed but not active (state: $state)."
    fi
  elif systemctl list-unit-files | grep -q "^systemd-timesyncd.service"; then
    local state
    state=$(systemctl is-active systemd-timesyncd 2>/dev/null || echo "unknown")
    if [[ "$state" == "active" ]]; then
      pass "systemd-timesyncd is active."
    else
      warn "systemd-timesyncd is not active (state: $state)."
    fi
  else
    warn "No known time synchronization service detected."
  fi
}

check_password_policy() {
  section "Password Policy (basic check)"
  if [[ -f /etc/pam.d/common-password ]]; then
    if grep -q "pam_pwquality.so" /etc/pam.d/common-password; then
      pass "pam_pwquality is used in common-password."
    else
      warn "pam_pwquality is not referenced in /etc/pam.d/common-password."
      echo "  Fix: configure pam_pwquality.so according to CIS guidance."
    fi
  else
    warn "/etc/pam.d/common-password not found."
  fi
}

# ============== MAIN ============================

require_root

echo "============================================================"
echo "   CIS-STYLE BASELINE & SECURITY AUDIT"
echo "============================================================"

check_os_version
check_ufw
check_ssh
check_swap
check_sysctl_cis
check_file_perms
check_services
check_auditd
check_time_sync
check_password_policy

echo -e "\n${BOLD}Summary:${RESET}"
echo -e "  ${GREEN}PASS:${RESET} $PASS_COUNT"
echo -e "  ${RED}FAIL:${RESET} $FAIL_COUNT"
echo -e "  ${YELLOW}WARN:${RESET} $WARN_COUNT"

if (( FAIL_COUNT == 0 )); then
  echo -e "\n${GREEN}System passes all mandatory CIS-style baseline checks (in this script).${RESET}"
else
  echo -e "\n${RED}System has $FAIL_COUNT failing checks. Review output above and remediate.${RESET}"
fi

exit 0

