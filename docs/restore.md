# 백업과 복구

[backup.yml](../roles/cs9_vmware_setup/tasks/backup.yml)은 Role의 기능별 설정 전에 상태를 수집한다. [restore.yml](../restore.yml)은 [복구 Task](../roles/cs9_vmware_setup/tasks/restore.yml)를 별도 진입점으로 실행한다.

## 백업 생성 시점과 위치

`start.sh`는 실행 시각으로 `BACKUP_ID`를 만들고, 절대 경로를 `generated_vars/env.yml`에 기록한다. 실제 백업은 TUI에서 Ansible 실행을 선택한 후, preflight 다음에 생성한다. bootstrap 패키지는 이보다 먼저 설치된다.

```text
backups/<YYYYMMDD_HHMMSS>/
├── restore_vars.yml       # 호스트명·서비스·설정·파일 존재 정보
├── files/                 # 원본 설정 파일·root shadow·SSH 키
└── network/               # 네트워크 export 출력 대상
```

백업 디렉터리는 root 소유 `0700`, 메타데이터와 root shadow 파일은 `0600`이다. 백업에는 암호 해시와 기존 SSH 개인키가 포함될 수 있으므로 root 전용으로 보관한다. 실행별 백업은 [Git 제외 규칙](../.gitignore)으로 관리한다.

### 백업 파일 조건

현재 메타데이터 템플릿은 파일 존재 여부 목록의 키로 `result.stat.path`를 사용한다. Ansible `stat`의 `path` 필드는 [대상 파일이 존재할 때 반환](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/stat_module.html)된다. 따라서 아래 백업 대상 중 파일이 없으면 메타데이터 작성이 실패할 수 있다.

- `/etc/hostname`, `/etc/hosts`, `/etc/selinux/config`, `/root/.bashrc`
- `ssh_key_path`와 공개키 파일 — 기본 `/root/.ssh/id_rsa`, `/root/.ssh/id_rsa.pub`

특히 새 VM의 SSH 키가 아직 없는 경우가 해당한다. SSH 키 생성 Task는 백업 이후에 실행된다. 실패한 실행의 백업은 `restore_vars.yml`까지 생성되었는지 확인해야 한다.

### Ansible 직접 실행

TUI가 생성한 변수 파일을 함께 전달한다.

```bash
sudo ansible-playbook -i inventory playbook.yml -e @generated_vars/env.yml
```

기본 변수 파일의 `backup_id`·`backup_path`는 빈 문자열이다. `backup.yml`의 `default(...)`는 정의된 빈 문자열을 대체하지 않으므로, 변수 파일 없이 직접 실행하면 백업 경로 생성이 실패한다. `start.sh`가 작성한 경로를 사용한다.

같은 `env.yml`을 재사용하면 백업 경로도 재사용된다. 이전 백업을 보존하며 새 적용을 시작하려면 `start.sh`에서 새 변수 파일과 백업 ID를 생성한다.

## 수집 항목과 복구 동작

| 대상 | 수집 | 복구 처리 |
|---|---|---|
| 호스트명 | 현재 정적 호스트명과 `/etc/hostname` | 저장한 호스트명을 `hostname` 모듈로 적용 |
| 시스템 파일 | `/etc/hosts`, `/etc/selinux/config`, `/root/.bashrc` 원본 | 해당 파일 전체를 백업 내용으로 복사 |
| root 계정 | root shadow 행 | 저장한 행을 `/etc/shadow`에 반영 |
| SSH 키 | 지정 경로의 키 파일과 존재 여부 | 기존 키 복사 또는 새로 생성된 키 삭제 |
| firewalld | enabled·active 상태 | 기록된 자동 시작·기동 상태 적용 |
| SELinux | 런타임 모드와 설정 파일 | 설정 파일 복원, 기록이 Enforcing·Permissive이면 `setenforce` 실행 |
| GNOME | 유휴 시간·잠금·전원·폰트·입력 소스 조회값 | 조회에 성공해 저장한 값을 `gsettings`로 적용 |
| 선택 패키지 | 설치 여부 | 별도 선택 시 기존에 없던 `code`, `gnome-tweaks`, `ibus`, `ibus-hangul` 제거 |

VS Code 확장 목록과 NetworkManager 연결 목록도 메타데이터에 기록한다. 네트워크 export/import 경로는 아래 지원 조건을 따른다.

파일 복구는 백업 이후 같은 파일에 추가한 내용도 백업 시점으로 되돌린다. 사용자 지정 `ps1_file`을 쓸 때는 백업·복구 Task의 고정 대상인 `/root/.bashrc`와 경로를 함께 확인한다.

## 복구 실행

VMware 콘솔에서 저장소 루트로 이동해 실행한다.

```bash
sudo ./start.sh --restore
```

TUI에서 `restore_vars.yml`이 있는 백업을 선택하고, 패키지 제거 여부를 지정한다. `Restore Network`는 기본 `No`를 유지한다.

Ansible 직접 실행 시에는 해당 백업의 절대 경로를 지정한다.

```bash
sudo ansible-playbook -i inventory restore.yml \
  -e restore_backup_path=/root/centosstream9-vmware-setup/backups/20260609_120000
```

위 경로와 ID는 실제 생성된 백업으로 바꾼다. 선택 패키지 제거를 함께 실행하려면 `-e restore_packages=true`를 추가한다.

### 네트워크 복구

현재 백업 Task는 `nmcli connection export`, 복구 Task는 `nmcli connection import type keyfile`을 사용한다. [NetworkManager 공식 문서](https://networkmanager.dev/docs/api/latest/nmcli.html)의 export/import는 VPN 연결용이며, 이 저장소에서 설정하는 Ethernet 프로필 복구에 맞는 방식이 아니다.

일반 Ethernet 연결은 **`restore_network=false`로 두고**, VMware 콘솔에서 보관한 주소·Gateway·DNS와 현재 프로필을 대조해 복원한다. 코드의 export/import 실패는 `failed_when: false`로 처리되므로 Playbook 종료 메시지와 별도로 네트워크 상태를 확인한다.

```bash
nmcli connection show
nmcli device status
ip -4 address
ip route
```

## 복구 후 확인

루트 README의 상태 조회 명령으로 호스트명·네트워크·SELinux·firewalld를 확인한다. 복구한 설정 파일은 해당 백업과 비교하고, GNOME은 적용 사용자의 세션에서 조회한다. 복구 Playbook은 안내 메시지로 끝나므로 재부팅이 필요한 설정은 작업 저장 후 수동으로 반영한다.

관련 코드: [백업](../roles/cs9_vmware_setup/tasks/backup.yml) · [복구](../roles/cs9_vmware_setup/tasks/restore.yml) · [설정 확인](configuration.md#설정-확인)
