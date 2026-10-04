#!/bin/bash
# Installs bwrap-root into the chroot it is run from and points Claude Code's sandbox at it.
# Run it as root inside the chroot.
#   PREFIX    where bin/ and lib/ go                          (default /usr/local)
#   SBX_USER  name of the sandbox account, for a new config  (default: sbx)
#   SBX_UID   uid of the sandbox account when it is created   (default: a free system uid)
# An existing config and managed-settings.json are kept.
set -eu
PREFIX=${PREFIX:-/usr/local}
SRT_URL=https://registry.npmjs.org/@anthropic-ai/sandbox-runtime/-/sandbox-runtime-0.0.37.tgz
HELPER_SHA256=74ae36efaa06865de565f023b7c474668018d65715638e008f8b51bf95e1107d
FILTER_SHA256=439626767f5e2159b0eb1351bd5c71ce95c0c88badf0a954a527acd9e796555c
MANAGED=/etc/claude-code/managed-settings.json
src=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
lib=$PREFIX/lib/bwrap-root

die() { echo "install.sh: $*" >&2; exit 1; }
((EUID == 0)) || die "run as root inside the chroot"
[[ $(uname -m) == aarch64 ]] || die "only arm64 is supported"
for b in /usr/bin/bwrap /usr/bin/setpriv /usr/bin/perl setfacl unshare ps awk getent useradd curl tar sha256sum; do
  command -v "$b" >/dev/null || die "$b is missing (install bubblewrap, util-linux, perl, acl, procps, passwd, curl)"
done
want_user=${SBX_USER-}
[[ -z $want_user || $want_user =~ ^[a-z_][a-z0-9_-]*$ ]] || die "SBX_USER=$want_user is not a valid account name"
if [[ -e $lib/config ]]; then
  . "$lib/config"
  [[ -z $want_user || $want_user == "$SBX_USER" ]] ||
    die "$lib/config names the sandbox account $SBX_USER; change SBX_USER there instead"
else
  . "$src/lib/config"
  SBX_USER=${want_user:-$SBX_USER}
fi
# An account of that name that install.sh did not create may be a person's, and sandboxed
# commands would get its files
if entry=$(getent passwd "$SBX_USER"); then
  IFS=: read -r _ _ uid gid _ home shell <<<"$entry"
  [[ $home == /nonexistent && $shell == */nologin && $(getent group "$SBX_USER" | cut -d: -f3) == "$gid" ]] ||
    die "an account named $SBX_USER already exists and install.sh did not create it; install with SBX_USER=<another name>"
  [[ -z ${SBX_UID-} || $SBX_UID == "$uid" ]] || die "$SBX_USER already exists with uid $uid, not $SBX_UID"
fi

install -d "$PREFIX/bin" "$lib" /var/lib/bwrap-root/proc
install -m 755 "$src/bin/bwrap-root" "$PREFIX/bin/bwrap-root"
install -m 755 "$src/lib/root-stage.sh" "$lib/root-stage.sh"
if [[ -e $lib/config ]]; then
  echo "kept      $lib/config"
else
  install -m 644 "$src/lib/config" "$lib/config"
  sed -i "s/^SBX_USER=.*/SBX_USER=$SBX_USER/" "$lib/config"
fi
[[ -n ${entry-} ]] || useradd --system ${SBX_UID:+--uid "$SBX_UID"} --user-group --no-create-home \
  --home-dir /nonexistent --shell /usr/sbin/nologin "$SBX_USER"

# sandbox-runtime 0.0.37 ships a helper that applies the filter without creating namespaces
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$SRT_URL" | tar -xz -C "$tmp" package/vendor/seccomp/arm64
seccomp=$tmp/package/vendor/seccomp/arm64
sha256sum -c --quiet - <<SUMS || die "checksum mismatch in $SRT_URL"
$HELPER_SHA256  $seccomp/apply-seccomp
$FILTER_SHA256  $seccomp/unix-block.bpf
SUMS
install -m 755 "$seccomp/apply-seccomp" "$lib/apply-seccomp"
install -m 644 "$seccomp/unix-block.bpf" "$lib/unix-block.bpf"

if [[ ! -e $MANAGED ]]; then
  install -d "$(dirname "$MANAGED")"
  printf '{\n  "sandbox": {\n    "bwrapPath": "%s"\n  }\n}\n' "$PREFIX/bin/bwrap-root" > "$MANAGED"
  chmod 644 "$MANAGED"
elif grep -q "\"bwrapPath\": *\"$PREFIX/bin/bwrap-root\"" "$MANAGED"; then
  echo "kept      $MANAGED"
else
  echo "kept      $MANAGED; set sandbox.bwrapPath to $PREFIX/bin/bwrap-root in it by hand"
fi

echo "installed $PREFIX/bin/bwrap-root and $lib (sandbox account $SBX_USER, uid $(id -u "$SBX_USER"))"
echo "next: tools/verify.sh <project directory>"
