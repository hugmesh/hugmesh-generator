# Vendored WebGL background libraries (platform preview only)

The Studio's platform preview is one self-contained `file://` page, so the shell pane
cannot fetch the host shell's chunks. When a theme declares a Vanta background, the
preview inlines these into the (sandboxed, nonce-scripted) shell frame. Nothing else in
the Studio loads them.

- `three.min.js`: three@0.187.0 (the host shell's pinned version), bundled to an IIFE
  that sets `globalThis.THREE` (`esbuild entry.mjs --bundle --minify --format=iife`,
  entry: `import * as THREE from 'three/build/three.module.js'; globalThis.THREE = THREE;`).
  MIT, see LICENSE-three.txt.
- `vanta.{fog,waves,net,globe}.min.js`: vanta@0.5.24 `dist/` files, verbatim. MIT, see
  LICENSE-vanta.txt.

Update them together with the host shell's `three` / `vanta` versions.
