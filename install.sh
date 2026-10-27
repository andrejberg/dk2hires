#!/usr/bin/env bash
# install.sh - dk2hires (DK2-Hochaufloesungs-Fix) in eine Wine-/Proton-Installation einspielen.
# Ablauf und Rueckbau: README.md.
#
#   ./install.sh --res BREITExHOEHE [--game-dir DIR] [--prefix DIR] [--lutris DIR] [--state-dir DIR] [--dry-run]
#
# --lutris DIR: GOG-Fassung ueber Lutris (umu/Proton); DIR ist der Wine-Prefix des Spiels,
# z. B. ~/Games/gog/dungeon-keeper-2. Spielordner ist dann DIR/drive_c/GOG Games/Dungeon Keeper 2.
#
# Fuegt im Spielordner zwei Dateien hinzu (dsound.dll, dk2hires.ini) und setzt im Wine-Prefix
# (Textdatei user.reg, ohne Wine zu starten):
#   HKCU\Software\Wine\AppDefaults\DKII-DX.exe\DllOverrides  "dsound"="native,builtin"
#   HKCU\Software\Bullfrog Productions Ltd\Dungeon Keeper II\Configuration\Video  Screen Width/Height
# Vorher werden user.reg, die alten Werte und ein SHA-256-Manifest des Spielordners gesichert.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GAME_DIR="$HOME/Games/Heroic/Dungeon Keeper 2"                  # Heroic-Standard
PREFIX="$HOME/Games/Heroic/Prefixes/default/Dungeon Keeper 2"   # Heroic-Standard
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dk2hires"
RES=""
DRY=0
NOPROC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --res) RES="$2"; shift 2;;
    --game-dir) GAME_DIR="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --lutris) PREFIX="${2%/}"; GAME_DIR="$PREFIX/drive_c/GOG Games/Dungeon Keeper 2"; shift 2;;
    --state-dir) STATE_DIR="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    --no-process-check) NOPROC=1; shift;;   # nur fuer Tests gegen Kopien, nie fuer die echte Installation
    *) echo "unbekannte Option: $1"; exit 2;;
  esac
done

[ -n "$RES" ] || { echo "Bitte die Aufloesung angeben, z. B. --res 3840x2160"; exit 2; }
W="${RES%x*}"; H="${RES#*x}"
[[ "$W" =~ ^[0-9]+$ && "$H" =~ ^[0-9]+$ ]] || { echo "Aufloesung bitte als BREITExHOEHE, z. B. 3840x2160"; exit 2; }

EXE_SHA="a5957e8c52b6dee80ddf6cc1d3ea5079aaaad4d11b40e0f067d34ff4157ce9bb"   # DKII-DX.exe, GOG 1.7
PATCH_SHA="0022e3aaf419f22c3287fb454e9e671ee249f1eefc652465bec96ecfd38f00c4" # patch.dll (GOG)
DLL_SRC="$HERE/dsound.dll"
INI_SRC="$HERE/dk2hires.ini"
REG="$PREFIX/user.reg"
REGPY=(python3 -I "$HERE/dk2reg.py")
KEY_OVR='Software\Wine\AppDefaults\DKII-DX.exe\DllOverrides'
KEY_VID='Software\Bullfrog Productions Ltd\Dungeon Keeper II\Configuration\Video'

say() { printf '%s\n' "$*"; }
run() { if [ "$DRY" = 1 ]; then say "  (dry-run) $*"; else "$@"; fi; }
# Laeuft DK2 oder ein Wine-Prozess dieses Prefix? Unter Proton steht in WINEPREFIX "<Prefix>/pfx/".
check_running() {
  local p arg envpfx want="${PREFIX%/}"
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$$" ] && continue
    while IFS= read -r -d '' arg; do
      case "${arg,,}" in *dkii*.exe) say "FEHLER: Dungeon Keeper 2 laeuft noch (PID ${p#/proc/}). Bitte beenden."; exit 1;; esac
    done < <(cat "$p/cmdline" 2>/dev/null || true)
    envpfx="$( { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | sed -n 's/^WINEPREFIX=//p' || true)"
    envpfx="${envpfx%/}"; envpfx="${envpfx%/pfx}"
    if [ -n "$envpfx" ] && [ "$envpfx" = "$want" ]; then
      say "FEHLER: Im Prefix laeuft noch ein Wine-Prozess (PID ${p#/proc/}). Bitte warten oder beenden."; exit 1
    fi
  done
}

say "== dk2hires install: Spielordner '$GAME_DIR', Prefix '$PREFIX', Aufloesung ${W}x${H}"

# 1. Voraussetzungen
[ -f "$GAME_DIR/DKII-DX.exe" ] || { say "FEHLER: $GAME_DIR/DKII-DX.exe nicht gefunden (anderer Spielordner: --game-dir DIR)"; exit 1; }
[ -f "$REG" ] || { say "FEHLER: $REG nicht gefunden (anderes Prefix: --prefix DIR, der Ordner mit user.reg; das Spiel vorher einmal starten)"; exit 1; }
[ -f "$DLL_SRC" ] || { say "FEHLER: $DLL_SRC fehlt (src/build.sh baut sie)"; exit 1; }
[ "$(sha256sum < "$GAME_DIR/DKII-DX.exe" | cut -d' ' -f1)" = "$EXE_SHA" ] || { say "FEHLER: DKII-DX.exe ist nicht die erwartete GOG-1.7-Fassung"; exit 1; }
[ "$(sha256sum < "$GAME_DIR/patch.dll" | cut -d' ' -f1)" = "$PATCH_SHA" ] || { say "FEHLER: patch.dll weicht von der GOG-Fassung ab"; exit 1; }
[ "$NOPROC" = 1 ] || check_running
if [ -e "$GAME_DIR/dsound.dll" ]; then
  if cmp -s "$GAME_DIR/dsound.dll" "$DLL_SRC"; then say "Hinweis: dsound.dll ist schon installiert (identisch)."
  else say "FEHLER: Im Spielordner liegt schon eine fremde dsound.dll. Abbruch."; exit 1; fi
fi
if [ -f "$STATE_DIR/state.env" ] && [ "$DRY" = 0 ]; then
  say "FEHLER: $STATE_DIR/state.env existiert, dk2hires ist laut Protokoll schon installiert. Erst uninstall.sh."; exit 1
fi

# 2. Sicherungen
TS="$(date +%Y%m%d-%H%M%S)"
run mkdir -p "$STATE_DIR"
say "-- Manifest des Spielordners und Sicherung von user.reg nach $STATE_DIR"
if [ "$DRY" = 0 ]; then
  (cd "$GAME_DIR" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$STATE_DIR/manifest-before.sha256"
  cp -p "$REG" "$STATE_DIR/user.reg.before-$TS"
fi
OLD_W="$("${REGPY[@]}" get "$REG" "$KEY_VID" "Screen Width" || true)"
OLD_H="$("${REGPY[@]}" get "$REG" "$KEY_VID" "Screen Height" || true)"
OLD_OVR="$("${REGPY[@]}" get "$REG" "$KEY_OVR" "dsound" || true)"
say "   bisher: Screen Width=${OLD_W:-<fehlt>} Screen Height=${OLD_H:-<fehlt>} dsound-Override=${OLD_OVR:-<fehlt>}"
if [ "$DRY" = 0 ]; then
  {
    printf 'INSTALLED_AT=%q\n' "$TS"
    printf 'GAME_DIR=%q\nPREFIX=%q\n' "$GAME_DIR" "$PREFIX"
    printf 'OLD_W=%q\nOLD_H=%q\nOLD_OVR=%q\n' "$OLD_W" "$OLD_H" "$OLD_OVR"
    printf 'DLL_SHA=%q\n' "$(sha256sum < "$DLL_SRC" | cut -d' ' -f1)"
    printf 'REG_BACKUP=%q\n' "$STATE_DIR/user.reg.before-$TS"
  } > "$STATE_DIR/state.env"
fi

# 3. Dateien in den Spielordner
say "-- Dateien kopieren"
run install -m 0644 "$DLL_SRC" "$GAME_DIR/dsound.dll"
[ -f "$INI_SRC" ] && run install -m 0644 "$INI_SRC" "$GAME_DIR/dk2hires.ini"

# 4. Registry im Prefix
say "-- Registry setzen"
run "${REGPY[@]}" set "$REG" "$KEY_OVR" "dsound" '"native,builtin"'
run "${REGPY[@]}" set "$REG" "$KEY_VID" "Screen Width" "$(printf 'dword:%08x' "$W")"
run "${REGPY[@]}" set "$REG" "$KEY_VID" "Screen Height" "$(printf 'dword:%08x' "$H")"

# 5. Kontrolle
if [ "$DRY" = 0 ]; then
  say "-- Kontrolle"
  say "   Screen Width=$("${REGPY[@]}" get "$REG" "$KEY_VID" "Screen Width")  Screen Height=$("${REGPY[@]}" get "$REG" "$KEY_VID" "Screen Height")  dsound=$("${REGPY[@]}" get "$REG" "$KEY_OVR" "dsound")"
  (cd "$GAME_DIR" && sha256sum --quiet -c "$STATE_DIR/manifest-before.sha256") && say "   Originaldateien unveraendert (Manifest ok)."
  say "   neu im Spielordner: $(cd "$GAME_DIR" && ls dsound.dll dk2hires.ini 2>/dev/null | tr '\n' ' ')"
fi
say "== fertig. Spiel starten; Protokoll: $GAME_DIR/dk2hires.log"
