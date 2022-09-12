### Utility library to allow flashing esp chips from within toit

This package implements (parts of) the [esp serial flasher protocol](https://docs.espressif.com/projects/esptool/en/latest/esp32/advanced-topics/serial-protocol.html)


For simple usage from an ESP32 host, to flash another ESP32 host:

```toit
import esp_serial_flasher show *

BLOCKSIZE ::= 0x1000

// blocks is a list of bytearrays of size BLOCKSIZE
flash offset/int blocks/List gpio0 en rx tx:
  flasher := Flasher --host=(Esp32Host --gpio0_pin=gpio0 --enable_pin=en --rx_pin=rx --tx_pin=tx)
  target := flasher.connect
  image_flasher := target.start_flash offset blocks.size*BLOCKSIZE BLOCKSIZE
  blocks.do: image_flasher.write it
```

If special host control is needed, implement the `HostAdapter`

To speed up the flash, change the baud rate with `Target.change_baud_rate`