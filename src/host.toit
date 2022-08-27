import uart
import gpio show Pin

ESP_SERIAL_DEFAULT_BAUDRATE  ::= 115200

interface HostAdapter:
  enter_bootloader
  reset
  connect -> uart.Port
  close -> none

class Esp32Host implements HostAdapter:
  gpio0_pin/Pin
  enable_pin/Pin
  tx_pin/Pin
  rx_pin/Pin

  port/uart.Port? := null

  constructor --.gpio0_pin/Pin --.enable_pin/Pin --.tx_pin/Pin --.rx_pin/Pin:

  close -> none:
    if port: port.close
    port = null

  reset:
    enable_pin.set 0
    sleep --ms=50
    enable_pin.set 1

  enter_bootloader:
    gpio0_pin.set 0
    sleep --ms=10
    reset
    sleep --ms=50
    gpio0_pin.set 1

  connect -> uart.Port:
    port = uart.Port --tx=tx_pin --rx=rx_pin --baud_rate=ESP_SERIAL_DEFAULT_BAUDRATE
    gpio0_pin.config --output
    enable_pin.config --output
    return port

