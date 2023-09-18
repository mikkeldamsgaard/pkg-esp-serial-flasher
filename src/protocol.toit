import encoding.hex

import slip show Slip

import .messages
import .config

ERASE_TIMEOUT_PER_MB_    ::= 30000
MD5_TIMEROUT_PER_MB_     ::= 8000
MINIMUM_COMMAND_TIMEOUT_ ::= 50
DAFULT_TIMEOUT           ::= 3000

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

  change_baud_rate baud_rate/int old_baud_rate:
    cmd/Command := ChangeBaudrateCommand baud_rate old_baud_rate
    send_cmd_ cmd
    check_status_response_ cmd

    slip.change_baud_rate baud_rate

  set_spi_parameters flash_size/int:
    cmd/Command := SpiSetParameters flash_size
    send_cmd_ cmd
    check_status_response_ cmd

  begin_flash offset/int erase_size/int block_size/int blocks_to_write/int include_encryption/bool?:
    cmd := FlashBeginCommand offset erase_size block_size blocks_to_write include_encryption
    trace_ "FlashBeginCommand offset=$offset erase_size=$erase_size block_size=$block_size blocks_to_write=$blocks_to_write include_encryption=$include_encryption"
    send_cmd_ cmd
    timeout := bytes_to_timeout_ erase_size ERASE_TIMEOUT_PER_MB_
    check_status_response_ cmd --timeout_ms=timeout

  write_flash buf/ByteArray sequence/int:
    cmd := FlashWriteCommand buf sequence
    send_cmd_ cmd
    check_status_response_ cmd

  end_flash:
    cmd := FlashCompleteCommand
    send_cmd_ cmd
    check_status_response_ cmd

  calculate_md5 addr/int size/int -> ByteArray:
    cmd := Md5SpiCommand addr size
    send_cmd_ cmd
    timeout := bytes_to_timeout_ size MD5_TIMEROUT_PER_MB_
    response_bytes := read_next_message_ timeout
    print "MD5: $(hex.encode response_bytes) : $response_bytes.size"
    return response_bytes

  spi_set_data_lengths_ chip/ChipConfig mosi_bits/int miso_bits/int:
    if mosi_bits>0: write_register chip.mosi_dlen mosi_bits-1
    if miso_bits>0: write_register chip.miso_dlen miso_bits-1

  spi_set_data_lengths_8266_ chip/ChipConfig mosi_bits/int miso_bits/int:
    mosi_mask := (mosi_bits == 0) ? 0 : mosi_bits - 1
    miso_mask := (miso_bits == 0) ? 0 : miso_bits - 1

    write_register chip.usr1 miso_mask << 8 | mosi_mask << 17

  /**
   send spi falsh command
   $tx_data is a list of unsigned 32 bit values to send
   $tx_size is the number of bits to write
   $rx_size is the number of bits of read
   return the read bits
  **/
  spi_flash_command chip/ChipConfig cmd/int tx_data/int tx_size/int rx_size/int -> int:
    old_usr := read_register chip.usr
    old_usr2 := read_register chip.usr2

    try:
      if chip.chip_type == CHIP_TYPE_ESP8266_:
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


  begin_mem offset/int blocks_to_write/int block_size/int size/int:
    cmd := MemBeginCommand offset blocks_to_write block_size size
    send_cmd_ cmd
    check_status_response_ cmd

  write_mem data/ByteArray seq/int:
    cmd := MemWriteCommand data seq
    send_cmd_ cmd
    check_status_response_ cmd

  end_mem entry/int:
    cmd := MemCompleteCommand entry
    send_cmd_ cmd
    catch:
      // Sending ESP_MEM_END usually sends a correct response back, however sometimes
      // (with ROM loader) the executed code may reset the UART or change the baud rate
      // before the transmit FIFO is empty. So in these cases we set a short timeout
      // and ignore errors.
      check_status_response_ cmd --timeout_ms=50


  close:
    slip.close

  bytes_to_timeout_ size/int timeout_per_mb/int:
    timeout := size * timeout_per_mb / 1_000_000
    return max timeout DAFULT_TIMEOUT

  send_cmd_ cmd/Command:
    slip_payload := cmd.bytes
    slip.send slip_payload
    trace_ "COMMAND: cmd_id=$(%x cmd.command) size=$cmd.size $(cmd.payload.size>50?"<bin>":(hex.encode cmd.payload))"
    trace_ "SLIP PAYLOAD (TX): $(hex.encode slip_payload)"

  check_status_response_ command/Command --timeout_ms=DAFULT_TIMEOUT -> int:
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
      trace_ "SLIP PAYLOAD (RX): $(hex.encode msg)"
      return msg
    unreachable

  trace_ txt: if should_trace: print "T: $txt"

