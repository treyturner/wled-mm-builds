# wled-mm-builds

Unofficial [WLED Moon Modules](https://mm.kno.wled.ge/) builds for [QuinLED](https://quinled.info/) hardware as well as a few other boards. I'm affiliated with neither.

## Targets

### QuinLED boards

- [Dig2go](https://quinled.info/quinled-dig2go/)
- [DigUno](https://quinled.info/pre-assembled-quinled-dig-uno/) (including wired ethernet and temperature sensor variants)

### Other boards

- [Adafruit Matrix Portal S3](https://www.adafruit.com/product/5778)
 with [HUB75 support](https://mm.kno.wled.ge/2D/HUB75/)
- [Lilygo T7 S3](https://lilygo.cc/en-us/products/t7-s3) for [MOONHUB75](https://github.com/MoonModules/Hardware/tree/main/MOONHUB75)
- [Ai Thinker ESP32-A1S Audio Kit](https://www.amazon.com/EC-Buying-ESP32-Audio-Kit-Development-ESP32-A1S/dp/B0B63KZ6C1) as a **dedicated audio sender**

### Planned but not yet implemented

- [DigQuad](https://quinled.info/pre-assembled-quinled-dig-quad/)
- [DigOcta](https://quinled.info/quinled-dig-octa/)
- [An-Penta-Mini](https://quinled.info/quinled-an-penta-mini)
- [An-Penta-Deca](https://quinled.info/quinled-an-penta-deca/)
- [An-Penta-Plus](https://quinled.info/quinled-an-penta-plus/)

## Environment Variables

- `IOT_SSID`: If set, will be supplied to build as `CLIENT_SSID`
- `WPA_KEY`: If set, will be supplied to build as `CLIENT_PASS`

## Building

1. Clone and change directory into repo

    ```bash
    git clone https://github.com/treyturner/wled-mm-builds.git \
    && cd wled-mm-builds
    ```

1. Checkout WLED-MM source

    ```bash
    make checkout GIT_REF="v14.7.1"
    ```

1. Build
    1. All targets:

        ```bash
        make build GIT_REF="v14.7.1"
        ```

    1. Or one or more space-separated targets:

        ```bash
        make build GIT_REF="v14.7.1" PIO_ENVS="quinled_dig2go quinled_diguno_eth_temp"
        ```

1. Profit

    Factory and OTA bins are emitted to `build/`.

## Flashing

**FACTORY IMAGES SHOULD BE FLASHED AT `0x0`**:

```bash
esptool.py write_flash 0x0 WLEDMM_14.7.1_QuinLED_Dig2go.bin
```

⚠️ **Note:** A full erase and reflash is likely needed for v14.7.1 due to the transition to the v4 framework. Future updates should generally be OTA-compatible.
