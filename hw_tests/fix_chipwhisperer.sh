#!/bin/bash
#
# ChipWhisperer Connection Fix Script
# Run this script whenever ChipWhisperer connection issues are detected
#

set -e

echo "======================================================="
echo "       CHIPWHISPERER AUTO-FIX SCRIPT"
echo "======================================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

success() { echo -e "${GREEN}✅ $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }
info() { echo -e "${YELLOW}➜ $1${NC}"; }

# Setup and activate the hw-lab virtual environment
VENV_PATH="$HOME/hw-lab"
echo "[0] Setting up hw-lab virtual environment..."
if [ -d "$VENV_PATH" ]; then
    info "hw-lab virtual environment found"
else
    info "Creating hw-lab virtual environment..."
    python3 -m venv "$VENV_PATH"
    success "Virtual environment created at $VENV_PATH"
fi

info "Activating hw-lab virtual environment..."
source "$VENV_PATH/bin/activate"
success "Virtual environment activated"

# Check and install ChipWhisperer library
echo ""
echo "[1] Checking ChipWhisperer library..."
if python3 -c "import chipwhisperer" 2>/dev/null; then
    success "ChipWhisperer library already installed"
else
    info "Installing ChipWhisperer library (this may take a few minutes)..."
    pip install --upgrade pip > /dev/null 2>&1
    pip install chipwhisperer
    if python3 -c "import chipwhisperer" 2>/dev/null; then
        success "ChipWhisperer library installed successfully"
    else
        error "Failed to install ChipWhisperer library"
        exit 1
    fi
fi

# Step 2: Check if ChipWhisperer USB is connected
echo ""
echo "[2] Checking ChipWhisperer USB device..."
if lsusb -d 2b3e:ace2 > /dev/null 2>&1; then
    success "ChipWhisperer USB device detected"
else
    error "ChipWhisperer USB device NOT found"
    echo "    - Connect the ChipWhisperer via USB"
    echo "    - Try a different USB port"
    exit 1
fi

# Step 3: Fix USB permissions
echo ""
echo "[3] Fixing USB permissions..."
if [ -e /dev/ttyACM0 ]; then
    sudo chmod 666 /dev/ttyACM0
    success "Serial device /dev/ttyACM0 permissions fixed"
else
    info "/dev/ttyACM0 not found, checking for other ACM devices..."
    for dev in /dev/ttyACM*; do
        if [ -e "$dev" ]; then
            sudo chmod 666 "$dev"
            success "Fixed permissions for $dev"
        fi
    done
fi

# Fix USB bus permissions for ChipWhisperer
info "Fixing USB bus permissions..."
for bus in /dev/bus/usb/*/; do
    sudo chmod -R 666 "$bus"* 2>/dev/null || true
done
success "USB bus permissions fixed"

# Step 4: Add user to dialout group (for serial access without sudo)
echo ""
echo "[4] Checking user groups..."
if groups | grep -q dialout; then
    success "User already in dialout group"
else
    info "Adding user to dialout group..."
    sudo usermod -a -G dialout "$USER"
    success "User added to dialout group (re-login required for permanent effect)"
fi

# Step 5: Setup udev rules for persistent permissions
echo ""
echo "[5] Setting up udev rules..."
UDEV_RULE='SUBSYSTEM=="usb", ATTRS{idVendor}=="2b3e", ATTRS{idProduct}=="ace2", MODE="0666"'
UDEV_FILE="/etc/udev/rules.d/99-chipwhisperer.rules"

if [ -f "$UDEV_FILE" ]; then
    success "udev rules already exist"
else
    info "Creating udev rules for ChipWhisperer..."
    echo "$UDEV_RULE" | sudo tee "$UDEV_FILE" > /dev/null
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    success "udev rules created (permissions will persist after reboot)"
fi

# Step 6: Test connection
echo ""
echo "[6] Testing ChipWhisperer connection..."
python3 -c "
import chipwhisperer as cw
try:
    scope = cw.scope()
    print(f'    ✅ ChipWhisperer connected! Serial: {scope.sn}')
    scope.dis()
except Exception as e:
    print(f'    ❌ Connection test failed: {e}')
    exit(1)
"

echo ""
echo "======================================================="
echo "       FIX COMPLETE"
echo "======================================================="
echo ""
success "ChipWhisperer is ready to use!"
echo ""
