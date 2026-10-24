# Simulate SYNC on Tang Primer 20K

frame_cycles = 450450 * 5 / 132 # 17062.5
vbl_start = 432 * 858 * 5 / 132 # 14040.0
# vbl is from 14040.0 to 17062.5
# display is from 0 to 14040.0

# In display: vbl=0 -> sw_bit = ~vbl = 1 (Negative, BMI branches)
# In VBL: vbl=1 -> sw_bit = ~vbl = 0 (Positive, BMI does not branch)

cycle = 0.0 # start of display
print(f"Start at cycle {cycle} (Display)")

for it in range(20):
    cycle = (cycle + 20279) % frame_cycles
    in_vbl = cycle >= vbl_start
    print(f"Iteration {it}: cycle in frame = {cycle:.1f} / {frame_cycles:.1f} -> {'VBL (EXIT!)' if in_vbl else 'DISPLAY (LOOP)'}")
    if in_vbl:
        break
