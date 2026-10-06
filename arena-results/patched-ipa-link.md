# Patched IPA

- Output: `spoti.pw-0.50.0-noplus.ipa`
- Download: https://filebin.net/spoti-pw-noplus-37401972450/spoti.pw-0.50.0-noplus.ipa
- GitHub Actions artifact: `spoti-pw-0.50.0-noplus-ipa` on run 37401972450
- Size: 130741496 bytes
- SHA-256: `f494ad4096adc81d3bab4b3fee4f30957cc84c0faa0b3e3be72e1f5d7d0a5ce6`

Patch applied to `Payload/Spotify.app/Frameworks/spotifyglass.dylib`:

- `-[SGModRow plus] -> false`
- `-[SGModPage plusFeature] -> nil`
- `-[SGOrderController plusFeature] -> nil`
- `-[SGPage plusLocked] -> false`
- `-[SGModPage locks:] -> false`
- `-[SGOrderController locked] -> false`
- `-[SGModSliderCell locked] -> false`
- `-[SGDSPSliderCell locked] -> false`
- `-[SGDSPErrorPage offeredPlus] -> false`
