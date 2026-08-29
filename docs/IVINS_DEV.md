# Official IVINS DEV runtime in NewSIM

NewSIM uses the signed Ubuntu 24.04 Noble AMD64 IVINS package matrix installed
inside `INDRA-COSYS-SIM`. The default `-IvinsRuntime installed` path sources
`/opt/iros2j`, `/opt/imavros`, `/opt/vins`, and `/opt/vio_stack/current`, then
builds only the repository-owned `vins_sim_bringup` adapter. It does not compile
or override an installed IVINS component.

The installed matrix uses the iHUB 0.3.2 Cosys backend directly and fixes the
camera pitch convention explicitly at `+1.0`. It neither loads nor accepts the
legacy `IHUB_SIM_BRIDGE` compatibility library. That library remains limited to
the explicit source-development fallback.

`ivins doctor` accepts only the exact signed IVINS 3.1.0.0 schema-4 manifest
for `ubuntu24-amd64-newsim`, then runs the package-owned NewSIM preflight. The
preflight verifies every pinned Debian package version and rejects Raspberry
Pi production entrypoints or `iboot-kalibr`.

`-IvinsRuntime source` is an explicit component-development fallback. Its runs
cannot serve as official enrollment, delivery, update, or IVINS release
evidence.

## Enrollment

An administrator first creates a one-time DEV enrollment for the NewSIM device
at `https://ivins.drone-age.org`. Put the key in a bounded root-owned WSL file
with mode `0600`; do not place it in the repository, PowerShell history, logs,
or a Windows-mounted path. Then run:

```powershell
.\dev.ps1 ivins -IvinsCommand doctor
.\dev.ps1 ivins -IvinsCommand enroll -IvinsEnrollmentKeyFile /root/ivins-enrollment.key
.\dev.ps1 ivins -IvinsCommand status
```

The wrapper always uses the official HTTPS endpoint and passes only the WSL
key-file path to the installer. The installer consumes the file only after the
signed initial delivery succeeds.

`dev.ps1 setup` creates `/etc/ivins/newsim-platform` and a persistent random
`/etc/ivins/newsim-instance-id` as immutable root-owned identity markers. The
instance ID is reused across runs and updates; setup refuses to replace a
conflicting marker. `ivins doctor` verifies both files before enrollment.

## Updates

The installed agent polls and stages a server-approved signed delivery without
applying it. Application still requires exact local intent through iBoot:

```powershell
.\dev.ps1 ivins -IvinsCommand sync
.\dev.ps1 ivins -IvinsCommand update-check
.\dev.ps1 ivins -IvinsCommand update-status
.\dev.ps1 ivins -IvinsCommand update-install -IvinsVersion 3.1.0.0
```

`update-install` accepts only an exact four-component product version. The
installer remains the sole owner of signature verification, staging, package
application, reboot recovery, health verification, reporting, and rollback.

## Qualification

After the installed matrix is healthy, collect separate immutable evidence for
Blocks and `sim2-rural`:

```powershell
.\dev.ps1 ros-test -Environment blocks -IvinsRuntime installed
.\dev.ps1 vins-test -Environment blocks -IvinsRuntime installed
.\dev.ps1 test -Environment blocks -WithRos2 -IvinsRuntime installed

.\dev.ps1 ros-test -Environment sim2-rural -Preview -IvinsRuntime installed
.\dev.ps1 vins-test -Environment sim2-rural -Preview -IvinsRuntime installed
.\dev.ps1 test -Environment sim2-rural -Preview -WithRos2 -IvinsRuntime installed
```

Camera-rate gates and any applicable climb/route gates remain separate and must
retain their existing fail-closed verdict semantics.
