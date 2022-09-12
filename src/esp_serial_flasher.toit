import gpio show Pin
import uart 
import slip show *
import log
import encoding.hex
import encoding.base64
import monitor show Channel Latch

import .config
import .host
import .protocol
import .stub

export HostAdapter Esp32Host ESP_SERIAL_DEFAULT_BAUDRATE

// Inspired by https://github.com/espressif/esp-serial-flasher and https://github.com/espressif/esptool
// Protocol: https://docs.espressif.com/projects/esptool/en/latest/esp32/advanced-topics/serial-protocol.html

PADDING_PATTERN_   ::= 0xFF

SPI_FLASH_READ_ID_ ::= 0x9F

class Flasher:
  host/HostAdapter
  trace/bool
  port/uart.Port? := null
  protocol/Protocol? := null
  stubs/List

  constructor --.host/HostAdapter --.trace/bool=false --.stubs=[]:

  connect --trials=5 --print_progress/bool=false-> Target:
    if not protocol:
      port = host.connect
      protocol = Protocol (Slip --port=port) trace

    try:
      retry_ trials:
        host.enter_bootloader
        retry_ trials:
          if print_progress: write_on_stdout_ "." false
          protocol.sync
    finally: | is_exception e |
      if print_progress: write_on_stdout_ "" true
      if is_exception:
        protocol.close
        protocol = null

    chip := detect_chip_

    // Look for a stub int the stubs list
    stub/Stub? := null
    stubs.do : | s/Stub |
      if s.chip_name == chip.name:
        stub = s

    if not stub:
      // ROM loader doesn't enable flash unless we explicitly do it
      if chip.chip_type != CHIP_TYPE_ESP8266_:
        spi_config := chip.read_spi_config protocol
        protocol.spi_attach spi_config
      else:
        protocol.begin_flash 0 0 0 0 null

    if stub:
      stub.run_stub protocol chip

    return Target this chip protocol stub

  disconnect_ reset/bool:
    if protocol:
      protocol.close
      protocol= null
    if reset: host.reset
    host.close


  detect_chip_ -> ChipConfig:
    magic_value := protocol.read_register CHIP_DETECT_MAGIC_REG_ADDR_

    chip := CHIP_CONFIGS_.filter: | chip/ChipConfig |
      chip.chip_magic_numbers.contains magic_value

    if chip.size: return chip[0]
    throw "Chip with magic number 0x$(%x magic_value) not found in configuration"


class Target:
  flasher/Flasher
  chip/ChipConfig
  protocol/Protocol
  flash_size_/int? := null
  stub/Stub?

  constructor .flasher .chip .protocol .stub:

  disconnect --reset/bool=false:
    flasher.disconnect_ reset

  change_baud_rate baud_rate/int:
    old_baud_rate := 0
    if stub: old_baud_rate = flasher.port.baud_rate
    protocol.change_baud_rate baud_rate old_baud_rate
    print "Changed baud rate to $baud_rate"

  detect_flash_size -> int:
    flash_id := protocol.spi_flash_command chip SPI_FLASH_READ_ID_ 0 0 24
    //"Manufacturer: $(%02x flash_id & 0xFF)"
    size_id := flash_id >> 16
    //"Device: $(%02x (flash_id >> 8) & 0xFF)$(%02x size_id)"

    if size_id < 0x12 or size_id > 0x18: throw "UNSUPPORTED FLASH CHIP"
    return 1 << size_id

  start_flash offset/int image_size/int --flash_size/int?=null --block_size/int=(stub?0x4000:0x0400) -> ImageFlasher:
    if not flash_size_:
      if not flash_size:
        flash_size_ = detect_flash_size
      else:
        flash_size_ = flash_size

    return ImageFlasher offset image_size block_size flash_size_ protocol chip


class ImageFlasher:
  block_size/int
  protocol/Protocol
  sequence/int := 0

  constructor offset/int image_size/int .block_size/int flash_size/int .protocol/Protocol chip/ChipConfig:
    blocks_to_write := (image_size + block_size - 1) / block_size

    protocol.set_spi_parameters flash_size

    encryption := chip.supports_encryption?false:null

    retry_ 5:
      protocol.begin_flash offset image_size block_size blocks_to_write encryption

  write buf/ByteArray:
    if buf.size > block_size: throw "Invalid buffer. Size ($buf.size) exceeds block size $block_size"

    padding_bytes := block_size - buf.size

    if padding_bytes != 0:
      tmp := ByteArray padding_bytes
      tmp.fill PADDING_PATTERN_
      buf = buf + tmp

    s := sequence++

    retry_ 10:
      protocol.write_flash buf s

  end:
    // TODO: Verify hash


retry_ trials --pause_between_retries_ms=100 [block]:
  while trials-- > 0:
    e := catch --unwind=(: trials == 0 ):
      block.call

    if not e: return
    sleep --ms=pause_between_retries_ms

  throw "Retry limit exceeped"

