import chipwhisperer as cw 
import matplotlib.pyplot as plt
import numpy as np

scope = cw.scope()
target = cw.target(scope)

# Required: Configure scope for STM32F target
scope.default_setup()

fw_path = '/home/pi/cw-firmware/firmware/mcu/simpleserial-aes/simpleserial-aes-CWLITEARM.hex'
cw.program_target(scope, cw.programmers.STM32FProgrammer, fw_path)


for i in range(10): 
    ktp = cw.ktp.Basic()
    key, pt = ktp.new_pair()

    trace = cw.capture_trace(scope, target, pt, key)
    np.save(f"aes_trace_{i}.npy", trace.wave)

wave = []
for i in range(10):
    wave.append(np.load(f"aes_trace_{i}.npy"))
    
waves = np.array(wave)
mean_wave = waves.mean(axis=0)
std_wave = waves.std(axis=0)

signal_var = np.var(mean_wave)
noise_var = np.mean(std_wave**2)

snr = signal_var / noise_var
print("Estimated SNR:", snr)


plt.figure(figsize=(10, 4))
plt.plot(mean_wave)
plt.title("Mean AES Power Trace (50 captures)")
plt.xlabel("Sample")
plt.ylabel("Power")
plt.show()

plt.savefig('aes_trace.png', dpi=150, bbox_inches='tight')
print("Figure saved to aes_trace.png")

