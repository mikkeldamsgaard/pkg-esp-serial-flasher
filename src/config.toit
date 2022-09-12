import .esp_serial_flasher
import .protocol

CHIP_DETECT_MAGIC_REG_ADDR_ ::= 0x40001000

ESP8266_SPI_REG_BASE_ ::=  0x60000200
ESP32S2_SPI_REG_BASE_ ::=  0x3f402000
ESP32xx_SPI_REG_BASE_ ::=  0x60002000
ESP32_SPI_REG_BASE_   ::=  0x3ff42000

CHIP_TYPE_ESP8266_ ::= 0
CHIP_TYPE_ESP32_   ::= 1

abstract class ChipConfig:
  chip_type/int
  name/string
  cmd/int
  usr/int
  usr1/int
  usr2/int
  w0/int
  mosi_dlen/int
  miso_dlen/int
  efuse_base/int
  chip_magic_numbers/Set
  supports_encryption/bool
  ram_block_size/int

  abstract read_spi_config protocol/Protocol -> int

  constructor --.chip_type --.name --.cmd --.usr --.usr1 --.usr2 --.w0 \
              --.mosi_dlen --.miso_dlen --.efuse_base --.chip_magic_numbers \
              --.supports_encryption --.ram_block_size=0x1000:

class ESP8266Config extends ChipConfig:
  constructor:
    super
        --chip_type  = CHIP_TYPE_ESP8266_
        --name       = "ESP8266"
        --cmd        = ESP8266_SPI_REG_BASE_ + 0x00
        --usr        = ESP8266_SPI_REG_BASE_ + 0x1c
        --usr1       = ESP8266_SPI_REG_BASE_ + 0x20
        --usr2       = ESP8266_SPI_REG_BASE_ + 0x24
        --w0         = ESP8266_SPI_REG_BASE_ + 0x40
        --miso_dlen  = 0
        --mosi_dlen  = 0
        --efuse_base = 0 // Not used
        --chip_magic_numbers = { 0xfff0c101, 0 }
        --supports_encryption = false

  read_spi_config protocol/Protocol -> int: // not used
    return 0

adjust_pin_number_ num/int -> int:
  return (num >= 30) ? num + 2 : num;

class ESP32Config extends ChipConfig:
  constructor:
    super
        --chip_type = CHIP_TYPE_ESP32_
        --name       = "ESP32"
        --cmd        = ESP32_SPI_REG_BASE_ + 0x00
        --usr        = ESP32_SPI_REG_BASE_ + 0x1c
        --usr1       = ESP32_SPI_REG_BASE_ + 0x20
        --usr2       = ESP32_SPI_REG_BASE_ + 0x24
        --w0         = ESP32_SPI_REG_BASE_ + 0x80
        --mosi_dlen  = ESP32_SPI_REG_BASE_ + 0x28
        --miso_dlen  = ESP32_SPI_REG_BASE_ + 0x2c
        --efuse_base = 0x3ff5A000
        --chip_magic_numbers = { 0x00f01d83, 0 }
        --supports_encryption = false

  read_spi_config protocol/Protocol -> int:
    reg5 := protocol.read_register efuse_base + 4*5
    reg3 := protocol.read_register efuse_base + 4*3

    pins := reg5 & 0xfffff

    if pins == 0 or pins == 0xfffff: return 0

    clk := adjust_pin_number_ (pins >> 0)  & 0x1f
    q   := adjust_pin_number_ (pins >> 5)  & 0x1f
    d   := adjust_pin_number_ (pins >> 10) & 0x1f
    cs  := adjust_pin_number_ (pins >> 15) & 0x1f
    hd  := adjust_pin_number_ (reg3 >> 4)  & 0x1f

    if clk == cs or clk == d or clk == q or q == cs or q == d or q == d: return 0

    return (hd << 24) | (cs << 18) | (d << 12) | (q << 6) | clk


abstract class ESP32XXConfig extends ChipConfig:
  constructor --name --efuse_base --chip_magic_numbers --reg_base/int=ESP32xx_SPI_REG_BASE_ --supports_encryption/bool:
    super
        --chip_type  = CHIP_TYPE_ESP32_
        --name       = name
        --cmd        = reg_base + 0x00
        --usr        = reg_base + 0x18
        --usr1       = reg_base + 0x1c
        --usr2       = reg_base + 0x20
        --w0         = reg_base + 0x58
        --mosi_dlen  = reg_base + 0x24
        --miso_dlen  = reg_base + 0x28
        --efuse_base = efuse_base
        --chip_magic_numbers = chip_magic_numbers
        --supports_encryption = supports_encryption

  read_spi_config protocol/Protocol -> int:
    reg1 := protocol.read_register efuse_base + 4 * 18
    reg2 := protocol.read_register efuse_base + 4 * 19

    pins := ((reg1 >> 16) | ((reg2 & 0xfffff) << 16)) & 0x3fffffff

    if pins == 0 or pins == 0xffffffff: return 0
    return pins

class ESP32C2Config extends ESP32XXConfig:
  constructor:
    super
      --name      = "ESP32C2"
      --efuse_base = 0x60008800
      --chip_magic_numbers = { 0x6f51306f, 0 }
      --supports_encryption = false

class ESP32C3Config extends ESP32XXConfig:
  constructor:
    super
      --name      = "ESP32C3"
      --efuse_base = 0x60008800
      --chip_magic_numbers = { 0x6921506f, 0x1b31506f }
      --supports_encryption = true

class ESP32S2Config extends ESP32XXConfig:
  constructor:
    super
      --name      = "ESP32S2"
      --efuse_base = 0x3f41A000
      --chip_magic_numbers = { 0x000007c6, 0 }
      --reg_base = ESP32S2_SPI_REG_BASE_
      --supports_encryption = true

class ESP32S3Config extends ESP32XXConfig:
  constructor:
    super
      --name      = "ESP32S3"
      --efuse_base = 0x60007000
      --chip_magic_numbers = { 0x00000009, 0 }
      --supports_encryption = true


class ESP32H2Config extends ESP32XXConfig:
  constructor:
    super
      --name      = "ESP32H2"
      --efuse_base = 0x6001A000
      --chip_magic_numbers = { 0xca26cc22, 0x6881b06f }
      --supports_encryption = true


CHIP_CONFIGS_ ::= [
  ESP8266Config,
  ESP32Config,
  ESP32C2Config,
  ESP32C3Config,
  ESP32S2Config,
  ESP32S3Config,
  ESP32H2Config
]

