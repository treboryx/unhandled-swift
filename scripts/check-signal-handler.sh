#!/usr/bin/env bash
# Fails when the signal handler, or any Unhandled function it reaches, can allocate, retain or run lazy initialization.
set -euo pipefail

package="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${UNHANDLED_SIGNAL_CHECK_BUILD:-/tmp/unhandled-swift-signal-check}"
swift="${SWIFT:-/usr/bin/swift}"

"$swift" build --package-path "$package" --scratch-path "$scratch" -c release --arch arm64 >/dev/null

objects=()
while IFS= read -r object; do objects+=("$object"); done < <(
    find "$scratch" -path '*Release*' -path '*Unhandled*' -path '*Objects-normal/arm64/*' -name '*.o' 2>/dev/null
    find "$scratch" -path '*release/Unhandled.build/*' -name '*.o' 2>/dev/null
)
if [ "${#objects[@]}" -eq 0 ]; then
    echo "check-signal-handler: no release objects for the Unhandled module under $scratch" >&2
    exit 1
fi

roots="$(nm -j -U "${objects[@]}" 2>/dev/null | grep '12handleSignal' | sort -u || true)"
if [ -z "$roots" ]; then
    echo "check-signal-handler: nm finds no handleSignal symbol in the release objects" >&2
    exit 1
fi
export SIGNAL_HANDLER_ROOTS="$roots"

for object in "${objects[@]}"; do
    echo "@@object $object"
    xcrun llvm-objdump --disassemble --reloc --no-show-raw-insn "$object"
done | python3 -I -c '
import os, re, subprocess, sys

forbidden_exact = ("_malloc", "_calloc", "_realloc", "_free")
forbidden_prefixes = (
    "_swift_once", "_swift_allocObject", "_swift_allocBox", "_swift_slowAlloc", "_swift_retain", "_swift_release",
    "_swift_bridgeObjectRetain", "_swift_bridgeObjectRelease", "_objc_",
)

def is_forbidden(name):
    return name in forbidden_exact or name.startswith(forbidden_prefixes)

header = re.compile(r"^[0-9a-f]+ <(.+)>:$")
relocation = re.compile(r"ARM64_RELOC_\w+\s+(\S+)")
branch = re.compile(r"\s(?:bl|b)\s+0x[0-9a-f]+ <([^>+]+)")

# objdump labels a function that shares its address with a section label (ltmp0) by that label, so nm names it.
def text_symbols(path):
    names = {}
    for entry in subprocess.run(["nm", "-n", "-U", path], capture_output=True, text=True, check=True).stdout.splitlines():
        fields = entry.split(maxsplit=2)
        if len(fields) == 3 and fields[1] in ("t", "T"):
            address, _, name = fields
            names.setdefault(int(address, 16), []).append(name)
    return names

functions = {}
current = None
aliases = {}
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("@@object "):
        aliases = text_symbols(line[len("@@object "):])
        current = None
        continue
    match = header.match(line)
    if match:
        address = int(line.split()[0], 16)
        current = set()
        for name in [match.group(1)] + aliases.get(address, []):
            if not name.startswith(("ltmp", "l_")):
                functions[name] = current
        continue
    if current is None:
        continue
    for pattern in (relocation, branch):
        found = pattern.search(line)
        if found:
            current.add(found.group(1))

roots = sorted(set(os.environ["SIGNAL_HANDLER_ROOTS"].split()))
missing = [name for name in roots if name not in functions]
if missing:
    sys.exit("check-signal-handler: no disassembly for " + ", ".join(missing))

seen, queue, failures = set(), list(roots), []
while queue:
    name = queue.pop()
    if name in seen:
        continue
    seen.add(name)
    for target in sorted(functions.get(name, ())):
        if is_forbidden(target):
            failures.append(f"{name} -> {target}")
        elif target in functions and target not in seen:
            queue.append(target)

external = sorted({t for name in seen for t in functions[name] if t not in functions and not t.startswith(("ltmp", "l_", "lCPI", "_$s9Unhandled"))})
print("reachable from the signal handler:")
for name in sorted(seen):
    print(f"  {name}")
print("external references: " + ", ".join(external))
if failures:
    print("FAIL: the signal handler reaches forbidden runtime calls:")
    for failure in failures:
        print(f"  {failure}")
    sys.exit(1)
print("OK: nothing matching " + ", ".join(forbidden_exact + tuple(p + "*" for p in forbidden_prefixes)) + " is reachable from the signal handler")
'
