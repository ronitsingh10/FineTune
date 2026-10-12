# Custom automation build

The Stream Deck plugin requires the local automation API. An upstream PR being open or unmerged does not affect a custom build made from this branch.

Build with Xcode installed:

```sh
./scripts/build-automation.zsh
```

The script assembles and signs the app under DerivedData, then creates `dist/FineTune-Automation-macOS.zip`. Signing outside Documents avoids Finder metadata interference. It verifies local ad-hoc signing, and does not replace `/Applications/FineTune.app`. This is a local development distribution, not a notarized public release.

The custom bundle ID is `com.finetuneapp.FineTune.Automation`. Preferences and imported AutoEQ files use `~/Library/Application Support/FineTune-Automation/`. Stock Sparkle updates are disabled at compile time so a stock release cannot replace the required API. The upstream build retains its normal identifier, settings directory, and updater.

Quit the stock FineTune before using the custom app. Keep only one audio controller running. On first launch, grant the custom app the system audio permission needed for per-app audio taps. Accessibility is needed only for FineTune features that use it, such as media-key interception; the plugin's local API itself requires no Accessibility grant.

Enable **Settings → General → Local Automation API**. It starts disabled. Install the `.streamDeckPlugin` file and import the XL profile. The plugin reports disabled, unavailable, or incompatible state clearly.

For rollback, quit the custom app and reopen stock FineTune. The plugin will be offline unless the stock build has the API. Stock settings are separate; no automatic import or overwrite occurs. To migrate settings, first export/back up both configurations and explicitly choose which settings to copy with both apps stopped.

Unit test hosts suppress audio monitoring, global hotkeys, orphan cleanup and permission requests, and use temporary settings. Permission acceptance and real audio playback are separate from unit-test success.
