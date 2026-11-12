#!/usr/bin/env python3
"""Build the ALS mod from the vehicle data shipped with BeamNG.

Everything that depends on a vehicle is regenerated from the game files, so a
game update only needs a re-run of this script. The hand written parts (lua,
input actions, key bindings) live in src/ and are copied as they are.

Usage:
    python build.py                 # build into build/
    python build.py --install       # build straight into the game's unpacked mods
    python build.py --mods          # also cover the vehicles in the mod repo
    python build.py <game path>     # override the auto-detected game directory

How it works:
  1. index every node of every jbeam in content/vehicles/*.zip, plus the mods in
     the user's mod repo when --mods is given;
  2. find the chassis parts (slotType "main") and the engine groups they allow;
  3. in every engine group that has a turbocharger, take the part that owns the
     engine management (the vanilla anti-lag part if the chassis has one, else
     the ECU parts) and generate a variant of it carrying the ALS controller;
  4. write one inputmap per chassis that can install such a part.
"""

import argparse
import json
import os
import shutil
import winreg
import zipfile
from collections import defaultdict
from copy import deepcopy
from pathlib import Path

from sjson import SJSONError, decode, first_value

MOD = Path(__file__).resolve().parent
SRC = MOD / "src"
GAME = "BeamNG.drive"

RPM_TO_AV = 0.10471971768
ANTILAG_MARGIN = 1.5
DEFAULT_TARGET_RPM = 90000
DEFAULT_SCRAMBLE_PSI = 10
DEFAULT_SCRAMBLE_MAX = 30
DEFAULT_WASTEGATE_MAX = 15
AFTERFIRE_VISUAL_THRESHOLD = 20000  # the stock 150000 gates out the flames
REV_LIMITER_CUT_TIME = 0.1
AUTO_ARM_RATIO = 0.7  # vanilla default 5000 RPM on a ~7000 RPM engine
AUTO_DISARM_RATIO = 0.43  # vanilla default 3000 RPM on the same engine
MIN_ACTIVE_RATIO = 0.35  # vanilla default 2000 RPM
AUTHORS = "ALS"
ACTIONS = ["als_toggle", "als_scramble", "als_rolling", "als_launch"]
INPUTMAP = "keyboardALS.json"
CONTROLLER = "powertrainControl/als_antiLag"
VANILLA_CONTROLLER = "powertrainControl/antiLag"


def find_game():
    """The BeamNG.drive install: Steam's registry entry, then its library, then
    the default install paths."""
    candidates = []
    uninstall = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 284160"
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, uninstall) as key:
            candidates.append(Path(winreg.QueryValueEx(key, "InstallLocation")[0]))
    except OSError:
        pass
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
            steam = Path(winreg.QueryValueEx(key, "SteamPath")[0])
        candidates.append(steam / "steamapps" / "common" / GAME)
    except OSError:
        pass
    for root in ("C:/Program Files/Steam", "C:/Program Files (x86)/Steam"):
        candidates.append(Path(root) / "steamapps" / "common" / GAME)

    for game in candidates:
        if game.is_dir():
            return game
    return None


def read_document(text):
    """Parse a jbeam, tolerating the brace mistakes mod files ship with.

    Mod authors sometimes leave out the outer object or close it one time too
    many; the engine reads both, so a strict reader would lose those parts.
    """
    if text.lstrip("\ufeff \n\t,")[:1] == '"':
        text = "{" + text + "}"
    try:
        return decode(text)
    except SJSONError:
        try:
            return first_value(text)
        except SJSONError:
            return None


def vehicle_key(path):
    """The vehicle a jbeam belongs to: the folder under vehicles/."""
    parts = path.split("/")
    return parts[1] if parts[0] == "vehicles" and len(parts) > 2 else None


def load_nodes(archives, mod_archives):
    """Every jbeam node in the given archives, grouped by vehicle folder.

    Returns the vehicles, the keys only the mods define and the keys a mod adds
    parts to on top of the stock vehicle.
    """
    vehicles = defaultdict(dict)
    mod_keys = set()
    game_keys = set()
    mods = set(mod_archives)
    unreadable = 0
    for index, archive in enumerate(archives, 1):
        with zipfile.ZipFile(archive) as zf:
            entries = [entry for entry in zf.namelist() if entry.endswith(".jbeam")]
            for entry in entries:
                document = read_document(zf.read(entry).decode("utf-8", "replace"))
                if not isinstance(document, dict):
                    unreadable += 1
                    continue
                key = vehicle_key(entry)
                if key is None:
                    continue
                (mod_keys if archive in mods else game_keys).add(key)
                for name, body in document.items():
                    if isinstance(body, dict) and name not in vehicles[key]:
                        vehicles[key][name] = {
                            "path": entry,
                            "data": body,
                        }
        print(
            f"reading {archive.stem} ({index}/{len(archives)})",
            end="\r",
            flush=True,
        )
    print(" " * 40, end="\r")
    if unreadable:
        print(f"unreadable jbeam files: {unreadable}")
    return vehicles, mod_keys - game_keys, mod_keys & game_keys


def load_locales(game):
    """Flat key -> English text map for the names the vanilla parts use."""
    locales = {}
    for name in ("vehiclesGenerated.translation.json", "main.translation.json"):
        path = game / "locales" / "translations" / "en-US" / name
        if path.exists():
            document = decode(path.read_text(encoding="utf-8"))
            if not isinstance(document, dict):
                raise ValueError(f"{name} is not a translation object")
            locales.update(document)
    return locales


def display_name(name, locales):
    """The text a part name renders as, for both plain names and localized ones."""
    if isinstance(name, str):
        return name.strip()
    if not isinstance(name, dict) or not isinstance(name.get("txt"), str):
        return ""
    # A key that is not in the locale files is shown verbatim by the game, so
    # the tail of it is the closest thing to the real name.
    text = locales.get(name["txt"], name["txt"].rsplit(".", 1)[-1])
    for key, value in (name.get("ctx") or {}).items():
        if not isinstance(value, str):
            continue
        text = text.replace("{{" + key + " | translate}}", locales.get(value, value))
        text = text.replace("{{" + key + "}}", locales.get(value, value))
    return text.strip()


def slot_types(node):
    """slotType of a part, always a list."""
    raw = node["data"].get("slotType")
    if raw is None:
        return []
    return raw if isinstance(raw, list) else [raw]


def slot_rows(node):
    """(slot, allowed part types, default part) for every slot a part opens."""
    rows = []
    for key in ("slots2", "slots"):
        for row in node["data"].get(key, []):
            if not isinstance(row, list) or not isinstance(row[0], str):
                continue
            name = row[0]
            if name in ("name", "type"):
                continue
            if len(row) > 1 and isinstance(row[1], list):
                allowed = [a for a in row[1] if isinstance(a, str)] or [name]
                default = row[3] if len(row) > 3 and isinstance(row[3], str) else ""
            else:
                allowed = [name]
                default = row[1] if len(row) > 1 and isinstance(row[1], str) else ""
            rows.append((name, allowed, default))
    return rows


def variable_rows(node):
    """The $variable rows a part defines, header row dropped."""
    return [
        row
        for row in node["data"].get("variables", [])
        if isinstance(row, list) and isinstance(row[0], str) and row[0].startswith("$")
    ]


def turbo_data(node):
    """The wastegate and boost data of a part's turbocharger section."""
    turbo = node["data"].get("turbocharger")
    if not isinstance(turbo, dict):
        return None
    curve = [
        (row[0], row[1])
        for row in turbo.get("pressurePSI", [])
        if isinstance(row, list)
        and len(row) >= 2
        and all(isinstance(v, (int, float)) for v in row[:2])
    ]
    start = turbo.get("wastegateStart")
    limit = turbo.get("wastegateLimit")
    return {
        "backPressureCoef": turbo.get("backPressureCoef", 0.0005),
        "frictionCoef": turbo.get("frictionCoef", 0.01),
        "start": start if isinstance(start, (int, float)) else None,
        "limit": limit if isinstance(limit, (int, float)) else None,
        "exhaust": turbo.get("maxExhaustPower", 0),
        "curve": curve,
    }


def group_turbos(nodes, members):
    """Every turbocharger section reachable from an engine group, best first."""
    turbos = []
    for member in members:
        data = turbo_data(nodes[member])
        if data and (data["curve"] or "backPressureCoef" in data):
            turbos.append(data)
    if not turbos:
        return None
    return max(turbos, key=lambda t: (bool(t["curve"]), t["exhaust"]))


def tunable(nodes, members):
    """True when the stock part already exposes the wastegate as a tuning variable.

    A wastegateLimit above wastegateStart is not a slider: it is just the band
    the PID regulates in. Only a variable row makes the set point tunable.
    """
    return any(
        row[0] in ("$wastegateStart", "$wastegateTarget", "$wastegateLimit")
        for member in members
        for row in variable_rows(nodes[member])
    )


def peaked(turbo):
    """True when the boost curve flattens out instead of climbing forever."""
    curve = turbo["curve"]
    if len(curve) < 3:
        return False
    top = max(psi for _, psi in curve)
    return curve[-1][1] <= top * 0.98


def target_rpm(turbo, nodes, members):
    """RPM the wastegate tries to hold, taken from the turbo's own data."""
    target = (
        turbo["start"] + 0.5
        if turbo["start"] is not None
        else next(
            (
                row[4]
                for member in members
                for row in variable_rows(nodes[member])
                if row[0] in ("$wastegateTarget", "$wastegateStart")
                and len(row) > 4
                and isinstance(row[4], (int, float))
            ),
            None,
        )
    )
    if target is None or not turbo["curve"]:
        return DEFAULT_TARGET_RPM
    for rpm, psi in turbo["curve"]:
        if psi >= target:
            return rpm
    return turbo["curve"][-1][0]


def antilag_power(turbo, rpm):
    """Power needed to hold the turbo at target speed, with a safety margin."""
    angular = rpm * RPM_TO_AV
    hold = angular * angular * turbo["backPressureCoef"] + turbo["frictionCoef"]
    return round(hold * ANTILAG_MARGIN / 10) * 10


def merge_after_turbo(engine, home, nodes):
    """True when the engine merges a turbo into itself before the ALS part.

    unifyParts walks the slots in order, so "$+wastegateStart" can only add to a
    set point that is already in the merged data. A part nested in the turbo slot
    - the vanilla anti-lag part - is merged into the turbo first, so it is safe
    as well.
    """
    rows = slot_rows(engine)
    home_row = next(
        (
            i
            for i, (_, allowed, default) in enumerate(rows)
            if home in allowed or home == default
        ),
        None,
    )
    if home_row is None:
        return True
    for i in range(home_row):
        _, allowed, default = rows[i]
        for part in allowed + [default]:
            turbo = nodes.get(part, {}).get("data", {}).get("turbocharger")
            if isinstance(turbo, dict) and isinstance(
                turbo.get("wastegateStart"), (int, float)
            ):
                return True
    return False


def part_redline(nodes, part):
    """The RPM ceiling a part can reach, from the data the part carries itself.

    The rev limiter is the ceiling the engine actually sees, so the lower of the
    limiter and the redline wins: a part can be rated for 3200 RPM and still be
    held at 2200 by its own limiter.
    """
    engine = nodes[part]["data"].get("mainEngine")
    if not isinstance(engine, dict):
        return None
    ceiling = None
    for key in ("revLimiterRPM", "maxRPM"):
        raw = engine.get(key)
        if isinstance(raw, str) and raw.startswith("$"):
            raw = next(
                (
                    row[4]
                    for row in variable_rows(nodes[part])
                    if row[0] == raw
                    and len(row) > 4
                    and isinstance(row[4], (int, float))
                ),
                None,
            )
        if isinstance(raw, (int, float)) and (ceiling is None or raw < ceiling):
            ceiling = raw
    return ceiling


def group_redline(nodes, members):
    """The redline of the engine a part belongs to.

    Vanilla anti-lag parts and plain ignition parts carry no mainEngine block at
    all, so the only ceiling available for them is the one the engine declares.
    """
    for member in members:
        engine = nodes[member]["data"].get("mainEngine")
        if isinstance(engine, dict) and isinstance(engine.get("maxRPM"), (int, float)):
            return engine["maxRPM"]
    return None


def wastegate_override(section, turbo, merge_after, stock_tunable):
    """Make a fixed wastegate tunable, the way the stock "Stage 3" parts are.

    The set point has to live in the part data: the turbocharger controller reads
    wastegateStart once when the vehicle loads and only exposes a wastegate offset
    at run time, which moves the target but never the part data.

    When the part owns the set point it is made variable in place. When it does
    not, the "$+key" merge modifier adds the slider to whatever the installed
    turbo already carries, instead of copying that turbo's number into the ALS
    part. Variables are substituted before parts are merged, so both forms see a
    number by the time they merge.

    Returns how far the slider may push the set point, in PSI, or None when there
    is no fixed set point to move (no turbo, or one the game already tunes).
    """
    if stock_tunable:
        # The stock part already ships a wastegate slider; a second one on the
        # same set point would only confuse the tuning page.
        return None
    own = section.get("wastegateStart")
    if isinstance(own, list) and all(isinstance(v, (int, float)) for v in own):
        # per gear set points: move every gear by the same amount
        base = max(own)
        section["wastegateStart"] = [f"$={v} + $alsWastegateBoost" for v in own]
        limit = section.get("wastegateLimit")
        if isinstance(limit, list) and all(isinstance(v, (int, float)) for v in limit):
            section["wastegateLimit"] = [f"$={v} + $alsWastegateBoost" for v in limit]
    elif isinstance(own, (int, float)):
        base = own
        section["wastegateStart"] = f"$={base} + $alsWastegateBoost"
        limit = section.get("wastegateLimit")
        if isinstance(limit, (int, float)):
            section["wastegateLimit"] = f"$={limit} + $alsWastegateBoost"
    elif merge_after:
        base = turbo["start"] if isinstance(turbo["start"], (int, float)) else 0
        section["$+wastegateStart"] = "$alsWastegateBoost"
        limit = section.get("wastegateLimit")
        if isinstance(limit, (int, float)):
            section["$+wastegateLimit"] = "$alsWastegateBoost"
    else:
        return None

    top = max(psi for _, psi in turbo["curve"]) if turbo["curve"] else 0
    span = round(top - base, 1) if top > base else DEFAULT_WASTEGATE_MAX
    return span if span > 0 else None


def als_variant(node, turbo, rpm, merge_after, stock_tunable, max_rpm, locales):
    """A copy of a vanilla part that also carries the ALS controller."""
    part: dict = deepcopy(node["data"])

    # The hotkeys are gated by the part, so they have to be listed here or the
    # bindings never show up in the controls menu.
    actions: list = [
        row for row in part.get("actionsEnabled", []) if isinstance(row, list)
    ] or [["id"]]
    for action in ACTIONS:
        if [action] not in actions:
            actions.append([action])

    info: dict = part.get("information") or {}
    base = display_name(info.get("name"), locales)
    # A localized name is a lookup key, so appending to it would point at a key
    # the game has no translation for; the resolved English text is written as a
    # plain string instead, which the game displays verbatim.
    if base and "lag" not in base.lower():
        info["name"] = base + " + ALS"
    info["authors"] = AUTHORS
    part["information"] = info

    ordered: dict = {}
    for key, value in part.items():
        ordered[key] = value
        if key == "slotType":
            ordered["actionsEnabled"] = actions
    if "slotType" not in part:
        ordered["actionsEnabled"] = actions
    part = ordered

    # A vanilla anti-lag part registers the plain controller and keeps its
    # tuning in an "antiLag" block; the wrapper takes both over instead of
    # adding a second controller to the same node group.
    controllers: list = part.get("controller") or [["fileName"]]
    for row in controllers:
        if isinstance(row, list) and row[:1] == [VANILLA_CONTROLLER]:
            row[0] = CONTROLLER
            if len(row) > 1:
                row[1] = {"name": "alsAntiLag"}
            break
    else:
        controllers.append([CONTROLLER, {"name": "alsAntiLag"}])
        part["controller"] = controllers

    config = part.pop("antiLag", None) or {
        "turboTargetRPM": rpm,
        "minActiveWheelSpeed": 1,
        "maxActiveThrottleInput": 0.2,
        "minActiveBrakeInput": 0.2,
        "timeoutTime": 30,
        "timeoutResetTime": 2,
    }
    if max_rpm:
        # The stock thresholds assume a car redline; a 2200 RPM bus diesel can never
        # reach them, so the hotkey would have no effect at all.
        config.setdefault("minActiveEngineRPM", round(max_rpm * MIN_ACTIVE_RATIO))
        config.setdefault("autoArmMinRPM", round(max_rpm * AUTO_ARM_RATIO))
        config.setdefault("autoDisarmMaxRPM", round(max_rpm * AUTO_DISARM_RATIO))
    config["scrambleBoostPsi"] = "$alsScrambleBoost"
    part["alsAntiLag"] = config

    section = part.get("turbocharger")
    if not isinstance(section, dict):
        section = {}
    section["maxAntilagPower"] = antilag_power(turbo, rpm)
    boost_span = wastegate_override(section, turbo, merge_after, stock_tunable)
    part["turbocharger"] = section

    engine: dict = part.get("mainEngine") or {}
    engine["revLimiterType"] = "timeBased"
    engine["revLimiterCutTime"] = REV_LIMITER_CUT_TIME
    engine["afterFireVisualThresholdSustained"] = AFTERFIRE_VISUAL_THRESHOLD
    part["mainEngine"] = engine

    variables = part.get("variables") or []
    if not variables or not isinstance(variables[0], list):
        variables.insert(
            0,
            [
                "name",
                "type",
                "unit",
                "category",
                "default",
                "min",
                "max",
                "title",
                "description",
            ],
        )
    variables.append(
        [
            "$alsScrambleBoost",
            "range",
            "psi",
            "Engine",
            DEFAULT_SCRAMBLE_PSI,
            0,
            DEFAULT_SCRAMBLE_MAX,
            "Scramble overboost",
            "Boost pressure added while the scramble key is held",
            {"stepDis": 1},
        ]
    )
    if boost_span:
        variables.append(
            [
                "$alsWastegateBoost",
                "range",
                "psi",
                "Engine",
                0,
                0,
                boost_span,
                "Wastegate pressure",
                "Raises the pressure the wastegate holds, on top of the stock set point",
                {"stepDis": 0.5},
            ]
        )
    part["variables"] = variables

    return part


def vehicle_parts(vehicles, key):
    """The parts a vehicle can install: its own files plus the shared ones.

    BeamNG keeps the engines several vehicles share in vehicles/common, and a
    vehicle only reaches them through the slots its own parts declare, so the
    shared parts are pulled in slot by slot until nothing new is left.
    """
    parts = dict(vehicles[key])
    slots = set()
    shared = vehicles.get("common", {})
    while True:
        for node in parts.values():
            for slot, allowed, default in slot_rows(node):
                slots.add(slot)
                slots.update(allowed)
                if default:
                    slots.add(default)
        fresh = [
            name
            for name, node in shared.items()
            if name not in parts and any(slot in slots for slot in slot_types(node))
        ]
        if not fresh:
            return parts
        for name in fresh:
            parts[name] = shared[name]


def vehicle_variants(nodes, locales, generated, used):
    """Generate the ALS variant of every engine group of one vehicle.

    Returns (groups, groups with a turbo, tunable groups, peaked groups, parts
    written, groups without a turbo).
    """
    by_slot = defaultdict(list)
    for name, node in nodes.items():
        for slot in slot_types(node):
            by_slot[slot].append(name)

    stats = [0, 0, 0, 0, 0]
    no_turbo = 0
    for name, node in nodes.items():
        if "powertrain" not in node["data"]:
            continue
        if not any("ecu" in slot.lower() for slot, _, _ in slot_rows(node)):
            continue
        stats[0] += 1
        members = [name]
        for _, allowed, default in slot_rows(node):
            members += [part for slot in allowed for part in by_slot.get(slot, [])]
            if default in nodes:
                members.append(default)
        turbo = group_turbos(nodes, members)
        if not turbo:
            no_turbo += 1
            continue
        # The vanilla anti-lag slot hangs off the turbo part, so look for it in
        # every part of the group before falling back to the ECU.
        homes = [
            part
            for member in members
            for slot, allowed, _ in slot_rows(nodes[member])
            if "antilag" in slot.lower()
            for allowed_slot in allowed
            for part in by_slot.get(allowed_slot, [])
        ] or [
            part
            for slot, allowed, _ in slot_rows(node)
            if "ecu" in slot.lower()
            for allowed_slot in allowed
            for part in by_slot.get(allowed_slot, [])
        ]
        adjustable = tunable(nodes, members)
        for home in dict.fromkeys(part for part in homes if part in nodes):
            if home in used:
                continue
            used.add(home)
            generated[nodes[home]["path"]][home + "_als"] = als_variant(
                nodes[home],
                turbo,
                target_rpm(turbo, nodes, members),
                merge_after_turbo(node, home, nodes),
                adjustable,
                part_redline(nodes, home) or group_redline(nodes, members),
                locales,
            )
            stats[4] += 1
        stats[1] += 1
        stats[2] += int(adjustable)
        stats[3] += int(peaked(turbo))
    return stats, no_turbo


def copy_tree(source, target):
    for path in source.rglob("*"):
        if path.is_file():
            out = target / path.relative_to(source)
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(path.read_bytes())


def main():
    parser = argparse.ArgumentParser(description="Generate the ALS mod.")
    parser.add_argument(
        "game", nargs="?", help="BeamNG game directory, auto-detected when omitted"
    )
    parser.add_argument(
        "--install",
        action="store_true",
        help="write straight into the game's unpacked mods folder instead of build/",
    )
    parser.add_argument(
        "--mods",
        action="store_true",
        help="also cover the vehicles in the installed mod repo",
    )
    args = parser.parse_args()

    game = Path(args.game) if args.game else find_game()
    if game is None:
        raise SystemExit(
            "BeamNG.drive not found, pass the game directory as an argument"
        )

    user = Path(os.environ["LOCALAPPDATA"]) / "BeamNG" / GAME
    build = (
        user / "current" / "mods" / "unpacked" / MOD.name
        if args.install
        else MOD / "build"
    )
    if build.exists():
        shutil.rmtree(build)
    build.mkdir(parents=True, exist_ok=True)

    game_archives = sorted((game / "content" / "vehicles").glob("*.zip"))
    mod_archives = []
    if args.mods:
        repo = user / "current" / "mods" / "repo"
        mod_archives = [
            archive
            for archive in sorted(repo.glob("*.zip"))
            if archive.stem != MOD.name
        ]

    vehicles, mod_keys, mixed_keys = load_nodes(
        game_archives + mod_archives, mod_archives
    )
    locales = load_locales(game)

    generated = defaultdict(dict)
    used = set()
    with_als = []
    totals = [0, 0, 0, 0, 0]
    without_turbo = 0

    print(f"{'vehicle':<21} {'engines':>7} {'turbos':>7} {'tunable':>8} {'peaked':>6}")
    print("-" * 53)
    for key, nodes in sorted(vehicles.items()):
        if not any("main" in slot_types(node) for node in nodes.values()):
            continue
        stats, no_turbo = vehicle_variants(
            vehicle_parts(vehicles, key), locales, generated, used
        )
        if not stats[0]:
            continue
        if stats[1]:
            with_als.append(key)
        marker = "[MOD]" if key in mod_keys else "[+mod]" if key in mixed_keys else ""
        print(
            f"{marker:<6} {key:<14} {stats[0]:>7} {stats[1]:>7} {stats[2]:>8} {stats[3]:>6}"
        )
        totals = [a + b for a, b in zip(totals, stats)]
        without_turbo += no_turbo
    print("-" * 53)
    print(f"{'total':<21} {totals[0]:>7} {totals[1]:>7} {totals[2]:>8} {totals[3]:>6}")
    print(
        f"engine groups without a turbo: {without_turbo}, parts generated: {totals[4]}"
    )

    for path, variants in sorted(generated.items()):
        out = build / path.replace(".jbeam", "_als.jbeam")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(
            json.dumps(variants, indent=4, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )

    inputmap = json.loads(
        (SRC / "vehicles" / "_inputmap" / INPUTMAP).read_text(encoding="utf-8")
    )
    for chassis_name in with_als:
        out = build / "vehicles" / chassis_name / "inputmaps" / INPUTMAP
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(inputmap, indent=2) + "\n", encoding="utf-8")

    copy_tree(SRC / "lua", build / "lua")
    copy_tree(SRC / "vehicles" / "common", build / "vehicles" / "common")
    if (SRC / "mod_info.json").exists():
        (build / "mod_info.json").write_text(
            (SRC / "mod_info.json").read_text(encoding="utf-8"), encoding="utf-8"
        )


if __name__ == "__main__":
    main()
