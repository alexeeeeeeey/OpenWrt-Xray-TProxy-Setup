# OpenWrt Xray TProxy (Manager Edition)

Установка Xray + TProxy + менеджер конфигурации на OpenWrt одной командой.

- можно менять ссылку без переустановки
- есть поддержка подписок
- ручное обновление (`refresh`)
- тест прокси через SOCKS
- несколько bypass MAC

---

## Требования

- OpenWrt 22.03+ (fw4 / nftables)
- архитектура устройства поддерживается Xray
- VLESS (желательно REALITY)

---

## Установка

```sh
opkg update && opkg install curl && sh -c "$(curl -fsSL https://raw.githubusercontent.com/alexeeeeeeey/OpenWrt-Xray-TProxy-Setup/main/install.sh)"
```

После установки доступен менеджер:

```sh
xray-manager
```

---

## Быстрый старт

### Обычная VLESS ссылка

```sh
xray-manager set 'vless://...'
xray-manager apply
```

---

## Routing bypass rules

These rules are now stored in `/etc/xray-manager/config` as `BYPASS_RULES` and are written into Xray `routing.rules` during `apply` / `refresh`.

Default rules:

```sh
domain:restream-media.net
.ru
.xn--p1ai
```

Examples:

```sh
xray-manager add-bypass-rule 'vk.com'
xray-manager add-bypass-rule '.youtube.com'
xray-manager add-bypass-rule 'domain:restream-media.net'
xray-manager list-bypass-rules
xray-manager del-bypass-rule 'vk.com'
```

Note:

- MAC bypass is still handled in `nftables`, because Xray `routing` itself does not match clients by MAC address.

---

### Подписка

```sh
xray-manager set 'https://example.com/subscription'
xray-manager refresh
```

---

## Тест прокси

```sh
xray-manager test
```

Эквивалент:

```sh
curl --socks5 127.0.0.1:10818 ifconfig.me
```

---

## Управление

### Основные команды

```sh
xray-manager menu
xray-manager show
xray-manager status
```

---

### Включить / выключить

```sh
xray-manager on
xray-manager off
```

---

## Подписки

### Обновить вручную

```sh
xray-manager refresh
```

Важно:
- обновление **не автоматическое**
- вызывается только вручную или через cron

---

### Автообновление (пример)

Раз в 6 часов:

```sh
echo "0 */6 * * * /usr/bin/xray-manager refresh" >> /etc/crontabs/root
/etc/init.d/cron restart
```

---

## Bypass MAC (несколько устройств)

### Добавить

```sh
xray-manager add-bypass-mac aa:bb:cc:dd:ee:ff
```

### Удалить

```sh
xray-manager del-bypass-mac aa:bb:cc:dd:ee:ff
```

### Список

```sh
xray-manager list-bypass-mac
```

---

## Что делает система

- ставит пакеты:
  - `kmod-nft-tproxy`
  - `kmod-nf-tproxy`
  - `curl`, `unzip`, `openssl`, `base64`
- скачивает Xray Core
- создаёт:
  - `/etc/xray/config.json`
  - `/etc/xray/nft.rules`
  - init-скрипты
- добавляет менеджер:
  - `/usr/bin/xray-manager`
- включает и запускает сервисы

---

## Архитектура

- inbound:
  - `dokodemo-door` (10808) — tproxy
  - `socks` (10818) — тестирование
- routing:
  - локальные сети bypass
  - заданные MAC bypass
- outbound:
  - VLESS (REALITY)

---

## Важно

### apply vs refresh

```sh
xray-manager apply
```

- пересобирает конфиг
- перезапускает Xray
- если режим subscription → также подтягивает обновление

```sh
xray-manager refresh
```

- только обновляет подписку
- затем применяет

---

## Ограничения

- из подписки берётся **первая валидная VLESS ссылка**
- нет выбора ноды (пока)
- нет LuCI интерфейса
- нет автообновления без cron

---

## Диагностика

### Проверка Xray

```sh
xray-manager status
```

### Проверка прокси

```sh
xray-manager test
```

---

## Минимальный workflow

```sh
xray-manager set 'https://sub'
xray-manager refresh
xray-manager test
```

или

```sh
xray-manager set 'vless://...'
xray-manager apply
```
