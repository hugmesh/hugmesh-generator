# Self-hosted MediaPipe face-tracking assets

Vendored so the 3D chat room's camera face tracking (XR-chat DESIGN §6 Stage 2)
runs ENTIRELY from our own origin — no CDN, no Google-hosted model fetch, and a
strict-CSP deployment needs no third-party exceptions.

| Asset | Source | License |
| --- | --- | --- |
| `face_landmarker.task` | `https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task` (MediaPipe Face Landmarker, float16 v1) | Apache-2.0 |
| `wasm/` (build output only) | copied at build time from the pinned npm package `@mediapipe/tasks-vision` (see `angular.json` assets mapping — NOT committed here) | Apache-2.0 |

The wasm runtime is deliberately NOT committed: `angular.json` maps
`node_modules/@mediapipe/tasks-vision/wasm` → `assets/mediapipe/wasm` at build
time, so the runtime always matches the pinned npm version. The model file IS
committed because it is not distributed in any npm package.

Consumed by `projects/matrix/src/app/chat3d/face-track.worker.ts`
(FilesetResolver base path + modelAssetPath both resolve to these assets).
