import bytes show Buffer
import packing show PackingBuffer UnpackingBuffer
import encoding.hex
import log

COMMAND_DIRECTION_WRITE  ::= 0
COMMAND_DIRECTION_READ   ::= 1

STATUS_FAILURE           ::= 1
STATUS_SUCCESS           ::= 0

COMMAND_FLASH_BEGIN      ::= 0x02
COMMAND_FLASH_DATA       ::= 0x03
COMMAND_FLASH_END        ::= 0x04
COMMAND_MEM_BEGIN        ::= 0x05
COMMAND_MEM_END          ::= 0x06
COMMAND_MEM_DATA         ::= 0x07
COMMAND_SYNC             ::= 0x08
COMMAND_WRITE_REG        ::= 0x09
COMMAND_READ_REG         ::= 0x0a

COMMAND_SPI_SET_PARAMS   ::= 0x0b
COMMAND_SPI_ATTACH       ::= 0x0d
COMMAND_CHANGE_BAUDRATE  ::= 0x0f
COMMAND_FLASH_DEFL_BEGIN ::= 0x10
COMMAND_FLASH_DEFL_DATA  ::= 0x11
COMMAND_FLASH_DEFL_END   ::= 0x12
COMMAND_SPI_FLASH_MD5    ::= 0x13

HEADER_SIZE              ::= 8

abstract class Command:
  direction/int
  command/int
  size/int := 0
  checksum/int
  abstract payload -> ByteArray

  constructor .command .checksum=0:
    direction = COMMAND_DIRECTION_WRITE
    size = payload.size

  bytes -> ByteArray:
    buf := PackingBuffer.le
    buf.write_uint8 direction
    buf.write_uint8 command
    buf.write_uint16 size
    buf.write_uint32 checksum
    buf.write_byte_array payload
    res := buf.bytes

    // log_msg :=  "Packed message: $(hex.encode res)"
    // if log_msg.size > 25: log_msg = log_msg[0..22]+"..."
    // logger_.info log_msg

    return res

class Sync extends Command:
  payload ::= #[
            0x07, 0x07, 0x12, 0x20,
            0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
            0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
            0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
            0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55]

  constructor:
    super COMMAND_SYNC

class ReadRegisterCommand extends Command:
  payload/ByteArray
  constructor address/int:
    buf := PackingBuffer.le --initial_size=4
    buf.write_uint32 address
    payload = buf.bytes
    super COMMAND_READ_REG

class WriteRegisterCommand extends Command:
  payload/ByteArray
  constructor address/int value/int --mask/int=0xFFFFFFFF --delay_us/int=0:
    buf := PackingBuffer.le --initial_size=8
    buf.write_uint32 address
    buf.write_uint32 value
    buf.write_uint32 mask
    buf.write_uint32 delay_us
    payload = buf.bytes
    super COMMAND_WRITE_REG

class SpiAttachCommand extends Command:
  payload/ByteArray
  constructor spi_config/int:
    buf := PackingBuffer.le --initial_size=8
    buf.write_uint32 spi_config
    buf.write_uint32 0
    payload = buf.bytes
    super COMMAND_SPI_ATTACH

class SpiSetParameters extends Command:
  payload/ByteArray
  constructor flash_size/int:
    buf := PackingBuffer.le --initial_size=8
    buf.write_uint32 0 // id
    buf.write_uint32 flash_size
    buf.write_uint32 64 * 1024 // block size
    buf.write_uint32 4 * 1024 // sector size
    buf.write_uint32 0x100 // page size
    buf.write_uint32 0xFFFF // status mask
    payload = buf.bytes
    super COMMAND_SPI_SET_PARAMS


class ChangeBaudrateCommand extends Command:
  payload/ByteArray
  constructor baud_rate/int old_baud_rate/int:
    buf := PackingBuffer.le --initial_size=8
    buf.write_uint32 baud_rate
    buf.write_uint32 old_baud_rate
    payload = buf.bytes
    super COMMAND_CHANGE_BAUDRATE

class FlashBeginCommand extends Command:    
  payload/ByteArray
  constructor offset/int erase_size/int block_size/int blocks_to_write/int include_encryption/bool?:
    buf := PackingBuffer.le --initial_size=20
    buf.write_uint32 erase_size
    buf.write_uint32 blocks_to_write
    buf.write_uint32 block_size
    buf.write_uint32 offset
    if include_encryption != null:
      buf.write_uint32 (include_encryption?1:0)
    payload = buf.bytes
    super COMMAND_FLASH_BEGIN

class FlashWriteCommand extends Command:
  payload/ByteArray
  constructor data/ByteArray sequence/int:
    buf := PackingBuffer.le --initial_size=data.size + 16
    buf.write_uint32 data.size
    buf.write_uint32 sequence
    buf.write_uint32 0
    buf.write_uint32 0
    buf.write_byte_array data
    payload = buf.bytes
    check_sum := calc_check_sum_ data
    super COMMAND_FLASH_DATA check_sum

class FlashCompleteCommand extends Command:
  payload ::= #[0x01]
  constructor:
    super COMMAND_FLASH_END

class MemBeginCommand extends Command:
  payload/ByteArray
  constructor offset/int blocks_to_write/int block_size/int size/int:
    buf := PackingBuffer.le --initial_size=20
    buf.write_uint32 size
    buf.write_uint32 blocks_to_write
    buf.write_uint32 block_size
    buf.write_uint32 offset
    payload = buf.bytes
    super COMMAND_MEM_BEGIN

class MemWriteCommand extends Command:
  payload/ByteArray
  constructor data/ByteArray sequence/int:
    buf := PackingBuffer.le --initial_size=data.size + 16
    buf.write_uint32 data.size
    buf.write_uint32 sequence
    buf.write_uint32 0
    buf.write_uint32 0
    buf.write_byte_array data
    payload = buf.bytes
    check_sum := calc_check_sum_ data
    super COMMAND_MEM_DATA check_sum

class MemCompleteCommand extends Command:
  payload/ByteArray
  constructor entry/int:
    buf := PackingBuffer.le --initial_size=8
    buf.write_uint32 (entry==0?1:0)
    buf.write_uint32 entry
    payload = buf.bytes
    super COMMAND_MEM_END

////
////
////
abstract class Response:
  buf_/UnpackingBuffer
  direction/int
  command/int
  size/int
  value/int

  constructor arr_/ByteArray:
    buf_ = UnpackingBuffer.le arr_
    direction = buf_.read_uint8
    command = buf_.read_uint8
    size = buf_.read_uint16
    value = buf_.read_uint32

class StatusResponse extends Response:
  failed/int? := null
  error/int? := null

  constructor arr/ByteArray:
    if arr.size < 10: throw "Invalid response: $(hex.encode arr)"
    super arr
    failed = buf_.read_uint8
    error = buf_.read_uint8

    //logger_.debug "direction: $direction, command: $command, size: $size, value: $value, failed: $failed, error: $error";
  
//
// Checksum
//
calc_check_sum_ buf/ByteArray:
  check_sum := 0xEF
  buf.do: check_sum ^= it
  return check_sum