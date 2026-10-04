# bwrap-android-chroot

English: [README.md](README.md)

순정 커널을 쓰는 루팅한 안드로이드 폰의 리눅스 chroot에서 Claude Code의 Bash 샌드박스를 켭니다.

## 테스트 환경

| | |
|---|---|
| 폰 | 삼성 갤럭시 S26 울트라, 순정 펌웨어, KernelSU로 루팅 |
| 커널 | 6.12.30 (android16 GKI, 삼성 빌드), arm64 |
| chroot | Termux의 chroot-distro로 설치한 Ubuntu 26.04 |
| 소프트웨어 | bubblewrap 0.11.1, sandbox-runtime 0.0.37의 `apply-seccomp` |

## 설치

Claude Code는 chroot 안에서 `su`로 root를 얻을 수 있는 일반 계정(예: Termux 앱 계정)으로 실행해야 합니다.
이 문서에서는 이 계정을 Claude Code 계정이라고 합니다. 아래 명령은 모두 chroot 안의 이 저장소 디렉터리에서 실행합니다.

1. 패키지 설치(root)

   ```sh
   apt install bubblewrap socat acl curl procps
   ```

2. `install.sh` 실행(root)

   ```sh
   bash install.sh
   ```

3. 샌드박스 계정 `sbx`에 프로젝트 디렉터리 접근 권한 부여(Claude Code 계정)

   ```sh
   setfacl -R -m u:sbx:rwX -m d:u:sbx:rwX -m "d:u:$(id -u):rwX" <프로젝트 디렉터리>
   ```

   마지막 항목은 `sbx`가 만든 파일을 Claude Code 계정이 수정할 수 있게 합니다.
   홈 디렉터리부터 프로젝트 디렉터리의 상위 디렉터리까지 경로상의 디렉터리마다 아래 명령도 실행하십시오.

   ```sh
   setfacl -m u:sbx:x <디렉터리>
   ```

   다른 이름으로 설치했다면 `sbx` 대신 그 이름을 쓰십시오.

   Claude Code 설정의 `sandbox.filesystem.allowWrite`에 넣은 경로에도 프로젝트 디렉터리와 같은 권한이 필요합니다.

4. 격리가 제대로 되는지 확인(Claude Code 계정, 항목마다 PASS 또는 FAIL 출력)

   ```sh
   bash tools/verify.sh <프로젝트 디렉터리>
   ```

5. Claude Code 설정(`~/.claude/settings.json`)에서 샌드박스 켜기(Claude Code 계정)

   ```json
   { "sandbox": { "enabled": true } }
   ```

   `sandbox.network.allowAllUnixSockets`는 켜지 마십시오. 켜면 Claude Code 프록시를 거치는 샌드박스 명령이 모두 거부됩니다.

`install.sh`는 `bwrap-root`를 `/usr/local/bin`에, 스크립트와 설정 파일을 `/usr/local/lib/bwrap-root`에 설치합니다.
npm에서 sandbox-runtime 0.0.37을 받아 체크섬을 대조한 뒤 `apply-seccomp`와 `unix-block.bpf`도 그 디렉터리에 넣고,
`sbx` 계정을 만들고, `/etc/claude-code/managed-settings.json`에 `sandbox.bwrapPath`를 지정합니다.
`sandbox.bwrapPath`는 관리 설정 파일에서만 적용됩니다. 이미 있는 설정 파일 `config`는 그대로 둡니다.
`managed-settings.json`이 이미 있으면 `"sandbox": { "bwrapPath": "/usr/local/bin/bwrap-root" }`를 직접 추가하십시오.
설치 위치는 `PREFIX`로 바꿀 수 있습니다. 제거하려면 설치한 파일, `/var/lib/bwrap-root`, 샌드박스 계정을 삭제하고
`managed-settings.json`에서 `sandbox.bwrapPath`를 지우십시오.

`bwrap-root` 설정 파일은 `/usr/local/lib/bwrap-root/config`입니다.

| 변수 | 뜻 | 기본값 |
|---|---|---|
| `SU` | root를 얻는 `su` 경로 | `/system/bin/su` |
| `SBX_USER` | 샌드박스 명령을 실행할 계정 | `sbx` |

계정 이름은 `SBX_USER=<이름> bash install.sh`로 정합니다. `install.sh`가 만들지 않은 같은 이름의 계정이 있으면 설치하지 않고 멈춥니다.
계정은 chroot의 시스템 UID 하나로 만듭니다. UID를 직접 정하려면 `SBX_UID=<UID> bash install.sh`로 설치하십시오.
이때 안드로이드가 쓰지 않는 번호를 고르십시오. 10000 이상은 앱이 쓰고, 그 아래에도 시스템 UID가
섞여 있습니다. 샌드박스 명령은 폰에서도 그 UID의 권한을 갖습니다.

## 동작 방식

```
Claude Code (sandbox.bwrapPath)
  -> bin/bwrap-root (Claude Code 계정): 인자와 환경 변수를 임시 파일로 넘김
  -> su -> lib/root-stage.sh (root): 별도 mount namespace 생성, 커널이 지원하지 않는 옵션 제거,
     프록시 소켓에 sbx 접근 권한 부여, Claude Code의 seccomp 헬퍼를 apply-seccomp로 교체
  -> /usr/bin/bwrap (root): Claude Code가 넘긴 옵션으로 샌드박스 구성
  -> setpriv: sbx 계정으로 전환, capability 제거, no-new-privs
  -> 명령: Claude Code의 프록시 socat을 띄운 뒤 apply-seccomp를 거쳐 실행
```

## 샌드박스 안의 상태

`tools/verify.sh`가 확인하는 항목입니다.

| 항목 | 상태 |
|---|---|
| 실행 계정 | `sbx`, capability 없음, 권한 상승 차단 |
| 네트워크 | 별도 network namespace, Claude Code 프록시로만 외부 접속 |
| Unix 소켓 | 생성 차단 |
| 파일시스템 | 루트 읽기 전용, 프로젝트 디렉터리 쓰기 가능 |
| Claude Code 계정만 읽을 수 있는 파일 | 읽기 불가 |
| 프로세스 | `sbx` 계정의 프로세스만 보임 |

## 순정 안드로이드 커널 이슈

| 커널에 없는 기능 | 이슈 | 대응 |
|---|---|---|
| user namespace | 일반 계정으로 bwrap 실행 불가, Claude Code의 seccomp 헬퍼 실행 실패 | root로 bwrap을 띄운 뒤 `sbx` 계정으로 전환, namespace를 만들지 않는 0.0.37의 `apply-seccomp` 사용 |
| PID namespace | 다른 프로세스가 보임, 명령이 끝나도 백그라운드 프로세스가 남음 | 다른 계정의 프로세스를 숨긴 `/proc`, 다음 샌드박스 명령이 시작될 때 남은 `sbx` 프로세스 정리 |

## 한계

- **동시에 실행되는 샌드박스 명령끼리는 서로의 프로세스가 보이고 환경 변수를 읽을 수 있습니다.** 모두 같은
  `sbx` 계정으로 실행됩니다.
- **샌드박스 밖에서 실행되는 명령은 `su`로 root를 얻을 수 있습니다.** Claude Code의 샌드박스 밖 실행 요청은
  root 명령 실행 요청으로 간주하십시오.
- **`bwrap-root`는 지원 목록에 없는 bwrap 옵션을 거부합니다.** Claude Code를 업데이트한 뒤 샌드박스 명령이
  `unsupported option`으로 실패하면 `lib/root-stage.sh`의 `ARITY` 표에 그 옵션과 인자 개수를 추가하고
  `install.sh`를 다시 실행하십시오.
