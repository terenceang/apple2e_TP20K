## 2026-09-30 - Canvas Re-allocations and String Formatting in Screen Rendering
**Learning:** Setting `canvas.width` / `canvas.height` on every render re-allocates the canvas backing buffer even if dimensions are identical. Also, calling `rgb(...)` inside a 960-cell screen render loop causes ~1,920 redundant string allocations per frame.
**Action:** Check `canvas.width` / `canvas.height` before assignment, and precompute RGB color strings outside rendering loops.
