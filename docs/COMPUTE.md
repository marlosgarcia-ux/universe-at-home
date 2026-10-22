# COMPUTE: how pixels get computed (fast, flawless, deterministic)

Status: in progress. Sections marked PENDING are being filled; everything else is final.

Labels used below: **[proved]** (proof given here), **[measured]** (number from `bench/compute.luau` or `tests/compute.test.luau` on this machine), **[predicted]** (derived from measured op costs, not run), **[conjecture]** (believed, not proved), **[needs probe]** (only `studio/EditableImageProbe.luau` in Roblox can settle it).

## 0. Headline findings

PENDING

## 1. What "flawless" means, operationally

PENDING

## 2. Spatial structures

### 2.1 Quadtree with Lipschitz or interval classification
PENDING
### 2.2 Morton traversal
PENDING
### 2.3 Per-tile shape binning
PENDING
### 2.4 Octrees where they fit
PENDING
### 2.5 Shells
PENDING
### 2.6 Tile deduplication by content, copy-on-write tiles
PENDING

## 3. Evaluation

### 3.1 Interval and affine arithmetic
PENDING
### 3.2 Scanline analytic spans (exact-area accumulation)
PENDING
### 3.3 Exact area coverage versus distance approximations
PENDING
### 3.4 Forward differencing
PENDING
### 3.5 Separable and running-sum filters, summed-area tables
PENDING
### 3.6 Distance transforms
PENDING
### 3.7 Low-resolution SDF magnification and multi-channel SDF
PENDING
### 3.8 Progressive any-time refinement
PENDING
### 3.9 Temporal coherence and dirty propagation
PENDING
### 3.10 Sphere tracing 3D SDFs, height field to normal map
PENDING

## 4. Coding techniques in Luau

### 4.1 Closures, a flat op-buffer interpreter, or generated source
PENDING
### 4.2 Batch row kernels
PENDING
### 4.3 Data layouts
PENDING
### 4.4 EditableImage combine ops as a C++ image-algebra coprocessor
PENDING
### 4.5 GPU display-time computation
PENDING
### 4.6 Actors in the parallel phase
PENDING
### 4.7 Time slicing
PENDING
### 4.8 Server native codegen plus baking
PENDING

## 5. Combining with ALLAN

PENDING

## 6. Measured summary

PENDING

## 7. Ranked pipeline recommendation

PENDING

## 8. Axioms added by this study (C1, C2, ...)

PENDING

## 9. Corrections to the project axioms

PENDING

## 10. What the Studio probe must confirm

PENDING

## 11. Files and how to reproduce

PENDING
