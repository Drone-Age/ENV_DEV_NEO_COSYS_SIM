# Офіційний IVINS DEV runtime у NewSIM

NewSIM використовує підписану матрицю IVINS для Ubuntu 24.04 Noble AMD64,
встановлену всередині `INDRA-COSYS-SIM`. Типовий режим
`-IvinsRuntime installed` підключає `/opt/iros2j`, `/opt/imavros`, `/opt/vins`
і `/opt/vio_stack/current`, після чого збирає лише адаптер NewSIM
`vins_sim_bringup`. Встановлені компоненти IVINS не компілюються й не
перекриваються.

`-IvinsRuntime source` є явним fallback для розробки компонентів. Його прогони
не можуть бути офіційним evidence enrollment, delivery, update чи IVINS
release.

## Реєстрація

Адміністратор спочатку створює одноразову DEV enrollment для пристрою NewSIM
на `https://ivins.drone-age.org`. Ключ треба зберегти в обмеженому root-owned
WSL-файлі з mode `0600`; його не можна класти в repository, PowerShell history,
logs або Windows-mounted path. Далі виконайте:

```powershell
.\dev.ps1 ivins -IvinsCommand doctor
.\dev.ps1 ivins -IvinsCommand enroll -IvinsEnrollmentKeyFile /root/ivins-enrollment.key
.\dev.ps1 ivins -IvinsCommand status
```

Wrapper завжди використовує офіційний HTTPS endpoint і передає installer лише
WSL-шлях до key file. Installer видаляє файл тільки після успішного signed
initial delivery.

`dev.ps1 setup` створює `/etc/ivins/newsim-platform` і постійний випадковий
`/etc/ivins/newsim-instance-id` як незмінні root-owned маркери ідентичності.
Instance ID повторно використовується між запусками й оновленнями; setup
відмовляється замінювати конфліктний marker. Перед enrollment команда
`ivins doctor` перевіряє обидва файли.

## Оновлення

Встановлений agent опитує сервер і автоматично stage-ить погоджений signed
delivery, але не застосовує його. Застосування вимагає точного локального intent
через iBoot:

```powershell
.\dev.ps1 ivins -IvinsCommand sync
.\dev.ps1 ivins -IvinsCommand update-check
.\dev.ps1 ivins -IvinsCommand update-status
.\dev.ps1 ivins -IvinsCommand update-install -IvinsVersion 3.1.0.4
```

`update-install` приймає лише точну чотирикомпонентну product version. Installer
залишається єдиним власником signature verification, staging, package apply,
reboot recovery, health verification, reporting і rollback.

## Кваліфікація

Після підтвердження здорової встановленої матриці треба створити окреме
immutable evidence для Blocks і `sim2-rural`:

```powershell
.\dev.ps1 ros-test -Environment blocks -IvinsRuntime installed
.\dev.ps1 vins-test -Environment blocks -IvinsRuntime installed
.\dev.ps1 test -Environment blocks -WithRos2 -IvinsRuntime installed

.\dev.ps1 ros-test -Environment sim2-rural -Preview -IvinsRuntime installed
.\dev.ps1 vins-test -Environment sim2-rural -Preview -IvinsRuntime installed
.\dev.ps1 test -Environment sim2-rural -Preview -WithRos2 -IvinsRuntime installed
```

Camera-rate gates та застосовні climb/route gates залишаються окремими й мають
зберігати чинну fail-closed verdict semantics.
