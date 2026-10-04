#!/bin/bash
# Runs as root. Starts bwrap with only mount and network namespaces and runs the command
# inside as the sandbox account.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
lib=$(dirname "$0")
. "$lib/config"
SBX_UID=$(id -u "$SBX_USER")
HP_PROC=/var/lib/bwrap-root/proc
spec=$1

# A chroot's / is not a mount point, so unshare cannot change its propagation
if [[ ${2:-} != --stage2 ]]; then
  exec unshare -m --propagation unchanged "$0" "$spec" --stage2
fi

# Without a PID namespace the background helpers of earlier commands move to init. A running
# command's chain of sandbox-account parents ends at its bwrap instead, so it keeps its
# helpers. /proc is still the real one here
orphans() {
  ps -e -o pid=,ppid=,uid=,stat= | awk -v u="$SBX_UID" '
    { ppid[$1] = $2; uid[$1] = $3; zombie[$1] = ($4 ~ /^Z/) }
    END {
      for (p in uid) {
        if (uid[p] != u || zombie[p]) continue
        q = p; while (uid[q] == u) q = ppid[q]
        if (q == 1) print p
      }
    }'
}
for _ in 1 2 3 4 5; do
  pids=$(orphans)
  [[ -n $pids ]] || break
  # shellcheck disable=SC2086
  { kill -STOP $pids; kill -KILL $pids; } 2>/dev/null || true
  sleep 0.1
done

[[ -f $spec && ! -L $spec ]] || { echo "bwrap-root: missing argument file $spec" >&2; exit 1; }
caller=$(stat -c %u "$spec")
mapfile -d '' -t all < "$spec"
mapfile -d '' -t envs < "$spec.env"
rm -f "$spec" "$spec.env"
cwd=${all[0]}; args=("${all[@]:1}")

# The command's environment. It reaches the command through a file descriptor after setpriv,
# so it shows up in no command line and bwrap and setpriv, which still run as root, never see it
declare -A env_of=()
for e in "${envs[@]}"; do env_of[${e%%=*}]=${e#*=}; done

# Number of values each option takes, to find where the command starts. Options missing
# here are refused rather than guessed
declare -A ARITY=(
  [--new-session]=0 [--die-with-parent]=0 [--as-pid-1]=0 [--clearenv]=0 [--level-prefix]=0
  [--share-net]=0 [--unshare-net]=0 [--unshare-ipc]=0 [--unshare-uts]=0
  [--unshare-cgroup]=0 [--unshare-cgroup-try]=0
  [--unshare-user]=0 [--unshare-user-try]=0 [--unshare-pid]=0 [--unshare-pid-try]=0
  [--disable-userns]=0 [--assert-userns-disabled]=0
  [--setenv]=2 [--bind]=2 [--ro-bind]=2 [--dev-bind]=2 [--bind-try]=2 [--ro-bind-try]=2
  [--dev-bind-try]=2 [--symlink]=2 [--chmod]=2 [--overlay]=3
  [--chdir]=1 [--unsetenv]=1 [--proc]=1 [--dev]=1 [--tmpfs]=1 [--dir]=1 [--remount-ro]=1
  [--seccomp-file]=1 [--cap-add]=1 [--cap-drop]=1
  [--uid]=1 [--gid]=1 [--hostname]=1 [--perms]=1 [--size]=1 [--sync-fd]=1 [--block-fd]=1
  [--userns-block-fd]=1 [--info-fd]=1 [--json-status-fd]=1 [--lock-file]=1 [--exec-label]=1
  [--file-label]=1 [--overlay-src]=1 [--tmp-overlay]=1 [--ro-overlay]=1 [--argv0]=1
)

out=(); cmd=(); bound_dirs=(); writable=(); chdir=$cwd; seccomp_file=
i=0; n=${#args[@]}
while ((i < n)); do
  a=${args[i]}
  if [[ $a == -- ]]; then cmd=("${args[@]:i+1}"); break; fi
  if [[ $a != --* ]]; then cmd=("${args[@]:i}"); break; fi
  k=${ARITY[$a]-}
  [[ -n $k ]] || { echo "bwrap-root: unsupported option $a" >&2; exit 1; }
  case $a in
    # Namespaces this kernel lacks
    --unshare-user|--unshare-user-try|--unshare-pid|--unshare-pid-try|--disable-userns|--assert-userns-disabled|--uid|--gid) ;;
    # File descriptors of the calling process do not reach here
    --sync-fd|--block-fd|--userns-block-fd|--info-fd|--json-status-fd) ;;
    # setpriv drops every capability at the end. Dropping them here would keep root out of
    # the home directory while bwrap sets up the mounts
    --cap-drop|--cap-add) ;;
    # Only the file bin/bwrap-root wrote: root reads and then deletes it
    --seccomp-file)
      [[ ${args[i+1]} == "$spec.seccomp" ]] || { echo "bwrap-root: unexpected seccomp file" >&2; exit 1; }
      seccomp_file=${args[i+1]} ;;
    # Without a PID namespace, a /proc with hidepid hides other users' processes
    --proc) out+=(--bind "$HP_PROC" "${args[i+1]}") ;;
    # A tmpfs made by root, writable by the sandbox account
    --tmpfs|--dir)
      ((${#out[@]} >= 2)) && [[ ${out[-2]} == --perms ]] || out+=(--perms 1777)
      out+=("$a" "${args[i+1]}") ;;
    --chdir) chdir=${args[i+1]} ;;
    --setenv) env_of[${args[i+1]}]=${args[i+2]} ;;
    --unsetenv) name=${args[i+1]}; unset 'env_of[$name]' ;;
    --clearenv) env_of=() ;;
    --bind|--ro-bind|--bind-try|--ro-bind-try)
      src=${args[i+1]}; dst=${args[i+2]}
      [[ -d $src ]] && bound_dirs+=("$dst")
      [[ $a == --bind || $a == --bind-try ]] && writable+=("$(realpath -m "$src")")
      out+=("$a" "$src" "$dst")
      # Claude Code's proxy socket: a real socket, not a link, directly in /tmp
      real=$(realpath -e "$src" 2>/dev/null || true)
      if [[ -n $real && ! -L $src && -S $real && $real =~ ^/tmp/claude-[^/]+\.sock$ ]]; then
        setfacl -m "u:$SBX_UID:rw" "$real"
        # The parent bwrap creates on a tmpfs copies the host's 0700. Leave it alone when it is
        # a bound host directory, where chmod would change the host
        parent=$(dirname "$dst"); inside_bound=0
        for b in "${bound_dirs[@]}"; do
          [[ $b == / || $parent == "$b" || $parent == "$b"/* ]] && inside_bound=1
        done
        ((inside_bound)) || out+=(--chmod 0755 "$parent")
      fi ;;
    *) out+=("$a" "${args[@]:i+1:k}") ;;
  esac
  ((i += 1 + k))
done
((${#cmd[@]})) || { echo "bwrap-root: no command given" >&2; exit 1; }
out+=(--chdir "$chdir")
env_of[PWD]=$chdir

# In place of Claude Code's apply-seccomp helper (after the proxy socat, before the user's
# command) goes the older helper, which only blocks Unix socket creation. A proxied command
# where that place is not found is refused rather than run without the filter
wrapped=0
for j in "${!cmd[@]}"; do
  if [[ ${cmd[j]} == *"ARGV0=apply-seccomp /proc/self/fd/"* ]]; then
    cmd[j]=$(printf '%s' "${cmd[j]}" | sed "s#ARGV0=apply-seccomp /proc/self/fd/[0-9]\+ #$lib/apply-seccomp $lib/unix-block.bpf #g")
    wrapped=1
  fi
done
if ((!wrapped)) && [[ "${cmd[*]}" == *"UNIX-CONNECT:/tmp/claude-"* ]]; then
  echo "bwrap-root: no place for the apply-seccomp filter found; refusing to run without it" >&2
  exit 1
fi
git_n=${env_of[GIT_CONFIG_COUNT]:-0}
[[ $git_n =~ ^[0-9]+$ ]] || git_n=0
git_n=$((10#$git_n))
env_of[GIT_CONFIG_KEY_$git_n]=safe.directory
env_of[GIT_CONFIG_VALUE_$git_n]='*'
env_of[GIT_CONFIG_COUNT]=$((git_n + 1))

# Claude Code records the working directory in $TMPDIR after every command
tmpdir=${env_of[TMPDIR]:-}
tmpdir_real=$(realpath -m "${tmpdir:-/nonexistent}")
tmpdir_bound=0
for w in "${writable[@]}"; do [[ $w == "$tmpdir_real" ]] && tmpdir_bound=1; done
if ((tmpdir_bound)) && [[ $tmpdir =~ ^/tmp/claude-[^/]+$ && -d $tmpdir && ! -L $tmpdir && $(stat -c %u "$tmpdir") == "$caller" ]]; then
  setfacl -m "u:$SBX_UID:rwx" "$tmpdir"
fi
envfile=$(mktemp /var/lib/bwrap-root/env.XXXXXX)
exec 7> "$envfile" 8< "$envfile"
rm -f "$envfile"
for k in "${!env_of[@]}"; do printf '%s=%s\0' "$k" "${env_of[$k]}"; done >&7
exec 7>&-

# bwrap cannot make / a slave mount when / is not a mount point, which a chroot's root is not
mount --rbind / /mnt
mount -t proc -o hidepid=2 proc "/mnt$HP_PROC"

drop=(/usr/bin/setpriv --reuid="$SBX_USER" --regid="$SBX_USER" --clear-groups --inh-caps=-all --bounding-set=-all --no-new-privs
  -- /usr/bin/perl -e 'open(my $f, "<&=", 8) or die "bwrap-root: no environment\n";
    local $/ = "\0"; my @e = <$f>; close $f; chomp @e;
    %ENV = map { split /=/, $_, 2 } @e;
    exec { $ARGV[0] } @ARGV or die "bwrap-root: $ARGV[0]: $!\n"' --)
if [[ -n $seccomp_file ]]; then
  exec 9< "$seccomp_file"; rm -f "$seccomp_file"
  exec chroot /mnt env -i PATH="$PATH" /usr/bin/bwrap "${out[@]}" --seccomp 9 -- "${drop[@]}" "${cmd[@]}"
fi
exec chroot /mnt env -i PATH="$PATH" /usr/bin/bwrap "${out[@]}" -- "${drop[@]}" "${cmd[@]}"
