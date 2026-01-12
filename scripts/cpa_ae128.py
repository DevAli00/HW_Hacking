import chipwhisperer as cw
import chipwhisperer.analyzer as cwa
import os
import time
from tqdm import tqdm  # Progress bar library

print("=== ATTACK 1: AES-128 CORRELATION POWER ANALYSIS ===")

# =========================================================
# STEP 1: CONNECT & SETUP HARDWARE
# =========================================================
print("\n[1/4] Connecting to Hardware...")
try:
    scope = cw.scope()            # Connect to the CW-Lite (Scope)
    target = cw.target(scope)     # Connect to the STM32 (Target)
    print(f"✅ Connected to {scope.sn}")
except Exception as e:
    print(f"❌ Connection Failed: {e}")
    print("Try unplugging/replugging the USB.")
    exit()

# Set standard clock/trigger settings
scope.default_setup()

# Compile & Flash the AES firmware to the STM32
# This ensures the chip is running the code we want to attack.
print("      Flashing 'simpleserial-aes' firmware...")
fw_path = '/home/pi/cw-firmware/firmware/mcu/simpleserial-aes/simpleserial-aes-CWLITEARM.hex'
cw.program_target(scope, cw.programmers.STM32FProgrammer, fw_path)

# =========================================================
# STEP 2: CAPTURE POWER TRACES
# =========================================================
# We need about 50 traces to break AES on this specific target.
NUM_TRACES = 50 
print(f"\n[2/4] Capturing {NUM_TRACES} Power Traces...")

# Create a project file to save our data
project = cw.create_project("lab_attack_1", overwrite=True)

# Key-Text-Pair generator: Gives us random inputs and keys
ktp = cw.ktp.Basic()

# The Capture Loop
for i in tqdm(range(NUM_TRACES)):
    # 1. Generate random key and plaintext
    key, text = ktp.next()
    
    # 2. Arm the scope (Tell it to wait for the trigger signal)
    scope.arm()
    
    # 3. Send the plaintext to the target chip
    target.simpleserial_write('p', text)
    
    # 4. Capture the power trace!
    ret = scope.capture()
    if ret:
        print("Timeout - capture failed.")
        continue
    
    # 5. Receive the encrypted response (optional, but good for verification)
    response = target.simpleserial_read('r', 16)
    
    # 6. Save everything to our project
    trace_data = scope.get_last_trace()
    project.traces.append(cw.Trace(trace_data, text, text, key))

print("✅ Capture Complete.")

# =========================================================
# STEP 3: RUN THE CPA ATTACK (THE MATH)
# =========================================================
print("\n[3/4] Running Correlation Analysis...")

# Define the Leakage Model
# We are telling the analyzer: "Look for power consumption that matches 
# the Hamming Weight of the S-Box Output."
leak_model = cwa.leakage_models.sbox_output

# Initialize the Attack
attack = cwa.cpa(project, leak_model)

# Run the statistical analysis
results = attack.run()

# =========================================================
# STEP 4: REPORT RESULTS
# =========================================================
print("\n[4/4] Recovered Key:")
print("---------------------------------------------------")

# The default key used by the firmware is usually:
# 2b 7e 15 16 28 ae d2 a6 ab f7 15 88 09 cf 4f 3c

known_key = [0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c]
recovered_key = []

for b in range(16):
    # 'results.find_maximums()' returns a list of best guesses for all bytes
    # We access byte 'b' and take the top guess [0][0]
    best_guess = results.find_maximums()[b][0][0]
    recovered_key.append(best_guess)
    
    # Visual check
    status = "✅" if best_guess == known_key[b] else "❌"
    print(f"Byte {b:02d} | Guess: 0x{best_guess:02x} | {status}")

print("---------------------------------------------------")

if recovered_key == known_key:
    print("🔥 SUCCESS! Full Key Recovered.")
else:
    print("⚠️  FAILED. Try increasing NUM_TRACES.")

# Cleanup
scope.dis()
target.dis()
