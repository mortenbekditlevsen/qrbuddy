final class Button {
  var button: gpio_num_t
  var previous: Bool = true
  init(gpioPin: Int) {
    button = gpio_num_t(Int32(gpioPin))

    guard gpio_reset_pin(button) == ESP_OK else {
      fatalError("cannot reset button")
    }

    guard gpio_set_direction(button, GPIO_MODE_INPUT) == ESP_OK else {
      fatalError("cannot reset button")
    }
    _ = trigger()
  }

  func getValue() -> Int32 {
    gpio_get_level(button)
  }
  func get() -> Bool {
    gpio_get_level(button) == 1
  }

  func trigger() -> Bool {
    let new = get()
    if new != previous {
      previous = new
      return !new
    }
    return false
  }

}
