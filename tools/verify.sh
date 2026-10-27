#!/bin/bash
# Checks an installed bwrap-root from inside the chroot, as the account Claude Code runs as:
# starts a command the way Claude Code does and compares what it can see and do with what the
# setup promises. Leaves nothing behind.
#   verify.sh <project directory prepared for the sandbox account>
dir=${1:?usage: verify.sh <project directory>}
bwrap=$(command -v bwrap-root) || { echo "verify.sh: bwrap-root is not on PATH" >&2; exit 1; }
lib=$(dirname "$(readlink -f "$bwrap")")/../lib/bwrap-root
. "$lib/config"
sbx_uid=$(id -u "$SBX_USER") || exit 1
[[ $("$SU" -c 'id -u' </dev/null 2>/dev/null) == 0 ]] ||
  { echo "verify.sh: '$SU -c id' does not give root to this account, so bwrap-root cannot either" >&2; exit 1; }
state=${XDG_STATE_HOME:-$HOME/.local/state}/bwrap-root
fail=0
check() { # check "description" condition...
  if "${@:2}"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi
}
val() { sed -n "s/^$1=//p" <<<"$out"; }

work=$(mktemp -d "$dir/.bwrap-verify.XXXXXX") || exit 1
# mktemp makes it 0700, which also empties the ACL mask the sandbox account needs
chmod 775 "$work"
secret=$(mktemp "$HOME/.bwrap-verify.XXXXXX") || exit 1
# Stands in for Claude Code's proxy socket
sock=$(mktemp -u /tmp/claude-verify-XXXXXX.sock)
socat UNIX-LISTEN:"$sock",fork SYSTEM:'echo relayed' </dev/null >/dev/null 2>&1 &
relay=$!
# World-writable outside the sandbox, so only a read-only mount stops the probe writing it
offbind=$(mktemp -u /tmp/bwrap-verify-XXXXXX)
# Claude Code's per-user TMPDIR, where it records the working directory after each command
tdir=$(mktemp -d /tmp/claude-verify-XXXXXX)
sid=$(cat /proc/sys/kernel/random/uuid)
pad=$tdir/-verify/$sid/scratchpad
(umask 077; mkdir -p "$pad/sub"; echo before > "$pad/before"; echo before > "$pad/sub/before")
trap 'kill $relay 2>/dev/null; rm -rf "$work" "$secret" "$sock" "$tdir" "$offbind"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S $sock ]] && break; sleep 0.2; done
cat > "$work/probe.sh" <<'EOF'
echo uid=$(id -u)
echo caps=$(sed -n "s/^CapEff:[[:space:]]*//p" /proc/self/status)
echo nnp=$(sed -n "s/^NoNewPrivs:[[:space:]]*//p" /proc/self/status)
echo seccomp=$(sed -n "s/^Seccomp:[[:space:]]*//p" /proc/self/status)
echo netns=$(readlink /proc/self/ns/net)
echo routes=$(tail -n +2 /proc/net/route | wc -l)
echo procuids=$(stat -c %u /proc/[0-9]* 2>/dev/null | sort -u | tr '\n' ' ')
touch "$3" 2>/dev/null && echo rootfs=writable || echo rootfs=readonly
touch "$1/written" 2>/dev/null && echo project=writable || echo project=readonly
cat "$2" >/dev/null 2>&1 && echo secret=readable || echo secret=unreadable
perl -e 'socket(S, 1, 1, 0) or exit 1' && echo unix=allowed || echo unix=blocked
perl -e 'socket(S, 2, 1, 0) or exit 1' && echo inet=allowed || echo inet=blocked
echo callerenv=$BWRAP_VERIFY
touch "$TMPDIR/cwd" 2>/dev/null && echo tmpdir=writable || echo tmpdir=readonly
touch "$4/written" 2>/dev/null && echo scratchpad=writable || echo scratchpad=readonly
echo padbefore=$(cat "$4/before" "$4/sub/before" 2>/dev/null | tr -d '\n')
echo proxy=$(socat -T 5 - TCP:localhost:3128 </dev/null 2>/dev/null)
EOF
hostns=$(readlink /proc/self/ns/net)
mounts=$(wc -l < /proc/self/mountinfo)
mkdir -p "$state"
start=$(mktemp "$state/.verify-start.XXXXXX" 2>/dev/null)

echo "command started the way Claude Code starts it:"
out=$(BWRAP_VERIFY=passed CLAUDE_CODE_SESSION_ID=$sid "$bwrap" --new-session --die-with-parent --unshare-net --bind "$sock" "$sock" --ro-bind / / \
  --bind "$work" "$work" --bind "$tdir" "$tdir" --setenv TMPDIR "$tdir" --dev /dev --unshare-pid --unshare-user --cap-drop ALL --proc /proc -- \
  /bin/sh -c "socat TCP-LISTEN:3128,fork,reuseaddr UNIX-CONNECT:$sock >/dev/null 2>&1 & sleep 1
ARGV0=apply-seccomp /proc/self/fd/3 /bin/sh $work/probe.sh $work $secret $offbind $pad" </dev/null 2>&1)
check "runs at all" test -n "$(val uid)"
check "runs as $SBX_USER (uid $(val uid))" test "$(val uid)" = "$sbx_uid"
check "no capabilities" test "$(val caps)" = 0000000000000000
check "privilege escalation is off" test "$(val nnp)" = 1
check "seccomp filter is on" test "$(val seccomp)" = 2
check "Unix sockets cannot be created" test "$(val unix)" = blocked
check "TCP sockets can be created (for the proxy)" test "$(val inet)" = allowed
check "reaches the host through the proxy socket" test "$(val proxy)" = relayed
check "own network namespace" test -n "$(val netns)" -a "$(val netns)" != "$hostns"
check "no route out" test "$(val routes)" = 0
check "root filesystem is read-only" test "$(val rootfs)" = readonly
check "project directory is writable" test "$(val project)" = writable
check "your environment reaches the command" test "$(val callerenv)" = passed
check "TMPDIR is writable" test "$(val tmpdir)" = writable
check "the session's scratchpad is writable" test "$(val scratchpad)" = writable
check "files already in the scratchpad can be read, in subdirectories too" test "$(val padbefore)" = beforebefore
echo after > "$pad/sub/after"
out2=$(CLAUDE_CODE_SESSION_ID=$sid "$bwrap" --ro-bind / / --bind "$tdir" "$tdir" --setenv TMPDIR "$tdir" --dev /dev --proc /proc -- \
  /bin/cat "$pad/sub/after" </dev/null 2>&1)
check "a file you add to a scratchpad subdirectory later can be read" test "$out2" = after
check "files only you can read stay unreadable" test "$(val secret)" = unreadable
check "sees only $SBX_USER processes" test "$(val procuids)" = "$sbx_uid"
[[ $fail == 0 ]] || { echo "--- output of the sandboxed command:"; echo "$out"; }

echo "while a command runs:"
value=bwrap-verify-$RANDOM$RANDOM
probe_sleep=2.$RANDOM
BWRAP_VERIFY=$value "$bwrap" --unshare-net --ro-bind / / --dev /dev --proc /proc -- /bin/sleep "$probe_sleep" </dev/null >/dev/null 2>&1 &
running=$!
probe_running() { pgrep -u "$SBX_USER" -f "^/bin/sleep ${probe_sleep/./\\.}\$" >/dev/null; }
for _ in $(seq 50); do probe_running && break; sleep 0.1; done
check "the command is running" probe_running
check "your environment is in no process's command line" \
  test -z "$(grep -l -a -F -f <(printf '%s\n' "$value") /proc/[0-9]*/cmdline 2>/dev/null)"
wait "$running"

echo "refused:"
"$bwrap" --unknown-option -- true </dev/null >/dev/null 2>&1
check "an option bwrap-root does not know" test $? -ne 0
out=$("$bwrap" --unshare-net --ro-bind / / -- /bin/sh -c "socat - UNIX-CONNECT:/tmp/claude-verify.sock" </dev/null 2>&1)
check "a proxied command with no place for the filter" grep -q refusing <<<"$out"

echo "nothing left behind:"
check "no mounts added here" test "$(wc -l < /proc/self/mountinfo)" = "$mounts"
check "argument files are removed" test -z "$(find "$state" -maxdepth 1 -name 'spec.*' -newer "$start" 2>/dev/null)"
rm -f "$start"

[[ $fail == 0 ]] && echo "Result: all checks passed." || echo "Result: some checks FAILED."
exit $fail
