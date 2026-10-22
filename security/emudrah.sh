#!/bin/sh
# @name: eMudhra trust check and fix
# @description: Checks ca-certificates and CA bundles (system, certifi, pip, Node) for the compromised eMudhra roots, updates if affected, then checks again
# Non-interactive, so it also works with nexterm/run-on-folder.sh. Exit code 1 = still affected after the update.

# Roots that chain to the compromised eMudhra intermediates
BAD_ROOTS='(emSign (ECC Root CA|Root TLS CA|Root CS CA) - G3|AAA Certificate Services)'
TEST_URL="https://dv-g3b-emudhra.we-have-a-problem.com/"

[ "$(id -u)" -eq 0 ] && SUDO="" || SUDO="sudo -n"
. /etc/os-release 2>/dev/null
OS="${ID:-unknown}-${VERSION_ID:-}"
if command -v dpkg >/dev/null; then PM=apt
elif command -v apk >/dev/null; then PM=apk
else echo "$(hostname): unsupported system ($OS), nothing checked"; exit 0; fi

# ge A B: version A >= version B
ge() { if [ "$PM" = apt ]; then dpkg --compare-versions "$1" ge "$2"; else [ "$(apk version -t "$1" "$2")" != "<" ]; fi; }

ca_fixed() {
  case "$OS" in
    debian-12) echo 20250419~deb12u2 ;; debian-13) echo 20250419+deb13u1 ;; debian-*) echo 20260816+nmu1 ;;
    ubuntu-*) echo "20260816ubuntu0.${VERSION_ID}.1" ;; alpine-*) echo 20261020-r0 ;;
  esac
}

# Counts compromised roots in a PEM bundle ("?" if it can't be inspected)
bad_roots() {
  if command -v openssl >/dev/null; then
    openssl crl2pkcs7 -nocrl -certfile "$1" 2>/dev/null | openssl pkcs7 -print_certs -noout 2>/dev/null \
      | grep -cE "^subject=.*CN ?= ?$BAD_ROOTS"
  elif grep -q '^# Subject:' "$1"; then
    grep -cE "^# Subject: CN=$BAD_ROOTS" "$1"
  else
    echo "?"
  fi
}

check() {
  BAD=0; WARN=0
  if [ "$PM" = apt ]; then cav=$(dpkg-query -W -f '${Version}' ca-certificates 2>/dev/null)
  else cav=$(apk info -v 2>/dev/null | sed -n 's/^ca-certificates-\([0-9].*\)$/\1/p' | head -n1); fi
  caf=$(ca_fixed)
  if [ -z "$cav" ]; then echo "  WARN  ca-certificates not installed"; WARN=$((WARN + 1))
  elif [ -n "$caf" ] && ge "$cav" "$caf"; then echo "  OK    ca-certificates ($cav)"
  elif [ -n "$caf" ]; then echo "  BAD   ca-certificates ($cav, fixed in $caf)"; BAD=$((BAD + 1))
  else echo "  WARN  ca-certificates ($cav): no known fixed version for $OS"; WARN=$((WARN + 1)); fi

  # System bundle plus bundles shipped by Python (certifi, pip), Node and others
  for b in $( { echo /etc/ssl/certs/ca-certificates.crt
      for d in /usr /opt /home /root /srv /var/lib /var/www /app; do
        [ -d "$d" ] && find "$d" -xdev \( -name cacert.pem -o -name ca-bundle.crt -o -name ca-bundle.pem \) -type f 2>/dev/null
      done; } | sort -u); do
    [ -s "$b" ] || continue
    n=$(bad_roots "$b")
    if [ "$n" = "?" ]; then echo "  INFO  $b not inspected (openssl missing)"
    elif [ "$n" -gt 0 ]; then
      if [ "$b" = /etc/ssl/certs/ca-certificates.crt ]; then echo "  BAD   $b trusts $n compromised root(s)"; BAD=$((BAD + 1))
      else echo "  WARN  $b trusts $n compromised root(s), update the app or package that ships it"; WARN=$((WARN + 1)); fi
    fi
  done

  if command -v curl >/dev/null; then
    curl -sS -o /dev/null --max-time 10 "$TEST_URL" 2>/dev/null; rc=$?
    case $rc in
      0) echo "  BAD   curl still accepts the compromised chain"; BAD=$((BAD + 1)) ;;
      35|51|58|60|77) echo "  OK    curl rejects the compromised chain" ;;
      *) echo "  INFO  live test not possible (curl exit $rc)" ;;
    esac
  fi
}

remediate() {
  if [ "$PM" = apt ]; then
    pkgs="ca-certificates $(dpkg-query -W -f '${Package} ${db:Status-Status}\n' 'nodejs' 2>/dev/null | awk '$2 == "installed" { print $1 }')"
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    # shellcheck disable=SC2086
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $pkgs
  else
    $SUDO apk update -q
    $SUDO apk upgrade -q ca-certificates ca-certificates-bundle
  fi
  $SUDO update-ca-certificates >/dev/null 2>&1
}

echo "== $(hostname) ($OS): eMudhra check"
check
if [ "$BAD" -eq 0 ]; then
  echo "== nothing to fix (${WARN} warning(s))"
  exit 0
fi
echo "== updating ca-certificates"
remediate 2>&1 | grep -E "^(E|W):|ERROR" || true
echo "== check again"
check
[ "$BAD" -eq 0 ] && echo "== fixed (${WARN} warning(s))" || { echo "== still affected: $BAD issue(s)"; exit 1; }
