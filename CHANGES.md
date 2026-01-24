# Changes in Feature: Parametric EQ

## Overview

This feature introduces a fully parametric equalizer mode alongside the existing graphic equalizer, allowing for high-precision audio adjustments and compatibility with standard parametric EQ preset formats.

## New Features

1. Parametric EQ Mode:
   - Variable number of bands (up to 64)
   - Support for Peaking, Low Shelf, and High Shelf filters
   - Adjustable Q-factor / Bandwidth for all filter types
   - Global Preamp Gain control

2. Preset Management System:
   - **Custom Presets**: Create, save, and manage unlimited custom parametric presets.
   - **Persistence**: Presets are saved as JSON files in `Application Support/FineTune/EQPresets`.
   - **Import Workflow**:
     - Dedicated **Standalone Import Window** (prevents app dismissal).
     - Support for text-based import (copy-paste).
     - File import via system picker.
   - **Edit Presets**: Pencil button to edit existing presets with pre-populated configuration.
   - **Delete Presets**: Inline trash button in dropdown for quick preset removal.

3. Hybrid UI:
   - **Graphic Mode**: Preserves the original 10-band slider interface.
   - **Parametric Mode**: New read-only list view with import capabilities.
   - **Unified Header**: Seamless switching between modes and consistent preset pickers.

## Architecture Changes

### Audio Engine

- **EQProcessor.swift**:
  - Unified processing loop using `vDSP_biquad` for both graphic and parametric modes.
  - Implemented thread-safe (lock-free) Preamp gain application.
  - **Stability**: Added NaN (Not-a-Number) detection and automatic filter reset preventing audio dropouts during rapid parameter changes.
  - Dynamic coefficient generation based on active mode.

- **BiquadMath.swift**:
  - Added RBJ Cookbook implementations for:
    - `lowShelfCoefficients`
    - `highShelfCoefficients`
  - Refined `peakingEQCoefficients` for consistency.

### Data Models

- **EQSettings.swift**:
  - Added `Mode` enum (`.graphic`, `.parametric`).
  - Added `parametricBands` array.
  - Added text parsing logic for parametric imports.

- **New Models**:
  - `CustomEQPreset.swift`: Codable model for user presets with `configurationText` serialization.
  - `EQBand.swift`: Struct representing a generic filter band.
  - `FilterType.swift`: Enum for filter types (Peak, LowShelf, HighShelf).

### Services

- **PresetManager.swift**:
  - Singleton service managing CRUD operations for custom presets.
  - Handles JSON encoding/decoding and file system interactions.
  - Uses `Combine` for reactive UI updates.

### UI Components

- **ImportWindowManager.swift**:
  - Manages a detached `NSWindow` for import/edit interfaces.
  - Supports both "New" and "Edit" modes with preset pre-population.
- **ParametricPresetPicker.swift**:
  - Custom dropdown matching the app's design system (`GroupedDropdownMenu`).
  - Inline delete buttons with automatic UI refresh.
- **EQPanelView.swift**:
  - Edit button (pencil icon) for modifying selected presets.
  - Fixed segmented control constraint warnings.
