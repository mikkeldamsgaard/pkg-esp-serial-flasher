import encoding.hex

import slip show Slip

import .messages
import .config

ERASE_TIMEOUT_PER_MB_    ::= 10000
MINIMUM_COMMAND_TIMEOUT_ ::= 50

SPI_USR_CMD_   ::= 1 << 31
SPI_USR_MISO_  ::= 1 << 28
SPI_USR_MOSI_  ::= 1 << 27
SPI_CMD_USR_   ::= 1 << 18
CMD_LEN_SHIFT_ ::= 28

class Protocol:
  slip/Slip
  should_trace/bool
  constructor .slip .should_trace:

  sync:
    cmd := Sync
    send_cmd_ cmd
    check_status_response_ cmd --timeout_ms=50

  spi_attach spi_config/int:
    cmd := SpiAttachCommand spi_config
    send_cmd_ cmd
    check_status_response_ cmd

  read_register address/int -> int:
    cmd := ReadRegisterCommand address
    send_cmd_ cmd
    return check_status_response_ cmd

  write_register address/int data/int -> int:
    cmd := WriteRegisterCommand address data
    send_cmd_ cmd
    return check_status_response_ cmd

  change_baud_rate baud_rate/int:
    cmd/Command := ChangeBaudrateCommand baud_rate
    send_cmd_ cmd
    check_status_response_ cmd

    slip.change_baud_rate baud_rate

  set_spi_parameters flash_size/int:
    cmd/Command := SpiSetParameters flash_size
    send_cmd_ cmd
    check_status_response_ cmd

  begin_flash offset/int erase_size/int block_size/int blocks_to_write/int include_encryption/bool:
    cmd := FlashBeginCommand offset erase_size block_size blocks_to_write include_encryption
    send_cmd_ cmd
    check_status_response_ cmd --timeout_ms=(bytes_to_timeout_ erase_size ERASE_TIMEOUT_PER_MB_)

  write_flash buf/ByteArray sequence/int:
    cmd := FlashWriteCommand buf sequence
    send_cmd_ cmd
    check_status_response_ cmd --timeout_ms=300

  spi_set_data_lengths_ chip/ChipConfig mosi_bits/int miso_bits/int:
    if mosi_bits>0: write_register chip.mosi_dlen mosi_bits-1
    if miso_bits>0: write_register chip.miso_dlen miso_bits-1

  spi_set_data_lengths_8266_ chip/ChipConfig mosi_bits/int miso_bits/int:
    mosi_mask := (mosi_bits == 0) ? 0 : mosi_bits - 1
    miso_mask := (miso_bits == 0) ? 0 : miso_bits - 1

    write_register chip.usr1 miso_mask << 8 | mosi_mask << 17

  /**
   send spi falsh command
   $tx is a list of unsigned 32 bit values to send
   $tx_size is the number of bits to write
   $rx_size is the number of bits of read
   return the read bits
  **/
  spi_flash_command chip/ChipConfig cmd/int tx_data/int tx_size/int rx_size/int -> int:
    old_usr := read_register chip.usr
    old_usr2 := read_register chip.usr2

    try:
      if chip.chip_type == CHIP_TYPE_ESP8622_:
        spi_set_data_lengths_8266_ chip tx_size rx_size
      else:
        spi_set_data_lengths_ chip tx_size rx_size

      usr_reg_2 := ( 7 << CMD_LEN_SHIFT_ ) | cmd
      usr_reg := SPI_USR_CMD_
      if rx_size > 0: usr_reg |= SPI_USR_MISO_
      if tx_size > 0: usr_reg |= SPI_USR_MOSI_

      write_register chip.usr usr_reg
      write_register chip.usr2 usr_reg_2

      if tx_size == 0:
        // clear data register before reading
        write_register chip.w0 0
      else:
        data_reg_addr := chip.w0

        if tx_size > 32:
          write_register data_reg_addr tx_data >> 32
          data_reg_addr += 4

        write_register data_reg_addr tx_data & 0xFFFFFFFF

      write_register chip.cmd SPI_CMD_USR_

      trials := 10
      while --trials>0:
        cmd_reg := read_register chip.cmd
        if cmd_reg & SPI_CMD_USR_ == 0: break

      if trials == 0: throw "TIMEOUT"

      return
          read_register chip.w0
    finally:
      write_register chip.usr old_usr
      write_register chip.usr2 old_usr2



  close:
    slip.close

  bytes_to_timeout_ size/int timeout_per_mb/int:
    timeout := size / 1_000_000 * timeout_per_mb
    return max timeout MINIMUM_COMMAND_TIMEOUT_

  send_cmd_ cmd/Command:
    slip_payload := cmd.bytes
    slip.send slip_payload
    trace_ "COMMAND: cmd_id=$(%x cmd.command) size=$cmd.size $(hex.encode cmd.payload)"

  check_status_response_ command/Command --timeout_ms=500 -> int:
    return check_status_response_with_command_id_ command.command --timeout_ms=timeout_ms

  check_status_response_with_command_id_ command/int --timeout_ms=500 -> int:
    while true:
      response_bytes := read_next_message_ timeout_ms
      response := StatusResponse response_bytes
      trace_ "RECEIVED: cmd_id=$(%x response.command) size=$response.size value=$(%08x response.value) failed=$response.failed error=$response.error"
      // Skip wrong direction and wrong command responses
      if response.direction != COMMAND_DIRECTION_READ or
          response.command != command:
        continue

      if response.failed != 0:
        throw "Command failed with error $response.error"

      return response.value

  read_next_message_ timeout_ms/int -> ByteArray:
    with_timeout --ms=timeout_ms:
      msg := slip.receive
      return msg
    unreachable

  trace_ txt: if should_trace: print "T: $txt"

