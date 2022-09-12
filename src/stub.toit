import .protocol
import .config

class Stub:
  entry/int
  text/ByteArray
  text_start/int
  data/ByteArray
  data_start/int
  chip_name/string

  constructor --.entry --.text --.text_start --.data --.data_start --.chip_name:

  run_stub protocol/Protocol chip/ChipConfig:
    print "Running stub"
    download_ protocol chip text_start text
    download_ protocol chip data_start data

    protocol.end_mem entry

    msg := protocol.read_next_message_ 3000
    if msg.to_string_non_throwing != "OHAI":
      throw "Stub failed to run"

    print "Stub running!!"

  download_ protocol/Protocol chip/ChipConfig offset/int data/ByteArray:
    num_blocks/int := (data.size + chip.ram_block_size - 1)/chip.ram_block_size
    protocol.begin_mem offset num_blocks chip.ram_block_size data.size
    num_blocks.repeat: | seq |
      protocol.write_mem data[seq*chip.ram_block_size .. min (seq+1)*chip.ram_block_size data.size] seq


