# 설정과 실행

[루트 README](../README.md)의 실행 절차를 기준으로, TUI 선택값과 실제 적용 파일을 설명한다. 실행 진입점은 [start.sh](../start.sh), 적용 순서는 [Role의 tasks/main.yml](../roles/cs9_vmware_setup/tasks/main.yml)에 있다.

## TUI 선택 항목

| 항목 | 처음 선택 | 적용 내용 |
|---|---|---|
| `HOSTNAME` | 해제 | 현재 호스트명을 기본값으로 표시하고 입력한 이름 적용 |
| `ROOTPWD` | 해제 | 입력한 root 암호를 SHA-512 해시로 변환해 계정에 적용 |
| `NETWORK` | 해제 | 기본 NIC 프로필의 고정 IPv4·Gateway·DNS·검색 도메인 설정 |
| `EXTRANIC` | 해제 | 게스트 OS에 인식된 추가 NIC의 연결 생성·IPv4 설정 |
| `FIREWALLD` | 선택 | 설치된 firewalld를 중지하고 자동 시작 비활성화 |
| `SELINUX` | 선택 | 기본 permissive, 세부 입력에서 목표 설정값 선택 |
| `SSHKEY` | 해제 | 기본 `/root/.ssh/id_rsa`에 패스프레이즈 없는 RSA 키 생성 |
| `HOSTS` | 선택 | `/etc/hosts`에 실습 호스트 관리 블록 추가 |
| `PS1` | 선택 | 기본 `/root/.bashrc`에 색상 프롬프트 관리 블록 추가 |
| `GNOME` | 선택 | 화면 잠금·유휴 시간·폰트·확장·Terminal 아이콘 설정 |
| `KOREAN` | 선택 | Hangul·US 입력 소스 설정, IBus 패키지 설치 |
| `VSCODE` | 해제 | VS Code·확장 설치, root 실행 alias 구성 |
| `REBOOT` | 해제 | 재부팅 Task 선택값. 기본 local 연결에서는 아래 수동 절차 사용 |

기본 패키지 설치와 NetworkManager 기동은 공통 Task다. `GNOME`을 선택하면 Tweaks 설치·확장 활성화·Terminal 아이콘 생성도 초기 활성화되며, 세부 입력에서 조정할 수 있다.

## 변수와 기본값

[start.sh](../start.sh)가 감지값과 선택값을 `generated_vars/env.yml`에 기록하고 `-e @generated_vars/env.yml`로 전달한다. 이 값이 [group_vars/all.yml](../group_vars/all.yml)과 [Role defaults](../roles/cs9_vmware_setup/defaults/main.yml)보다 우선한다.

| 설정 | TUI에서 사용하는 값 |
|---|---|
| 호스트명 | `hostnamectl --static`으로 조회한 현재값 |
| 기본 NIC | 연결된 첫 번째 비-loopback 장치, 감지 실패 시 `ens160` |
| 기본 연결 이름 | NIC의 현재 NetworkManager 프로필, 감지 실패 시 `eth0` |
| IPv4·Gateway·DNS·검색 도메인 | 현재 장치에서 조회한 값; DNS·주소 목록은 첫 번째 값 사용 |
| 감지 실패 시 네트워크 기본값 | `192.168.10.10/24`, Gateway `192.168.10.2`, DNS `8.8.8.8`, 도메인 `example.com` |
| 추가 NIC | `ens192`, 연결 이름 `eth1`, `10.1.93.200/24`, 기본 Gateway 미설정 |
| GNOME | idle delay `0`, 잠금 해제, 고정폭 폰트 `Monospace Bold 18` |
| VS Code | 작업 폴더 `/root/shell`, 사용자 데이터 `/root/vscode` |

`HOSTS` 항목의 기본 블록은 다음과 같다. 실제 실습 주소에 맞추려면 생성된 변수 파일의 `hosts_entries`를 수정한 뒤 적용한다.

| IP | FQDN | 별칭 |
|---|---|---|
| `192.168.10.10` | `main.example.com` | `main` |
| `192.168.10.20` | `server1.example.com` | `server1` |
| `192.168.10.30` | `server2.example.com` | `server2` |

변수 파일 저장 후에는 root 권한으로 편집한다. root 암호 변경을 선택하면 평문 입력값도 이 파일에 들어간다. 생성 파일은 권한 `0600`으로 관리하며, [Git 제외 규칙](../.gitignore)이 `generated_vars/*.yml`과 실행별 백업을 제외한다.

## 네트워크 적용

[network.yml](../roles/cs9_vmware_setup/tasks/network.yml)은 기본 NIC의 현재 연결을 조회하고 IPv4 방식·주소·Gateway·DNS·검색 도메인을 비교한다. 변경이 필요하면 `nmcli connection modify` 후 `connection up`을 실행한다.

`NETWORK` 선택은 **고정 IPv4 설정**을 뜻한다. DHCP로 받은 주소를 기본값으로 사용해도 적용 방식은 `manual`이다. 여러 주소·DNS를 사용하는 VM에서는 생성된 변수 파일을 확인한 뒤 적용한다.

추가 NIC는 장치 존재를 먼저 확인한다. 연결이 없으면 Ethernet 프로필을 만들며, Gateway 미설정 선택에서는 `ipv4.never-default=yes`로 기본 경로 생성을 막는다. 추가 NIC는 선택할 때마다 설정·활성화 명령을 실행한다.

설정 변경은 VMware 콘솔에서 진행하고, 네트워크 복구 옵션의 지원 상태는 [백업과 복구](restore.md#네트워크-복구)를 확인한다.

## SELinux와 데스크톱

[security.yml](../roles/cs9_vmware_setup/tasks/security.yml)은 목표값을 `/etc/selinux/config`에 기록한다. 실행 중 모드가 Enforcing이고 목표가 permissive 또는 disabled이면 `setenforce 0`을 실행한다. enforcing 선택은 설정 파일에 반영되며 현재 모드는 `getenforce`로 확인한다.

[gnome.yml](../roles/cs9_vmware_setup/tasks/gnome.yml)과 [korean_input.yml](../roles/cs9_vmware_setup/tasks/korean_input.yml)은 root 권한의 `gsettings` 조회·설정을 사용한다. 화면 잠금·유휴 시간·폰트·입력 소스는 현재값 조회에 성공했을 때 비교 후 변경한다. 전원 프로필도 해당 스키마의 `power-profile` 키 조회에 성공한 경우에 적용한다.

확장 활성화는 설치된 확장 목록을 순회한다. Terminal 아이콘은 `/root/바탕화면`과 `/root/Desktop`으로 복사하며, 해당 디렉터리와 원본 launcher가 준비되어 있어야 한다. GUI 반영은 적용 대상 사용자의 GNOME 세션에서 확인한다.

## VS Code

[vscode.yml](../roles/cs9_vmware_setup/tasks/vscode.yml)은 Microsoft GPG 키·RPM 저장소를 등록한 뒤 `code`를 설치한다. 확장 목록 조회에 성공하면 아래 목록 중 미설치 항목을 설치한다.

- `MS-CEINTL.vscode-language-pack-ko`
- `rogalmic.bash-debug`
- `mads-hartmann.bash-ide-vscode`
- `jeff-hykin.better-shellscript-syntax`

root용 alias는 별도 사용자 데이터 디렉터리와 `--no-sandbox` 옵션을 사용한다. 새 쉘을 열거나 `.bashrc`를 다시 읽으면 적용된다.

```bash
source /root/.bashrc
code
```

## 재부팅

[reboot.yml](../roles/cs9_vmware_setup/tasks/reboot.yml)은 호스트명·기본 네트워크 변경이나 SELinux disabled 설정 변경 시 재부팅 플래그를 참조한다.

기본 Inventory는 `ansible_connection=local`이다. Ansible의 [reboot Action 구현](https://github.com/ansible/ansible/blob/stable-2.19/lib/ansible/plugins/action/reboot.py)은 제어 노드 자신의 재부팅을 막기 위해 local 연결을 거부한다. **TUI의 `REBOOT`를 해제한 채 적용하고**, 필요한 경우 작업을 저장한 뒤 VM에서 수동으로 실행한다.

```bash
sudo reboot
```

## 설정 확인

루트 README의 네트워크·서비스 상태 조회와 함께 선택한 항목을 확인한다.

| 대상 | 확인 명령·위치 |
|---|---|
| 호스트 블록 | `/etc/hosts`의 `ANSIBLE MANAGED BLOCK` |
| SELinux 영구 설정 | `/etc/selinux/config`의 `SELINUX=` |
| PS1·VS Code alias | `/root/.bashrc`의 프로젝트 관리 블록 |
| 백업 | `backups/<BACKUP_ID>/restore_vars.yml` 생성 여부 |

GNOME 명령은 설정을 적용한 root GNOME 세션에서 실행한다.

```bash
gsettings get org.gnome.desktop.session idle-delay
gsettings get org.gnome.desktop.screensaver lock-enabled
gsettings get org.gnome.desktop.interface monospace-font-name
gsettings get org.gnome.desktop.input-sources sources
```

기본값의 확인 기준은 유휴 시간 `uint32 0`, 잠금 `false`, 폰트 `'Monospace Bold 18'`, Hangul·US 입력 소스다.

VS Code 설치를 선택했다면 다음으로 패키지와 확장을 조회한다.

```bash
rpm -q code
sudo code --list-extensions --user-data-dir /root/vscode --no-sandbox
```

## 실행 중 문제 확인

| 증상 | 확인할 항목 |
|---|---|
| bootstrap 패키지 설치 실패 | 초기 네트워크와 `dnf repolist`로 저장소 상태 확인 |
| TUI 한글 표시 이상 | `locale`로 UTF-8 터미널 환경 확인 |
| 네트워크 적용 후 접속 중단 | VMware 콘솔에서 `nmcli device status`, `nmcli connection show`, `ip route` 확인 |
| 백업 메타데이터 작성 실패 | [백업 파일 조건](restore.md#백업-파일-조건)의 파일 존재 여부 확인 |
| GNOME 항목 적용 생략 | 적용 사용자의 세션, 스키마·키 조회 결과 확인 |
| 재부팅 Task 실패 | `REBOOT` 해제 및 수동 재부팅 절차 사용 |
