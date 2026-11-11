# ALS: Anti-Lag System

Anti-lag on every turbocharged car in BeamNG.drive. **Yes, even the mod ones.**

[![Subscribe on BeamNG](https://img.shields.io/badge/Subscribe_on_BeamNG.com-FF6600?style=for-the-badge)](https://www.beamng.com/resources/als-anti-lag-system.40159/)

The mod adds one function: anti-lag. Everything else about the turbo stays as it was. Vanilla
anti-lag parts have their power written into jbeam; here it is calculated from that turbo's own
wastegate pressure and pressure curve, which lands on the same kind of numbers.

[![ALS: Anti-Lag System](https://img.youtube.com/vi/5gnrHvG4MQY/maxresdefault.jpg)](https://www.youtube.com/watch?v=5gnrHvG4MQY)

The video shows an older version: the tuning sliders and the ALS part in the parts menu no longer
exist. The keys and how anti-lag behaves are the same.

## Controls

| Key | Action | What it does |
|---|---|---|
| `K` | Toggle ALS | Off when the vehicle spawns |
| `NumPad +` | Scramble | Toggle: raises the boost set point for an overboost until pressed again |
| `U` | Rolling anti-lag | Hold to keep anti-lag running while driving |
| `;` | Rolling launch | The rev cut jumps to the RPM the engine is at, and anti-lag is forced on |

The four actions sit under **Vehicle Specific (installed parts)** in Settings → Controls, and each
car can have its own binding.

![ALS bindings in the Controls menu](assets/bindings.png)

They also show up in the in-game bindings legend:

![ALS actions in the in-game bindings legend](assets/actions.png)

## Caveats

- The mod ships its own copy of `lua/vehicle/powertrain/turbocharger.lua`. Only the anti-lag power
  estimate differs from the game's version, but the file replaces the game's one: a mod that also
  replaces it will win one way or the other, and a game update means the copy has to be re-checked.
- Scramble is a fixed +10 psi offset. There are no tuning sliders.
- Anti-lag needs a turbocharger. A naturally aspirated car keeps the keys, but they do nothing.

## License

beamNG Common Development and Distribution License (bCDDL), v1.1. See `LICENSE`.
