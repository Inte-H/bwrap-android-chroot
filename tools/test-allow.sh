#!/bin/bash
# Checks bin/bwrap-root-allow against the cases it has to get right, as the Claude Code account.
# Works on a copy of the script in a private directory under $HOME and removes it. With a working
# $SU it also opens files as the sandbox account and checks a directory that account owns.
#   test-allow.sh
src=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$src/lib/config"
id "$SBX_USER" >/dev/null 2>&1 || { echo "test-allow.sh: no account $SBX_USER" >&2; exit 1; }
t=$(mktemp -d "$HOME/.bwrap-test-allow.XXXXXX") || exit 1
s=$(mktemp -d /var/tmp/bwrap-test-allow.XXXXXX) || exit 1
home_acl=$(getfacl -p "$HOME" 2>/dev/null)
root=0; [[ $("$SU" -c 'id -u' </dev/null 2>/dev/null) == 0 ]] && root=1
as_root() { "$SU" -c "$(printf '%q ' "$@")" </dev/null; }
trap '((root)) && as_root rm -rf "$t/owned"; rm -rf "$t" "$s"; setfacl --restore=- <<<"$home_acl"' EXIT
mkdir -p "$t/p/bin" "$t/p/lib/bwrap-root"
cp "$src/bin/bwrap-root-allow" "$t/p/bin/"; cp "$src/lib/config" "$t/p/lib/bwrap-root/"
allow() { "$t/p/bin/bwrap-root-allow" "$@"; }
fail=0
check() { # check "description" condition...
  if "${@:2}"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi
}
# A check that needs root to open files as the sandbox account
rcheck() { if ((root)); then check "$@"; else echo "  SKIP  $1 (needs $SU)"; fi; }
# What the sandbox account's own ACL entry allows after the mask, or --- without an entry
sbx() {
  getfacl -cp -- "$1" 2>/dev/null | awk -F '[:\t]+' -v u="$SBX_USER" '
    $1 == "user" && $2 == u { r = $4 == "#effective" ? $5 : $3 } END { print r == "" ? "---" : r }'
}
is() { [[ $(sbx "$1") == "$2" ]]; }
opens() { as_root setpriv --reuid="$SBX_USER" --regid="$SBX_USER" --clear-groups -- cat "$1" >/dev/null 2>&1; }
# Lists the directory as the sandbox account, or without $SU checks that other may read and pass
lists() {
  if ((root)); then as_root setpriv --reuid="$SBX_USER" --regid="$SBX_USER" --clear-groups -- ls "$1" >/dev/null 2>&1
  else is "$1" r-x || [[ $(stat -c %A "$1") == *r-x ]]; fi
}

mkdir -p "$t/mw/sub" "$t/grp" "$t/up/x/y" "$t/up/x/z" "$t/a/bin" "$t/b" "$t/cfg" "$t/proj/node_modules/.bin" "$t/other" "$t/chain/hop" "$t/real" "$t/mid"
chmod 700 "$t/a" "$t/b" "$t/cfg" "$t/proj" "$t/other" "$t/chain" "$t/chain/hop" "$t/real" "$t/mid"
printf '#!/bin/sh\n' > "$t/a/bin/tool"; chmod 755 "$t/a/bin/tool"
echo s > "$t/cfg/hosts.yml"; chmod 600 "$t/cfg/hosts.yml"
setfacl -m "u:$SBX_USER:rwx" "$t/proj"
echo s > "$t/other/real"; chmod 600 "$t/other/real"; ln -s "$t/other/real" "$t/a/bin/link"
echo s > "$t/real/file"; chmod 600 "$t/real/file"
ln -s "$t/real/file" "$t/chain/hop/second"; ln -s "$t/chain/hop/second" "$t/a/bin/first"
ln -s "$t/real" "$t/b/dirlink"
echo s > "$t/mid/file"; chmod 600 "$t/mid/file"; ln -s "$t/mid" "$t/midlink"
echo s > "$t/masked"; chmod 600 "$t/masked"; setfacl -m "u:$SBX_USER:r" "$t/masked"; chmod 600 "$t/masked"
echo s > "$s/f"; chmod 600 "$s/f"
chmod 700 "$t/up" "$t/up/x" "$t/up/x/y" "$t/up/x/z"; echo s > "$t/up/x/z/f"; chmod 600 "$t/up/x/z/f"; ln -s "$t/up/x/y" "$t/b/ylink"
setfacl -m "u:$SBX_USER:rw" "$t/mw"; chmod 700 "$t/mw"; echo s > "$t/mw/sub/f"; chmod 600 "$t/mw/sub/f"
mkdir -p "$t/open/dir" "$t/peek"; chmod 777 "$t/open/dir"; echo s > "$t/open/rw"; chmod 666 "$t/open/rw"
chmod 704 "$t/peek"; echo s > "$t/peek/f"; chmod 600 "$t/peek/f"
mkdir -p "$t/wonly/d" "$t/dot"; chmod 706 "$t/wonly"; chmod 702 "$t/wonly/d"; echo s > "$t/wonly/f"; chmod 600 "$t/wonly/f"; chmod 700 "$t/dot"
echo s > "$t/mwfile"; setfacl -m "u:$SBX_USER:rw" "$t/mwfile"; chmod 600 "$t/mwfile"
setfacl -m g::r-x "$t/grp"; setfacl -m "u:nobody:r" "$t/grp"; chmod 700 "$t/grp"; echo s > "$t/grp/f"

echo "granted:"
allow -q "$t/a/bin"; rc=$?
check "a program directory: exit 0" test $rc = 0
check "  its 0700 parents can be passed" is "$t/a" --x
check "  it can be read and listed" lists "$t/a/bin"
allow -q "$t/cfg/hosts.yml"
check "a 0600 settings file can be read" is "$t/cfg/hosts.yml" r--
check "  its directory can be passed" is "$t/cfg" --x
allow -q "$t/proj"
check "an entry that allows more keeps it" is "$t/proj" rwx
allow -q "$t/a/bin/link"
check "a link: its target can be read" is "$t/other/real" r--
check "  the target's directory can be passed" is "$t/other" --x
allow -q "$t/a/bin/first"
check "a chain of links: the middle link's directory can be passed" is "$t/chain/hop" --x
check "  the last target can be read" is "$t/real/file" r--
allow -q "$t/b/dirlink/"
check "a link to a directory, given with a trailing slash: the link's directory" is "$t/b" --x
check "  and the directory it points to" is "$t/real" r-x
allow -q "$t/midlink/file"
check "a link in the middle of the path" is "$t/mid" --x
allow -q "$t/masked"
check "an entry the mask had emptied works again" is "$t/masked" r--
allow -q "$s/f"; rc=$?
check "a file under a sticky directory that is not yours, /var/tmp" test $rc = 0 -a "$(sbx "$s/f")" = r--
allow -q "$t/b/ylink/../z/f"
check "'..' after a link goes to the link target's parent" is "$t/up/x/z/f" r--
check "  and the target's directories can be passed" is "$t/up/x" --x
check "  including the one '..' was looked up in" is "$t/up/x/y" --x
rcheck "  the sandbox account can really open it" opens "$t/b/ylink/../z/f"
allow -q "$t/open/dir" "$t/open/rw"
check "a directory others may write keeps that for the sandbox account" is "$t/open/dir" ---
check "  and so does a file others may write" test "$(getfacl -cp "$t/open/rw" | grep -c "^user:$SBX_USER")" = 0
allow -q "$t/peek/f"
check "passage through a directory others may read keeps the read" is "$t/peek" r-x
allow -q "$t/wonly/f"
check "passage through a directory others may only write adds no w" is "$t/wonly" r-x
allow -q "$t/wonly/d"
check "a directory others may only write gets read and passage, no w" is "$t/wonly/d" r-x
check "  and a second run neither refuses nor changes it" test -z "$(allow "$t/wonly/f" "$t/wonly/d" 2>&1)"
check "a path ending in /. is handled once" test "$(allow "$t/dot/." | grep -c "$t/dot\$")" = 1
allow -q "$t/mw/sub/f"
check "a directory whose w the mask had removed gets passage only" is "$t/mw" --x
allow -q "$t/mwfile"
check "a file whose w the mask had removed gets read only" is "$t/mwfile" r--
allow -q "$t/grp/f"
check "the owning group gets back only the passage granted, not what the mask took" \
  grep -qx $'group::r-x\t#effective:--x' <(getfacl -cp "$t/grp")
: > "$t/looked"; allow -q -w "$t/looked" "$t/a/bin/first"
check "-w lists the directories behind links" grep -qx "$t/chain/hop" "$t/looked"
rcheck "a 0600 settings file really opens for the sandbox account" opens "$t/cfg/hosts.yml"
check "running again changes and prints nothing" test -z "$(allow "$t/a/bin" "$t/cfg/hosts.yml" "$t/a/bin/first" 2>&1)"

echo "refused:"
allow -q "$t/proj/node_modules/.bin"; rc=$?
check "a path through a directory sandboxed commands can change" test $rc = 1 -a "$(sbx "$t/proj/node_modules")" = ---
if ((root)); then
  as_root mkdir -m 755 "$t/owned" && as_root touch "$t/owned/f" && as_root chown "$(id -u)" "$t/owned/f" &&
    as_root chown "$SBX_USER" "$t/owned"
  allow -q "$t/owned/f"; rc=$?
  check "a path through a directory the sandbox account owns, even read-only" test $rc = 1 -a "$(sbx "$t/owned/f")" = ---
else
  echo "  SKIP  a directory the sandbox account owns (needs $SU)"
fi
allow -q /etc/passwd; rc=$?
check "a file that is not yours" test $rc = 1
allow -q "$t/nope"; rc=$?
check "a missing path" test $rc = 1
check "-q prints nothing" test -z "$(allow -q "$t/nope" /etc/passwd 2>&1)"

[[ $fail == 0 ]] && echo "Result: all checks passed." || echo "Result: some checks FAILED."
exit $fail
