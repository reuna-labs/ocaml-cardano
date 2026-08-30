#!/bin/sh
# Enforce the package boundary used by the Solo5 builds. The signed-data and
# transport-independent RPC packages must not acquire host I/O or GMP; the
# flow adapter may use Lwt/Mirage_flow, but not Unix or a host network stack.

set -eu

OFFLINE="cardano-types cardano-address cardano-crypto cardano-plutus cardano-plutus-vm cardano-transaction cardano-rpc cardano"
FLOW="cardano-rpc-flow"
OFFLINE_FORBIDDEN="unix threads lwt lwt.unix async cohttp cohttp-lwt cohttp-lwt-unix conduit conduit-lwt conduit-lwt-unix mirage-flow mirage-flow-unix tcpip zarith"
FLOW_FORBIDDEN="unix threads lwt.unix async cohttp-lwt-unix conduit-lwt-unix mirage-flow-unix h2-lwt-unix h2-mirage tcpip conduit-mirage"

status=0

fail() {
  echo "no_io_guard: FAIL $*" >&2
  status=1
}

declared_deps() {
  awk '
    /^depends: \[/ { inside = 1; next }
    inside && /^\]/ { inside = 0 }
    inside {
      if ($0 ~ /with-test|with-doc|with-dev-setup/) next
      if (match($0, /"[^"]+"/)) {
        name = substr($0, RSTART + 1, RLENGTH - 2)
        if (name != "ocaml" && name != "dune") print name
      }
    }
  ' "$1"
}

check_package() {
  pkg="$1"
  shift
  forbidden="$*"
  file="$pkg.opam"
  [ -f "$file" ] || {
    fail "$file is missing"
    return
  }

  pending=$(declared_deps "$file")
  seen=""
  bad=""
  while [ -n "$pending" ]; do
    dep=$(printf '%s\n' "$pending" | head -n 1)
    pending=$(printf '%s\n' "$pending" | tail -n +2)
    case " $seen " in *" $dep "*) continue ;; esac
    seen="$seen $dep"

    for banned in $forbidden; do
      [ "$dep" = "$banned" ] && bad="$bad $dep"
    done

    if [ -f "$dep.opam" ]; then
      pending=$(printf '%s\n%s\n' "$pending" "$(declared_deps "$dep.opam")" | grep -v '^$' || true)
    fi
  done

  if [ -n "$bad" ]; then
    fail "$pkg depends on:$bad"
  else
    echo "  ok  $pkg"
  fi
}

echo "no_io_guard: offline packages stay free of host I/O and GMP"
for pkg in $OFFLINE; do
  check_package "$pkg" $OFFLINE_FORBIDDEN
done

echo "no_io_guard: flow transport stays free of a host OS"
for pkg in $FLOW; do
  check_package "$pkg" $FLOW_FORBIDDEN
done

if [ "$status" -eq 0 ]; then
  echo "no_io_guard: clean"
else
  echo "no_io_guard: violations found" >&2
fi
exit "$status"
