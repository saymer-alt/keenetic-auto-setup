# План независимых сборок transport binaries

[Индекс](README.md) · [Основной отчёт](WDTT-CSQTT-WG-OBFUSCATOR-2026.md) · [Матрица](TRANSPORT-COMPATIBILITY-MATRIX.md) · [Сборки](TRANSPORT-BUILD-PLAN.md) · [Интеграция](KAS-TRANSPORT-INTEGRATION.md) · [Тесты](TRANSPORT-TEST-PLAN.md)

**Уточнение Phase 2:** единственное место новых сборок — `saymer-alt/entware-go`, база `gh-action-build`. Отдельный репозиторий не создаётся. Новые workflows только build-only; общий release `latest`, действующие IPK и уведомления агрегатора не изменяются. Сейчас бинарники остаются в изолированной лаборатории; release/public upload не выполнялись. Точные результаты — [тестовый план](TRANSPORT-TEST-PLAN.md), [JSON](TRANSPORT-RESEARCH-EVIDENCE.json).

## 1. Единица сборки и совместимости

Не собирать «latest WDTT вообще». Единица — `component + fork + exact SHA + local patchset digest + toolchain digest + dependency lock digest + target + flags`. Сервер и клиент имеют отдельные manifest records и общий **tested pair**. Имена релизов не являются доказательством wire-совместимости. [W1] [Q2] [C9]

Лабораторный проект дерева внутри entware-go (это не готовый production workflow):

```text
sources.lock.json                # SHA, URL, license scope, module subdir
toolchains.lock.json             # archives/container digest, SHA256, target ABI
recipes/wt-client.sh
recipes/wdtt-server.sh
recipes/wg-obfuscator.sh
recipes/csqtt-client.sh           # opt-in после licensing gate
patches/wt-client/<revision>/     # redaction, secret-fd, atomic config event
checks/elf.py                    # machine/endian/FPABI/PT_INTERP/NEEDED
checks/protocol-fixtures/        # synthetic data only
licenses/                       # per-component notices + transitive inventory
compatibility/pairs.json         # не только semver
```

Source lock для первого WDTT: `hoaxisr/proxy-turn-vk-android@1110a75f76e42c23149b8e24f9182c1ff179e515`, subdir `go_client`; server отдельный root module того же checkout. WG-obfs: `ClusterM/wg-obfuscator@7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f`. CSQTT: `amurcanov/csqtt@71712b07dbabe16fa43f5a248dc69e1ab9f3a270`, subdir `rust-client`; tag2.1.9 runtime tree совпадает, но в lock всё равно SHA. [W1] [O1] [C1]

## 2. Go: реально выполненный рецепт wt-client

Windows host Go1.27.0, Linux ELF, отдельные GOPATH/GOCACHE в lab; upstream не патчился. Ветка module указывает Go1.26, поэтому старый Entware compiler не предполагается совместимым. `GOTOOLCHAIN=local` не скачивает незаметно иной Go. [W1] [E1]

```sh
# Из зафиксированного checkout/go_client, чистая isolated build directory.
export GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux
export GOARCH=arm64                 # отдельно amd64, mipsle, mips
export GOMIPS=softfloat             # существенно для MIPS32
go build -mod=readonly -trimpath -buildvcs=false \
  -ldflags='-s -w -buildid=' -o "$OUT/wt-client-linux-$GOARCH" .
go version -m "$OUT/wt-client-linux-$GOARCH"
sha256sum "$OUT/wt-client-linux-$GOARCH"
```

Все четыре target build прошли. Повтор AMD64 на том же host/cache дал идентичный SHA256; это **локальная повторяемость**, не доказательство двух независимых clean builders. Следующий gate — clean Linux runner и другой абсолютный checkout path, те же archive/compiler/deps, binary compare/diffoscope. CGO0 убирает dynamic libc dependency, но не syscall/kernel требования. Softfloat исполняет FP программно; это не отключает стоимость integer crypto. [D1]

Standalone не требует выпиливать `awgmproto`: сначала сохранить небольшой MIT protocol module как compile dependency. Удаление этой зависимости — отдельный fork patch со стоимостью поддержки и regression fd-protocol. Daemon AWG Manager ни при сборке, ни при ручном vpn mode не нужен. [W1] [W5]

Выполнен first-pass `go list -mod=readonly -deps -json` для linux/arm64 CGO0:31 module records включая main, импортов go-lzo нет. Root license files/hash/markers сохранены в evidence; большинство имеют MIT/BSD/Apache тексты, но это не полный scope audit. У main `go_client` GPL LICENSE расположен выше в upstream root. У linked `bogdanfinn/fhttp@v0.6.8` root LICENSE в module payload не найден; doc.go ссылается на BSD-style Go license, GitHub tag SHA `ecfe905c2db9d1ec769a16a14191ec84553dd235`. До публикации восстановить точные notices/условия для Go-derived и fork-specific кода, проверить subdirectory/vendor scopes. Не объявлять fhttp public domain или автоматически MIT. Это **открытый notice/provenance gate**, не установленная GPL2/GPL3 несовместимость. [D4] [L1]

### Server

Root server module не содержит upstream go.sum. В lab скопирован **только manifest** в отдельный `server.go.mod`; `go build -mod=mod -modfile=<LAB>/server.go.mod ... .` создал lock в lab и не изменил checkout. AMD64 build прошёл. Это первичное разрешение зависимостей, а не замороженная upstream recipe; перед CI snapshot resolved go.mod/go.sum, verify, license inventory, затем `-mod=readonly`. Не выполнять `go mod tidy` по движущейся ветке на каждом release. Recipe kkvoru с root server.go не подходит текущему amurcanov layout. [R2]

Серверный бинарник не запускался с реальной WG/NAT конфигурацией, не доказывает pairing. Выбрать ко-пиннутый server и зафиксировать protocol fixtures; panel/SQLite из ildarmaga не добавлять автоматически в router client dependency. [W15] [R10]

## 3. C: wg-obfuscator

Реально скомпилированы шесть C units: `wg-obfuscator.c config.c masking.c masking_stun.c obfuscation.c logging.c`. `make install` пропускается: upstream install управляет systemd, который не является Entware init. Для CI можно использовать make с overrides в staging либо эквивалентную явную gcc команду. [O1] [O2]

```sh
"$CC" -O2 -Wall -pthread -static -s \
  -o "$OUT/wg-obfuscator" \
  wg-obfuscator.c config.c masking.c masking_stun.c obfuscation.c logging.c
# MIPS32 добавить: -march=mips32 -mabi=32 -msoft-float
readelf -h -l -A "$OUT/wg-obfuscator"
```

ARM64/MIPS использовали `cross-tools/musl-cross` release20250520, gcc toolchain внутри архивов; SHA256 sidecars сверены до распаковки. [D3]

| Архив toolchain | SHA256 |
|---|---|
| aarch64-unknown-linux-musl.tar.xz | `76f0d71893f3864e91ad09feff71a719cdf94cccd4f14cc25d7deed395968b5b` |
| mipsel-unknown-linux-muslsf.tar.xz | `36d8b864b3f6d27558d3f19695a4a39b79a873086edc60bebf733777df2b8359` |
| mips-unknown-linux-muslsf.tar.xz | `cc87dcaeed29f970bddb4b572c40a4074b9ac3997ba254725e8a89e05485538a` |

Published sidecar обеспечивает integrity относительно загруженного release, но сам по себе не независимую подпись автора: future toolchain lock проходит review, mirror/attestation и закрепляется. Upstream workflow загружает toolchains без такой полной политики; копировать подход без SHA нельзя. Toolchain licenses не равны license output ELF; inventory обоих нужно сохранить отдельно. [O10]

AMD64 lab использовал gcc15/glibc static и получил `getaddrinfo` NSS warning: такой ELF не объявляется универсальным автономным binary на разных системах. Production candidate AMD64 тоже строить static musl и отдельно проверять DNS; dynamic Entware build допустим только под точный SDK/sysroot и ABI. ARM/MIPS musl ELF без PT_INTERP проверены readelf; MIPS FP ABI Soft float. Предупреждение strncpy truncation line804 записано, не скрыто общим «без предупреждений».

UPX не применять по умолчанию: экономия flash не доказывает уменьшение working set и усложняет диагностику/reproducibility. Сначала uncompressed ELF, потом отдельное измерение при необходимости. Entware ipk wrapper — отдельный этап после standalone ELF и hardware acceptance; package не должен автоматически включать daemon либо править NDMS на install. [E1] [O1]

## 4. Rust: CSQTT client отдельно от server

Реально выполнена native AMD64 GNU/glibc сборка:

```sh
cd rust-client
# rustc/cargo/std1.97.1 установлены только в LAB/toolchain,
# архивы проверены по official channel manifest SHA256.
export CARGO_HOME="$LAB/cargo-home" CARGO_TARGET_DIR="$LAB/target"
export RUSTC="$LAB/toolchain/bin/rustc" CARGO_BUILD_JOBS=4
export PATH="$LAB/toolchain/bin:/usr/local/bin:/usr/bin:/bin"
cargo build --locked --release --bin client
```

Cargo.lock сохранён upstream. Прямой crate aws-lc-rs1.18.0 тянет native AWS-LC, primp тянет дополнительные TLS/compression зависимости, поэтому «Rust binary всегда pure/static» неверно. Manifest rust-version1.97.1 реально проверен official toolchain. Native build прошёл без системной установки Rust; результат10,366,208 B, динамический interpreter `/lib64/ld-linux-x86-64.so.2`, required GLIBC symbols до2.38 по readelf. Есть три upstream dead-code warnings. Это lab ELF, не универсальный VPS/router package. [C1]

В build Cargo.toml Clap отключены стандартные features/help: `client --help` на полученном ELF возвращает ошибку unknown argument и Usage (rc2). Это успешный startup/parser probe, **не успешный help contract и не сетевой сеанс**. Future wrapper должен знать конкретный CLI, а не считать любой `--help !=0` доказательством плохого ELF. [C1] [C4]

ARM64 candidate: официальный Rust std `aarch64-unknown-linux-musl` той же версии + проверенный musl cross CC/AR, target-specific Cargo linker/CC env; `cargo build --locked --release --bin client --target aarch64-unknown-linux-musl`. **Vanilla exit101:** udp_batch.rs553/577 `flags` i32→u32 mismatch,643 private msghdr padding. Минимальный lab-only patch: привести flags к inferred libc type и zero-initialize C msghdr/mmsghdr, затем присвоить public iov fields. Это не patch KAS/upstream и не проверка корректности I/O на старом ядре. Результат повторной сборки — в [тестах](TRANSPORT-TEST-PLAN.md) и JSON. Серверный `build_linux.sh`/cargo-zigbuild для AMD64/ARM64/ARMv7 — reference, **не выполненный клиентский рецепт**. [C12] [C14]

MIPS gate до включения в matrix: target-tier/stdlib availability, custom target endian/softfloat/cpu, atomic/TLS behavior, AWS-LC C/asm support, linker, musl, time64 syscalls и exact kernel. Если нужен crypto-backend replacement, это уже порт с security review, не смена GOARCH. До решения не обещать сроки «один день на Rust MIPS». [D2] [C14]

## 5. GitHub Actions: build-only и отдельная публикация

1. **Dispatch + resolve (read-only):** вручную выбранный утверждённый source-lock ID, разрешённый repo/SHA, immutable toolchain digests. Permissions `contents:read`, no secrets, no production environments. Tag resolve→SHA сравнить с lock; moving tag abort. Никакого запуска upstream install scripts.
2. **License/dependency preflight:** `go list -deps -json`/`go version -m`, Cargo metadata locked + vendored native trees, C include/vendor inventory; SPDX scope, direct+transitive licenses, no unknown/conflicting terms. PolyForm channel opt-in с owner policy, GPL source/notice completeness. Failure до upload/publication. [E4] [C13]
3. **Build matrix:** wdtt-client4 targets, wdtt-serverAMD64, wg-obfs4 static musl; CSQTT только подтверждённые targets и разрешённый license channel. `fail-fast:false`, logs по target, timeout30min (проектное значение), resource caps; rerun не меняет dependency locks.
4. **Verification:** ELF machine/endian/softfloat/loader/NEEDED, sha256, expected flags, CLI/parser smoke native+QEMU, wire golden fixtures, tamper/truncation cases, port collision, readonly upstream tree. Cross smoke ≠ hardware pass. [O7] [O8] [C10]
5. **Reproducibility:** второй чистый job с тем же toolchain/source/epoch и другим path; SHA compare. При расхождении сохранить diffoscope/metadata, не ставить значок reproducible. C debug/build-id/path и Rust remap-path-prefix/target-dependent linker требуют фиксации.
6. **Bundle:** binary+SHA256SUMS+signed/attested manifest+source archive+patches+recipe+toolchain/dependency hashes+LICENSES/NOTICE+SBOM+compatibility.json+test-results. Actions artifact доступен ограниченно и не равен долговременному corresponding-source hosting.
7. **Publish workflow отдельно:** только `workflow_dispatch`, protected Environment с ручным owner approval; берёт **проверенный artifact digest из build run**, не пересобирает «тот же tag». contents:write только publisher; oidc/id-token при attestation только этой стадии. Не запускать из pull_request_target с untrusted code. Third-party Actions pin full reviewed commit SHA, не только @v4.
8. **Immutable release / retention:** уникальная версия вроде `wt-client-hoaxisr-1.4.0-kas.0+1110a75f.r1`, component manifests append-only; не перетирать старый healthy binary. Хранить N и N-1 + источники всех опубликованных версий; `latest` только pointer после acceptance. Не удалять старую проверенную архитектуру из-за partial matrix failure. [E2]

Новый build-only workflow в entware-go не должен давать себе право менять KAS stable/main, updater URLs или VPS systemd. Из исторического mihomo-auto-build берём урок provenance и license gate, а не прежние публикационные полномочия. Его jobs остаются отключёнными. [E3]

## 6. Диагностика build failure

| Класс | Сохранять | Действие |
|---|---|---|
| Go module mismatch / no lock | toolchain version, resolved mod/sum, exact import chain | Не `tidy` silently; review lock update |
| C/ASM crypto Rust | first failing compiler/link command, target, sysroot, AWS-LC config | Не переносить server dependencies на client; минимальный backend probe |
| MIPS hardfloat / endian | ELF header+attributes, disassembly sample | Reject артефакт до публикации |
| missing glibc loader / symbol version | PT_INTERP, NEEDED, version-info | Собирать musl либо exact Entware SDK; не symlink чужую libc |
| source tag gone / checksum drift | expected/actual SHA, mirror provenance | Stop; использовать verified cache, не менять URL на случайный fork |
| reproducibility diff | binaries, compiler/env/epoch, diffoscope | UNVERIFIED reproducibility; manual investigation |
| upstream warnings | полный capped log + classified baseline | Не прятать; Werror только после согласованного baseline |

Build/runtime logs должны быть bounded и synthetic-only; GitHub annotations и cache не должны содержать secrets. Публикационный gate требует отдельной проверки notices/source completeness и license scope: compile success не является правом распространения.

## Первичные источники

[C1]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/Cargo.toml#L1-L67
[C10]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/shared/wire_protocol.rs#L1-L6
[C12]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-server/build_linux.sh#L1-L85
[C13]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/LICENSE#L1-L84
[C14]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/udp_batch.rs#L525-L580
[C4]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/main.rs#L78-L165
[C9]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/protocol.rs#L1-L65
[D1]: https://go.dev/wiki/MinimumRequirements
[D2]: https://doc.rust-lang.org/rustc/platform-support.html
[D3]: https://github.com/cross-tools/musl-cross/releases/tag/20250520
[D4]: https://github.com/bogdanfinn/fhttp/blob/ecfe905c2db9d1ec769a16a14191ec84553dd235/doc.go#L1-L4
[E1]: https://github.com/saymer-alt/entware-go/blob/2c44dd44d14ffaa1a0a29f2008507e1b392ae597/go_env.mk#L1-L85
[E2]: https://github.com/saymer-alt/entware-go/blob/2c44dd44d14ffaa1a0a29f2008507e1b392ae597/.github/workflows/build-mihomo.yml#L97-L129
[E3]: https://github.com/saymer-alt/mihomo-auto-build/blob/f3fef398e023b2700e315093ac788b21c21342e7/README.md#L1-L35
[E4]: https://github.com/saymer-alt/mihomo-auto-build/blob/f3fef398e023b2700e315093ac788b21c21342e7/docs/GPL-SOURCE-AUDIT-2026-10-11.md#L36-L72
[L1]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/LICENSE#L1-L30
[O1]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/Makefile#L1-L65
[O10]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/.github/workflows/build.yml#L64-L140
[O2]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/Makefile#L100-L124
[O7]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/wg-obfuscator.c#L1035-L1120
[O8]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/wg-obfuscator.c#L1195-L1248
[Q2]: https://github.com/SpaceNeuroX/proxy-turn-vk-android/blob/a296c57eaba69bb9479a24f9157856490890e47d/go_client/session.go#L275-L325
[R10]: https://github.com/ildarmaga/wdtt/blob/ef697994bc7ac650b81623484933d930c5cd766b/server/go.mod#L1-L29
[R2]: https://github.com/kkvoru/wdtt-server-entware/blob/a61fdcfe206b9e00b89005e1c5c86f3e2d71abac/build_server.bat#L15-L40
[W1]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/go.mod#L1-L41
[W15]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/server.go#L1719-L1735
[W5]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/awgm_control.go#L150-L175


> Уточнения Phase 2 от 2026-10-11: сборки только entware-go/gh-action-build; предпочтительный свободный стенд KN-4210 после подключения и read-only preflight. ABI, ядро и RAM не предполагаются. KN-1010 испытывается отдельно от рабочей сети. Домашний Keenetic — production, эксперименты запрещены. Политика и матрица: [Phase 2](PHASE2-HARDWARE-AND-GATES.md). Результаты QEMU остаются лабораторными.
