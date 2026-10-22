#!/bin/sh
# @name: PHP2Shell check and fix
# @description: Checks installed PHP for CVE-2026-109618/109619, updates PHP and restarts php-fpm/apache2 if affected, then checks again
# Non-interactive, so it also works with nexterm/run-on-folder.sh. Exit code 1 = still affected after the update.

PHP_FIXED="8.2.35 8.3.36 8.4.27 8.5.12"

[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO="sudo -n"
. /etc/os-release 2>/dev/null
OS="${ID:-unknown}-${VERSION_ID:-}"
if command -v dpkg >/dev/null; then PM=apt
elif command -v apk >/dev/null; then PM=apk
else echo "$(hostname): unsupported system ($OS), nothing checked"; exit 0; fi

# ge A B: version A >= version B
ge() { if [ "$PM" = apt ]; then dpkg --compare-versions "$1" ge "$2"; else [ "$(apk version -t "$1" "$2")" != "<" ]; fi; }

# Fixed distro revisions where the upstream version string stays old (backports)
php_distro_fixed() {
  case "$OS:$1" in
    debian-12:8.2) echo 8.2.35-1~deb12u1 ;;   debian-13:8.4) echo 8.4.27-1~deb13u1 ;;
    ubuntu-22.04:8.1) echo 8.1.2-1ubuntu2.28 ;; ubuntu-24.04:8.3) echo 8.3.6-0ubuntu0.24.04.13 ;;
    ubuntu-26.04:8.5) echo 8.5.4-0ubuntu1.5 ;; ubuntu-26.10:8.5) echo 8.5.9-0ubuntu2.1 ;;
  esac
}

# Prints "branch version" for each installed PHP
php_installed() {
  if [ "$PM" = apt ]; then
    dpkg-query -W -f '${Package} ${Version} ${db:Status-Status}\n' 'php*-common' 2>/dev/null \
      | awk '$1 ~ /^php[0-9]+\.[0-9]+-common$/ && $3 == "installed" { sub(/^php/, "", $1); sub(/-common$/, "", $1); print $1, $2 }'
  else
    apk info -v 2>/dev/null | sed -n 's/^php\([0-9]\)\([0-9]\)-\([0-9][^ ]*\)$/\1.\2 \3/p'
  fi
}

check() {
  BAD=0; WARN=0
  for line in $(php_installed | tr ' ' '|'); do
    br=${line%%|*}; ver=${line#*|}
    up=${ver#*:}; up=${up%%[-+]*}
    fixed_up=$(for f in $PHP_FIXED; do case $f in "$br".*) echo "$f" ;; esac; done)
    distro=$(php_distro_fixed "$br")
    if [ -n "$fixed_up" ] && ge "$up" "$fixed_up"; then echo "  OK    PHP $br ($ver)"
    elif [ -n "$distro" ] && ge "$ver" "$distro"; then echo "  OK    PHP $br ($ver, backported fix)"
    elif [ -z "$fixed_up" ] && [ -z "$distro" ]; then echo "  WARN  PHP $br ($ver): no known fixed version, check your package source"; WARN=$((WARN + 1))
    else echo "  BAD   PHP $br ($ver)"; BAD=$((BAD + 1)); fi
  done
}

remediate() {
  if [ "$PM" = apt ]; then
    pkgs=$(dpkg-query -W -f '${Package} ${db:Status-Status}\n' 'php*' 'libapache2-mod-php*' 2>/dev/null | awk '$2 == "installed" { print $1 }' | tr '\n' ' ')
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    # shellcheck disable=SC2086
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $pkgs
    for s in $(systemctl list-units --type=service --all --no-legend --plain 'php*-fpm*' 2>/dev/null | awk '{ print $1 }'); do
      $SUDO systemctl try-restart "$s" && echo "  restarted $s"
    done
    if dpkg-query -W -f '${db:Status-Status}' 'libapache2-mod-php*' 2>/dev/null | grep -q installed; then
      $SUDO systemctl try-restart apache2 && echo "  restarted apache2"
    fi
  else
    $SUDO apk update -q
    # shellcheck disable=SC2046
    $SUDO apk upgrade -q $(apk info 2>/dev/null | grep '^php[0-9]')
    for s in /etc/init.d/php-fpm*; do [ -e "$s" ] && $SUDO rc-service "${s##*/}" restart >/dev/null 2>&1 && echo "  restarted ${s##*/}"; done
  fi
}

echo "== $(hostname) ($OS): PHP2Shell check"
if [ -z "$(php_installed)" ]; then echo "== PHP not installed, nothing to do"; exit 0; fi
check
if [ "$BAD" -eq 0 ]; then
  echo "== nothing to fix (${WARN} warning(s))"
  exit 0
fi
echo "== updating PHP"
remediate 2>&1 | grep -E "restarted|^(E|W):|ERROR" || true
echo "== check again"
check
[ "$BAD" -eq 0 ] && echo "== fixed (${WARN} warning(s))" || { echo "== still affected: $BAD issue(s)"; exit 1; }
