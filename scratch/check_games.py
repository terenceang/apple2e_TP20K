with open('Disk/Total Replay v6.1.hdv', 'rb') as f:
    data = f.read()

import re

# Find ProDOS directory entries (typically filenames have format byte 0: length/type, then name)
# Let's search for games known to have Mockingboard support in Total Replay
known_games = [
    b'SKYFOX', b'ZAXXON', b'ULTIMA', b'SILPHEED', b'THUNDER.BOMBS', b'LADY.TUT',
    b'BERZAP', b'FLAK', b'GENIUS', b'KAMUNGAS', b'RESCUE.RAIDERS', b'WILLY.BYTE',
    b'CRIME.WAVE', b'ONE.ON.ONE', b'SPY.STRIKES.BACK', b'BROADSIDES', b'NIGHT.FLIGHT',
    b' Lancaster', b'CROSSFIRE', b'POOYAN', b'TAPPER'
]

for g in known_games:
    count = len(re.findall(re.escape(g), data, re.IGNORECASE))
    print(f"{g.decode('ascii')}: {count} occurrences")
