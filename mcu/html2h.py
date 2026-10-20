# PlatformIO pre-build step: src/index.html -> src/index_html.h (EMBED_TXTFILES does not work under PlatformIO).
Import("env")
import os
d = env.subst("$PROJECT_DIR")
b = open(os.path.join(d, "src", "index.html"), "rb").read() + b"\0"
h = "// generated from index.html by html2h.py: do not edit\nstatic const char index_html[] = {\n"
h += ",\n".join(",".join(str(x) for x in b[i:i + 24]) for i in range(0, len(b), 24)) + "};\n"
p = os.path.join(d, "src", "index_html.h")
if not os.path.exists(p) or open(p).read() != h:
    open(p, "w").write(h)
