# Universal MikroTik VLAN Config Generator

Перша версія генератора конфігурацій RouterOS 7 для двох ролей:

- `gateway`: WAN, VLAN routing, DHCP, NAT, firewall, локальні WiFi SSID;
- `access-point`: VLAN trunk, access-порти, WiFi та окремий management VLAN.

Генератор підтримує обидва WiFi-стеки MikroTik:

- `wifi`: новий `/interface wifi`;
- `wireless`: старий `/interface wireless`.

## Важливо

Скрипти розраховані на чисту конфігурацію після:

```routeros
/system reset-configuration no-defaults=yes skip-backup=yes
```

Reset виконуйте окремо. Генератор навмисно не додає руйнівну команду reset у `.rsc`.

Перед reset збережіть export і backup. Перший імпорт краще робити через serial console, MAC Winbox або порт, який не бере участі в новому bridge.

## Файли

- `Generate-MikroTikConfig.ps1` - генератор;
- `configs/gateway.example.json` - головний роутер;
- `configs/ap-legacy.example.json` - AP зі старим `wireless`;
- `configs/ap-wifi.example.json` - AP з новим `wifi`;
- `generated/*.rsc` - готові результати генерації.

## Ваша схема у прикладах

| VLAN | Назва | Підмережа | Призначення |
|---:|---|---|---|
| 888 | `mgmt` | `10.11.88.0/24` | керування |
| 100 | `work` | `10.11.100.0/24` | робоча мережа |
| 200 | `guest` | `10.11.200.0/24` | гостьова мережа |

Gateway:

- `ether1` - WAN через DHCP;
- `ether2` - tagged trunk 888/100/200;
- `ether3` - untagged access VLAN 100;
- `ether5` - untagged access VLAN 888;
- `wifi1` - WORK/VLAN 100;
- `wifi2` - GUEST/VLAN 200.

Legacy AP:

- `ether1` - tagged trunk;
- `ether5` - management access VLAN 888;
- `wlan2` - WORK/VLAN 100;
- `wlan1` - GUEST/VLAN 200;
- IP самого AP - `10.11.88.2/24` на VLAN-інтерфейсі, не на bridge.

## Генерація

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Generate-MikroTikConfig.ps1 `
  -ConfigPath .\configs\gateway.example.json `
  -OutputPath .\generated\gateway.rsc

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Generate-MikroTikConfig.ps1 `
  -ConfigPath .\configs\ap-legacy.example.json `
  -OutputPath .\generated\ap-legacy.rsc

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Generate-MikroTikConfig.ps1 `
  -ConfigPath .\configs\ap-wifi.example.json `
  -OutputPath .\generated\ap-wifi.rsc
```

Обов'язково змініть `CHANGE-ME-...` паролі у JSON і згенеруйте файли повторно.
Готовий `.rsc` містить WiFi-паролі відкритим текстом, тому не публікуйте його.

Поле `wifi.country` має відповідати країні, де фізично працює роутер. Потужність передавача вручну не задається: RouterOS застосовує регуляторні обмеження вибраної країни.

## Імпорт на RouterOS

Завантажте потрібний `.rsc` у Files, перегляньте його і виконайте:

```routeros
/import file-name=gateway.rsc verbose=yes
```

Для AP використайте відповідний `ap-legacy.rsc` або `ap-wifi.rsc`.

## Закладені правила безпеки

- `vlan-filtering` вмикається останньою командою;
- trunk приймає лише tagged frames;
- access-порти приймають лише untagged/priority-tagged frames;
- IP керування AP знаходиться на `vlan888-mgmt`;
- VLAN-и не маршрутизуються один до одного;
- усі VLAN-и мають доступ до WAN;
- клієнти GUEST ізольовані один від одного на WiFi;
- Winbox та SSH доступні лише з management subnet;
- Telnet, FTP, HTTP та API вимкнені;
- DNS redirect відсутній.

## Межі першої версії

- тільки RouterOS 7;
- WAN поки що тільки DHCP;
- конфігурація призначена для чистого роутера, а не для міграції діючого;
- IPv6 поки не налаштовується;
- CAPsMAN, VPN, QoS і винятки між VLAN поки не включені;
- відповідність `wifi1/wifi2` або `wlan1/wlan2` діапазонам 2.4/5 GHz треба перевірити на конкретній моделі.

## Перевірка після імпорту

```routeros
/interface bridge vlan print
/interface bridge port print
/ip address print
/ip dhcp-server print
/ip firewall filter print
```

На AP додатково:

```routeros
/ping 10.11.88.1
```

Очікувані адреси:

- WORK: `10.11.100.10-10.11.100.100`;
- GUEST: `10.11.200.10-10.11.200.100`;
- MGMT: `10.11.88.10-10.11.88.50`.

## Git workflow

RouterOS не запускає Git напряму. Репозиторій зберігає генератор, приклади та історію змін, а конфігурація передається на MikroTik через SSH/SFTP.

Рекомендований цикл роботи:

```powershell
git switch -c feature/change-vlan-layout
# Відредагуйте example JSON та/або генератор.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-MikroTikConfigs.ps1
git add .
git commit -m "Update MikroTik VLAN layout"
git push
```

Для реального роутера створіть локальний файл, який не потрапить у commit:

```powershell
New-Item -ItemType Directory -Force .\configs\local | Out-Null
Copy-Item .\configs\gateway.example.json .\configs\local\gateway.json
# Відредагуйте configs\local\gateway.json і встановіть реальні паролі.
```

Каталоги `configs/local`, `generated/local` і `backups` ігноруються Git. Саме у `configs/local` потрібно зберігати реальні WiFi-паролі. Не записуйте ключі чи паролі у tracked JSON, workflow або командний рядок.

GitHub Actions автоматично запускає `Test-MikroTikConfigs.ps1` для кожного push у `main` і pull request. Перевірка генерує всі приклади повторно та падає, якщо tracked `.rsc` застаріли або порушено основні інваріанти.

## Deployment через SSH

Windows OpenSSH Client уже надає `ssh.exe` та `scp.exe`. Спочатку перевірте звичайне підключення:

```powershell
ssh admin@10.11.88.1
```

Краще використовувати окремий SSH-ключ, а не пароль. Публічний ключ потрібно завантажити у Files та імпортувати на RouterOS:

```routeros
/user/ssh-keys/import public-key-file=mikrotik_deploy.pub user=admin
```

Генерація, upload та безпечний `dry-run` без застосування:

```powershell
.\Deploy-MikroTikConfig.ps1 `
  -RouterHost 10.11.88.1 `
  -User admin `
  -IdentityFile "$env:USERPROFILE\.ssh\mikrotik_deploy" `
  -ConfigPath .\configs\local\gateway.json
```

Після перевірки результату застосуйте той самий профіль:

```powershell
.\Deploy-MikroTikConfig.ps1 `
  -RouterHost 10.11.88.1 `
  -User admin `
  -IdentityFile "$env:USERPROFILE\.ssh\mikrotik_deploy" `
  -ConfigPath .\configs\local\gateway.json `
  -Apply
```

Скрипт не вимикає перевірку SSH host key, не передає пароль у параметрах і не виконує reset. За замовчуванням він:

1. генерує тимчасовий `.rsc` поза репозиторієм;
2. відмовляється працювати з `CHANGE-ME` паролями;
3. завантажує файл через SCP/SFTP;
4. виконує `/import ... verbose=yes dry-run=yes`;
5. застосовує конфіг лише за наявності `-Apply`;
6. видаляє тимчасовий файл з роутера.

Поточна версія конфігурації призначена для чистого RouterOS. Вона не робить автоматичну міграцію діючого роутера і не запускає `/system reset-configuration`. Для першого розгортання reset та відновлення доступу слід планувати окремо через MAC Winbox, serial console або `run-after-reset`.

## Deployment з GitHub

Звичайний GitHub-hosted runner не бачить приватну адресу MikroTik. Для автоматичного deployment потрібен один із варіантів:

- self-hosted GitHub runner у вашій management VLAN;
- VPN між runner та management мережею;
- локальний сервер, який після merge виконує `Deploy-MikroTikConfig.ps1`.

Приватний SSH-ключ має зберігатися у credential store runner або GitHub Actions Secret, а не в репозиторії. На цьому етапі workflow виконує лише перевірку і нічого не змінює на роутерах.
