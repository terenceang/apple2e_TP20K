# web/ -- Apple //e keyboard, console and debugger

A browser front end for the Apple //e on the [Tang Nano 20K](../README.md). It
puts the machine's own keyboard, its text screen and its hardware debugger in
the browser.

```
browser ──Web Serial──▶  USB ──▶  BL616  ──▶  FPGA
```

**With the board plugged into the machine running the browser, that is the whole
thing.** There is no daemon, no Node process and nothing to install: the app is
a static bundle and the browser opens the serial port itself. Web Serial is the
only transport; there is no fallback for other machines or other browsers.

## Running it

```sh
cd web
npm install
npm run charset          # optional; needs the ROM, see below
npm run build
```

Serve the result over `https://` or `http://localhost` — Web Serial needs a
*secure context*, so a plain `http://192.168.x.x` will not do. GitHub Pages is
`https`, so it is fine. For a quick look on the machine the board is plugged
into:

```sh
python3 -m http.server -d web/dist 8000   # then open http://localhost:8000
```

Press **Connect USB** and pick the FT2232C channel that turns out to be the
//e's. Then type.

### Which USB channel?

The board's BL616 is an FT2232C with two serial channels, and only one of them
is the FPGA's UART; the other is the BL616's own console. They look identical
in the browser's device picker, so the app cannot tell them apart by name — it
asks instead. On connecting it sends the debugger's own handshake (`Ctrl+B`,
then `?`) and looks for the help line that comes back. If the wrong channel was
picked it says so and closes the port, because there is nothing on that end
that would answer. The probe leaves the //e exactly as it found it.

That is the only way to be sure, and it costs about 20 ms.

## Requirements for the USB path

- **Chrome or Edge.** Firefox and Safari have no Web Serial, and there is no
  fallback transport.
- **https or localhost**, for a secure context.
- A click to connect, because the browser will only open the device picker from
  a user gesture. That is why there is a button rather than an auto-connect.

### Hosting the page on GitHub Pages

The page is static and can live anywhere; it needs nothing but `https`.

```sh
cd web
npm run pages        # build, check, copy into ../docs
```

`docs/` is the site's root, so the app is `docs/index.html` plus `docs/assets/`
and the site lands at `https://<owner>.github.io/<repo>/`. `npm run pages`
prints the URL. The board documentation — Sipeed's datasheet and schematics —
lives in `Documents/`, deliberately outside `docs/`, because **everything in
`docs/` is published**. The deploy script refuses to run if it finds anything in
`docs/` it did not put there, so a document dropped in the wrong place is a
loud failure rather than a published one.

Pages will not run the build itself unless you add a workflow, so the output
is committed:

```sh
git add docs && git commit -m "Publish the web front end" && git push
```

Then set **Settings → Pages → Source** to *Deploy from a branch*, branch
`main`, folder `/docs`. A project site is served from `/<repo>/`, which is why
the published build uses relative asset paths — absolute ones would 404.

**The published bundle contains no character ROM.** `charset.js` imports
`generated/charset.json` and Vite inlines it, so a build made after
`npm run charset` carries all 4096 bytes of Apple's 2732 — and a Pages site is
public the moment it is published, which is the same reason `roms/*.hex` is
gitignored. `npm run pages` swaps that import for a stub, so the published
screen pane shows text rather than the real //e glyphs and says so; a local
build still has them. `scripts/pages.mjs` checks the built output for the ROM
and **refuses to copy** if it is there anyway, and the check is verified to
fail when the swap is disabled.

### The character ROM

The screen is drawn with the same 2732 video ROM the FPGA reads, addressed with
the same expression `video_generator.v` uses, so the browser and the HDMI
monitor are the same picture. That ROM is Apple copyright and not in the repo.
Supply it (see [`roms/README.md`](../roms/README.md)) and then:

```sh
make web-charset
```

Without it the app still works; the screen falls back to showing text instead of
pixels and says so. `web/src/generated/charset.json` is gitignored for the same
reason `roms/*.hex` is, and a build made after `npm run charset` has the ROM
compiled into the bundle — so `npm run pages` deliberately leaves it out. A
local build has the real glyphs; a published one does not.

## The wire protocol

Host to //e, at 115200 8N1. Everything except the two packets is a plain ASCII
keystroke, so a Bluetooth-to-UART module or `picocom` still works.

| Bytes | Meaning |
|---|---|
| `02` | toggle the hardware debugger. The firmware throws this away before the keyboard sees it, so Ctrl+B can never type a character |
| `FE <code> <btns>` | one keypress: the final 7-bit key code, and the paddle button bits (bit 0 Open-Apple, bit 1 Solid-Apple) down with it |
| `FF 01 <btns> <x> <y>` | gamepad: buttons, paddle 0, paddle 1 |
| `FF 04` | all keys up: drops any-key-down (`$C010` bit 7) |
| `1B 5B 41/42/43/44` | ANSI cursor keys, mapped to `$0B/$0A/$15/$08` |
| anything else | a single ASCII keystroke, with CR/LF and DEL normalised |

`<code>` is the **final** character, not a key position. A real //e does that
translation in a keyboard PROM on the motherboard (341-0132-D), taking a
matrix position plus the shift and caps-lock lines; the ROMs then take
`$C000` D6-D0 as final, so nothing downstream needs to know a modifier was held.
This app plays the part of that PROM, which is why `keymap.js` is where the
shift and caps-lock logic lives and the RTL is a plain latch.

`FE` is a packet leader, so a dumb terminal that sends a raw `FE` for `~` now
starts a packet instead of typing `~`. Send `FE 7E 00` for that character.

### What comes back

One stream, and the firmware keeps it that way on purpose: COUT is only
mirrored while the machine is running and the debugger only prints while it is
paused, so the mode tells you which is live. `stream.js` classifies the lines
and everything unrecognised is console text.

| Shape | Meaning |
|---|---|
| `\r\n[ Apple //e Debugger ] (h=Help, c=Cont)\r\n> ` | entered the debugger |
| `\r\n[Resuming...]\r\n` | left it |
| `PC:$FA62 A:$.. X:$.. Y:$.. SP:$.. P:[NV-BDIZC] OP:$..` | registers |
| `$0300: 01 02 ... 0F 10  |ascii|` | 16 bytes of memory, address advances by 16 each dump |
| `VID:T PLL:1` | video mode and PLL lock |
| `$SS <flags>` ... `$SEND` | the screen dump, see below |

**Commands** are `r s c/g m t w h/? x`, plus `0 1 4 8 f v` to set the memory
dump address to `$0000 $0100 $0400 $0800 $FA60 $FFF0` before `m`. The
firmware's own `?` only lists six of them; `x`, `g` and `w` work and are not in
its help text.

Commands are only accepted when the debugger's main state is idle, and anything
sent sooner is dropped without a word. The banner prints **two** prompts -- one
at the end of the banner string, one after the register dump -- so neither one
on its own means idle. `useApple.ts` therefore releases queued commands after
200 ms of silence, which at 115200 is many times longer than a 45-byte register
line takes.

## The screen

`W` (`w`) dumps the whole 1 KB text page in memory order, plus lo-res rows
20-23 of the same page, which is what the bottom four lines show in mixed-mode
graphics. It is only readable while the CPU is paused, so **Freeze &
capture** pauses, dumps, and lets the machine run again. There is no way to read
RAM while the CPU is running: the 64 KB is time-multiplexed between the CPU and
the video generator, and stealing cycles from either is how the display goes
wrong.

The screen shows text only. Hi-res is not rendered in the browser: `w` dumps
the text page, not `$2000`/`$4000`, so a hi-res screen is only visible on the
HDMI output.

The dump is memory order, and the renderer mirrors `video_generator.v` exactly:

- 24 rows of 40 cells, 7x8 dots, picked out of the dump with the row
  interleave (`protocol.js` `textPageIndex`, the addressing
  `video_generator.v` reads the page with)
- bit 7 of a cell is inverse video, and the //e draws flashing characters by
  toggling it, so one bit drives both
- in mixed mode the bottom four lines are lo-res blocks from the `$GF` rows,
  top four scanlines from the high nibble and four from the low one
- the glyph address is `{0, code[7]|(code[6]&flash), code[6]&code[7], code[5:0], row}` and
  **a set bit is a lit dot** -- the code field is 6 bits wide, so `$41` reads
  glyph 1. `test/charset.test.js` pins that down against glyphs whose shape is
  not in doubt.

## Layout of the source

```
src/
  keymap.js         what each //e key produces, shift/caps logic, host mapping
  keyboard/
    layouts.js      the 63 keys as x/y/w/h + legends; the only place the
                    physical arrangement lives
  protocol.js       byte encoding and the firmware's literal strings
  disk.js           Disk II image validation, interleaving (.dsk/.do <-> .po) & UART protocol
  stream.js         the one incoming stream, classified
  serial-link.js    Web Serial: the whole transport, straight to the board
  charset.js        the character ROM, addressed as the RTL addresses it
  useApple.ts       the link, command pacing, screen capture, disk management
  components/       Keyboard, Console, Screen, DebuggerPane, Gamepad, FlashBar, DiskPane
scripts/charset.mjs roms/apple2e_char.hex -> src/generated/charset.json
scripts/pages.mjs   build the Pages bundle, check it, copy to docs/
test/               node --test
```

## Security

There is nothing to defend: the browser opens the port itself, and no other
page can reach it — Web Serial is per-origin and gated behind a click. A site
that has been granted the port once still needs a user gesture to reopen it.

## Tests

```sh
make web-test
```

None of this needs the board or a browser: the Web Serial object and localStorage
are injected, so the whole of the app's logic is reachable from node.

`keymap.test.js` is the era check, and it is deliberately unforgiving: it pins
the key count at 63, fails if a REPT key, a function key, a numeric keypad, a
`⌘` or a Macintosh `*:` key ever appears, and checks that the generated
character repertoire is exactly the //e's 40-column set -- all 95 printable
ASCII, `$01`-`$1B` from CONTROL and the named keys, and DEL, and nothing else.
In particular it holds that SHIFT-G is the BELL rather than a tilde, that
CAPS LOCK shifts letters only, and that the tilde is on its own cap and not on
G.

`charset.test.js` pins the video ROM convention. `stream.test.js` drives the
parser with the exact bytes the firmware emits, chunked every 1, 3, 7, 16, 40
and 4096 bytes, because at 115200 nothing lands in one read. `serial-link.test.js`
drives the whole Web Serial path against an injected fake, because that is the
only way to get at it outside a browser — and it is how the `open()`-on-the-port
bug and the dropped 8N1 were found.

## Things that are deliberately not here

- **A live screen.** No polling, by agreement. The //e stays free-running; the
  screen updates when you ask.
- **BLE.** The BL616 has a radio, but the browser would need Chrome and HTTPS
  for Web Bluetooth, and USB is already wired up.
- **A //e emulator.** This is a front end to the real machine, not a copy of it.
- **A third game button.** The RTL decodes one at `$C063`, but no //e key closes
  it: the Open-Apple and Solid-Apple keys are hand-control buttons 0 and 1, and
  that is the whole of the machine's game input.
- **Flash buttons.** Programming runs `openFPGALoader`, and the browser cannot
  start a subprocess. Use `make flash-sram` / `make flash` from a terminal.
