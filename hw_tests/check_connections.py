#!/usr/bin/env python3
"""
Pre-Lab Connection Check
Verifies ChipWhisperer and PYNQ Z2 are both connected before starting.

Usage:
    python3 check_connections.py           # Normal check
    python3 check_connections.py --fix     # Try to fix USB permissions
"""

import subprocess
import sys
import socket
import os
import glob

PYNQ_IP = "192.168.2.99"
PYNQ_SSH_PORT = 22

def check_pynq_connection():
    """Check if PYNQ Z2 board is reachable via network."""
    print("[1] Checking PYNQ Z2 connection...")
    
    # First try ping
    try:
        result = subprocess.run(
            ["ping", "-c", "2", "-W", "2", PYNQ_IP],
            capture_output=True,
            text=True,
            timeout=10
        )
        if result.returncode == 0:
            print(f"    ✅ PYNQ Z2 at {PYNQ_IP} is responding to ping")
            
            # Also check if SSH port is open (common for PYNQ)
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(3)
                result = sock.connect_ex((PYNQ_IP, PYNQ_SSH_PORT))
                sock.close()
                if result == 0:
                    print(f"    ✅ SSH port {PYNQ_SSH_PORT} is open")
                else:
                    print(f"    ⚠️  SSH port {PYNQ_SSH_PORT} not responding (may still work)")
            except Exception:
                pass
            
            return True
        else:
            print(f"    ❌ PYNQ Z2 at {PYNQ_IP} is not responding")
            print(f"       - Check network cable connection")
            print(f"       - Ensure PYNQ Z2 is powered on (blue LED)")
            print(f"       - Verify IP configuration")
            return False
    except subprocess.TimeoutExpired:
        print(f"    ❌ Ping to {PYNQ_IP} timed out")
        return False
    except Exception as e:
        print(f"    ❌ Error checking PYNQ: {e}")
        return False


def fix_usb_permissions():
    """Fix USB permissions for ChipWhisperer."""
    print("    Attempting to fix USB permissions...")
    try:
        # Fix all USB bus devices
        for bus_dir in glob.glob("/dev/bus/usb/*"):
            subprocess.run(["sudo", "chmod", "666"] + glob.glob(f"{bus_dir}/*"), 
                          capture_output=True)
        # Fix serial device
        subprocess.run(["sudo", "chmod", "666", "/dev/ttyACM0"], capture_output=True)
        print("    ✅ USB permissions fixed")
        return True
    except Exception as e:
        print(f"    ❌ Could not fix permissions: {e}")
        return False


def check_chipwhisperer_connection(auto_fix=False):
    """Check if ChipWhisperer is connected via USB."""
    print("\n[2] Checking ChipWhisperer connection...")
    
    # Check USB device presence
    try:
        result = subprocess.run(
            ["lsusb", "-d", "2b3e:ace2"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if "2b3e:ace2" in result.stdout:
            print("    ✅ ChipWhisperer USB device detected")
        else:
            print("    ❌ ChipWhisperer USB device NOT found")
            print("       - Check USB cable connection")
            print("       - Try a different USB port")
            return False
    except Exception as e:
        print(f"    ⚠️  Could not check USB devices: {e}")
    
    # Check serial device
    try:
        result = subprocess.run(
            ["ls", "/dev/ttyACM0"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            print("    ✅ Serial device /dev/ttyACM0 exists")
        else:
            print("    ⚠️  /dev/ttyACM0 not found")
    except Exception:
        pass
    
    # Try to actually connect
    try:
        import chipwhisperer as cw
        print(f"    ChipWhisperer library version: {cw.__version__}")
        
        print("    Attempting to connect to ChipWhisperer...")
        scope = cw.scope()
        print(f"    ✅ ChipWhisperer connected!")
        print(f"       Serial: {scope.sn}")
        scope.dis()
        return True
        
    except ImportError:
        print("    ❌ ChipWhisperer library not installed")
        return False
    except Exception as e:
        if "permission" in str(e).lower() or "communicate" in str(e).lower():
            if auto_fix:
                print(f"    ⚠️  Permission issue detected, attempting fix...")
                if fix_usb_permissions():
                    # Try again after fixing
                    try:
                        import time
                        time.sleep(1)
                        scope = cw.scope()
                        print(f"    ✅ ChipWhisperer connected after fix!")
                        print(f"       Serial: {scope.sn}")
                        scope.dis()
                        return True
                    except Exception as e2:
                        print(f"    ❌ Still failed after fix: {e2}")
            else:
                print(f"    ❌ ChipWhisperer connection failed: {e}")
                print("       💡 Try running with --fix flag: python3 check_connections.py --fix")
        else:
            print(f"    ❌ ChipWhisperer connection failed: {e}")
        print("       - Try unplugging and replugging the USB cable")
        print("       - Wait 10 seconds and try again")
        return False


def main():
    print("=" * 55)
    print("       PRE-LAB CONNECTION CHECK")
    print("=" * 55)
    print()
    
    auto_fix = "--fix" in sys.argv
    if auto_fix:
        print("  [Running in auto-fix mode]\n")
    
    pynq_ok = check_pynq_connection()
    cw_ok = check_chipwhisperer_connection(auto_fix=auto_fix)
    
    print()
    print("=" * 55)
    print("                 SUMMARY")
    print("=" * 55)
    
    if pynq_ok and cw_ok:
        print("\n  ✅ ALL SYSTEMS GO! Both devices are connected.\n")
        print("  You can now start your lab.\n")
        return 0
    else:
        print("\n  ❌ CONNECTION ISSUES DETECTED:\n")
        if not pynq_ok:
            print(f"     • PYNQ Z2 ({PYNQ_IP}): NOT CONNECTED")
        if not cw_ok:
            print("     • ChipWhisperer: NOT CONNECTED")
        print("\n  Please fix the issues above before starting the lab.\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
