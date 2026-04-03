# AutoEQ & Headphone Correction

FineTune can apply headphone-specific frequency response corrections using profiles from the [AutoEQ](https://github.com/jaakkopasanen/AutoEq) project. This compensates for your headphones' natural frequency curve, giving you a flatter, more accurate sound.

## How It Works

Every pair of headphones colors the sound differently. Some boost bass, others are harsh in the treble. AutoEQ measures these deviations and generates corrective EQ filters. FineTune applies these filters per-device, so each pair of headphones gets its own correction profile.

Corrections are applied on top of FineTune's 10-band EQ, so you can still tweak the sound to your taste after applying a profile.

## Browse Built-in Profiles

1. Click the **wand icon** next to any headphone device in FineTune
2. Search for your headphone model by name
3. Select a profile. It's applied immediately.

Profiles are fetched on demand from the AutoEQ database and cached locally for offline use. The database includes thousands of headphones from major brands (Sony, Sennheiser, Apple, Bose, Audio-Technica, Beyerdynamic, and more).

> **Tip:** If your exact model isn't listed, try searching for the product line — similar models often share frequency response characteristics.

## Import Custom Profiles

If you have a custom measurement or want to use a profile from another source:

1. Click **"Import ParametricEQ.txt..."** at the bottom of the AutoEQ panel
2. Select your `.txt` file
3. The profile is imported and applied to the selected device
4. Use the **Correction** switch in the picker to A/B the profile without removing it

FineTune accepts [EqualizerAPO](https://sourceforge.net/projects/equalizerapo/) ParametricEQ.txt files:

```
Preamp: -6.2 dB
Filter 1: ON PK Fc 100 Hz Gain -2.3 dB Q 1.41
Filter 2: ON LSC Fc 105 Hz Gain 7.0 dB Q 0.71
Filter 3: ON HSC Fc 8000 Hz Gain 2.1 dB Q 0.71
```

### Supported Filter Types

| Code | Type | Description |
|------|------|-------------|
| `PK` / `PEQ` | Peaking | Boost or cut a narrow frequency range |
| `LS` / `LSC` | Low shelf | Boost or cut everything below a frequency |
| `HS` / `HSC` | High shelf | Boost or cut everything above a frequency |

Up to 10 filters per profile. The `Preamp` line sets a global gain offset to prevent clipping.

## Where to Get Profiles

- **Built-in search** — The easiest way. Thousands of headphones are available directly in FineTune.
- **[autoeq.app](https://www.autoeq.app/)** — Web-based tool with more options. Select **EqualizerAPO ParametricEq** as the equalizer app, download the file, and import it into FineTune.
- **[AutoEQ GitHub](https://github.com/jaakkopasanen/AutoEq)** — The full repository of measurements and generated profiles.
- **Custom measurements** — If you've measured your headphones yourself (e.g., with a MiniDSP EARS or similar), you can create a ParametricEQ.txt file in any text editor following the format above.

## Managing Profiles

- Each device remembers its assigned profile independently
- To temporarily bypass a profile, click the wand icon and turn **Correction** off
- To remove a profile entirely, click the wand icon and select **No correction**
- Favorite frequently-used profiles for quick access with the star icon — favorited profiles appear at the top of search results and are shown when the search field is empty
