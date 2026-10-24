#!/usr/bin/env python3
"""
Apple //e Serial Debugger & Protocol CLI for Tang Primer 20K
Communicates with the onboard serial debugger over 1,000,000 baud 8N1 UART.
"""

import sys
import time
import argparse
import serial
from serial.tools import list_ports


def find_com_port(preferred="COM47"):
    """Auto-detect or verify the Apple //e serial port."""
    if preferred:
        try:
            s = serial.Serial(preferred, 1000000, timeout=0.1)
            s.close()
            return preferred
        except Exception:
            pass

    for p in list_ports.comports():
        port = p.device
        try:
            s = serial.Serial(port, 1000000, timeout=0.2)
            s.reset_input_buffer()
            s.write(b'\x02')
            time.sleep(0.05)
            s.write(b'?\r\n')
            time.sleep(0.1)
            resp = s.read_all()
            s.close()
            if b'Debugger' in resp or b'Cmds:' in resp:
                return port
        except Exception:
            continue
    return None


class Apple2Debugger:
    def __init__(self, port="COM47"):
        self.port_name = port
        self.ser = serial.Serial(port, 1000000, timeout=0.3)
        self.ser.reset_input_buffer()

    def close(self):
        if self.ser and self.ser.is_open:
            self.ser.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()

    def ensure_debugger(self):
        """Ensure we are in debugger mode (CPU paused)."""
        self.ser.write(b'?\r\n')
        time.sleep(0.05)
        resp = self.ser.read_all()
        if b'Cmds:' not in resp and b'>' not in resp:
            # Send Ctrl-B to toggle into debugger
            self.ser.write(b'\x02')
            time.sleep(0.08)
            self.ser.write(b'?\r\n')
            time.sleep(0.05)
            self.ser.read_all()

    def ensure_running(self):
        """Ensure CPU is running (console mode)."""
        self.ser.write(b'c\r\n')
        time.sleep(0.05)
        self.ser.read_all()

    def cmd(self, command_str, wait_s=0.1):
        """Send a single debugger command and return the raw output."""
        self.ensure_debugger()
        self.ser.reset_input_buffer()
        self.ser.write(command_str.encode('ascii') + b'\r\n')
        time.sleep(wait_s)
        return self.ser.read_all().decode('latin1', errors='replace')

    def get_regs(self):
        """Query CPU registers."""
        out = self.cmd('r', wait_s=0.08)
        regs = [line.strip() for line in out.splitlines() if 'PC:' in line]
        return regs[0] if regs else out.strip()

    def step(self, count=1):
        """Step the CPU by N instructions."""
        steps = []
        for _ in range(count):
            out = self.cmd('s', wait_s=0.05)
            regs = [line.strip() for line in out.splitlines() if 'PC:' in line]
            if regs:
                steps.append(regs[0])
        return steps

    def resume(self):
        """Resume CPU execution."""
        self.ser.write(b'c\r\n')
        time.sleep(0.05)
        return self.ser.read_all().decode('latin1', errors='replace').strip()

    def dump_mem(self, addr_hex, lines=1):
        """Dump memory starting at hex address."""
        self.ensure_debugger()
        self.cmd(f'@{addr_hex}', wait_s=0.05)
        results = []
        for _ in range(lines):
            out = self.cmd('m', wait_s=0.08)
            for line in out.splitlines():
                line = line.strip()
                if line.startswith('$') and len(line) >= 40:
                    results.append(line)
        return results

    def get_status(self):
        """Get hardware diagnostic status (VID, PLL, DDR3)."""
        out = self.cmd('t', wait_s=0.08)
        lines = [l.strip() for l in out.splitlines() if 'VID:' in l or 'PLL:' in l]
        return lines[0] if lines else out.strip()

    def get_info(self):
        """Get drive info (Disk II head, TF card status)."""
        out = self.cmd('i', wait_s=0.08)
        lines = [l.strip() for l in out.splitlines() if 'H:' in l or 'S:' in l]
        return lines[0] if lines else out.strip()

    def remount_drive(self, drive_num):
        """Remount drive 1-4 (S6D1, S6D2, S7D1, S7D2) from TF card."""
        if drive_num not in (1, 2, 3, 4):
            raise ValueError("Drive must be 1 to 4")
        return self.cmd(f'y{drive_num}', wait_s=0.2)

    def dump_screen(self):
        """Dump 40x24 text screen page 1 ($0400)."""
        out = self.cmd('w', wait_s=0.25)
        hex_rows = []
        for line in out.splitlines():
            line = line.strip()
            if len(line) == 80 and not line.startswith('$'):
                row_chars = []
                for i in range(0, 80, 2):
                    code = int(line[i:i+2], 16) & 0x7F
                    row_chars.append(chr(code) if 32 <= code <= 126 else ' ')
                hex_rows.append(''.join(row_chars))
        return hex_rows

    def cold_boot(self):
        """Trigger cold boot (Ctrl-OpenApple-Reset)."""
        self.ensure_running()
        # Reset asserted with Open-Apple held (bit 3 | bit 0 = 0x09)
        self.ser.write(b'\xff\x03\x09')
        time.sleep(0.2)
        # Release reset, keep Open-Apple held
        self.ser.write(b'\xff\x03\x01')
        time.sleep(0.1)
        # Release all
        self.ser.write(b'\xff\x03\x00')

    def trigger_self_test(self, continuous=False, soak_s=14):
        """Trigger Apple //e Enhanced built-in self test."""
        self.ensure_running()
        # Assert Reset with Open-Apple + Closed-Apple held (0x08 | 0x01 | 0x02 = 0x0B)
        self.ser.write(b'\xff\x03\x0b')
        time.sleep(0.3)
        # Release Reset, keep Open-Apple + Closed-Apple held (0x03)
        self.ser.write(b'\xff\x03\x03')
        
        if not continuous:
            # Let CPU enter test, then release modifiers for a single pass
            time.sleep(1.5)
            self.ser.write(b'\xff\x03\x00')
            print(f"[*] Running single pass (waiting ~{soak_s}s)...")
            time.sleep(soak_s)
        else:
            print(f"[*] In continuous soak loop mode for {soak_s}s...")
            time.sleep(soak_s)
            self.ser.write(b'\xff\x03\x00')
            time.sleep(15)


def main():
    parser = argparse.ArgumentParser(description="Apple //e Tang Primer 20K Serial Debugger CLI")
    parser.add_argument("--port", default="COM47", help="Serial port (default: COM47)")
    
    sub = parser.add_subparsers(dest="subcmd", help="Subcommand")
    
    sub.add_parser("regs", help="Show 65C02 CPU registers")
    
    step_p = sub.add_parser("step", help="Single step instruction(s)")
    step_p.add_argument("count", type=int, nargs="?", default=1, help="Number of steps")
    
    sub.add_parser("cont", help="Resume CPU execution")
    
    mem_p = sub.add_parser("mem", help="Dump memory")
    mem_p.add_argument("addr", help="Hex address (e.g. 0300, c0f0)")
    mem_p.add_argument("lines", type=int, nargs="?", default=1, help="Number of 16-byte lines")
    
    sub.add_parser("status", help="Get hardware status (VID, PLL, DDR3)")
    sub.add_parser("info", help="Get floppy head & TF card drive status")
    sub.add_parser("screen", help="Capture and print text screen")
    sub.add_parser("reset", help="Cold boot (Ctrl-OA-Reset)")
    
    mount_p = sub.add_parser("remount", help="Remount drive 1-4 from TF card")
    mount_p.add_argument("drive", type=int, choices=[1, 2, 3, 4], help="Drive number (1-4)")
    
    diag_p = sub.add_parser("selftest", help="Run built-in self-test")
    diag_p.add_argument("--continuous", action="store_true", help="Keep looping continuously")
    diag_p.add_argument("--time", type=int, default=14, help="Duration in seconds")
    
    args = parser.parse_args()
    if not args.subcmd:
        parser.print_help()
        sys.exit(1)

    port = args.port
    with Apple2Debugger(port=port) as dbg:
        if args.subcmd == "regs":
            print(dbg.get_regs())
        elif args.subcmd == "step":
            for s in dbg.step(args.count):
                print(s)
        elif args.subcmd == "cont":
            dbg.resume()
            print("[+] CPU resumed.")
        elif args.subcmd == "status":
            print(dbg.get_status())
        elif args.subcmd == "info":
            print(dbg.get_info())
        elif args.subcmd == "mem":
            for line in dbg.dump_mem(args.addr, args.lines):
                print(line)
        elif args.subcmd == "screen":
            rows = dbg.dump_screen()
            print("+" + "-"*40 + "+")
            for r in rows:
                print(f"|{r}|")
            print("+" + "-"*40 + "+")
        elif args.subcmd == "reset":
            dbg.cold_boot()
            print("[+] Cold reboot triggered.")
        elif args.subcmd == "remount":
            dbg.remount_drive(args.drive)
            print(f"[+] Remounted drive {args.drive}.")
        elif args.subcmd == "selftest":
            dbg.trigger_self_test(continuous=args.continuous, soak_s=args.time)
            rows = dbg.dump_screen()
            print("\nScreen dump:")
            for r in rows:
                if r.strip():
                    print(f"  {r.strip()}")


if __name__ == "__main__":
    main()
