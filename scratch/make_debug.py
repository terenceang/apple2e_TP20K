with open('scratch/trace_app.py') as f:
    text = f.read()

text = "hist = []\n" + text
text = text.replace("    last_pc = PC\n    op = read_mem(PC)", "    hist.append(PC); hist = hist[-20:]\n    last_pc = PC\n    op = read_mem(PC)")
text = text.replace("print(f\"Halted at PC=${PC:04X} after {step} steps\")", "print(f\"Halted at PC=${PC:04X}\"); print([hex(x) for x in hist])")

with open('scratch/trace_app_debug.py', 'w') as f:
    f.write(text)
