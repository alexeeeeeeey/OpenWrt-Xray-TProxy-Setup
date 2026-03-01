# OpenWrt Xray TProxy

Установка Xray + tproxy на OpenWrt одной командой

Требования:
- OpenWrt 22.03+ (fw4 / nftables)
- только VLESS + REALITY (vless:// с параметрами reality)

## Быстрый запуск

```sh
opkg update && opkg install curl && sh -c "$(curl -fsSL https://raw.githubusercontent.com/alexeeeeeeey/OpenWrt-Xray-TProxy-Setup/main/install.sh)" -- 'vless://...'
```

С исключением из проксирования MAC адреса:

```sh
opkg update && opkg install curl && sh -c "$(curl -fsSL https://raw.githubusercontent.com/alexeeeeeeey/OpenWrt-Xray-TProxy-Setup/main/install.sh)" -- 'vless://...' '18:c0:4d:da:29:8b'
```

Xray запускается с 2 inbound: dokodemo-door (port 10808) и socks (port 10818), второй для проверки

```sh
curl ifconfig.me --socks5 127.0.0.1:10818
```

Включить/выключить прокси
```sh
/root/on.sh
/root/off.sh
```

## Что делает скрипт

- ставит `unzip`, `kmod-nft-tproxy`, `kmod-nf-tproxy`, `curl`
- скачивает Xray Core
- генерирует `/etc/xray/config.json` из `vless://` ссылки
- создает `/etc/xray/nft.rules`, `/etc/init.d/xray`, `/etc/init.d/xray-tproxy`, `/root/on.sh`, `/root/off.sh`
- включает и запускает сервисы
