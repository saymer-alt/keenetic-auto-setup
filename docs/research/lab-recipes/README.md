# Рецепты выполненной лаборатории

Это наши исследовательские scripts, **не установщики KAS и не production CI**. Они компилируют в локальную lab directory, не устанавливают transport services. Для Python build scripts использовались Windows+Go1.27.0+WSL Linux; runtime probe запускался python3 внутри WSL. Пользовательские devices/VPS не нужны и не затрагиваются.

`probe_csqtt_musl_patch.py` и [лабораторный diff](CSQTT-musl-ABI-lab.patch) содержат небольшой фрагмент исходного CSQTT, Copyright2026 amurcanov. Для него сохранены [полные PolyForm terms и Required Notices](LICENSES/CSQTT-PolyForm-Noncommercial-1.0.0.txt). Проба относится только к некоммерческому исследованию; не является лицензией на коммерческую интеграцию или разрешением публиковать transport binaries. Изменены flags casts и инициализация C header, upstream/KAS source не менялся.

Required Notice: Copyright 2026 amurcanov.
Required Notice: Commercial use of CSQTT requires a separate written license from the licensor.
Required Notice: Redistributions and derivative works must retain attribution to the original CSQTT project and these notices.

Рабочий layout относительно этих scripts:

```text
repos/hoaxisr__proxy-turn-vk-android/     # exact1110a75f76e42c23149b8e24f9182c1ff179e515
repos/ClusterM__wg-obfuscator/           # exact7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f
repos/amurcanov__csqtt/                 # exact71712b07dbabe16fa43f5a248dc69e1ab9f3a270
evidence/rust-1.97.1.toml              # official channel manifest
lab/                                  # generated caches/toolchains/binaries/results
```

Rust manifest получать с `https://static.rust-lang.org/dist/channel-rust-1.97.1.toml`; его digest и архивные hashes записаны в [evidence](../TRANSPORT-RESEARCH-EVIDENCE.json). Не заменять manifest другой версией молча. Compiler archives/install prefix строго под lab; gcc/readelf/qemu нужны в WSL. Скрипты C сверяют sidecars upstream release20250520; для повторения pinned build дополнительно сравнить с записанными SHA256, как описано в [плане сборок](../TRANSPORT-BUILD-PLAN.md).

Порядок: build_wdtt → build_extra; build_obfuscator → probe_runtime; build_csqtt → build_csqtt_arm64; test_csqtt после завершения Cargo build (общий target lock). run_socks_probe использует socks_probe.go, создаёт отдельный Go module; library revision pinned, x/net разрешается отдельно и lock сохраняется в lab. CLI probes, synthetic forwarding и узкие upstream tamper tests не равны crypto audit/real VPN/hardware acceptance.

[Индекс](../README.md) · [Все выполненные результаты и ограничения](../TRANSPORT-TEST-PLAN.md)
