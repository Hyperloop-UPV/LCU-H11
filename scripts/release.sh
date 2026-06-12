#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    cat <<EOF
Usage: $0 [version]

Generate an LCU firmware release tarball containing pre-built ELF binaries
and the full source tree (minus build artifacts and STM32CubeH7 bloat).

If version is omitted, a timestamp is used (YYYYMMDD-HHMMSS).

Builds 6 targets:
  LCU-Master-H11: board-release-eth-lan8700-{1,3,5}dof
  LCU-Slave-H11:  board-release-{1,3,5}dof
EOF
    exit 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
fi

VERSION="${1:-$(date +%Y%m%d-%H%M%S)}"
RELEASE_NAME="lcu-release-${VERSION}"
RELEASE_DIR="/tmp/lcu-release/${RELEASE_NAME}"
BUILDS_DIR="${RELEASE_DIR}/builds"
SRC_DIR="${RELEASE_DIR}/src"
EXCLUDE_FILE="${RELEASE_DIR}/.rsync-exclude"

# ─── checks ───
for tool in arm-none-eabi-gcc cmake ninja uv; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found in PATH" >&2; exit 1; }
done

# clean up any previous attempt
rm -rf "$RELEASE_DIR"

# ─── presets to build ───
PRESETS=(
    "LCU-Master-H11:board-release-eth-lan8700-1dof"
    "LCU-Master-H11:board-release-eth-lan8700-3dof"
    "LCU-Master-H11:board-release-eth-lan8700-5dof"
    "LCU-Slave-H11:board-release-1dof"
    "LCU-Slave-H11:board-release-3dof"
    "LCU-Slave-H11:board-release-5dof"
)

# ─── helpers ───
log()  { echo "  [$1] $2"; }
fail() { echo "ERROR: $1" >&2; exit 1; }
git_sha() { git -C "$ROOT_DIR/$1" rev-parse HEAD; }

# ─── setup python envs ───
echo "=== Setting up Python environments ==="
for board in LCU-Master-H11 LCU-Slave-H11; do
    board_dir="${ROOT_DIR}/${board}"
    venv_dir="${board_dir}/virtual"
    if [ -f "${venv_dir}/bin/python" ]; then
        log "$board" "venv already exists"
    else
        log "$board" "creating venv with uv"
        uv venv "$venv_dir" --quiet
    fi
    VIRTUAL_ENV="$venv_dir" uv pip install -r "${board_dir}/requirements.txt" --quiet
done

# ─── clean previous builds ───
echo "=== Cleaning previous builds ==="
rm -rf "${ROOT_DIR}/LCU-Master-H11/out" "${ROOT_DIR}/LCU-Slave-H11/out"

# ─── build all presets ───
echo "=== Building ${#PRESETS[@]} targets ==="
mkdir -p "$BUILDS_DIR"

for entry in "${PRESETS[@]}"; do
    board="${entry%%:*}"
    preset="${entry#*:}"
    board_dir="${ROOT_DIR}/${board}"
    out_elf="${board_dir}/out/build/latest.elf"
    dest_dir="${BUILDS_DIR}/${board}/${preset}"
    dest_elf="${dest_dir}/firmware.elf"

    log "$board" "configuring $preset"
    ( cd "$board_dir" && cmake --preset "$preset" ) >/dev/null \
        || fail "cmake configure failed for $board::$preset"

    log "$board" "building $preset"
    ( cd "$board_dir" && cmake --build --preset "$preset" -j"$(nproc)" ) >/dev/null \
        || fail "cmake build failed for $board::$preset"

    [ -f "$out_elf" ] || fail "ELF not produced: $out_elf"

    mkdir -p "$dest_dir"
    cp "$out_elf" "$dest_elf"
    log "$board" "-> $dest_elf"
done

# ─── collect git info ───
MASTER_SHA="$(git_sha LCU-Master-H11)"
SLAVE_SHA="$(git_sha LCU-Slave-H11)"
TOOLCHAIN_VER="$(arm-none-eabi-gcc --version | head -1)"

# ─── copy source tree ───
echo "=== Copying source tree ==="
mkdir -p "$SRC_DIR"

cat > "$EXCLUDE_FILE" <<'RSYNCEOF'
# build artifacts
.git/
out/
build/
virtual/
__pycache__/
*.pyc
*.pyo
compile_commands.json
.cache/
CMakeCache.txt
CMakeFiles/
CMakeUserPresets.json

# generated sources (regenerated at cmake configure)
Core/Inc/Communications/Packets/DataPackets.hpp
Core/Inc/Communications/Packets/OrderPackets.hpp
Core/Src/Runes/generated_metadata.cpp

# STM32CubeH7 bloat (identical patterns for both Master and Slave)
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Projects/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Utilities/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Documentation/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/_htmresc/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Drivers/CMSIS/DSP/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Drivers/CMSIS/docs/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Drivers/CMSIS/Core/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Drivers/CMSIS/Core_A/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Drivers/CMSIS/NN/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Drivers/CMSIS/RTOS/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Drivers/CMSIS/RTOS2/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Drivers/BSP/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Middlewares/Third_Party/FreeRTOS/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Middlewares/Third_Party/mbedTLS/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Middlewares/Third_Party/FatFs/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Middlewares/Third_Party/OpenAMP/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Middlewares/Third_Party/LibJPEG/
LCU-Master-H11/deps/ST-LIB/STM32CubeH7/Middlewares/ST/

LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Projects/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Utilities/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Documentation/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/_htmresc/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Drivers/CMSIS/DSP/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Drivers/CMSIS/docs/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Drivers/CMSIS/Core/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Drivers/CMSIS/Core_A/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Drivers/CMSIS/NN/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Drivers/CMSIS/RTOS/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Drivers/CMSIS/RTOS2/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Drivers/BSP/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Middlewares/Third_Party/FreeRTOS/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Middlewares/Third_Party/mbedTLS/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Middlewares/Third_Party/FatFs/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Middlewares/Third_Party/OpenAMP/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Middlewares/Third_Party/LibJPEG/
LCU-Slave-H11/deps/ST-LIB/STM32CubeH7/Middlewares/ST/
RSYNCEOF

rsync -a --exclude-from="$EXCLUDE_FILE" "${ROOT_DIR}/" "$SRC_DIR/"

# BSP/Components/lan8742 was excluded wholesale; copy it back
for board in LCU-Master-H11 LCU-Slave-H11; do
    lan8742_src="${ROOT_DIR}/${board}/deps/ST-LIB/STM32CubeH7/Drivers/BSP/Components/lan8742"
    if [ -d "$lan8742_src" ]; then
        lan8742_dst="${SRC_DIR}/${board}/deps/ST-LIB/STM32CubeH7/Drivers/BSP/Components/lan8742"
        mkdir -p "$(dirname "$lan8742_dst")"
        cp -r "$lan8742_src" "$lan8742_dst"
    fi
done

rm -f "$EXCLUDE_FILE"

# copy adj dirs to top-level for convenience
echo "=== Copying adj configs ==="
mkdir -p "${RELEASE_DIR}/adj"
for dof in 1DOF 3DOF 5DOF; do
    adj_src="${ROOT_DIR}/LCU-Master-H11/deps/adj_${dof}"
    if [ -d "$adj_src" ]; then
        cp -r "$adj_src" "${RELEASE_DIR}/adj/adj_${dof}"
        log "adj" "adj_${dof}"
    fi
done

# ─── manifest ───
echo "=== Generating manifest ==="
cat > "${RELEASE_DIR}/manifest.json" <<MANIFESTEOF
{
    "version": "${VERSION}",
    "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "toolchain": "${TOOLCHAIN_VER}",
    "boards": {
        "LCU-Master-H11": {
            "git_sha": "${MASTER_SHA}",
            "presets": [
                "board-release-eth-lan8700-1dof",
                "board-release-eth-lan8700-3dof",
                "board-release-eth-lan8700-5dof"
            ]
        },
        "LCU-Slave-H11": {
            "git_sha": "${SLAVE_SHA}",
            "presets": [
                "board-release-1dof",
                "board-release-3dof",
                "board-release-5dof"
            ]
        }
    },
    "files": {
        "LCU-Master-H11": {
            "board-release-eth-lan8700-1dof": "builds/LCU-Master-H11/board-release-eth-lan8700-1dof/firmware.elf",
            "board-release-eth-lan8700-3dof": "builds/LCU-Master-H11/board-release-eth-lan8700-3dof/firmware.elf",
            "board-release-eth-lan8700-5dof": "builds/LCU-Master-H11/board-release-eth-lan8700-5dof/firmware.elf"
        },
        "LCU-Slave-H11": {
            "board-release-1dof": "builds/LCU-Slave-H11/board-release-1dof/firmware.elf",
            "board-release-3dof": "builds/LCU-Slave-H11/board-release-3dof/firmware.elf",
            "board-release-5dof": "builds/LCU-Slave-H11/board-release-5dof/firmware.elf"
        }
    }
}
MANIFESTEOF

# ─── flash helper ───
echo "=== Generating flash helper ==="
cat > "${RELEASE_DIR}/flash.sh" <<'FLASHEOF'
#!/usr/bin/env bash
set -euo pipefail

RELEASE_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${RELEASE_DIR}/manifest.json"

usage() {
    echo "Usage: $0 <board> <dof>"
    echo "  board: master | slave"
    echo "  dof:   1 | 3 | 5"
    exit 1
}

[ $# -eq 2 ] || usage

BOARD_INPUT="$1"
DOF="$2"

case "$BOARD_INPUT" in
    master) BOARD="LCU-Master-H11"
            PRESET="board-release-eth-lan8700-${DOF}dof" ;;
    slave)  BOARD="LCU-Slave-H11"
            PRESET="board-release-${DOF}dof" ;;
    *)      usage ;;
esac

case "$DOF" in
    1|3|5) ;;
    *) usage ;;
esac

ELF="${RELEASE_DIR}/builds/${BOARD}/${PRESET}/firmware.elf"

[ -f "$ELF" ] || { echo "ERROR: ELF not found: $ELF" >&2; exit 1; }

echo "Flashing ${BOARD} ${PRESET}..."
echo "ELF: ${ELF}"

if command -v STM32_Programmer_CLI >/dev/null 2>&1; then
    STM32_Programmer_CLI -c port=SWD mode=UR -w "$ELF" -rst
elif command -v openocd >/dev/null 2>&1; then
    echo "WARNING: OpenOCD requires stlink.cfg and stm32h7x.cfg in .vscode/"
    echo "Run: openocd -f .vscode/stlink.cfg -f .vscode/stm32h7x.cfg -c \"program ${ELF} verify reset exit\""
    exit 1
else
    echo "ERROR: No flash tool found (STM32_Programmer_CLI or openocd)" >&2
    exit 1
fi
FLASHEOF
chmod +x "${RELEASE_DIR}/flash.sh"

# ─── pack ───
echo "=== Packing ==="
ARCHIVE="${ROOT_DIR}/${RELEASE_NAME}.tar.gz"
tar czf "$ARCHIVE" -C "/tmp/lcu-release" "$RELEASE_NAME"
echo "=== Done: ${ARCHIVE} ==="
du -sh "$ARCHIVE"
