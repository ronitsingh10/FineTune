# Changes in Feature: Parametric EQ

## Overview

This feature introduces a fully parametric equalizer mode alongside the existing graphic equalizer, allowing for high-precision audio adjustments and compatibility with standard parametric EQ preset formats.

## New Features

1. Parametric EQ Mode:
   - Variable number of bands (up to 64)
   - Support for Peaking, Low Shelf, and High Shelf filters
   - Adjustable Q-factor / Bandwidth for all filter types
   - Global Preamp Gain control

2. Import Workflow:
   - Text-based import for EQ settings
   - Compatible with common formats (e.g., "Filter 1: ON PK Fc 100 Hz Gain -3.0 dB Q 2.0")

3. Hybrid UI:
   - **Graphic Mode**: Preserves the original 10-band slider interface
   - **Parametric Mode**: New read-only list view with import capabilities

## Architecture Changes

### Audio Engine

- **EQProcessor.swift**:
  - Unified processing loop using `vDSP_biquad` for both graphic and parametric modes
  - Implemented thread-safe (lock-free) Preamp gain application
  - Dynamic coeffecient generation based on active mode

- **BiquadMath.swift**:
  - Added RBJ Cookbook implementations for:
    - `lowShelfCoefficients`
    - `highShelfCoefficients`
  - Refined `peakingEQCoefficients` for consistency

### Data Models

- **EQSettings.swift**:
  - Added `Mode` enum (`.graphic`, `.parametric`)
  - Added `parametricBands` array
  - Added text parsing logic for parametric imports

- **New Models**:
  - `EQBand.swift`: Struct representing a generic filter band
  - `FilterType.swift`: Enum for filter types (Peak, LowShelf, HighShelf)
