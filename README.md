# ALS: Anti-Lag System

Anti-lag you control from the keyboard, on every turbocharged car in BeamNG.drive.

This is not gt02's [Anti-Lag System (Turbo)](https://www.beamng.com/resources/anti-lag-system-turbo.5791/) updated for a new game. It is a
full rewrite, and the philosophy is different. gt02's mod gives the car a custom turbocharger and
drives it from its own copy of the turbo code. This mod keeps the car's own turbo and adds the
anti-lag to the car's own ECU, so the parts read and behave like vanilla ones. Only the hotkeys and
the scramble/rolling ideas carry over.

## Controls

| Key | Action | What it does |
|---|---|---|
| `K` | Toggle ALS | Default is on |
| `NumPad +` | Scramble | Extra boost pressure while the key is held |
| `U` | Rolling anti-lag | Hold to keep anti-lag running while driving |
| `;` | Rolling launch | The rev cut jumps to the RPM the engine is at, and anti-lag is forced on |

## Tuning

Every ALS part adds two sliders under **Engine**:

- **Scramble overboost**: 0 to 30 psi added while `+` is held (default 10). If the turbo already sits
  at its physical ceiling and cannot spin faster, the extra pressure will not appear, or will be
  smaller than the slider says.
- **Wastegate pressure**: raises the pressure the wastegate holds, up to the top of that turbo's own
  curve. It only shows up where the stock part has no wastegate slider.

## Original vs this mod

| | gt02's mod | this mod |
|---|---|---|
| Why it changed | last updated 2024; the game removed the hooks its turbo controller hung on, so the parts behaved like a plain variable turbo | rebuilt on the game's own anti-lag |
| Parts menu | Intake | Engine Management |
| Where the ALS lives | ❌ its own turbo parts and a fork of `turbocharger.lua` | ✅ the vanilla anti-lag controller |
| Parts | ❌ hand-written jbeam per car, one shared ALS turbo copied from the vanilla Stage 3 | ✅ a fork of every ECU with the ALS attached |
| Adaptive tuning | ❌ one fixed set of numbers for all cars | ✅ the script works out each engine's own redline, wastegate and turbo curve |
| Game updates | ❌ fix the files by hand | ✅ re-run `build.py` |
| Launch | ➖ rolling ALS set a temp rev limiter; anti-lag came in on its own triggers | ✅ `;` pins the rev cut at the current RPM and keeps anti-lag on |
| Turbo coverage | ✅ an ALS turbo on every car, even cars that never had one | ❌ only engines the game turbocharges |
| Scramble range | ✅ up to 50 psi | ❌ up to 30 psi |
| Boost by gear / speed | ✅ separate controller parts people used | ❌ none |
| Sounds | ➖ copies one turbo onto every car, so all cars get the same sounds | ✅ vanilla, per car; the mod only calls what the car already has |

## Running the build

```sh
python build.py                              # auto-detects the game, writes the mod into build/
python build.py --install                    # builds straight into current/mods/unpacked/als
python build.py "D:\Games\BeamNG.drive" --install   # point at the game explicitly
```

The game directory is optional. No dependencies beyond the standard library.

## License

beamNG Common Development and Distribution License (bCDDL), v1.1. See `LICENSE`, and credit to gt02
for the original mod.
