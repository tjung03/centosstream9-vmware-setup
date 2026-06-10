# centosstream9-vmware-setup

CentOS Stream 9 기반 VMware 실습 VM의 게스트 OS 내부 환경설정을 자동화하는 도구다. `vm환경설정.pdf`의 실습 환경 구성 내용을 기준으로 하되, VM이 이미 부팅된 상태에서 게스트 OS 내부에서 처리 가능한 작업만 수행한다.

## 대상과 전제

- OS: CentOS Stream 9
- 기본 실행 대상: localhost
- 기본 프로젝트 이름 및 예시 경로: `~/centosstream9-vmware-setup`
- VM은 이미 생성되어 있고 부팅된 상태라고 가정한다.
- 초기 네트워크는 이미 구성되어 있다고 가정한다. 이 도구 자체를 클론받기 위해 네트워크가 먼저 필요하기 때문이다.

저장소 경로는 코드에 하드코딩하지 않는다. `start.sh`는 자신의 파일 위치를 기준으로 프로젝트 루트 경로를 계산한다.

## 실행 방법

일반 사용자 홈에서 실행하는 예시:

```bash
git clone <repo-url> ~/centosstream9-vmware-setup
cd ~/centosstream9-vmware-setup
sudo ./start.sh
```

root 실습 환경에서 실행하는 예시:

```bash
git clone <repo-url> /root/centosstream9-vmware-setup
cd /root/centosstream9-vmware-setup
./start.sh
```

`git clone`, `cd`, `./start.sh` 실행은 사용자가 직접 수행한다. 이 도구는 GitHub 저장소 생성, GitHub 업로드, `git push`, `git pull`, `git clone`을 수행하지 않는다.

## TUI 동작 방식

`start.sh`를 실행하면 `dialog` 기반 TUI가 열린다.

첫 화면 이후 `Setup Modules` 체크리스트에서 적용할 항목을 선택한다. 항목명은 `HOSTNAME`, `NETWORK`, `GNOME`처럼 영어로 표시하고, 설명은 한국어로 표시한다.

체크리스트 예시:

```text
HOSTNAME  호스트명 변경 - 현재값: ansible
NETWORK   기본 NIC 설정 변경 - 현재: ens160, IP: 192.168.x.x/24
FIREWALLD firewalld 중지 및 비활성화
SELINUX   SELinux를 permissive로 설정
HOSTS     /etc/hosts에 실습 호스트 항목 추가
```

체크리스트에서 `SPACE`로 선택/해제하고 `ENTER`로 진행한다.

그 다음 기본값 사용 여부를 묻는다.

- `Yes`: 빠르게 진행한다. 현재 시스템에서 감지한 값과 문서 기준 기본값을 사용한다.
- `No`: 선택한 항목에 대해서만 세부값을 입력한다. 호스트명, IP, SELinux 상태, GNOME 폰트, VSCode 경로 등을 수정할 수 있다.

마지막으로 `ansible-playbook`을 지금 실행할지 묻는다.

- `Yes`: `generated_vars/env.yml` 생성 후 바로 Ansible을 실행한다.
- `No`: 변수 파일만 생성하고 종료한다.

수동 실행이 필요한 경우:

```bash
sudo ansible-playbook -i inventory playbook.yml -e @generated_vars/env.yml
```

## 전체 실행 흐름

```text
start.sh 실행
→ CentOS Stream 9 및 root 권한 확인
→ dialog, ansible-core 등 bootstrap 패키지 확인 및 설치
→ 현재 호스트명, NIC, IP 등 환경값 감지
→ TUI 체크리스트에서 적용 항목 선택
→ generated_vars/env.yml 생성
→ 사용자가 동의하면 ansible-playbook 실행
→ localhost 환경설정 적용
→ 필요한 경우 reboot 안내 또는 자동 reboot
```

## 디렉터리 구조

```text
.
├── start.sh
├── ansible.cfg
├── inventory
├── playbook.yml
├── restore.yml
├── README.md
├── .gitignore
├── backups/
├── generated_vars/
│   └── .gitkeep
├── group_vars/
│   └── all.yml
├── roles/
│   └── cs9_vmware_setup/
│       ├── defaults/
│       │   └── main.yml
│       ├── tasks/
│       │   ├── main.yml
│       │   ├── backup.yml
│       │   ├── preflight.yml
│       │   ├── packages.yml
│       │   ├── hostname.yml
│       │   ├── network.yml
│       │   ├── security.yml
│       │   ├── ssh_key.yml
│       │   ├── hosts.yml
│       │   ├── shell_profile.yml
│       │   ├── gnome.yml
│       │   ├── korean_input.yml
│       │   ├── vscode.yml
│       │   ├── reboot.yml
│       │   └── restore.yml
│       └── templates/
│           └── bashrc_prompt.j2
├── scripts/
│   └── README.keep
└── files/
    └── README.keep
```

`scripts/`는 TUI 코드가 더 커질 경우 분리하기 위한 확장 디렉터리다. 현재 버전은 실행 진입점을 단순하게 유지하기 위해 `start.sh`에 TUI 로직을 포함한다.

`templates/hosts.j2`는 의도적으로 두지 않았다. `/etc/hosts` 전체를 덮어쓰기보다 Ansible `blockinfile`로 관리 블록만 삽입하는 방식이 안전하기 때문이다.

## 주요 파일

- `start.sh`: 실행 진입점. OS 확인, bootstrap 패키지 설치, TUI 입력, 변수 파일 생성, Ansible 실행 및 복구 모드 실행을 담당한다.
- `ansible.cfg`: Ansible 기본 설정. 외부 collection 의존을 줄이기 위해 기본 callback을 사용한다.
- `inventory`: localhost 전용 기본 inventory.
- `playbook.yml`: `roles/cs9_vmware_setup` role을 실행하는 메인 playbook.
- `restore.yml`: 백업 디렉터리를 사용해 이전 상태로 되돌리는 복구 playbook.
- `group_vars/all.yml`: 기본 변수값. role defaults와 같은 기본값을 유지한다.
- `generated_vars/env.yml`: `start.sh` 실행 중 생성되는 사용자 입력 변수 파일.
- `backups/<BACKUP_ID>/`: `playbook.yml` 적용 직전에 생성되는 복구용 백업.
- `roles/cs9_vmware_setup/tasks/*.yml`: 기능별 Ansible task.
- `roles/cs9_vmware_setup/templates/bashrc_prompt.j2`: PS1 설정 블록 템플릿.

## 자동 감지되는 값

TUI는 현재 실행 환경의 값을 일부 감지해서 기본값으로 사용한다.

- 현재 호스트명
- 활성 NIC 인터페이스명
- NetworkManager connection/profile 이름
- 현재 IP/CIDR
- 현재 Gateway
- 현재 DNS
- 현재 DNS search domain

예를 들어 현재 호스트명이 `ansible`이면 체크리스트에는 `HOSTNAME  호스트명 변경 - 현재값: ansible`처럼 표시된다. `main.example.com` 같은 문서 기준 값은 `/etc/hosts` 기본 항목처럼 문서에서 고정된 값이 필요한 곳에만 그대로 사용한다.

## TUI에서 선택 가능한 항목

- `HOSTNAME`: 호스트명 변경. 기본값은 현재 호스트명이며, 세부값 수정에서 원하는 값으로 바꿀 수 있다.
- `ROOTPWD`: root 암호 변경. 선택 시 암호를 입력해야 한다.
- `NETWORK`: 기본 NIC 설정 변경. 선택하지 않으면 기존 네트워크를 건드리지 않는다.
- `EXTRANIC`: 이미 VM에 장착되어 게스트 OS에 보이는 추가 NIC의 IP 설정.
- `FIREWALLD`: firewalld 중지 및 비활성화.
- `SELINUX`: SELinux 목표 상태 설정. 기본값은 `permissive`.
- `SSHKEY`: 추후 원격 VM 확장을 위한 로컬 SSH 키 생성.
- `HOSTS`: `/etc/hosts`에 실습 호스트 항목 추가.
- `PS1`: root shell prompt 설정.
- `GNOME`: GNOME 화면 잠금, 전원 모드, 폰트, extensions, Terminal 아이콘 설정.
- `KOREAN`: 한국어 Hangul 입력 소스 설정.
- `VSCODE`: VSCode repository 등록, 설치, root alias, 확장 설치.
- `REBOOT`: 필요 시 자동 reboot 허용.

## 문서 기준 기본값

문서 기준 실습 호스트 항목은 다음과 같다.

```text
192.168.10.10 main.example.com main
192.168.10.20 server1.example.com server1
192.168.10.30 server2.example.com server2
```

문서 기준 기본 네트워크 예시는 다음과 같다.

```text
main    192.168.10.10/24  GW 192.168.10.2  DNS 8.8.8.8
server1 192.168.10.20/24  GW 192.168.10.2  DNS 8.8.8.8
server2 192.168.10.30/24  GW 192.168.10.2  DNS 8.8.8.8
```

단, 이 도구는 현재 시스템값을 먼저 감지한다. 기본 NIC 설정을 선택하더라도 세부값 수정을 하지 않으면 감지된 현재 네트워크 값을 우선 사용한다. 문서 기준 IP로 바꾸려면 `Default Values`에서 `No`를 선택하고 세부값을 직접 입력한다.

## 자동화되는 설정

- CentOS Stream 9 및 root 권한 preflight
- 기본 패키지 설치
- 호스트명 설정
- 선택적 root 암호 변경
- 선택적 NetworkManager 프로필 수정
- 선택적 추가 NIC IP 설정. 단, NIC가 이미 게스트 OS에 보여야 한다.
- firewalld 중지 및 비활성화
- SELinux permissive/enforcing/disabled 설정
- SSH 키 생성 옵션
- `/etc/hosts` 실습 호스트 관리 블록 삽입
- `/root/.bashrc` PS1 설정
- GNOME 화면 잠금, idle delay, 전원 모드, 고정폭 폰트 설정
- 한국어 Hangul 입력 소스 설정
- VSCode repo 등록, 설치, root alias, 확장 설치 옵션

## 자동화에서 제외되는 항목

다음은 VMware 또는 하이퍼바이저 레벨 작업이거나, GUI 수동 조작이 더 안정적인 작업이므로 제외한다.

- 제공된 VM 링크 클론 생성
- VM 전원 OFF/ON
- VMware Network Adapter 추가
- 물리 디스크 추가
- VMware/VirtualBox 설정 변경
- GitHub 저장소 생성 및 업로드
- `git push`, `git clone`, `git pull`
- GNOME 한/영 전환 키 상세 설정 등 GUI 의존성이 높은 세부 설정
- 원격 `server1`, `server2`에 대한 SSH 키 배포 및 원격 설정 적용

단, 추가 NIC가 이미 게스트 OS에 인식되어 있다면 해당 NIC의 IP 설정은 선택적으로 처리할 수 있다.

## 네트워크 설정 주의사항

초기 네트워크는 이미 구성되어 있다고 가정한다. 이 도구는 GitHub 저장소를 사용자가 직접 클론한 뒤 실행되기 때문이다.

`NETWORK`를 선택하면 NetworkManager 프로필을 수정하고 connection을 다시 올릴 수 있다. 원격 터미널에서 실행 중이라면 연결이 끊길 수 있다. 네트워크 설정을 변경할 때는 가능하면 VMware 콘솔에서 실행한다.

`NETWORK`를 선택하지 않으면 기본 NIC 설정은 변경하지 않는다.

## 변수 파일과 민감정보

`generated_vars/env.yml`은 실행 중 생성된다. root 암호 변경을 선택하면 암호가 이 파일에 들어갈 수 있다. 따라서 `start.sh`는 파일 권한을 `600`으로 설정한다.

`.gitignore`는 `generated_vars/*.yml`을 제외한다. 실제 저장소에는 `generated_vars/.gitkeep`만 유지한다.

운영용으로 확장한다면 `ansible-vault`를 사용해 민감정보를 암호화하는 편이 낫다.

## Reboot 정책

기본값은 자동 reboot 비활성화다.

호스트명, 네트워크, SELinux disabled 등 시스템 상태에 영향을 줄 수 있는 변경이 발생하면 Ansible 내부에서 `reboot_required=true`로 표시한다.

- `REBOOT` 미선택: reboot 필요 메시지만 출력한다.
- `REBOOT` 선택: 필요한 경우 Ansible `reboot` 모듈로 재부팅한다.

로컬호스트 대상이므로 실습 중에는 자동 reboot보다 수동 reboot 확인 방식을 권장한다.

## Ansible 멱등성 원칙

가능하면 내장 모듈을 사용한다.

- 패키지: `ansible.builtin.dnf`
- 서비스: `ansible.builtin.systemd_service`
- 파일/디렉터리: `ansible.builtin.file`, `copy`
- 파일 블록: `blockinfile`
- 템플릿: `template` 또는 `lookup('template')`
- 사용자: `user`

`nmcli`, `gsettings`, `gnome-extensions`, `ssh-keygen`, VSCode extension 설치처럼 내장 모듈만으로 처리하기 어려운 영역은 `command` 또는 `shell`을 제한적으로 사용한다. 이 경우 사전 조회, `creates`, `changed_when` 등을 사용해 멱등성을 보완한다.

## 원격 VM 확장 전제조건

현재 기본 대상은 localhost다. 추후 `server1`, `server2`로 확장하려면 다음이 필요하다.

- 원격 VM 네트워크 통신 가능
- SSH 접속 가능
- root 또는 sudo 권한
- SSH 키 인증 또는 패스워드 인증
- inventory 확장
- 원격 대상별 변수 분리

## 문제 해결

### dialog가 없음

`start.sh`가 root 권한으로 `dnf install -y dialog`를 시도한다. 네트워크 또는 repo 문제가 있으면 먼저 DNF repository 상태를 확인한다.

### TUI에서 한글이 깨짐

터미널이 UTF-8을 지원하는지 확인한다.

```bash
echo $LANG
locale
```

가능하면 GNOME Terminal, SSH UTF-8 터미널, 또는 VMware 콘솔의 UTF-8 환경에서 실행한다.

### ansible-playbook이 없음

`start.sh`가 `ansible-core` 설치를 시도한다. 설치가 실패하면 다음을 수동으로 확인한다.

```bash
sudo dnf install -y ansible-core
```

### Windows에서 Linux로 복사 후 실행이 이상함

CRLF 줄바꿈을 확인한다.

```bash
file start.sh
```

`CRLF line terminators`가 보이면 변환한다.

```bash
sudo dnf install -y dos2unix
dos2unix start.sh
find . -type f \( -name "*.sh" -o -name "*.yml" -o -name "*.j2" -o -name "*.md" \) -exec dos2unix {} \;
```

실행 권한도 확인한다.

```bash
chmod +x start.sh
```

### 네트워크 설정 후 연결이 끊김

`NETWORK` 선택 시 발생할 수 있다. VMware 콘솔에서 접속해 설정을 확인한다.

```bash
nmcli device status
nmcli connection show
ip addr
ip route
```

### GNOME 설정이 적용되지 않음

`gsettings`는 GNOME 세션과 사용자 환경의 영향을 받는다. root GUI 세션이 아닌 경우 일부 설정은 적용되지 않을 수 있다. 이 경우 README의 자동화 범위 내 한계로 보고 GUI에서 수동 확인한다.

### VSCode root 실행 이슈

root로 VSCode를 실행할 때는 다음 옵션이 필요하다.

```bash
code --user-data-dir /root/vscode --no-sandbox
```

이 도구는 VSCode 설치를 선택한 경우 `/root/.bashrc`에 다음 alias를 추가할 수 있다.

```bash
alias code='code --user-data-dir /root/vscode --no-sandbox'
alias vscode='code'
```

## v1.1 구조 변경: Role 기반 구성

v1.1부터는 단순 `tasks/*.yml` 나열 구조가 아니라 Ansible role 구조를 사용한다.

```text
roles/
└── cs9_vmware_setup/
    ├── defaults/
    │   └── main.yml
    ├── tasks/
    │   ├── main.yml
    │   ├── backup.yml
    │   ├── preflight.yml
    │   ├── packages.yml
    │   ├── hostname.yml
    │   ├── network.yml
    │   ├── security.yml
    │   ├── ssh_key.yml
    │   ├── hosts.yml
    │   ├── shell_profile.yml
    │   ├── gnome.yml
    │   ├── korean_input.yml
    │   ├── vscode.yml
    │   ├── reboot.yml
    │   └── restore.yml
    └── templates/
        └── bashrc_prompt.j2
```

외부 collection은 기본적으로 요구하지 않는다. 실습 VM에서 인터넷 연결이나 Ansible Galaxy 접근이 불안정할 수 있으므로, 기본 구현은 `ansible.builtin` 중심으로 작성했다. NetworkManager는 별도 collection을 쓰면 더 정돈할 수 있지만, bootstrap 부담을 줄이기 위해 `nmcli`를 제한적으로 사용한다. `nmcli`, `gsettings`, `ssh-keygen`, `code` 같은 명령은 해당 영역에 적합한 기본 모듈이 부족한 경우에만 사용한다.

## 복구 기능

v1.1부터 `ansible-playbook playbook.yml`이 실제 변경 작업을 시작하기 전에 rollback backup을 생성한다.

기본 백업 위치:

```bash
backups/<YYYYMMDD_HHMMSS>/
```

백업에는 다음 정보가 포함된다.

- 이전 hostname
- `/etc/hosts`
- `/etc/selinux/config`
- `/root/.bashrc`
- root shadow line
- SSH key 파일 존재 여부 및 원본 파일
- firewalld enabled/active 상태
- SELinux runtime 상태
- 일부 GNOME gsettings 값
- VSCode extension 목록
- 선택된 NetworkManager connection export
- 일부 패키지 설치 여부

복구 실행:

```bash
sudo ./start.sh --restore
```

또는 Ansible을 직접 실행할 수 있다.

```bash
sudo ansible-playbook -i inventory restore.yml \
  -e restore_backup_path=/path/to/centosstream9-vmware-setup/backups/<BACKUP_ID>
```

네트워크 복구는 현재 연결을 끊을 수 있으므로 기본값이 `false`다. 필요한 경우에만 `restore_network=true`로 실행한다.

```bash
sudo ansible-playbook -i inventory restore.yml \
  -e restore_backup_path=/path/to/backups/<BACKUP_ID> \
  -e restore_network=true
```

패키지 제거도 기본값이 `false`다. 패키지 제거는 다른 용도에 영향을 줄 수 있으므로 필요한 경우에만 `restore_packages=true`를 사용한다.

```bash
sudo ansible-playbook -i inventory restore.yml \
  -e restore_backup_path=/path/to/backups/<BACKUP_ID> \
  -e restore_packages=true
```

### 복구 기능의 한계

이 복구 기능은 이 도구가 변경하는 영역을 중심으로 되돌린다. VM 전체 상태를 바이트 단위로 완전히 동일하게 되돌리는 기능은 아니다. 완전한 원상복구가 반드시 필요하면 VMware snapshot 또는 clone을 함께 사용해야 한다.

특히 다음은 완전 동일성을 보장하기 어렵다.

- Ansible 실행 중 외부에서 동시에 변경한 파일
- 패키지 의존성까지 포함한 전체 RPM DB 상태
- GNOME live session의 즉시 반영 상태
- 네트워크 연결이 끊긴 상태에서의 원격 복구
- VSCode 내부 캐시 또는 사용자 데이터 전체

실습 VM에서는 중요한 실험 전 VMware snapshot을 먼저 만들고, 이 도구의 rollback backup을 보조 복구 수단으로 사용하는 방식을 권장한다.
