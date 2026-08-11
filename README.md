# OpenWrt Xray TProxy (Web + CLI)

Установка Xray + TProxy + менеджер конфигурации на OpenWrt одной командой.

Что умеет:

- веб-интерфейс для OpenWrt и прежний консольный менеджер
- несколько подключений с быстрым переключением, как в Happ
- VLESS с REALITY, XHTTP, gRPC и WebSocket
- Hysteria2 (`hysteria2://` и `hy2://`)
- подписки с импортом всех нод или выбором одной ноды из CLI
- повторный выбор ноды без переустановки
- SOCKS5 upstream, включая локальный `127.0.0.1:1080`
- локальный SOCKS listener для тестов и приложений
- bypass по MAC и доменным правилам с добавлением, удалением и включением/выключением
- проверка Xray/nft перед применением конфига
- автоопределение архитектуры Xray

---

## Требования

- OpenWrt 22.03+ (fw4 / nftables)
- архитектура устройства поддерживается Xray
- для входа в веб-интерфейс должен быть задан пароль `root` (`passwd`)

---

## Установка

```sh
opkg update && opkg install ca-bundle ca-certificates uclient-fetch && uclient-fetch -q -O - https://raw.githubusercontent.com/alexeeeeeeey/OpenWrt-Xray-TProxy-Setup/main/install.sh | sh
```

После установки доступен менеджер:

```sh
xray-manager
```

Веб-интерфейс:

```text
http://192.168.1.1/xray-manager/
```

Используется встроенный `uhttpd`. Страница и CGI защищены root-паролем OpenWrt. Если пароль ещё не задан:

```sh
passwd
/etc/init.d/uhttpd restart
```

---

## Несколько подключений

В веб-интерфейсе можно вставить сразу несколько ссылок — по одной на строку. Если вставить URL подписки, все поддерживаемые ноды будут добавлены отдельными профилями и сгруппированы по источнику. Каждую подписку можно обновить отдельно или обновить все сразу.

То же из консоли:

```sh
xray-manager add-link 'vless://...'
xray-manager add-link 'hysteria2://...'
xray-manager import-links 'https://example.com/subscription'
xray-manager refresh-links 'https://example.com/subscription'
xray-manager refresh-all-links
xray-manager list-links
xray-manager use-link <id>
xray-manager disable-link <id>
xray-manager enable-link <id>
xray-manager del-link <id>
```

Звёздочка в `list-links` отмечает активный профиль. `use-link` выбирает профиль и сразу применяет конфигурацию; `select-link` только сохраняет выбор.

---

## Быстрый старт

### VLESS / REALITY / XHTTP / gRPC

Сохранить и сразу применить:

```sh
xray-manager use 'vless://...'
```

Только сохранить без применения:

```sh
xray-manager set 'vless://...'
xray-manager apply
```

Транспорт определяется параметром ссылки `type`, в том числе `type=xhttp` и `type=grpc`. REALITY определяется через `security=reality` и стандартные параметры `pbk`, `sid`, `sni`, `fp`.

### Hysteria2

Поддерживаются обе распространённые схемы ссылки:

```sh
xray-manager use 'hysteria2://password@example.com:443/?sni=example.com'
xray-manager use 'hy2://password@example.com:443/?sni=example.com'
```

Также разбираются `insecure`, `fp`, `pinSHA256` и Salamander obfs через `obfs=salamander&obfs-password=...`.

---

## Подписка с выбором подключения

Старый интерактивный импорт показывает список доступных VLESS, Hysteria2 и SOCKS подключений и сохраняет выбранную ноду.

```sh
xray-manager use 'https://example.com/subscription'
```

Менеджер попросит выбрать номер ноды. Выбор сохраняется в `SUBSCRIPTION_PICK`, поэтому `refresh` будет обновлять именно выбранную ноду.

Посмотреть список заново:

```sh
xray-manager list-nodes
```

Выбрать другую ноду:

```sh
xray-manager select-node 3
xray-manager apply
```

Обновить подписку вручную:

```sh
xray-manager refresh
```

---

## SOCKS upstream

Если на роутере или рядом уже есть локальный SOCKS5, можно пустить TProxy через него.

По умолчанию используется `127.0.0.1:1080`:

```sh
xray-manager use-socks
```

С явным host/port:

```sh
xray-manager use-socks 127.0.0.1 1080
```

С авторизацией:

```sh
xray-manager use 'socks://user:pass@127.0.0.1:1080'
```

Важно: SOCKS сам по себе не шифрует трафик, поэтому этот режим лучше использовать для локального upstream.

---

## Локальный SOCKS для приложений

Xray поднимает локальный SOCKS5 listener:

```sh
127.0.0.1:10818
```

Проверка:

```sh
xray-manager test
```

Для `test` нужен рабочий `curl`, потому что он умеет проверять именно SOCKS. Установка, импорт подписок и обновление подписок используют `curl` только если он исправен, иначе переходят на `wget` / `uclient-fetch`.

Изменить адрес/порт listener:

```sh
xray-manager set-local-socks 127.0.0.1 10818
xray-manager apply
```

---

## Управление

```sh
xray-manager menu
xray-manager show
xray-manager show-secret
xray-manager status
xray-manager doctor
xray-manager on
xray-manager off
```

`show` не печатает полный текущий URL с секретами. Для отладки есть `show-secret`.

---

## Routing bypass rules

Правила хранятся в `/etc/xray-manager/config` как `BYPASS_RULES` и попадают в Xray `routing.rules` во время `apply` / `refresh`.

Правила по умолчанию:

```sh
domain:restream-media.net
.ru
.xn--p1ai
```

Примеры:

```sh
xray-manager add-bypass-rule 'vk.com'
xray-manager add-bypass-rule '.youtube.com'
xray-manager add-bypass-rule 'domain:restream-media.net'
xray-manager list-bypass-rules
xray-manager disable-bypass-rule 'domain:restream-media.net'
xray-manager enable-bypass-rule 'domain:restream-media.net'
xray-manager del-bypass-rule 'vk.com'
xray-manager apply
```

MAC bypass остаётся в `nftables`, потому что Xray routing не матчится по MAC.

---

## Bypass MAC

```sh
xray-manager add-bypass-mac aa:bb:cc:dd:ee:ff
xray-manager disable-bypass-mac aa:bb:cc:dd:ee:ff
xray-manager enable-bypass-mac aa:bb:cc:dd:ee:ff
xray-manager del-bypass-mac aa:bb:cc:dd:ee:ff
xray-manager list-bypass-mac
xray-manager apply
```

---

## Настройки без лишних цифр

Дефолты уже заданы:

- LAN interface: `br-lan`
- TProxy inbound: `10808`
- local SOCKS listener: `127.0.0.1:10818`
- local SOCKS upstream shortcut: `127.0.0.1:1080`
- fwmark: `1`
- routing table: `100`

Обычно руками нужен только URL, подписка или команда `use-socks`.

Если LAN интерфейс отличается:

```sh
xray-manager set-lan-iface br-lan
xray-manager apply
```

---

## Что создаётся

- `/usr/bin/xray`
- `/usr/bin/xray-manager`
- `/etc/xray/config.json`
- `/etc/xray/nft.rules`
- `/etc/init.d/xray`
- `/etc/init.d/xray-tproxy`
- `/etc/xray-manager/config`
- `/etc/xray-manager/links`
- `/www/xray-manager/`
- `/www/cgi-bin/xray-manager`

---

## Архитектура

Inbounds:

- `local-socks` (`127.0.0.1:10818`) для тестов и локальных приложений
- `tproxy` (`10808`) для прозрачного проксирования LAN

Outbounds:

- `proxy`: VLESS или SOCKS5 upstream
- `direct`: прямой выход для bypass
- `block`: blackhole

---

## Автообновление подписки

Пример: раз в 6 часов.

```sh
echo "0 */6 * * * /usr/bin/xray-manager refresh" >> /etc/crontabs/root
/etc/init.d/cron restart
```

---

## Диагностика

```sh
xray-manager doctor
xray-manager status
xray-manager test
```

`doctor` проверяет state, Xray config и nft rules. Если новый конфиг не проходит проверку, старый рабочий конфиг не перезаписывается.

Если после `opkg install curl` появляется ошибка вида `symbol not found`, значит `curl` и `libcurl` не совпали по версии. Для установки менеджера `curl` больше не нужен:

```sh
opkg update
opkg install ca-bundle ca-certificates uclient-fetch
uclient-fetch -q -O - https://raw.githubusercontent.com/alexeeeeeeey/OpenWrt-Xray-TProxy-Setup/main/install.sh | sh
```
