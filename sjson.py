"""Minimal SJSON reader for BeamNG jbeam files.

BeamNG does not read jbeam as JSON. It uses SJSON (Autodesk's Simplified JSON),
where commas are whitespace, `//` and `/* */` are comments, and object members
may be separated by nothing at all. `lua/common/ljson.lua` in the game is the
reference implementation; this is a compact port of it, following the grammar
notes in https://github.com/Telestang/BeamXP (MIT licensed).

Supported subset -- everything the stock content actually uses: quoted keys,
`:` separators, strings, numbers, booleans, null, objects and arrays.
"""

DIGITS = "0123456789"
ESCAPES = {
    "t": "\t",
    "n": "\n",
    "f": "\f",
    "r": "\r",
    "b": "\b",
    '"': '"',
    "\\": "\\",
    "9": "\t",
    "0": "\r",
}


class SJSONError(ValueError):
    """Raised when a document cannot be read even under SJSON rules."""


def _skip(text, i):
    """Whitespace, commas and comments are all the same thing to SJSON."""
    n = len(text)
    while i < n:
        char = text[i]
        if char <= " " or char == ",":
            i += 1
        elif char == "/":
            nxt = text[i + 1] if i + 1 < n else ""
            if nxt == "/":
                end = text.find("\n", i + 2)
                i = n if end < 0 else end
            elif nxt == "*":
                end = text.find("*/", i + 2)
                i = n if end < 0 else end + 2
            else:
                raise SJSONError(f"invalid comment at char {i}")
        else:
            return i
    return i


def _string(text, i):
    start = i
    i += 1
    end = text.find('"', i)
    if end < 0:
        raise SJSONError(f"unterminated string at char {start}")
    if "\\" not in text[i:end]:
        return text[i:end], end + 1
    out = []
    while i < len(text):
        char = text[i]
        if char == '"':
            return "".join(out), i + 1
        if char != "\\":
            out.append(char)
            i += 1
            continue
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if nxt in ESCAPES:
            out.append(ESCAPES[nxt])
            i += 2
        else:
            # ljson keeps the backslash literally and moves on.
            out.append("\\")
            i += 1
    raise SJSONError(f"unterminated string at char {start}")


def _number(text, i):
    """One number, read the way ljson's readNumber does."""
    start = i
    if text[i] in "+-":
        i += 1
    while i < len(text) and text[i] in DIGITS:
        i += 1
    if i < len(text) and text[i] == ".":
        i += 1
        while i < len(text) and text[i] in DIGITS:
            i += 1
    if i < len(text) and text[i] in "eE":
        i += 1
        if i < len(text) and text[i] in "+-":
            i += 1
        while i < len(text) and text[i] in DIGITS:
            i += 1
    if i == start or (i == start + 1 and text[start] in "+-"):
        raise SJSONError(f"invalid number at char {start}")
    value = float(text[start:i])
    if value.is_integer() and "e" not in text[start:i].lower():
        value = int(value)
    return value, i


def _value(text, i):
    char = text[i]
    if char == "{":
        return _object(text, i)
    if char == "[":
        return _array(text, i)
    if char == '"':
        return _string(text, i)
    if text.startswith("true", i):
        return True, i + 4
    if text.startswith("false", i):
        return False, i + 5
    if text.startswith("null", i):
        return None, i + 4
    return _number(text, i)


def _object(text, i):
    out = {}
    start = i
    i = _skip(text, i + 1)
    while i < len(text) and text[i] != "}":
        if text[i] != '"':
            raise SJSONError(f"expected a key at char {i}")
        key, i = _string(text, i)
        i = _skip(text, i)
        if i >= len(text) or text[i] != ":":
            raise SJSONError(f"expected ':' at char {i}")
        value, i = _value(text, _skip(text, i + 1))
        # null is nil in Lua, which means the key is simply absent.
        if value is None:
            out.pop(key, None)
        else:
            out[key] = value
        i = _skip(text, i)
    if i >= len(text):
        raise SJSONError(f"unclosed object at char {start}")
    return out, i + 1


def _array(text, i):
    out = []
    start = i
    i = _skip(text, i + 1)
    while i < len(text) and text[i] != "]":
        value, i = _value(text, i)
        # Rows are positional, so a null stays in place instead of shifting
        # every later column of the row.
        out.append(value)
        i = _skip(text, i)
    if i >= len(text):
        raise SJSONError(f"unclosed array at char {start}")
    return out, i + 1


def first_value(text):
    """The first value of a document, with anything after it ignored."""
    text = text.lstrip("\ufeff")
    return _value(text, _skip(text, 0))[0]


def decode(text):
    """Read one jbeam/.pc document the way the engine would."""
    text = text.lstrip("\ufeff")
    i = _skip(text, 0)
    if i >= len(text):
        return {}
    value, i = _value(text, i)
    i = _skip(text, i)
    if i < len(text):
        raise SJSONError(f"unexpected trailing content at char {i}")
    return value
