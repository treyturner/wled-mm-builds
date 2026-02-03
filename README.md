# wled-mm-builds

Unofficial [WLED Moon Modules](https://mm.kno.wled.ge/) builds for [QuinLED](https://quinled.info/) hardware like the Dig2go, DigUno, DigQuad, and DigOcta as well as a few other boards.

## Targets

### QuinLED boards

- An-Penta-Mini
- An-Penta-Deca
- An-Penta-Plus
- Dig2go
- DigUno
- DigUno Ethernet
- DigUno Temp Sensor
- DigUno Ethernet + Temp Sensor
- DigQuad
- DigOcta

### Other boards

- Adafruit Matrix Portal S3 ([🔗](https://www.adafruit.com/product/5778))
- Lilygo T7 S3 ([🔗](https://lilygo.cc/en-us/products/t7-s3)) for MOONHUB75 ([🔗](https://github.com/MoonModules/Hardware/tree/main/MOONHUB75))
- Ai Thinker ESP32-A1S Audio Kit ([🔗](https://www.amazon.com/EC-Buying-ESP32-Audio-Kit-Development-ESP32-A1S/dp/B0B63KZ6C1)) as a dedicated audio sender

## Environment Variables

- `IOT_SSID`: If set, will be supplied to build as CLIENT_SSID
- `WPA_KEY`: If set, will be supplied to build as CLIENT

## Building

1. Clone repo

```bash
git clone https://forgejo.treyturner.info/treyturner/wled-mm-builds.git
```

2. Build

All targets:

```bash
make build GIT_REF="v14.7.1"
```

One or more space-separated targets:

```bash
make build GIT_REF="v14.7.1" PIO_ENVS="quinled_dig2go quinled_diguno_eth_temp"
```

Factory and OTA bins are emitted to `build/`.

FACTORY IMAGES SHOULD BE FLASHED AT 0x0:

```bash
esptool.py write_flash 0x0 WLEDMM_14.7.1_QuinLED_Dig2go.bin
```