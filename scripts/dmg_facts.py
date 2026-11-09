#!/usr/bin/env python3
"""What a disk image's window layout is made of, read from the volume itself — the facts behind
"the window shows its picture" (the owner, 3 November: 0.1.1's image had its icons and its window
size, and no picture, while make_dmg.sh said it was laid out).

    python3 scripts/dmg_facts.py /Volumes/Lumen [--icon-size 128] [--no-picture]
    python3 scripts/dmg_facts.py --compare kept.DS_Store /Volumes/Lumen/.DS_Store

Says, in words:
- the picture: whether .background/background.tiff is there, its pages (Finder takes the 2x one on
  a Retina screen) with their size in pixels and their resolution;
- the layout Finder kept, read from the volume's .DS_Store (its B-tree, as Finder writes it): the
  window's bounds and whether its toolbar shows (bwsp), the icon view's options (icvp) — the
  background's kind and the picture it names: the alias's volume name, its folder and file, the
  path inside the volume and the mount point the volume had when Finder made it — and each item's
  place (Iloc);
- whether the picture the layout names is the file in the volume.

Exit 0 when the layout names a picture and that picture is in the volume (and, with --icon-size, keeps
icons of that size; with --no-picture, no picture is asked for), 1 when it does not (no .DS_Store, no
picture named, a picture named that is not there, Finder's own icon size), 2 when the volume cannot be
read.

--compare says, record by record, what differs between two .DS_Store files — the one Finder kept in
the writable image and the read-only image's (make_dmg.sh): CI run 672 on macOS 26 found their bytes
different and every fact read from them the same. For a record that is a property list, which of its
keys differ. Exit 0 when every record is the same, value for value, 1 when one is not, 2 when one of
the files does not read. Standard library only.
"""
import os
import plistlib
import struct
import sys


# --- .DS_Store: a buddy-allocated file holding one B-tree of records (Finder's format) ---

class DSStore:
    def __init__(self, data):
        if len(data) < 36 or data[0:4] != b"\x00\x00\x00\x01" or data[4:8] != b"Bud1":
            raise ValueError("not a .DS_Store (no Bud1 header)")
        self.data = data
        root_offset, root_size, root_offset2 = struct.unpack(">III", data[8:20])
        if root_offset != root_offset2:
            raise ValueError("its header disagrees with itself")
        block = data[4 + root_offset: 4 + root_offset + root_size]
        count, _ = struct.unpack(">II", block[0:8])
        self.addresses = list(struct.unpack(f">{count}I", block[8:8 + 4 * count]))
        position = 8 + 4 * ((count + 255) // 256 * 256)
        (toc_count,) = struct.unpack(">I", block[position:position + 4])
        position += 4
        self.toc = {}
        for _ in range(toc_count):
            length = block[position]
            name = block[position + 1:position + 1 + length].decode("ascii")
            (value,) = struct.unpack(">I", block[position + 1 + length:position + 5 + length])
            self.toc[name] = value
            position += 5 + length
        if "DSDB" not in self.toc:
            raise ValueError("no DSDB in its table of contents")

    def block(self, number):
        address = self.addresses[number]
        offset, size = address & ~0x1F, 1 << (address & 0x1F)
        return self.data[4 + offset: 4 + offset + size]

    def records(self):
        master = self.block(self.toc["DSDB"])
        root, _levels, _records, _nodes, _page = struct.unpack(">IIIII", master[0:20])
        found = []
        self._walk(root, found)
        return found

    def _walk(self, number, found):
        node = self.block(number)
        child, count = struct.unpack(">II", node[0:8])
        position = 8
        for _ in range(count):
            if child:
                (left,) = struct.unpack(">I", node[position:position + 4])
                position += 4
                self._walk(left, found)
            record, position = self._record(node, position)
            found.append(record)
        if child:
            self._walk(child, found)

    @staticmethod
    def _record(node, position):
        (length,) = struct.unpack(">I", node[position:position + 4])
        position += 4
        name = node[position:position + 2 * length].decode("utf-16-be")
        position += 2 * length
        code = node[position:position + 4].decode("latin-1")
        kind = node[position + 4:position + 8].decode("latin-1")
        position += 8
        if kind in ("long", "shor"):
            (value,) = struct.unpack(">I", node[position:position + 4])
            position += 4
        elif kind == "bool":
            value = bool(node[position])
            position += 1
        elif kind == "type":
            value = node[position:position + 4].decode("latin-1")
            position += 4
        elif kind in ("comp", "dutc"):
            (value,) = struct.unpack(">Q", node[position:position + 8])
            position += 8
        elif kind == "blob":
            (size,) = struct.unpack(">I", node[position:position + 4])
            value = node[position + 4:position + 4 + size]
            position += 4 + size
        elif kind == "ustr":
            (size,) = struct.unpack(">I", node[position:position + 4])
            value = node[position + 4:position + 4 + 2 * size].decode("utf-16-be")
            position += 4 + 2 * size
        else:
            raise ValueError(f"a record of an unknown kind {kind!r}")
        return (name, code, kind, value), position


# --- An Alias Manager record (version 2), as Finder keeps the background picture's ---

def read_alias(data):
    """The facts of an alias record: what it names and where its volume was mounted."""
    facts = {}
    if len(data) < 150:
        return {"unreadable": f"{len(data)} bytes"}
    version, kind = struct.unpack(">HH", data[6:10])
    facts["version"] = version
    if version != 2:
        return facts
    facts["kind"] = "folder" if kind == 1 else "file"
    facts["volume"] = data[11:11 + data[10]].decode("mac-roman", "replace")
    facts["file"] = data[51:51 + data[50]].decode("mac-roman", "replace")
    position = 150
    while position + 4 <= len(data):
        tag, length = struct.unpack(">hH", data[position:position + 4])
        if tag == -1:
            break
        value = data[position + 4:position + 4 + length]
        if tag == 0:
            facts["folder"] = value.decode("mac-roman", "replace")
        elif tag == 2:
            facts["carbon path"] = value.decode("mac-roman", "replace")
        elif tag == 18:
            facts["path in the volume"] = value.decode("utf-8", "replace")
        elif tag == 19:
            facts["volume mounted at"] = value.decode("utf-8", "replace")
        position += 4 + length + (length & 1)
    return facts


# --- TIFF: how many pages, and each one's size and resolution ---

def tiff_pages(data):
    if data[0:4] not in (b"II*\x00", b"MM\x00*"):
        raise ValueError("not a TIFF")
    order = "<" if data[0:2] == b"II" else ">"
    (offset,) = struct.unpack(order + "I", data[4:8])
    pages = []
    while offset and len(pages) < 16:
        (count,) = struct.unpack(order + "H", data[offset:offset + 2])
        tags = {}
        for index in range(count):
            entry = data[offset + 2 + 12 * index: offset + 14 + 12 * index]
            tag, kind, number = struct.unpack(order + "HHI", entry[0:8])
            if kind == 3:
                (value,) = struct.unpack(order + "H", entry[8:10])
            elif kind == 4:
                (value,) = struct.unpack(order + "I", entry[8:12])
            elif kind == 5:
                (where,) = struct.unpack(order + "I", entry[8:12])
                top, bottom = struct.unpack(order + "II", data[where:where + 8])
                value = top / bottom if bottom else 0
            else:
                continue
            tags[tag] = value
        pages.append({"width": tags.get(256), "height": tags.get(257), "dpi": tags.get(282)})
        (offset,) = struct.unpack(order + "I", data[offset + 2 + 12 * count: offset + 6 + 12 * count])
    return pages


BACKGROUND_KINDS = {0: "Finder's own (none set)", 1: "a colour", 2: "a picture"}


def compare(kept_path, image_path):
    """What differs between two .DS_Store files, record by record (see --compare above)."""
    try:
        with open(kept_path, "rb") as handle:
            kept = handle.read()
        with open(image_path, "rb") as handle:
            image = handle.read()
        if kept == image:
            print(f"layout facts: the .DS_Store Finder kept is the read-only image's, byte for byte ({len(image)} bytes)")
            return 0
        before, after = DSStore(kept).records(), DSStore(image).records()
    except (OSError, ValueError, struct.error, IndexError) as error:
        print(f"layout facts: the two .DS_Store files cannot be compared ({error})")
        return 2
    keyed_before = {(name, code): (kind, value) for name, code, kind, value in before}
    keyed_after = {(name, code): (kind, value) for name, code, kind, value in after}
    differing = []
    for key in sorted(set(keyed_before) | set(keyed_after)):
        name, code = key
        where = "the window" if name == "." else name
        if key not in keyed_after:
            differing.append(f"{where} {code}: in the one Finder kept, NOT in the image's")
            continue
        if key not in keyed_before:
            differing.append(f"{where} {code}: in the image's, not in the one Finder kept")
            continue
        (kind, old), (new_kind, new) = keyed_before[key], keyed_after[key]
        if (kind, old) == (new_kind, new):
            continue
        said = f"{where} {code} ({kind})"
        if isinstance(old, bytes) and isinstance(new, bytes):
            try:
                old_options, new_options = plistlib.loads(old), plistlib.loads(new)
                keys = sorted(k for k in set(old_options) | set(new_options) if old_options.get(k) != new_options.get(k))
                said += ": its keys " + ", ".join(keys) if keys else ": the same keys and values, written otherwise"
            except Exception:  # noqa: BLE001 - not a property list: its bytes are compared
                changed = sum(1 for a, b in zip(old, new) if a != b) + abs(len(old) - len(new))
                said += f": {changed} of its {len(new)} bytes ({len(old)} in the one Finder kept)"
        else:
            said += f": {old!r} kept, {new!r} in the image"
        differing.append(said)
    changed_bytes = sum(1 for a, b in zip(kept, image) if a != b) + abs(len(kept) - len(image))
    if not differing:
        print(f"layout facts: the .DS_Store Finder kept and the read-only image's differ in {changed_bytes} of "
              f"{len(image)} bytes, outside their records: the same {len(after)} records, value for value")
        return 0
    print(f"layout facts: the .DS_Store Finder kept and the read-only image's differ in {changed_bytes} of "
          f"{len(image)} bytes and in {len(differing)} of their records: " + "; ".join(differing))
    return 1


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("volume", nargs="?")
    parser.add_argument("--icon-size", type=float, help="the icon view's icon size the layout must keep (make_dmg.sh: 128)")
    parser.add_argument("--no-picture", action="store_true", help="no picture is expected (make_dmg.sh --no-picture, the control)")
    parser.add_argument("--compare", nargs=2, metavar=("KEPT", "IMAGE"),
                        help="two .DS_Store files compared record by record (make_dmg.sh)")
    arguments = parser.parse_args()
    if arguments.compare:
        return compare(*arguments.compare)
    if arguments.volume is None:
        parser.error("a mounted volume, or --compare")
    volume = arguments.volume
    if not os.path.isdir(volume):
        print(f"layout facts: {volume} is not a mounted volume")
        return 2
    ok = True
    folder = os.path.join(volume, ".background")
    pictures = sorted(name for name in os.listdir(folder) if not name.startswith(".")) if os.path.isdir(folder) else []
    for name in pictures:
        with open(os.path.join(folder, name), "rb") as handle:
            data = handle.read()
        if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
            width, height = struct.unpack(">II", data[16:24])
            print(f"layout facts: the picture .background/{name} is in the volume, {len(data)} bytes, a PNG of {width}×{height} px")
            continue
        try:
            pages = tiff_pages(data)
            described = "; ".join(f"{p['width']}×{p['height']} px at {p['dpi']:g} dpi" if p["dpi"] else f"{p['width']}×{p['height']} px"
                                  for p in pages)
            print(f"layout facts: the picture .background/{name} is in the volume, {len(data)} bytes, "
                  f"{len(pages)} page(s): {described}")
        except (ValueError, struct.error) as error:
            print(f"layout facts: .background/{name} is in the volume but reads as neither a TIFF nor a PNG ({error})")
            ok = False
    if not pictures:
        print("layout facts: NO picture in the volume (nothing in .background)")
        ok = False

    store_path = os.path.join(volume, ".DS_Store")
    if not os.path.isfile(store_path):
        print("layout facts: NO .DS_Store in the volume — Finder's own window: no layout was kept")
        return 1
    with open(store_path, "rb") as handle:
        store_data = handle.read()
    try:
        records = DSStore(store_data).records()
    except (ValueError, struct.error, IndexError) as error:
        print(f"layout facts: .DS_Store ({len(store_data)} bytes) does not read ({error})")
        return 1
    print(f"layout facts: .DS_Store, {len(store_data)} bytes, {len(records)} record(s)")
    named = None
    icon_size = None
    for name, code, kind, value in records:
        where = "the window" if name == "." else name
        if code == "Iloc" and kind == "blob" and len(value) >= 8:
            x, y = struct.unpack(">II", value[0:8])
            print(f"layout facts: {where} is placed at {x}, {y} (Iloc)")
        elif code in ("bwsp", "icvp", "lsvp", "lsvP") and kind == "blob":
            try:
                options = plistlib.loads(value)
            except Exception as error:  # noqa: BLE001 - a record that does not read is said as such
                print(f"layout facts: {where} {code} does not read as a property list ({error})")
                continue
            if code == "bwsp":
                print(f"layout facts: {where}'s bounds {options.get('WindowBounds')}, toolbar "
                      f"{'shown' if options.get('ShowToolbar') else 'hidden'}, status bar "
                      f"{'shown' if options.get('ShowStatusBar') else 'hidden'} (bwsp)")
            elif code == "icvp":
                kind_number = options.get("backgroundType")
                if name == ".":
                    icon_size = options.get("iconSize")
                print(f"layout facts: {where}'s icon view: icons {options.get('iconSize')} pt, text {options.get('textSize')} pt, "
                      f"arranged by {options.get('arrangeBy')}, background {kind_number} = "
                      f"{BACKGROUND_KINDS.get(kind_number, 'unknown')} (icvp)")
                alias = options.get("backgroundImageAlias")
                if alias is not None:
                    named = read_alias(alias)
                    print("layout facts: the background picture it names (alias): "
                          + ", ".join(f"{key} {value!r}" for key, value in named.items()))
                elif kind_number == 2:
                    print("layout facts: a picture background with NO picture named (no backgroundImageAlias)")
        elif code == "vSrn":
            pass
        else:
            shown = value if not isinstance(value, bytes) else f"{len(value)} bytes"
            print(f"layout facts: {where} {code} {kind} {shown}")
    size_ok = arguments.icon_size is None or icon_size == arguments.icon_size
    if not size_ok:
        print(f"layout facts: the icon view keeps icons of {icon_size} pt, not the {arguments.icon_size:g} asked for: "
              "Finder kept its own view options")
    if arguments.no_picture:
        return 0 if size_ok else 1
    if named is None:
        print("layout facts: the layout names NO background picture: Finder shows its own background")
        return 1
    inside = named.get("path in the volume")
    if inside is not None:
        target = os.path.join(volume, inside.lstrip("/"))
        there = os.path.isfile(target)
        print(f"layout facts: the picture it names, {inside!r} in the volume, is {'there' if there else 'NOT there'}")
        ok = ok and there
    if named.get("volume mounted at") not in (None, "/Volumes/Lumen"):
        print(f"layout facts: when Finder made it the volume was mounted at {named.get('volume mounted at')!r}, not "
              "/Volumes/Lumen (another volume of that name was mounted then)")
    return 0 if ok and size_ok else 1


if __name__ == "__main__":
    sys.exit(main())
