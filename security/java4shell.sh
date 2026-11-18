#!/bin/sh
# @name: Security: Java4Shell check and fix
# @description: Checks every Java runtime for CVE-2026-114938 (OpenJDK Base64 intrinsic, AVX-512 VBMI CPUs), updates OpenJDK packages if affected, then checks again
# Non-interactive, so it also works with nexterm/run-on-folder.sh. Exit code 1 = still affected after the update.

# Last affected build per branch, from Oracle's 17 Nov 2026 advisory (fixed: 17.0.21.1, 21.0.13.1, 25.0.5.1, 27.0.1.1)
FIXED="17.0.21.1 21.0.13.1 25.0.5.1 27.0.1.1"
CVE=114938
FLAG="-XX:-UseBASE64Intrinsics"

[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO="sudo -n"
. /etc/os-release 2>/dev/null
OS="${ID:-unknown}-${VERSION_ID:-}"
if command -v dpkg >/dev/null; then PM=apt
elif command -v apk >/dev/null; then PM=apk
else PM=none; fi

# ge A B: version A >= version B
ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# Only x86-64 CPUs with all four flags can reach the vulnerable code path
cpu_exposed() {
  [ "$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | grep -owE 'avx512f|avx512bw|avx512vbmi|bmi2' | sort -u | wc -l)" -eq 4 ]
}

# Every java binary: installed JDKs, bundled ones under /opt etc., and the ones running right now
java_bins() {
  {
    for d in /usr/lib/jvm /opt /usr/local /srv /home /root /var/lib /app; do
      [ -d "$d" ] && find "$d" -xdev -path '*/bin/java' -type f 2>/dev/null
    done
    for p in /proc/[0-9]*; do
      e=$(readlink "$p/exe" 2>/dev/null) || continue
      case "$e" in */bin/java|*/bin/java" (deleted)") echo "${e% (deleted)}" ;; esac
    done
  } | while read -r j; do readlink -f "$j" 2>/dev/null || echo "$j"; done | sort -u
}

# Version of a java binary: from the release file next to it, else by running it
java_version() {
  v=$(sed -n 's/^JAVA_RUNTIME_VERSION="\([^"+]*\).*/\1/p; s/^JAVA_VERSION="\([^"]*\)"/\1/p' "${1%/bin/java}/release" 2>/dev/null | head -n1)
  [ -n "$v" ] || v=$("$1" -version 2>&1 | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -n1)
  echo "${v%%[-+_]*}"
}

# Debian/Ubuntu backport fixes keep the version, so look for the CVE in the package changelog
patched_package() {
  [ "$PM" = apt ] || return 1
  pkg=$(dpkg -S "$1" 2>/dev/null | head -n1 | cut -d: -f1) || return 1
  [ -n "$pkg" ] && zgrep -q "$CVE" "/usr/share/doc/$pkg/changelog.Debian.gz" 2>/dev/null
}

# Running JVMs of this binary that have the workaround flag (command line or JAVA_TOOL_OPTIONS)
mitigated() {
  any=0
  for p in /proc/[0-9]*; do
    e=$(readlink "$p/exe" 2>/dev/null) || continue
    [ "$(readlink -f "${e% (deleted)}" 2>/dev/null)" = "$1" ] || continue
    any=1
    tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q -- "$FLAG" && continue
    tr '\0' '\n' < "$p/environ" 2>/dev/null | grep -q "^JAVA_TOOL_OPTIONS=.*$FLAG" && continue
    return 1
  done
  [ "$any" -eq 1 ]
}

check() {
  BAD=0; WARN=0; FOUND=0
  if cpu_exposed; then echo "  INFO  CPU has AVX-512 VBMI, the vulnerable path is reachable"; EXPOSED=1
  else echo "  INFO  CPU lacks AVX-512 VBMI (or isn't x86-64), the vulnerable path can't run here"; EXPOSED=0; fi
  for j in $(java_bins); do
    FOUND=1
    v=$(java_version "$j"); major=${v%%.*}; [ "$major" = 1 ] && major=8
    fixed=$(for f in $FIXED; do case $f in "$major".*) echo "$f" ;; esac; done)
    if [ -z "$v" ]; then st="WARN"; why="version unknown"
    elif [ "$major" -lt 17 ] 2>/dev/null; then st="OK"; why="Java $major isn't affected"
    elif [ "$major" -eq 17 ] && ! ge "$v" 17.0.6; then st="OK"; why="before 17.0.6, no intrinsic yet"
    elif [ -n "$fixed" ] && ge "$v" "$fixed"; then st="OK"; why="fixed"
    elif patched_package "$j"; then st="OK"; why="backported fix"
    elif [ -z "$fixed" ]; then st="BAD"; why="end-of-life branch, move to 17, 21 or 25"
    else st="BAD"; why="fixed in $fixed"; fi
    if [ "$st" = BAD ] && [ "$EXPOSED" -eq 0 ]; then st="WARN"; why="$why (not exploitable on this CPU)"
    elif [ "$st" = BAD ] && mitigated "$j"; then st="WARN"; why="$why, running with $FLAG"; fi
    case $st in BAD) BAD=$((BAD + 1)) ;; WARN) WARN=$((WARN + 1)) ;; esac
    printf '  %-5s Java %s %s: %s\n' "$st" "${v:-?}" "$j" "$why"
  done
  [ "$FOUND" -eq 1 ] || echo "  OK    no Java runtime found"
  # A JVM started before an update keeps running the old, deleted binary
  for p in /proc/[0-9]*; do
    e=$(readlink "$p/exe" 2>/dev/null) || continue
    case "$e" in *"/bin/java (deleted)") echo "  WARN  PID ${p#/proc/} still runs the old Java, restart it"; WARN=$((WARN + 1)) ;; esac
  done
}

remediate() {
  if [ "$PM" = apt ]; then
    pkgs=$(dpkg-query -W -f '${Package} ${db:Status-Status}\n' 'openjdk-*' 'temurin-*' 2>/dev/null | awk '$2 == "installed" { print $1 }' | tr '\n' ' ')
    [ -n "$pkgs" ] || { echo "  no OpenJDK packages, bundled runtimes need an update of their app"; return; }
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    # shellcheck disable=SC2086
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $pkgs
  elif [ "$PM" = apk ]; then
    $SUDO apk update -q
    # shellcheck disable=SC2046
    $SUDO apk upgrade -q $(apk info 2>/dev/null | grep '^openjdk[0-9]')
  fi
}

echo "== $(hostname) ($OS): Java4Shell check"
check
if [ "$BAD" -eq 0 ]; then
  echo "== nothing to fix (${WARN} warning(s))"
  exit 0
fi
echo "== updating Java packages"
remediate 2>&1 | grep -E "^  |^(E|W):|ERROR" || true
echo "== check again"
check
if [ "$BAD" -eq 0 ]; then
  echo "== fixed (${WARN} warning(s)), restart your Java services"
  exit 0
fi
echo "== still affected: $BAD issue(s)"
echo "   Until a fixed build is out, start the affected JVMs with $FLAG and restart them,"
echo "   e.g. Environment=JAVA_TOOL_OPTIONS=$FLAG in the systemd unit, or the app's JVM arguments."
exit 1
