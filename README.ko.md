# Agent Dashboard

[English](README.md) · [한국어](README.ko.md)

> 에이전트를 띄운 창을 계속 전환하고, 터미널을 하나씩 돌아보는 데 지치지 않으셨나요?
>
> 여러 서버와 클라이언트에서 실행 중인 에이전트의 상태를 한곳에서 확인하기 위해 이 프로젝트를 만들었습니다. 에이전트 상태를 관리하는 도구는 많지만, SSH와 devcontainer를 함께 사용하는 제 환경에 적용하기는 어려웠습니다.
>
> 이제는 AI 에이전트의 도움을 받아 필요한 도구를 직접 만들거나, 기존 도구를 자신의 환경에 맞게 고칠 수 있습니다. 저와 비슷한 불편을 겪는 분들이 조금 더 쉽게 시작하고 각자의 필요에 맞게 바꿔 쓸 수 있도록, 이 프로젝트의 소스코드를 공개합니다.

[웹 앱 열기](https://agent-dashboard.5pecia1.dev) · [macOS 앱 설치](#macos-앱-설치) · [서버 설정](#서버-설정) · [빠른 시작](docs/quickstart.md)

Agent Dashboard는 코딩 에이전트의 활동을 모아 어떤 세션에 주의가 필요한지 보여 줍니다. 웹·macOS 대시보드, 에이전트 훅, Cloudflare Workers + D1 서버로 구성되며, 서버는 다른 Worker에 내장할 수도 있습니다.

웹 앱과 macOS 앱은 **직접 운영하는 서버**에 연결합니다. 공개 웹 앱은 호스팅된 계정을 제공하거나 대시보드 데이터를 공용 서버에 저장하지 않습니다.

## macOS 앱 설치

Apple silicon Mac에서는 다음 명령으로 GitHub Releases의 최신 안정 버전을 설치합니다.

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh | bash
```

설치기는 릴리스 체크섬을 검증하고 `~/Applications/Agent Dashboard.app`에 앱을 설치합니다. 앱을 연 뒤 서버 origin과 클라이언트 토큰을 입력합니다. 소스에서 빌드할 필요는 없습니다. [Releases](https://github.com/5pecia1/agent-dashboard/releases)에서 macOS ZIP 파일을 직접 내려받을 수도 있습니다.

현재 앱은 Developer ID 서명과 공증을 받지 않았으므로, 처음 실행할 때 macOS에서 승인이 필요할 수 있습니다. [macOS 설치 및 업데이트 안내](docs/quickstart.md#macos-installation-and-updates)를 참고하세요. 브라우저에서는 [웹 앱을 열면 됩니다](https://agent-dashboard.5pecia1.dev).

## 서버 설정

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/5pecia1/agent-dashboard/tree/main/examples/cloudflare-worker/deploy)

Cloudflare와 GitHub 계정으로 브라우저에서 서버를 배포할 수 있습니다. 설정 화면에 훅용 `INGEST_TOKEN`과 대시보드용 `CLIENT_TOKEN`을 서로 다른 값으로 입력하면, Cloudflare가 D1을 생성하고 서버를 배포합니다. 완료 후 앱을 연결하고 에이전트를 실행하는 각 머신에 훅을 설치하세요. [브라우저 배포 안내](examples/cloudflare-worker/deploy/README.md)를 참고하세요.

터미널로 설치하려면 Node.js 22 이상, npm, Cloudflare 계정이 필요합니다. 릴리스된 서버 스타터를 다음 명령으로 설치할 수 있습니다.

```sh
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- server --prerelease
cd agent-dashboard-server
npm ci
```

서버는 현재 알파 버전이므로, 위 명령은 사전 릴리스를 명시적으로 포함합니다. 생성된 `README.md` 또는 [빠른 시작 안내](docs/quickstart.md#set-up-your-cloudflare-server)에 따라 Cloudflare에 로그인하고, D1을 생성하고, 토큰 두 개를 설정한 뒤 배포합니다. 설치기는 프로젝트를 생성하며, 클라우드 리소스 생성과 배포는 수행하지 않습니다.

기존 Hono Worker에 통합하려면 [서버 패키지를 설치하세요](server/README.md). 에이전트 훅에는 `INGEST_TOKEN`을, 대시보드에는 별도의 `CLIENT_TOKEN`을 사용합니다.

## 에이전트 연결

서버를 배포한 뒤, 에이전트를 실행하는 각 머신에 해당 서버 버전의 훅을 설치합니다. `https://YOUR_SERVER`를 서버 origin으로 바꿔 실행하세요.

```sh
curl -fsSL https://YOUR_SERVER/setup.sh | bash
```

훅 설치기에는 `curl`, `jq`, `python3`가 필요합니다. 입력을 요청하면 수집용 토큰(`INGEST_TOKEN`)을 입력하고, Codex에서는 `/hooks`에서 새 훅을 신뢰하도록 설정합니다. 에이전트 세션을 시작한 뒤 대시보드에서 확인하세요. 변경 사항 미리 보기, 업데이트, 데이터 처리 방식, Antigravity CLI에서 보고되는 범위와 보고되지 않는 범위는 [훅 안내](hooks/README.md)를 참고하세요. 푸시 알림은 선택 사항입니다.

## 버전 선택과 업데이트

버전을 지정하지 않으면 설치기는 **해당 구성 요소의** 최신 안정 버전을 선택하고, 이번 설치에서 내려받을 대상을 고정합니다. `--prerelease`를 사용하면 사전 릴리스도 포함합니다. `--version`은 사전 릴리스를 포함해 정확한 버전을 선택하며, 해당 버전이 없으면 실패합니다. 다른 버전으로 대체하지 않습니다.

```sh
# 특정 앱 버전을 설치합니다.
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- --version v0.1.1

# 설정을 유지하면서 기존 앱을 최신 안정 버전으로 업데이트합니다.
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- --replace

# 특정 사전 릴리스로 서버 프로젝트를 생성합니다.
curl -fsSL https://raw.githubusercontent.com/5pecia1/agent-dashboard/main/install.sh \
  | bash -s -- server --version 0.1.0-alpha.5 --dir ./my-agent-server
```

`--dry-run`을 사용하면 설치하지 않고 선택된 릴리스와 설치 경로를 확인할 수 있습니다. 실행 전에 설치기를 살펴보려면 [install.sh](install.sh)를 읽거나, 내려받아 로컬에서 실행하세요. 스크립트는 GitHub Raw에서, 릴리스 압축 파일과 체크섬은 GitHub Releases에서 제공합니다. Pages는 웹 앱만 호스팅합니다.

## 사용량 연동

웹 앱과 macOS 앱에는 TeamClaude와 Devin 사용량 패널이 포함되어 있습니다. macOS 앱은 이 컴퓨터의 Grok 로그인으로 Grok 사용량을 표시할 수 있고, 이 Mac의 Grok Bot 앱으로 Grok Bot 주간 사용량도 표시할 수 있습니다. 설정에서 자신의 엔드포인트와 키를 입력하세요. 설정하지 않은 연동은 요청을 보내지 않습니다. 브라우저의 HTTPS·CORS 요구 사항, macOS의 Grok 스위치, 인증 정보의 로컬 저장 방식은 [사용량 연동 설정 안내](docs/integrations.md)를 참고하세요.

## 개발과 업그레이드

API 계약은 `contracts/dashboard-protocol.v1.json`에 있습니다. 앱 릴리스는 `vVERSION`, 서버 릴리스는 `server-vVERSION` 형식을 사용합니다. 각 서버 릴리스에는 해당 버전의 훅 자산이 포함됩니다. 서버를 개발하려면 저장소 루트에서 다음 명령을 실행합니다.

```sh
npm --prefix server ci
npm --prefix server run check
npm --prefix server test
npm --prefix server run verify:package
```

소스 빌드는 [앱 안내](app/README.md)를, 웹 호스팅과 릴리스는 [배포 안내](docs/deployment.md)를 참고하세요.

서버가 제공하는 훅을 업그레이드하기 전에 릴리스 노트를 확인하고, 미적용 SQL 마이그레이션을 적용하고, 서버 패키지를 업데이트하세요. 스키마를 업그레이드하기 전에는 데이터베이스를 백업하세요. 패키지 업그레이드 과정에서 관리자용 rebuild 엔드포인트를 실행하지 마세요.

변경 제안은 [CONTRIBUTING.md](CONTRIBUTING.md)를, 취약점 보고는 [SECURITY.md](SECURITY.md)를 참고하세요.

이 소프트웨어는 소스코드가 공개된 source-available 소프트웨어입니다. 허용되는 사용과 제한 사항은 [LICENSE](LICENSE)를, 제삼자 고지는 [NOTICE](NOTICE)를 확인하세요.
