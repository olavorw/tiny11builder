#!/bin/bash

set -e

# arch btw, CLI because if you're using arch, do you really need a gui??

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check for required packages
check_dependencies() {
    local missing=()
    for pkg in wimlib chntpw xorriso; do
        if ! command -v ${pkg%lib} &> /dev/null && \
           ! pacman -Q $pkg &> /dev/null; then
            missing+=($pkg)
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        print_error "Missing packages: ${missing[*]}"
        print_info "Install with: sudo pacman -S ${missing[*]}"
        exit 1
    fi
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_error "Don't run as root. Script will use sudo when needed."
    exit 1
fi

# Parse arguments
ISO_FILE=""
SCRATCH_DIR="${PWD}/tiny11_work"

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--iso)
            ISO_FILE="$2"
            shift 2
            ;;
        -s|--scratch)
            SCRATCH_DIR="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 -i <iso_file> [-s <scratch_dir>]"
            echo "  -i, --iso        Windows 11 ISO file"
            echo "  -s, --scratch    Working directory (default: ./tiny11_work)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ -z "$ISO_FILE" ]; then
    print_error "ISO file not specified. Use -i <iso_file>"
    exit 1
fi

if [ ! -f "$ISO_FILE" ]; then
    print_error "ISO file not found: $ISO_FILE"
    exit 1
fi

check_dependencies

# Setup directories
ISO_MOUNT="${SCRATCH_DIR}/iso_mount"
WIM_MOUNT="${SCRATCH_DIR}/wim_mount"
TINY11_DIR="${SCRATCH_DIR}/tiny11"
OUTPUT_ISO="${PWD}/tiny11.iso"

mkdir -p "$ISO_MOUNT" "$WIM_MOUNT" "$TINY11_DIR"

# Mount ISO
print_info "Mounting ISO..."
sudo mount -o loop,ro "$ISO_FILE" "$ISO_MOUNT"
trap "sudo umount '$ISO_MOUNT' 2>/dev/null; sudo umount '$WIM_MOUNT' 2>/dev/null" EXIT

# Copy ISO contents
print_info "Copying ISO contents..."
rsync -a --info=progress2 "$ISO_MOUNT/" "$TINY11_DIR/"
chmod -R u+w "$TINY11_DIR"

# Convert install.esd to install.wim if needed
if [ -f "$TINY11_DIR/sources/install.esd" ] && \
   [ ! -f "$TINY11_DIR/sources/install.wim" ]; then
    print_info "Converting install.esd to install.wim..."
    wimlib-imagex info "$TINY11_DIR/sources/install.esd"
    read -p "Enter image index: " INDEX
    wimlib-imagex export "$TINY11_DIR/sources/install.esd" $INDEX \
        "$TINY11_DIR/sources/install.wim" --compress=LZX:100
    rm -f "$TINY11_DIR/sources/install.esd"
fi

# Get image info
print_info "Available images:"
wimlib-imagex info "$TINY11_DIR/sources/install.wim"

# Get valid index
while true; do
    read -p "Enter image index to customize: " INDEX
    if [[ "$INDEX" =~ ^[0-9]+$ ]]; then
        MAX_INDEX=$(wimlib-imagex info "$TINY11_DIR/sources/install.wim" | \
            grep -oP 'Image Count:\s+\K[0-9]+')
        if [ "$INDEX" -ge 1 ] && [ "$INDEX" -le "$MAX_INDEX" ]; then
            break
        else
            print_error "Index must be between 1 and $MAX_INDEX"
        fi
    else
        print_error "Please enter a valid number"
    fi
done

print_info "Using image index: $INDEX"

# Mount WIM image
print_info "Mounting Windows image..."
sudo wimlib-imagex mountrw "$TINY11_DIR/sources/install.wim" "$INDEX" "$WIM_MOUNT"

# Remove provisioned apps
print_info "Removing bloatware..."
APPS_TO_REMOVE=(
    "Microsoft.BingNews" "Microsoft.BingWeather" "Clipchamp.Clipchamp"
    "Microsoft.GamingApp" "Microsoft.GetHelp" "Microsoft.Getstarted"
    "Microsoft.MicrosoftOfficeHub" "Microsoft.MicrosoftSolitaireCollection"
    "Microsoft.People" "Microsoft.Windows.Photos" "Microsoft.WindowsAlarms"
    "Microsoft.WindowsCamera" "Microsoft.windowscommunicationsapps"
    "Microsoft.WindowsFeedbackHub" "Microsoft.WindowsMaps"
    "Microsoft.WindowsSoundRecorder" "Microsoft.Xbox" "Microsoft.ZuneMusic"
    "Microsoft.ZuneVideo" "Microsoft.YourPhone" "Microsoft.Copilot"
)

# Remove app packages
for app in "${APPS_TO_REMOVE[@]}"; do
    sudo find "$WIM_MOUNT/Program Files/WindowsApps" -iname "*${app}*" \
        -exec rm -rf {} + 2>/dev/null || true
done

# Remove Edge
print_info "Removing Edge..."
sudo rm -rf "$WIM_MOUNT/Program Files (x86)/Microsoft/Edge"* \
    "$WIM_MOUNT/Windows/System32/Microsoft-Edge-Webview" 2>/dev/null || true

# Remove OneDrive
print_info "Removing OneDrive..."
sudo rm -f "$WIM_MOUNT/Windows/System32/OneDriveSetup.exe" 2>/dev/null || true

# Download autounattend.xml
print_info "Downloading autounattend.xml..."
AUTOUNATTEND_DIR="$WIM_MOUNT/Windows/System32/Sysprep"
sudo mkdir -p "$AUTOUNATTEND_DIR"

if curl -fSL --connect-timeout 10 --max-time 30 \
    "https://raw.githubusercontent.com/ntdevlabs/tiny11builder/main/autounattend.xml" \
    -o "/tmp/autounattend.xml"; then
    sudo cp "/tmp/autounattend.xml" "$AUTOUNATTEND_DIR/autounattend.xml"
    rm -f "/tmp/autounattend.xml"
    print_info "autounattend.xml downloaded successfully"
else
    print_warn "Failed to download autounattend.xml, continuing without it..."
fi

# Registry modifications using chntpw
print_info "Modifying registry..."

# Create registry modification script
cat > /tmp/reg_mods.txt << 'EOF'
cd \Setup\LabConfig
nv 1 BypassTPMCheck
nv 1 BypassSecureBootCheck
nv 1 BypassRAMCheck
nv 1 BypassStorageCheck
nv 1 BypassCPUCheck
q
y
EOF

# Apply registry changes to SYSTEM hive
print_info "Applying registry tweaks to SYSTEM hive..."
if [ -f "$WIM_MOUNT/Windows/System32/config/SYSTEM" ]; then
    sudo chntpw -e "$WIM_MOUNT/Windows/System32/config/SYSTEM" \
        < /tmp/reg_mods.txt 2>&1 | grep -v "^chntpw" || true
else
    print_warn "SYSTEM hive not found, skipping registry mods"
fi

# Remove scheduled tasks
print_info "Removing telemetry tasks..."
sudo rm -rf \
    "$WIM_MOUNT/Windows/System32/Tasks/Microsoft/Windows/Customer Experience Improvement Program" \
    "$WIM_MOUNT/Windows/System32/Tasks/Microsoft/Windows/Application Experience" \
    2>/dev/null || true

# Unmount and commit changes
print_info "Committing changes to install.wim (this may take a while)..."
sudo wimlib-imagex unmount "$WIM_MOUNT" --commit

# Optimize WIM
print_info "Optimizing install.wim..."
wimlib-imagex optimize "$TINY11_DIR/sources/install.wim"

# Process boot.wim
print_info "Processing boot.wim..."
if [ -f "$TINY11_DIR/sources/boot.wim" ]; then
    sudo wimlib-imagex mountrw "$TINY11_DIR/sources/boot.wim" 2 "$WIM_MOUNT"
    
    # Apply same registry tweaks to boot.wim
    if [ -f "$WIM_MOUNT/Windows/System32/config/SYSTEM" ]; then
        sudo chntpw -e "$WIM_MOUNT/Windows/System32/config/SYSTEM" \
            < /tmp/reg_mods.txt 2>&1 | grep -v "^chntpw" || true
    fi
    
    sudo wimlib-imagex unmount "$WIM_MOUNT" --commit
else
    print_warn "boot.wim not found, skipping"
fi

# Copy autounattend to root
print_info "Copying autounattend.xml to ISO root..."
if [ -f "$AUTOUNATTEND_DIR/autounattend.xml" ]; then
    sudo cp "$AUTOUNATTEND_DIR/autounattend.xml" "$TINY11_DIR/autounattend.xml" 2>/dev/null || true
elif [ -f "/tmp/autounattend.xml" ]; then
    cp "/tmp/autounattend.xml" "$TINY11_DIR/autounattend.xml" 2>/dev/null || true
fi

# Verify boot files exist
print_info "Verifying boot files..."
if [ ! -f "$TINY11_DIR/boot/etfsboot.com" ]; then
    print_error "BIOS boot file not found: boot/etfsboot.com"
    exit 1
fi
if [ ! -f "$TINY11_DIR/efi/microsoft/boot/efisys.bin" ]; then
    print_error "EFI boot file not found: efi/microsoft/boot/efisys.bin"
    exit 1
fi

# Create ISO using xorriso
print_info "Creating bootable ISO (this may take a while)..."
cd "$TINY11_DIR"
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "TINY11" \
    -appid "TINY11" \
    -publisher "TINY11" \
    -preparer "prepared by xorriso" \
    -eltorito-boot boot/etfsboot.com \
    -no-emul-boot \
    -boot-load-size 8 \
    -eltorito-alt-boot \
    -e efi/microsoft/boot/efisys.bin \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output "$OUTPUT_ISO" \
    .

cd - > /dev/null

if [ ! -f "$OUTPUT_ISO" ] || [ ! -s "$OUTPUT_ISO" ]; then
    print_error "Failed to create ISO or ISO is empty"
    exit 1
fi

# Cleanup
print_info "Cleaning up..."
sudo umount "$ISO_MOUNT" 2>/dev/null || true
sudo umount "$WIM_MOUNT" 2>/dev/null || true
rm -rf "$SCRATCH_DIR"
rm -f /tmp/reg_mods.txt /tmp/autounattend.xml

print_info "✓ Tiny11 ISO created: $OUTPUT_ISO"
ls -lh "$OUTPUT_ISO"