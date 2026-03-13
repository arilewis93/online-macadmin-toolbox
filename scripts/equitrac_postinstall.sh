#!/bin/bash

# =============================================================================
# Equitrac Mac Client - Silent Installation (Intune-compatible)
# =============================================================================
#
# Designed and engineered by:
#   Lance van der Molen and Aryeh Lewis
#   iStore Business - Apple Platform Managed Services
#
# Based on: Equitrac_MacOSX_6_4_3_59.pkg (Kofax signed)
#
# Inner PKG components:
#   com.equitrac.macclient  -> Print Client + EQLoginController
#                              CUPS backend: /usr/libexec/cups/backend/eqtrans
#   com.equitrac.drc        -> Document Routing Client (DRC)
#                              CUPS backend: /usr/libexec/cups/backend/eqpmon
#                              DRC is OFF by default -- needs choices XML
#
# Re-engineered by iStore Business for Intune headless MDM deployment
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# CONFIGURATION - Update these values per environment
# ---------------------------------------------------------------------------

PLIST_BUNDLE_ID="com.istorebusiness.equitrac"
PLIST_PATH="/Library/Managed Preferences/${PLIST_BUNDLE_ID}.plist"

# Payload directory -- pkgs are deployed here by the outer .pkg.
# Only filenames are stored in the config profile; this path is prepended
# by the script at runtime, keeping the deployment path out of the profile.
PAYLOAD_DIR="/private/var/tmp/.eqpayload"

# Installer pkg: filename only from profile, full path built at runtime
INSTALLER_PKG_NAME=$(defaults read "$PLIST_PATH" INSTALLER_PKG 2>/dev/null)
INSTALLER_PKG="${PAYLOAD_DIR}/${INSTALLER_PKG_NAME}"

SECURITY_DOMAIN=$(defaults read "${PLIST_PATH}" SECURITY_DOMAIN 2>/dev/null)
SECURITY_USERNAME=$(defaults read "${PLIST_PATH}" SECURITY_USERNAME 2>/dev/null)
SECURITY_PASSWORD=$(defaults read "${PLIST_PATH}" SECURITY_PASSWORD 2>/dev/null)
SECURITY_NODE=$(defaults read "${PLIST_PATH}" SECURITY_NODE 2>/dev/null)
DATACENTER_NAME=$(defaults read "${PLIST_PATH}" DATACENTER_NAME 2>/dev/null)
CAS_SERVER=$(defaults read "${PLIST_PATH}" CAS_SERVER 2>/dev/null)
DRE_SERVER=$(defaults read "${PLIST_PATH}" DRE_SERVER 2>/dev/null)
INSTALL_DRC=$(defaults read "${PLIST_PATH}" INSTALL_DRC 2>/dev/null || echo false)
DRC_SYS_NAME_MODE=$(defaults read "${PLIST_PATH}" DRC_SYS_NAME_MODE 2>/dev/null)

# Read new prefs from config profile
SKIP_LINK_LOCAL_IP=$(defaults read "${PLIST_PATH}" SKIP_LINK_LOCAL_IP 2>/dev/null || echo true)
IP_ADDR_INTERFACE=$(defaults read "${PLIST_PATH}" IP_ADDR_INTERFACE 2>/dev/null || echo "")
REG_MACHINE_ID_DNS=$(defaults read "${PLIST_PATH}" REG_MACHINE_ID_DNS 2>/dev/null || echo false)
USE_CACHED_LOGIN=$(defaults read "${PLIST_PATH}" USE_CACHED_LOGIN 2>/dev/null || echo false)
PROMPT_FOR_PASSWORD=$(defaults read "${PLIST_PATH}" PROMPT_FOR_PASSWORD 2>/dev/null || echo true)
USER_ID_LABEL=$(defaults read "${PLIST_PATH}" USER_ID_LABEL 2>/dev/null || echo "")
IGNORE_SUPPLIES_LEVEL_JOB=$(defaults read "${PLIST_PATH}" IGNORE_SUPPLIES_LEVEL_JOB 2>/dev/null || echo false)

# Normalize booleans (defaults read returns 1/0 for plist booleans)
for _bvar in INSTALL_DRC SKIP_LINK_LOCAL_IP REG_MACHINE_ID_DNS USE_CACHED_LOGIN PROMPT_FOR_PASSWORD IGNORE_SUPPLIES_LEVEL_JOB; do
    case "${!_bvar,,}" in
        1|true|yes) printf -v "$_bvar" '%s' "true" ;;
        *)          printf -v "$_bvar" '%s' "false" ;;
    esac
done

MAX_AGE_DAYS=7

# ---------------------------------------------------------------------------
# PRINTER CONFIG - loaded from MDM config profile at runtime
#
# PRINTERS  - array of dicts, each with:
#               name  - CUPS queue name / DRE printer name
#               ppd   - "generic" OR an absolute path to a source .ppd file
#
# PRINT_DRIVERS - flat array of .pkg filenames to install before creating printers.
#                 Filenames only (no paths) -- the script prepends PAYLOAD_DIR.
#                 Not tied to any individual printer; all pkgs are installed
#                 once, in order, before any queues are created.
#                 Any missing pkg is a fatal error.
#
# Example profile keys (com.istorebusiness.equitrac.plist):
#
#   <key>PRINTERS</key>
#   <array>
#     <dict>
#       <key>name</key>  <string>HP-Colour-Mac</string>
#       <key>ppd</key>   <string>/private/var/tmp/.eqpayload/HP-Colour-Mac</string>
#     </dict>
#     <dict>
#       <key>name</key>  <string>HP-Black-White</string>
#       <key>ppd</key>   <string>generic</string>
#     </dict>
#   </array>
#
#   <key>PRINT_DRIVERS</key>
#   <array>
#     <string>hp-printer-essentials-UniPS-6_3_0_1.pkg</string>
#   </array>
#
# Populated by load_printer_config().
# ---------------------------------------------------------------------------

# Populated by load_printer_config()
PRINTER_NAMES=()      # parallel array: queue names
PRINTER_PPDS=()       # parallel array: "generic" or absolute ppd source path
PRINT_DRIVERS=()      # flat array: pkg full paths to install (filenames from profile + PAYLOAD_DIR)
PRINTER_TYPES=()     # parallel array: "dre" or "ip"
PRINTER_IPS=()       # parallel array: IP address (IP printers only, empty for DRE)
PRINTER_PROTOCOLS=() # parallel array: "raw" or "lpr" (IP printers only, empty for DRE)
PRINTER_PORTS=()     # parallel array: port number (IP+raw only, empty otherwise)
PRINTER_QUEUES=()    # parallel array: queue name (IP+lpr only, empty otherwise)

# EQPrinterUtilityX / EquitracOfficePrefs feature flags (read from config profile)
# Each maps to a bit in the "Feature Selection" bitmask written to EquitracOfficePrefs:
#
#   PREF_CLIENT_BILLING        = 2
#   PREF_PROMPT_FOR_LOGIN      = 4
#   PREF_COST_PREVIEW          = 8
#   PREF_ALLOW_RENAME_DOCUMENT = 16
#   PREF_RELEASE_KEY           = 32
#
# compute_feature_selection() sums whichever are true and stores the result in
# FEATURE_SELECTION, which is then written to EquitracOfficePrefs.
PREF_CLIENT_BILLING=false
PREF_PROMPT_FOR_LOGIN=false
PREF_COST_PREVIEW=false
PREF_ALLOW_RENAME_DOCUMENT=false
PREF_RELEASE_KEY=false
FEATURE_SELECTION=0     # computed by compute_feature_selection()

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------
LOG="/var/log/equitrac_install.log"

log_info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }
log_warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG" >&2; }

# ---------------------------------------------------------------------------
# PRINTER CONFIG LOADER
# ---------------------------------------------------------------------------
# Reads the PRINTERS array-of-dicts from the MDM config profile plist and
# populates PRINTER_NAMES, PRINTER_PPDS, and PRINT_DRIVERS.
#
# Requires: /usr/libexec/PlistBuddy (present on all macOS versions we support)
# ---------------------------------------------------------------------------
load_printer_config() {
    log_info "Loading printer config from profile..."

    local pb="/usr/libexec/PlistBuddy"

    if [[ ! -x "$pb" ]]; then
        log_error "PlistBuddy not found -- cannot load printer config"
        return 1
    fi

    # ---- PRINTERS array -------------------------------------------------------
    local printer_count
    printer_count=$("$pb" -c "Print :PRINTERS" "$PLIST_PATH" 2>/dev/null \
                    | grep -c "^    Dict {" || true)

    if [[ "$printer_count" -eq 0 ]]; then
        log_warn "No PRINTERS defined in config profile -- skipping printer creation"
    else
        log_info "Found $printer_count printer(s) in config profile"
        local i
        for (( i = 0; i < printer_count; i++ )); do
            local name ppd

            name=$("$pb" -c "Print :PRINTERS:${i}:name" "$PLIST_PATH" 2>/dev/null || true)
            ppd=$( "$pb" -c "Print :PRINTERS:${i}:ppd"  "$PLIST_PATH" 2>/dev/null || true)

            if [[ -z "$name" ]]; then
                log_warn "PRINTERS[$i] has no 'name' key -- skipping"
                continue
            fi

            # Default ppd to "generic" if not specified
            [[ -z "$ppd" ]] && ppd="generic"

            PRINTER_NAMES+=( "$name" )
            PRINTER_PPDS+=( "$ppd" )

            local ptype
            ptype=$("$pb" -c "Print :PRINTERS:${i}:type" "$PLIST_PATH" 2>/dev/null || echo "dre")
            PRINTER_TYPES+=( "$ptype" )

            if [[ "$ptype" == "ip" ]]; then
                local pip pproto pport pqueue
                pip=$("$pb" -c "Print :PRINTERS:${i}:ip" "$PLIST_PATH" 2>/dev/null || echo "")
                pproto=$("$pb" -c "Print :PRINTERS:${i}:protocol" "$PLIST_PATH" 2>/dev/null || echo "raw")
                pport=$("$pb" -c "Print :PRINTERS:${i}:port" "$PLIST_PATH" 2>/dev/null || echo "9100")
                pqueue=$("$pb" -c "Print :PRINTERS:${i}:queue" "$PLIST_PATH" 2>/dev/null || echo "")
                PRINTER_IPS+=( "$pip" )
                PRINTER_PROTOCOLS+=( "$pproto" )
                PRINTER_PORTS+=( "$pport" )
                PRINTER_QUEUES+=( "$pqueue" )
                log_info "  Printer[$i]: type=ip name='$name' ip='$pip' proto='$pproto' port='$pport' queue='$pqueue' ppd='$ppd'"
            else
                PRINTER_IPS+=( "" )
                PRINTER_PROTOCOLS+=( "" )
                PRINTER_PORTS+=( "" )
                PRINTER_QUEUES+=( "" )
                log_info "  Printer[$i]: type=dre name='$name' ppd='$ppd'"
            fi
        done
    fi

    # ---- PRINT_DRIVERS flat array ---------------------------------------------
    local driver_count
    driver_count=$("$pb" -c "Print :PRINT_DRIVERS" "$PLIST_PATH" 2>/dev/null \
                   | grep -c "^    " || true)

    if [[ "$driver_count" -eq 0 ]]; then
        log_info "No PRINT_DRIVERS defined in config profile -- no driver pkgs to install"
    else
        log_info "Found $driver_count driver pkg(s) in config profile"
        local j
        for (( j = 0; j < driver_count; j++ )); do
            local pkg
            pkg=$("$pb" -c "Print :PRINT_DRIVERS:${j}" "$PLIST_PATH" 2>/dev/null || true)
            if [[ -z "$pkg" ]]; then
                log_warn "PRINT_DRIVERS[$j] is empty -- skipping"
                continue
            fi
            # Security: must be a bare filename, not a path
            validate_pkg_filename "$pkg" "PRINT_DRIVERS[$j]"
            PRINT_DRIVERS+=( "${PAYLOAD_DIR}/${pkg}" )
            log_info "  Driver[$j]: $pkg -> ${PAYLOAD_DIR}/${pkg}"
        done
    fi

    # ---- Feature Selection prefs ---------------------------------------------
    # Read each boolean from the profile; default to false if missing.
    # compute_feature_selection() will sum these into FEATURE_SELECTION.
    local pref_key pref_val
    for pref_key in \
        PREF_CLIENT_BILLING \
        PREF_PROMPT_FOR_LOGIN \
        PREF_COST_PREVIEW \
        PREF_ALLOW_RENAME_DOCUMENT \
        PREF_RELEASE_KEY; do

        pref_val=$(defaults read "$PLIST_PATH" "$pref_key" 2>/dev/null || echo "false")
        # Normalise: accept 1/true/yes (case-insensitive) as true, everything else false
        case "${pref_val,,}" in
            1|true|yes) pref_val="true"  ;;
            *)           pref_val="false" ;;
        esac
        printf -v "$pref_key" '%s' "$pref_val"
        log_info "  $pref_key = $pref_val"
    done
}

# ---------------------------------------------------------------------------
# FEATURE SELECTION BITMASK
# ---------------------------------------------------------------------------
# Sums the bit values for whichever prefs are enabled and stores the result
# in FEATURE_SELECTION.  Must be called after load_printer_config().
#
# Bit map:
#   CLIENT_BILLING        = 2
#   PROMPT_FOR_LOGIN      = 4
#   COST_PREVIEW          = 8
#   ALLOW_RENAME_DOCUMENT = 16
#   RELEASE_KEY           = 32
# ---------------------------------------------------------------------------
compute_feature_selection() {
    local total=0

    declare -A _PREF_BITS=(
        [PREF_CLIENT_BILLING]=2
        [PREF_PROMPT_FOR_LOGIN]=4
        [PREF_COST_PREVIEW]=8
        [PREF_ALLOW_RENAME_DOCUMENT]=16
        [PREF_RELEASE_KEY]=32
    )

    local key
    for key in "${!_PREF_BITS[@]}"; do
        local val="${!key}"   # indirect expansion: value of the variable named by $key
        if [[ "$val" == "true" ]]; then
            total=$(( total + _PREF_BITS[$key] ))
            log_info "  Feature Selection: +${_PREF_BITS[$key]} ($key)"
        fi
    done

    FEATURE_SELECTION=$total
    log_info "Feature Selection total = $FEATURE_SELECTION"
}

# ---------------------------------------------------------------------------
# PKG FILENAME VALIDATION
# ---------------------------------------------------------------------------
# Security: only bare filenames are accepted from the config profile.
# Path separators and traversal sequences are rejected so that the profile
# cannot redirect the installer to arbitrary locations on disk.
# ---------------------------------------------------------------------------
validate_pkg_filename() {
    local name="$1"
    local label="$2"
    if [[ -z "$name" ]]; then
        log_error "FATAL: $label is empty"
        exit 1
    fi
    if [[ "$name" == */* ]] || [[ "$name" == *..* ]]; then
        log_error "FATAL: $label must be a bare filename (no path components): $name"
        exit 1
    fi
    if [[ ! "$name" =~ \.pkg$ ]]; then
        log_warn "$label does not end in .pkg: $name"
    fi
}

# ---------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# ---------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_macos_version() {
    local version
    version=$(sw_vers -productVersion)
    log_info "macOS version: $version"

    local major
    major=$(echo "$version" | cut -d. -f1)
    if [[ "$major" -lt 11 ]]; then
        log_warn "macOS $version detected. Equitrac 6.4 targets 10.12.6+, but Intune PKG requires macOS 11+"
    fi
}

# ---------------------------------------------------------------------------
# DIRECTORY SETUP
# ---------------------------------------------------------------------------
create_directories() {
    log_info "Creating Equitrac directories..."

    local base_dir="/Library/Application Support/Equitrac"
    local dre_dir="$base_dir/DRE"
    local log_dir="/Library/Application Support/Kofax/ControlSuite/Logs/Equitrac"

    mkdir -p "$base_dir" "$dre_dir" "$log_dir"
    chown -R root:admin "$base_dir"
    chmod -R 775 "$base_dir"
    chmod 755 "$dre_dir"

    log_info "Directories created"
}

# ---------------------------------------------------------------------------
# CONFIGURATION FILES
# ---------------------------------------------------------------------------
create_config_files() {
    log_info "Writing configuration files..."

    local hostname_fqdn
    hostname_fqdn=$(hostname -f 2>/dev/null || hostname)

    local base_dir="/Library/Application Support/Equitrac"

    # EquitracOfficePrefs - plain text key-value format
    # This is the main config file read by EQPrinterUtilityX and EQLoginController
    cat > "$base_dir/EquitracOfficePrefs" <<EOF
DNSMachineID = ${hostname_fqdn}
DRCSysNameMode = ${DRC_SYS_NAME_MODE}
Feature Selection = ${FEATURE_SELECTION}
IPAddrInterfaceName = ${IP_ADDR_INTERFACE}
IgnoreSuppliesLevelJob = ${IGNORE_SUPPLIES_LEVEL_JOB}
LastCASSync = $(date +%s)
LastModifiedTimestamp = $(date '+%Y-%m-%d %H:%M:%S')
LastPrinterCacheFullUpdate = $(date +%s)
PromptForPasssword = ${PROMPT_FOR_PASSWORD}
RegMachineIDWithDNSSvr = ${REG_MACHINE_ID_DNS}
SkipLinkLocalIPAddr = ${SKIP_LINK_LOCAL_IP}
UseCachedLogin = ${USE_CACHED_LOGIN}
UserIDLabelText = ${USER_ID_LABEL}
EOF

    if [[ "$INSTALL_DRC" == true ]]; then
        # EQDRECAS.cfg - CAS server for DRC
        echo "$CAS_SERVER" > "$base_dir/DRE/EQDRECAS.cfg"
        # EQDRESYS.cfg - local hostname identifier for DRC
        echo "$hostname_fqdn" > "$base_dir/DRE/EQDRESYS.cfg"
    fi

    log_info "Configuration files written"
}

# ---------------------------------------------------------------------------
# SUPPORT FILES (security, tools, uninstall)
# ---------------------------------------------------------------------------
copy_support_files() {
    log_info "Copying support files..."

    local base_dir="/Library/Application Support/Equitrac"
    local staging="$PAYLOAD_DIR"

    for dir in security Tools Uninstall; do
        if [[ -d "$staging/$dir" ]]; then
            cp -R "$staging/$dir" "$base_dir/"
            log_info "Copied $dir"
        else
            log_warn "$dir not found in staging"
        fi
    done
}

# ---------------------------------------------------------------------------
# SECURITY FRAMEWORK ENROLLMENT
# ---------------------------------------------------------------------------
ENROLLMENT_MARKER="/Library/Application Support/Equitrac/.security_enrolled"

register_security_framework() {
    log_info "Registering with Security Framework..."

    local security_script="${PAYLOAD_DIR}/security/NDI.SecurityConfig.sh"

    if [[ ! -f "$security_script" ]]; then
        log_error "Security script not found: $security_script"
        install_network_remediation "security script missing at install time"
        return 1
    fi

    chmod +x "$security_script"

    # Command from client install guide:
    if "$security_script" enroll \
        "${SECURITY_DOMAIN}\\${SECURITY_USERNAME}" \
        "$SECURITY_PASSWORD" \
        "$SECURITY_NODE" \
        "$DATACENTER_NAME" \
        "everyone" \
        "enroll_drc"; then
        log_info "Security Framework registration successful"
        touch "$ENROLLMENT_MARKER"
    else
        log_error "Security Framework registration failed (non-fatal, continuing)"

        # Determine if this is a network issue or a server/credential issue
        # macOS ping -W is in MILLISECONDS (not seconds like Linux)
        if /sbin/ping -c 1 -W 2000 "$CAS_SERVER" >/dev/null 2>&1; then
            # CAS is reachable but enrollment still failed -- likely credential
            # or server-side issue. Remediation daemon won't help.
            log_error "CAS server is reachable. Failure is likely credential/server-side."
            log_error "Check credentials and SFS configuration. Manual enrollment needed."
        else
            # CAS unreachable -- network issue. Install auto-retry daemon.
            log_info "CAS server unreachable -- installing network remediation daemon..."
            install_network_remediation "enrollment failed -- CAS unreachable"
        fi
    fi
}

# ---------------------------------------------------------------------------
# NETWORK REMEDIATION FAILSAFE
# ---------------------------------------------------------------------------
# If the Mac isn't on NEDCORP when Intune installs, security enrollment
# fails. This installs a LaunchDaemon that watches for network changes
# (WatchPaths on /Library/Preferences/SystemConfiguration) and retries
# enrollment when the CAS server becomes reachable.
#
# Once enrollment succeeds, the daemon self-removes.
# Safety: auto-removes after 7 days if enrollment never succeeds.
# ---------------------------------------------------------------------------
install_network_remediation() {
    local reason="$1"
    local daemon_label="com.istorebusiness.equitrac.network-remediation"
    local daemon_plist="/Library/LaunchDaemons/${daemon_label}.plist"
    local script_dest="/Library/Application Support/Equitrac/equitrac_network_remediation.sh"

    log_info "Installing network remediation: $reason"

    # Write the remediation script
    cat > "$script_dest" <<'REMEDIATION_SCRIPT'
#!/bin/bash
# =============================================================================
# Equitrac Network Remediation - Security Enrollment Retry
# =============================================================================
# Designed and engineered by:
#   Lance van der Molen
#   iStore Business - Apple Platform Managed Services
#
# Triggered by: LaunchDaemon on network change + 5-min safety interval
#
# If the Mac wasn't on NEDCORP when Intune installed Equitrac, security
# enrollment would have failed. This daemon watches for network changes,
# checks NEDCORP reachability, retries enrollment, then self-removes.
# =============================================================================
set -uo pipefail

PLIST_BUNDLE_ID="com.istorebusiness.equitrac"
PLIST_PATH="/Library/Managed Preferences/${PLIST_BUNDLE_ID}.plist"

SECURITY_DOMAIN=$(defaults read "${PLIST_PATH}" SECURITY_DOMAIN 2>/dev/null)
SECURITY_USERNAME=$(defaults read "${PLIST_PATH}" SECURITY_USERNAME 2>/dev/null)
SECURITY_PASSWORD=$(defaults read "${PLIST_PATH}" SECURITY_PASSWORD 2>/dev/null)
SECURITY_NODE=$(defaults read "${PLIST_PATH}" SECURITY_NODE 2>/dev/null)
DATACENTER_NAME=$(defaults read "${PLIST_PATH}" DATACENTER_NAME 2>/dev/null)
CAS_SERVER=$(defaults read "${PLIST_PATH}" CAS_SERVER 2>/dev/null)
DRE_SERVER=$(defaults read "${PLIST_PATH}" DRE_SERVER 2>/dev/null)

EQ_BASE="/Library/Application Support/Equitrac"
SECURITY_SCRIPT="$EQ_BASE/security/NDI.SecurityConfig.sh"
MARKER_FILE="$EQ_BASE/.security_enrolled"
DAEMON_LABEL="com.istorebusiness.equitrac.network-remediation"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
SCRIPT_PATH="$EQ_BASE/equitrac_network_remediation.sh"
LOG="/var/log/equitrac_remediation.log"
MAX_AGE_DAYS=7

log_info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

self_remove() {
    log_info "Self-removing: $1"
    launchctl bootout system/"$DAEMON_LABEL" 2>/dev/null \
        || launchctl remove "$DAEMON_LABEL" 2>/dev/null
    rm -f "$DAEMON_PLIST" "$SCRIPT_PATH" "$EQ_BASE/.remediation_attempts"
    log_info "Remediation files cleaned up."
}

check_max_age() {
    [[ ! -f "$DAEMON_PLIST" ]] && return 0
    local plist_epoch now age_days
    plist_epoch=$(stat -f %m "$DAEMON_PLIST" 2>/dev/null || echo 0)
    now=$(date +%s)
    age_days=$(( (now - plist_epoch) / 86400 ))
    if [[ $age_days -ge $MAX_AGE_DAYS ]]; then
        log_error "Daemon is $age_days days old (limit $MAX_AGE_DAYS). Giving up."
        self_remove "max age exceeded -- manual enrollment required"
        exit 0
    fi
}

check_nedcorp_reachable() {
    # macOS ping -W is in MILLISECONDS (not seconds like Linux)
    /sbin/ping -c 1 -W 2000 "$CAS_SERVER" >/dev/null 2>&1 && return 0
    /sbin/ping -c 1 -W 2000 "$DRE_SERVER" >/dev/null 2>&1 && return 0
    return 1
}

run_enrollment() {
    if [[ ! -f "$SECURITY_SCRIPT" ]]; then
        log_error "Security script missing: $SECURITY_SCRIPT"
        self_remove "no security script -- cannot remediate"
        exit 1
    fi
    chmod +x "$SECURITY_SCRIPT"
    log_info "Attempting security enrollment..."
    if "$SECURITY_SCRIPT" enroll \
        "${SECURITY_DOMAIN}\\${SECURITY_USERNAME}" \
        "$SECURITY_PASSWORD" \
        "$SECURITY_NODE" \
        "$DATACENTER_NAME" \
        "everyone" \
        "enroll_drc"; then
        log_info "Security enrollment SUCCEEDED"
        touch "$MARKER_FILE"
        return 0
    else
        log_error "Enrollment failed (will retry on next network change)"
        return 1
    fi
}

main() {
    # Let network settle after change event (DHCP/DNS may lag)
    sleep 10

    # Already done?
    if [[ -f "$MARKER_FILE" ]]; then
        self_remove "enrollment already completed"
        exit 0
    fi

    check_max_age

    # Not on NEDCORP? Exit silently. Reduce log noise: only log every 10th attempt.
    if ! check_nedcorp_reachable; then
        local attempt_file="$EQ_BASE/.remediation_attempts"
        local count=0
        [[ -f "$attempt_file" ]] && count=$(cat "$attempt_file" 2>/dev/null || echo 0)
        count=$((count + 1))
        echo "$count" > "$attempt_file"
        (( count % 10 == 1 )) && log_info "Network unreachable (attempt $count). Waiting..."
        exit 0
    fi

    # Network is up -- try enrollment
    if run_enrollment; then
        self_remove "enrollment succeeded"
    fi
}

main "$@"
REMEDIATION_SCRIPT

    chmod 700 "$script_dest"
    chown root:wheel "$script_dest"

    # Write the LaunchDaemon plist
    cat > "$daemon_plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${daemon_label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${script_dest}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>WatchPaths</key>
    <array>
        <string>/Library/Preferences/SystemConfiguration</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>StandardOutPath</key>
    <string>/var/log/equitrac_remediation.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/equitrac_remediation.log</string>
    <key>ThrottleInterval</key>
    <integer>30</integer>
</dict>
</plist>
PLIST_EOF

    chown root:wheel "$daemon_plist"
    chmod 644 "$daemon_plist"

    # Load the daemon immediately
    if launchctl bootstrap system "$daemon_plist" 2>/dev/null; then
        log_info "Network remediation daemon loaded (bootstrap)"
    elif launchctl load "$daemon_plist" 2>/dev/null; then
        log_info "Network remediation daemon loaded (legacy)"
    else
        log_warn "Could not load remediation daemon -- it will start at next boot"
    fi

    log_info "Remediation installed. Will retry enrollment on every network change."
    log_info "Auto-expires after $MAX_AGE_DAYS days. Log: /var/log/equitrac_remediation.log"
}

# ---------------------------------------------------------------------------
# INNER PKG INSTALL (with DRC enabled via choices XML)
# ---------------------------------------------------------------------------
install_inner_packages() {
    log_info "Installing inner Equitrac package..."

    if [[ ! -f "$INSTALLER_PKG" ]]; then
        log_error "Inner installer not found: $INSTALLER_PKG"
        return 1
    fi

    if [[ "$INSTALL_DRC" == true ]]; then
        # The inner PKG has DRC off by default (start_selected="false").
        # The install guide says to click Customize and enable DRC.
        # For silent install, we use a choices XML to force both components on.
        local choices_xml="/tmp/equitrac_choices.xml"

        cat > "$choices_xml" <<'CHOICESEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>choiceIdentifier</key>
    <string>com.equitrac.macclient</string>
    <key>choiceAttribute</key>
    <string>selected</string>
    <key>attributeSetting</key>
    <integer>1</integer>
  </dict>
  <dict>
    <key>choiceIdentifier</key>
    <string>com.equitrac.drc</string>
    <key>choiceAttribute</key>
    <string>enabled</string>
    <key>attributeSetting</key>
    <integer>1</integer>
  </dict>
  <dict>
    <key>choiceIdentifier</key>
    <string>com.equitrac.drc</string>
    <key>choiceAttribute</key>
    <string>selected</string>
    <key>attributeSetting</key>
    <integer>1</integer>
  </dict>
</array>
</plist>
CHOICESEOF

        log_info "Installing with DRC enabled (choices XML)..."
        if installer -applyChoiceChangesXML "$choices_xml" \
                      -pkg "$INSTALLER_PKG" \
                      -target / 2>>"$LOG"; then
            log_info "Inner package installed (Print Client + DRC)"
        else
            log_error "Inner package installation failed"
            rm -f "$choices_xml"
            return 1
        fi
        rm -f "$choices_xml"
    else
        # Default install -- Print Client only, no DRC
        if installer -pkg "$INSTALLER_PKG" -target /; then
            log_info "Inner package installed (Print Client only)"
        else
            log_error "Inner package installation failed"
            return 1
        fi
    fi

    # Install print drivers declared in the config profile (PRINT_DRIVERS key).
    # All pkgs are installed in order before any printer queues are created.
    # A missing pkg file is a fatal error -- the driver list in the profile
    # must match what is actually staged on disk.
    for pkg in "${PRINT_DRIVERS[@]}"; do
        if [[ ! -f "$pkg" ]]; then
            log_error "FATAL: Driver pkg not found: $pkg"
            log_error "Ensure all PRINT_DRIVERS paths are present in the staging directory."
            exit 1
        fi
        log_info "Installing driver pkg: $pkg"
        installer -pkg "$pkg" -target / 2>>"$LOG" || {
            log_error "FATAL: Driver installation failed: $pkg"
            return 1
        }
        log_info "Driver pkg installed: $pkg"
    done


    # The inner PKG postinstall does:
    #   1. Restarts CUPS (kill -HUP cupsd) to register eqtrans backend
    #   2. Loads com.equitrac.sharedengine LaunchDaemon
    #   3. Loads com.equitrac.logincontroller LaunchAgent for logged-in users
    #   4. (DRC) Restarts CUPS again for eqpmon backend
    #   5. (DRC) Loads com.equitrac.drc LaunchDaemon

    sleep 3

    # Verify services
    if launchctl list 2>/dev/null | grep -q "equitrac.sharedengine"; then
        log_info "EQSharedEngine service running"
    else
        log_warn "EQSharedEngine may not be running yet"
    fi

    if [[ "$INSTALL_DRC" == true ]]; then
        if launchctl list 2>/dev/null | grep -q "equitrac.drc"; then
            log_info "DRC service running"
        else
            log_warn "DRC service may not be running yet"
        fi
    fi

    # Verify CUPS backends installed on disk
    if [[ -x "/usr/libexec/cups/backend/eqtrans" ]]; then
        log_info "CUPS backend eqtrans binary installed"
    else
        log_warn "eqtrans backend binary not found"
    fi

    if [[ "$INSTALL_DRC" == true ]] && [[ -x "/usr/libexec/cups/backend/eqpmon" ]]; then
        log_info "CUPS backend eqpmon binary installed"
    fi
}

# ---------------------------------------------------------------------------
# CUPS BACKEND VERIFICATION
# Ensures CUPS has registered eqtrans before we try to create printers.
# Without this, lpadmin will reject the eqtrans:// URI and printers
# won't be created at all.
# ---------------------------------------------------------------------------
verify_cups_backend() {
    log_info "Verifying CUPS has registered eqtrans backend..."

    local retries=0
    local max_retries=3

    while [[ $retries -lt $max_retries ]]; do
        if lpinfo -v 2>/dev/null | grep -q "eqtrans"; then
            log_info "CUPS backend eqtrans is registered"
            return 0
        fi

        retries=$((retries + 1))
        log_warn "eqtrans not yet registered with CUPS (attempt $retries/$max_retries)"

        # Force CUPS restart to pick up new backend
        if command -v launchctl &>/dev/null; then
            launchctl kickstart -k system/org.cups.cupsd 2>>"$LOG" \
                || killall cupsd 2>/dev/null \
                || true
        else
            killall -HUP cupsd 2>/dev/null || true
        fi

        sleep 5
    done

    # Final check -- if still not registered, warn but continue
    # lpadmin may still work if the binary exists on disk
    if [[ -x "/usr/libexec/cups/backend/eqtrans" ]]; then
        log_warn "eqtrans not in lpinfo but binary exists. Proceeding anyway."
        return 0
    else
        log_error "eqtrans backend not found anywhere. Printer creation will fail."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# EQPRINTERUTILITYX INSTALL
# ---------------------------------------------------------------------------
install_printer_utility() {
    log_info "Installing EQPrinterUtilityX to /Applications/Utilities/..."

    local src="${PAYLOAD_DIR}/EQPrinterUtilityX.app"
    local dst="/Applications/Utilities/EQPrinterUtilityX.app"

    if [[ ! -d "$src" ]]; then
        log_error "EQPrinterUtilityX.app not found in staging"
        return 1
    fi

    # Remove existing if present (upgrade)
    [[ -d "$dst" ]] && rm -rf "$dst"

    ditto "$src" "$dst"
    chown -R root:admin "$dst"
    chmod -R 755 "$dst"
    open "$dst"

    log_info "EQPrinterUtilityX installed (bundle: com.equitrac.printerutility v6.4.3.59)"
}


# ---------------------------------------------------------------------------
# PRINTER CREATION
#
# The inner PKG installs CUPS backend "eqtrans" at:
#   /usr/libexec/cups/backend/eqtrans
#
# Printer URI format: eqtrans://DRE_SERVER/PRINTER_NAME
# ---------------------------------------------------------------------------

# install_custom_ppds
# For every printer entry in the config whose ppd value is NOT "generic",
# copy the source file into /Library/Printers/PPDs/Contents/Resources/
# with a sanitised filename derived from the printer name.
install_custom_ppds() {
    log_info "Installing custom PPDs from printer config..."

    local ppd_dir="/Library/Printers/PPDs/Contents/Resources"
    mkdir -p "$ppd_dir"

    local i
    for (( i = 0; i < ${#PRINTER_NAMES[@]}; i++ )); do
        local name="${PRINTER_NAMES[$i]}"
        local ppd_src="${PRINTER_PPDS[$i]}"

        [[ "$ppd_src" == "generic" ]] && continue

        if [[ ! -f "$ppd_src" ]]; then
            log_warn "PPD source not found for '$name': $ppd_src"
            continue
        fi

        # Destination filename: <PrinterName>.ppd
        local ppd_dest="${ppd_dir}/${name}.ppd"
        cp "$ppd_src" "$ppd_dest"
        chown root:admin "$ppd_dest"
        chmod 644 "$ppd_dest"
        log_info "Installed PPD for '$name': $ppd_dest"
    done
}

# ---------------------------------------------------------------------------
# EQPRINTERUTILITYX PREFERENCES
# ---------------------------------------------------------------------------
# Writes the computed Feature Selection bitmask and any additional boolean
# prefs to the EQPrinterUtilityX preferences plist.
#
# The plist is written system-wide so it applies regardless of which user
# launches EQPrinterUtilityX.
# ---------------------------------------------------------------------------
configure_printer_utility_prefs() {
    log_info "Configuring EQPrinterUtilityX preferences..."

    local plist="/Library/Preferences/com.equitrac.printerutility.plist"

    # Write the Feature Selection value (bitmask sum computed from config profile)
    defaults write "$plist" FeatureSelection -int "$FEATURE_SELECTION"

    # Write individual boolean prefs so EQPrinterUtilityX picks them up directly
    # as well. This mirrors what the Settings dialog writes when toggled manually.
    # Key names confirmed via: defaults read /Library/Preferences/com.equitrac.printerutility
    defaults write "$plist" ClientBilling    -bool "$PREF_CLIENT_BILLING"
    defaults write "$plist" PromptForLogin   -bool "$PREF_PROMPT_FOR_LOGIN"
    defaults write "$plist" CostPreview      -bool "$PREF_COST_PREVIEW"
    defaults write "$plist" AllowRenameDocument -bool "$PREF_ALLOW_RENAME_DOCUMENT"
    defaults write "$plist" ReleaseKey       -bool "$PREF_RELEASE_KEY"

    # Ensure system-wide readability
    chown root:admin "$plist" 2>/dev/null || true
    chmod 644 "$plist"

    log_info "EQPrinterUtilityX prefs written (FeatureSelection=$FEATURE_SELECTION)"
    log_info "  ClientBilling=$PREF_CLIENT_BILLING  PromptForLogin=$PREF_PROMPT_FOR_LOGIN"
    log_info "  CostPreview=$PREF_COST_PREVIEW  AllowRenameDocument=$PREF_ALLOW_RENAME_DOCUMENT  ReleaseKey=$PREF_RELEASE_KEY"
}

create_printers() {
    log_info "Creating Equitrac printers..."

    if [[ ${#PRINTER_NAMES[@]} -eq 0 ]]; then
        log_warn "No printers defined in config -- skipping printer creation"
        return 0
    fi

    # Determine which CUPS backend to use
    local backend="eqtrans"
    if [[ ! -x "/usr/libexec/cups/backend/eqtrans" ]]; then
        log_warn "eqtrans backend not found -- trying lpd:// fallback"
        backend="lpd"
    fi

    # Resolve generic PPD once (shared by all printers that request it)
    local generic_ppd=""
    for ppd_candidate in \
        "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/PrintCore.framework/Versions/A/Resources/Generic.ppd" \
        "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/PrintCore.framework/Versions/A/Resources/AirPrint.ppd" \
        "/usr/share/cups/model/Generic-PostScript_Printer-Postscript.ppd" \
        "/Library/Printers/PPDs/Contents/Resources/HP LaserJet Series PCL 4_5.gz"; do
        if [[ -f "$ppd_candidate" ]]; then
            generic_ppd="$ppd_candidate"
            log_info "Using generic PPD: $generic_ppd"
            break
        fi
    done

    local ppd_install_dir="/Library/Printers/PPDs/Contents/Resources"

    local i
    for (( i = 0; i < ${#PRINTER_NAMES[@]}; i++ )); do
        local printer_name="${PRINTER_NAMES[$i]}"
        local ppd_config="${PRINTER_PPDS[$i]}"
        local printer_type="${PRINTER_TYPES[$i]}"
        local device_uri=""

        if [[ "$printer_type" == "ip" ]]; then
            local pip="${PRINTER_IPS[$i]}"
            local pproto="${PRINTER_PROTOCOLS[$i]}"
            if [[ "$pproto" == "lpr" ]]; then
                local pqueue="${PRINTER_QUEUES[$i]}"
                device_uri="lpd://${pip}/${pqueue}"
            else
                local pport="${PRINTER_PORTS[$i]:-9100}"
                device_uri="socket://${pip}:${pport}"
            fi
        else
            # DRE printer -- use eqtrans backend (or lpd fallback)
            device_uri="${backend}://${DRE_SERVER}/${printer_name}"
        fi

        local ppd_path=""

        if [[ "$ppd_config" == "generic" ]]; then
            if [[ -n "$generic_ppd" ]]; then
                ppd_path="$generic_ppd"
            else
                log_warn "No generic PPD available for '$printer_name' -- skipping"
                continue
            fi
        else
            # Custom PPD was installed by install_custom_ppds(); reference it by name
            local custom_ppd="${ppd_install_dir}/${printer_name}.ppd"
            if [[ -f "$custom_ppd" ]]; then
                ppd_path="$custom_ppd"
            else
                log_warn "Custom PPD not found for '$printer_name' ($custom_ppd) -- falling back to generic"
                ppd_path="$generic_ppd"
            fi
        fi

        if [[ -z "$ppd_path" ]]; then
            log_warn "No PPD available for '$printer_name' -- skipping"
            continue
        fi

        log_info "Adding printer: $printer_name -> $device_uri  [PPD: $ppd_path]"

        # Step 1: Create the queue
        #   -o printer-error-policy=retry-job  CRITICAL: without this, if DRE is
        #      unreachable at install time, CUPS sets state=stopped. The printer
        #      then appears in System Settings but is MISSING from app print dialogs.
        lpadmin \
            -p "$printer_name" \
            -D "$printer_name" \
            -L "Equitrac Follow-You Printing" \
            -v "$device_uri" \
            -P "$ppd_path" \
            -o printer-is-shared=false \
            -o printer-error-policy=retry-job 2>>"$LOG" || {
                log_warn "lpadmin failed for $printer_name"
                continue
            }

        # Step 2: Explicitly enable and accept
        # The -E flag on lpadmin is supposed to do this, but with custom
        # backends (eqtrans) it's unreliable.
        /usr/sbin/cupsenable "$printer_name" 2>>"$LOG" || {
            log_warn "cupsenable failed for $printer_name"
        }
        /usr/sbin/cupsaccept "$printer_name" 2>>"$LOG" || {
            log_warn "cupsaccept failed for $printer_name"
        }

        # Step 3: Set printer options
        lpadmin -p "$printer_name" \
            -o Duplex=DuplexNoTumble \
            -o sides=two-sided-long-edge 2>>"$LOG" || true

        log_info "Printer $printer_name created and enabled"
    done

    # Step 4: Restart CUPS to flush printers.conf and ensure all queues are live
    log_info "Restarting CUPS to finalize printer registration..."
    if command -v launchctl &>/dev/null; then
        launchctl kickstart -k system/org.cups.cupsd 2>>"$LOG" \
            || killall cupsd 2>/dev/null \
            || true
    fi
    sleep 2

    # Verify printer states
    log_info "Final printer state:"
    lpstat -p 2>>"$LOG" | tee -a "$LOG" || true

    log_info "Printer creation complete"
}

# ---------------------------------------------------------------------------
# CLEANUP
# ---------------------------------------------------------------------------
cleanup_staging() {
    log_info "Cleaning up staging directory..."
    rm -rf "$PAYLOAD_DIR"
    rm -f /tmp/equitrac_choices.xml
    log_info "Staging directory removed"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
main() {
    log_info "========================================="
    log_info "Equitrac silent install starting"
    log_info "========================================="

    check_root
    check_macos_version

    # Phase 1: Pre-configuration
    create_directories
    validate_pkg_filename "$INSTALLER_PKG_NAME" "INSTALLER_PKG"
    load_printer_config
    compute_feature_selection
    create_config_files
    copy_support_files

    # Phase 3: Security enrollment
    register_security_framework

    # Phase 4: Install inner Equitrac PKG (Print Client + DRC)
    # This is the critical step. If it fails, everything else is pointless.
    if ! install_inner_packages; then
        log_error "FATAL: Inner package installation failed. Aborting."
        exit 1
    fi

    # Phase 5: Install EQPrinterUtilityX
    install_printer_utility

    # Phase 6: Verify CUPS knows about eqtrans backend (non-fatal; printer creation has lpd fallback)
    verify_cups_backend || log_warn "CUPS backend verification failed -- printer creation will attempt lpd:// fallback"

    # Phase 7: Configure (replaces osascript GUI automation)
    install_custom_ppds
    configure_printer_utility_prefs
    create_printers

    # Phase 8: Cleanup
    cleanup_staging


    log_info "========================================="
    log_info "Equitrac installation complete"
    log_info "Log: /var/log/equitrac_install.log"
    log_info "Equitrac logs: /Library/Application Support/Kofax/ControlSuite/Logs/Equitrac/"
    log_info "========================================="
    exit 0
}

main "$@"

# =============================================================================
# POST-DEPLOYMENT NOTES
# =============================================================================
#
# VERIFY ON TEST MAC:
#   pkgutil --pkgs | grep -i equitrac
#   lpstat -p -d
#   launchctl list | grep -i equitrac
#   ls -la /usr/libexec/cups/backend/eq*
#   cat /var/log/equitrac_install.log
#   defaults read /Library/Preferences/com.equitrac.printerutility
#   cat "/Library/Application Support/Equitrac/EquitracOfficePrefs"
#   cat "/Library/Application Support/Equitrac/DRE/EQDRECAS.cfg"
#
# EQLOGINCONTROLLER:
#   The inner PKG installs a LaunchAgent (com.equitrac.logincontroller.plist)
#   that loads EQLoginController.app per user at login. This is handled by
#   the inner PKG's own postinstall script -- no action needed here.
#   Location: /Library/Application Support/Equitrac/EQLoginController.app
#
# PLIST KEY VERIFICATION:
#   The exact keys for CASServer/ClientBilling/PromptForLogin must be
#   confirmed. On a test Mac, toggle the settings in EQPrinterUtilityX
#   Settings dialog, then run:
#     defaults read /Library/Preferences/com.equitrac.printerutility
#     defaults read ~/Library/Preferences/com.equitrac.printerutility
#   Update the configure_printer_utility_prefs() function if keys differ.
#
# HP COLOUR PRINTER DRIVER:
#   The client install guide references hp-printer-essentials-UniPS-6_3_0_1.pkg
#   from smb://10.59.103.83/slvc/software_Library/Apple_Software/Printers
#   If the bundled HP-Colour-Mac PPD file is not sufficient (i.e., printer
#   features are missing), deploy the HP driver package as a separate Intune
#   PKG app with a dependency/supersedence on the Equitrac app.
#
# NETWORK REQUIREMENTS:
#   - Macs must be on NEDCORP network (or VPN)
#   - CAS server (10.59.21.135) must be reachable
#   - DRE server (105eqtpr01.africa.nedcor.net) must be reachable
#   - Users must be in Printer Exclusion Payload group (Hein Gerber manages)
#
# UNINSTALL:
#   sudo "/Library/Application Support/Equitrac/Uninstall/EQUninstall.sh"
#   Or deploy as an Intune uninstall script.
#
# =============================================================================