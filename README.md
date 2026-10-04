# bwrap-android-chroot

한국어: [README.ko.md](README.ko.md)

Enable Claude Code's Bash sandbox in a Linux chroot on a rooted Android phone running the stock kernel.

## Test environment

| | |
|---|---|
| Phone | Samsung Galaxy S26 Ultra, stock firmware, rooted with KernelSU |
| Kernel | 6.12.30 (android16 GKI, Samsung build), arm64 |
| Chroot | Ubuntu 26.04 installed with Termux's chroot-distro |
| Software | bubblewrap 0.11.1, `apply-seccomp` from sandbox-runtime 0.0.37 |

## Install

Run Claude Code inside the chroot as a regular account that can get root with `su`, for example the
Termux app's account. This README calls it the Claude Code account. Run every command below inside
the chroot, from this repository's directory.

1. Install the packages (root)

   ```sh
   apt install bubblewrap socat acl curl procps
   ```

2. Run `install.sh` (root)

   ```sh
   bash install.sh
   ```

3. Give the sandbox account `sbx` access to your project directory (Claude Code account)

   ```sh
   setfacl -R -m u:sbx:rwX -m d:u:sbx:rwX -m "d:u:$(id -u):rwX" <project directory>
   ```

   The last entry lets the Claude Code account modify files that `sbx` creates.
   Also run this for your home directory and every directory below it on the way to the project
   directory:

   ```sh
   setfacl -m u:sbx:x <directory>
   ```

   Paths in Claude Code's `sandbox.filesystem.allowWrite` need the same access as the project directory.

4. Verify the isolation (Claude Code account; each check prints PASS or FAIL)

   ```sh
   bash tools/verify.sh <project directory>
   ```

5. Enable the sandbox in Claude Code's settings, `~/.claude/settings.json` (Claude Code account)

   ```json
   { "sandbox": { "enabled": true } }
   ```

   Leave `sandbox.network.allowAllUnixSockets` off. With it on, every sandboxed command that goes
   through Claude Code's proxy is refused.

`install.sh` installs `bwrap-root` into `/usr/local/bin` and the scripts and the settings file into
`/usr/local/lib/bwrap-root`. It downloads sandbox-runtime 0.0.37 from npm, checks the checksums, puts
`apply-seccomp` and `unix-block.bpf` into that directory as well, creates the `sbx` account, and sets
`sandbox.bwrapPath` in `/etc/claude-code/managed-settings.json`. `sandbox.bwrapPath` only takes
effect in the managed settings file. An existing `config` is kept. If `managed-settings.json` already
exists, add `"sandbox": { "bwrapPath": "/usr/local/bin/bwrap-root" }` to it yourself.
`PREFIX` changes the install location. To uninstall, delete the installed files, `/var/lib/bwrap-root`
and the `sbx` account, and remove `sandbox.bwrapPath` from `managed-settings.json`.

The `bwrap-root` settings file is `/usr/local/lib/bwrap-root/config`:

| Variable | Meaning | Default |
|---|---|---|
| `SU` | path of the `su` that gives root | `/system/bin/su` |
| `SBX_USER` | account that runs sandboxed commands; `install.sh` creates it if missing | `sbx` |

The `sbx` account gets one of the chroot's system uids. To choose the uid, install with
`SBX_UID=<uid> bash install.sh`, and pick one Android does not use. Apps use 10000 and up, and system
uids are scattered below that. Sandboxed commands have that uid's rights on the phone.

## How it works

```
Claude Code (sandbox.bwrapPath)
  -> bin/bwrap-root (Claude Code account): hands the arguments and environment over in temporary files
  -> su -> lib/root-stage.sh (root): new mount namespace, drops options the kernel cannot honor,
     gives sbx access to the proxy socket, swaps Claude Code's seccomp helper for apply-seccomp
  -> /usr/bin/bwrap (root): builds the sandbox from Claude Code's options
  -> setpriv: switches to sbx, drops all capabilities, sets no-new-privs
  -> the command: Claude Code's proxy socat starts, then the command runs under apply-seccomp
```

## Inside the sandbox

What `tools/verify.sh` checks:

| Item | State |
|---|---|
| Account | `sbx`, no capabilities, privilege escalation blocked |
| Network | own network namespace, outside access only through Claude Code's proxy |
| Unix sockets | creation blocked |
| Filesystem | read-only root, writable project directory |
| Files only the Claude Code account can read | unreadable |
| Processes | only `sbx` processes visible |

## Stock Android kernel issues

| Missing in the kernel | Issue | Workaround |
|---|---|---|
| User namespaces | bwrap cannot run as a regular account; Claude Code's seccomp helper fails | bwrap starts as root and the command switches to `sbx`; `apply-seccomp` from 0.0.37, which creates no namespaces |
| PID namespaces | other processes are visible; background processes outlive the command | a `/proc` that hides other accounts' processes; leftover `sbx` processes are killed when the next sandboxed command starts |

## Limits

- **Sandboxed commands running at the same time see each other's processes and can read their
  environment.** They all run as the same `sbx` account.
- **A command run outside the sandbox can get root with `su`.** Treat Claude Code's request to run a
  command outside the sandbox as a request to run it as root.
- **`bwrap-root` rejects bwrap options that are not in its list.** If sandboxed commands fail with
  `unsupported option` after a Claude Code update, add the option and its argument count to the
  `ARITY` table in `lib/root-stage.sh` and run `install.sh` again.
