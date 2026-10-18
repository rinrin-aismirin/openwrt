// SPDX-License-Identifier: GPL-2.0-only
/*
 * LED driver for the Awinic AW9523B in LED (constant-current) mode
 *
 * Each of the 16 port pins can sink a constant current with 256 dimming
 * steps. Pins described as LED child nodes are switched to LED mode; the
 * others are left in their reset state (GPIO). The global current range
 * (ISEL) is the smallest "led-max-microamp" of all children, or the full
 * range when none is given.
 */

#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/leds.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/property.h>
#include <linux/regmap.h>

#define AW9523B_REG_ID			0x10
#define AW9523B_REG_GCR			0x11
#define AW9523B_REG_LEDMODE_P0		0x12
#define AW9523B_REG_LEDMODE_P1		0x13
#define AW9523B_REG_SOFT_RESET		0x7f

#define AW9523B_ID			0x23
#define AW9523B_GCR_ISEL_MASK		GENMASK(1, 0)
#define AW9523B_NUM_PINS		16
#define AW9523B_ID_RETRIES		5

/* Imax for ISEL = 0..3, in microamps (typical values from the datasheet) */
static const u32 aw9523b_isel_microamp[] = { 37000, 27750, 18500, 9250 };

struct aw9523b_led {
	struct led_classdev cdev;
	struct regmap *regmap;
	u8 dim_reg;
};

struct aw9523b {
	struct regmap *regmap;
	struct aw9523b_led leds[AW9523B_NUM_PINS];
};

/*
 * Pins 0-7 are P0_0-P0_7 and pins 8-15 are P1_0-P1_7. The dimming registers
 * are not in pin order: P1_0-P1_3, then P0_0-P0_7, then P1_4-P1_7.
 */
static u8 aw9523b_dim_reg(unsigned int pin)
{
	if (pin < 8)
		return 0x24 + pin;
	if (pin < 12)
		return 0x20 + pin - 8;
	return 0x2c + pin - 12;
}

static int aw9523b_brightness_set(struct led_classdev *cdev,
				  enum led_brightness brightness)
{
	struct aw9523b_led *led = container_of(cdev, struct aw9523b_led, cdev);

	return regmap_write(led->regmap, led->dim_reg, brightness);
}

static bool aw9523b_writeable_reg(struct device *dev, unsigned int reg)
{
	return reg <= 0x07 || (reg >= 0x11 && reg <= 0x13) ||
	       (reg >= 0x20 && reg <= 0x2f) || reg == AW9523B_REG_SOFT_RESET;
}

static bool aw9523b_readable_reg(struct device *dev, unsigned int reg)
{
	/* The dimming registers and the reset register are write-only. */
	return reg <= 0x07 || (reg >= 0x10 && reg <= 0x13);
}

static const struct regmap_config aw9523b_regmap_config = {
	.reg_bits = 8,
	.val_bits = 8,
	.max_register = AW9523B_REG_SOFT_RESET,
	.writeable_reg = aw9523b_writeable_reg,
	.readable_reg = aw9523b_readable_reg,
};

static int aw9523b_hw_init(struct device *dev, struct regmap *regmap)
{
	struct gpio_desc *reset;
	unsigned int id;
	int i, ret;

	/* RSTN must be low for at least 20 us; I2C needs 5 ms after release. */
	reset = devm_gpiod_get_optional(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(reset))
		return dev_err_probe(dev, PTR_ERR(reset), "failed to get reset GPIO\n");
	if (reset) {
		usleep_range(50, 100);
		gpiod_set_value_cansleep(reset, 0);
		usleep_range(5000, 6000);
	}

	for (i = 0; i < AW9523B_ID_RETRIES; i++) {
		ret = regmap_read(regmap, AW9523B_REG_ID, &id);
		if (!ret && id == AW9523B_ID)
			break;
		usleep_range(5000, 6000);
	}
	if (ret)
		return dev_err_probe(dev, ret, "failed to read chip ID\n");
	if (id != AW9523B_ID)
		return dev_err_probe(dev, -ENODEV, "unexpected chip ID 0x%02x\n", id);

	if (!reset) {
		/* Without a reset line, start from a known state. */
		ret = regmap_write(regmap, AW9523B_REG_SOFT_RESET, 0);
		if (ret)
			return ret;
		usleep_range(1000, 2000);
	}

	return 0;
}

static int aw9523b_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	u32 max_microamp = aw9523b_isel_microamp[0];
	unsigned int isel, pin, ledmode = 0;
	struct aw9523b *chip;
	int ret;

	chip = devm_kzalloc(dev, sizeof(*chip), GFP_KERNEL);
	if (!chip)
		return -ENOMEM;

	chip->regmap = devm_regmap_init_i2c(client, &aw9523b_regmap_config);
	if (IS_ERR(chip->regmap))
		return PTR_ERR(chip->regmap);

	ret = aw9523b_hw_init(dev, chip->regmap);
	if (ret)
		return ret;

	device_for_each_child_node_scoped(dev, child) {
		u32 microamp;

		if (fwnode_property_read_u32(child, "reg", &pin) || pin >= AW9523B_NUM_PINS)
			return dev_err_probe(dev, -EINVAL, "invalid reg in %pfwP\n", child);
		if (ledmode & BIT(pin))
			return dev_err_probe(dev, -EINVAL, "pin %u described twice\n", pin);
		ledmode |= BIT(pin);

		if (!fwnode_property_read_u32(child, "led-max-microamp", &microamp))
			max_microamp = min(max_microamp, microamp);
	}

	/* The largest range that does not exceed any child's limit. */
	for (isel = 0; isel < ARRAY_SIZE(aw9523b_isel_microamp) - 1; isel++)
		if (aw9523b_isel_microamp[isel] <= max_microamp)
			break;
	if (aw9523b_isel_microamp[isel] > max_microamp)
		return dev_err_probe(dev, -EINVAL, "led-max-microamp below %u\n",
				     aw9523b_isel_microamp[isel]);

	ret = regmap_write(chip->regmap, AW9523B_REG_GCR, isel);
	if (ret)
		return ret;

	/* Dim to zero before switching the pins to LED mode. */
	for (pin = 0; pin < AW9523B_NUM_PINS; pin++) {
		if (!(ledmode & BIT(pin)))
			continue;
		ret = regmap_write(chip->regmap, aw9523b_dim_reg(pin), 0);
		if (ret)
			return ret;
	}

	/* A cleared bit selects LED mode; undescribed pins stay GPIO. */
	ret = regmap_write(chip->regmap, AW9523B_REG_LEDMODE_P0, ~ledmode & 0xff);
	if (ret)
		return ret;
	ret = regmap_write(chip->regmap, AW9523B_REG_LEDMODE_P1, ~(ledmode >> 8) & 0xff);
	if (ret)
		return ret;

	device_for_each_child_node_scoped(dev, child) {
		struct led_init_data init_data = { .fwnode = child };
		struct aw9523b_led *led;

		fwnode_property_read_u32(child, "reg", &pin);
		led = &chip->leds[pin];
		led->regmap = chip->regmap;
		led->dim_reg = aw9523b_dim_reg(pin);
		led->cdev.max_brightness = LED_FULL;
		led->cdev.brightness_set_blocking = aw9523b_brightness_set;

		/* max-brightness from the child node is applied here. */
		ret = devm_led_classdev_register_ext(dev, &led->cdev, &init_data);
		if (ret)
			return dev_err_probe(dev, ret, "failed to register LED %u\n", pin);

		/* The chip was reset, so "keep" means off. */
		if (led_init_default_state_get(child) == LEDS_DEFSTATE_ON) {
			led->cdev.brightness = led->cdev.max_brightness;
			ret = aw9523b_brightness_set(&led->cdev, led->cdev.brightness);
			if (ret)
				return ret;
		}
	}

	return 0;
}

static const struct of_device_id aw9523b_of_match[] = {
	{ .compatible = "awinic,aw9523b-leds" },
	{ }
};
MODULE_DEVICE_TABLE(of, aw9523b_of_match);

static struct i2c_driver aw9523b_driver = {
	.driver = {
		.name = "leds-aw9523b",
		.of_match_table = aw9523b_of_match,
	},
	.probe = aw9523b_probe,
};
module_i2c_driver(aw9523b_driver);

MODULE_DESCRIPTION("Awinic AW9523B LED driver");
MODULE_LICENSE("GPL");
