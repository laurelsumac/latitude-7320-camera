static void ov8856_release_power(void *data);

static int ov8856_get_power_resources(struct ov8856 *sensor)
{
	struct i2c_client *client = v4l2_get_subdevdata(&sensor->sd);
	struct device *dev = &client->dev;
	static const char * const supply_names[] = { "avdd", "dvdd", "dovdd" };
	unsigned int index;
	int ret;

	if (!dmi_match(DMI_PRODUCT_NAME, "Latitude 7320 Detachable") ||
	    strcmp(dev_name(dev), "i2c-OVTI8856:00"))
		return 0;

	sensor->managed_power = true;
	for (index = 0; index < ARRAY_SIZE(sensor->supplies); index++)
		sensor->supplies[index].supply = supply_names[index];

	ret = devm_regulator_bulk_get(dev, ARRAY_SIZE(sensor->supplies), sensor->supplies);
	if (ret)
		return ret;

	sensor->xvclk = devm_clk_get(dev, NULL);
	if (IS_ERR(sensor->xvclk))
		return PTR_ERR(sensor->xvclk);
	if (clk_get_rate(sensor->xvclk) != OV8856_MCLK)
		return dev_err_probe(dev, -EINVAL, "rear camera clock is not 19.2 MHz\n");

	sensor->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(sensor->reset_gpio))
		return PTR_ERR(sensor->reset_gpio);
	return devm_add_action_or_reset(dev, ov8856_release_power, dev);
}

static int ov8856_power_on(struct device *dev)
{
	struct v4l2_subdev *subdev = dev_get_drvdata(dev);
	struct ov8856 *sensor = to_ov8856(subdev);
	int ret;

	if (!sensor->managed_power)
		return 0;

	ret = regulator_bulk_enable(ARRAY_SIZE(sensor->supplies), sensor->supplies);
	if (ret)
		return dev_err_probe(dev, ret, "cannot enable rear camera supplies\n");

	ret = clk_prepare_enable(sensor->xvclk);
	if (ret) {
		regulator_bulk_disable(ARRAY_SIZE(sensor->supplies), sensor->supplies);
		return dev_err_probe(dev, ret, "cannot enable rear camera clock\n");
	}

	usleep_range(1000, 2000);
	gpiod_set_value_cansleep(sensor->reset_gpio, 0);
	usleep_range(5000, 6000);
	sensor->power_enabled = true;
	return 0;
}

static int ov8856_power_off(struct device *dev)
{
	struct v4l2_subdev *subdev = dev_get_drvdata(dev);
	struct ov8856 *sensor = to_ov8856(subdev);

	if (!sensor->managed_power || !sensor->power_enabled)
		return 0;

	gpiod_set_value_cansleep(sensor->reset_gpio, 1);
	clk_disable_unprepare(sensor->xvclk);
	sensor->power_enabled = false;
	return regulator_bulk_disable(ARRAY_SIZE(sensor->supplies), sensor->supplies);
}

static void ov8856_release_power(void *data)
{
	struct device *dev = data;

	if (!pm_runtime_status_suspended(dev))
		ov8856_power_off(dev);
	pm_runtime_set_suspended(dev);
}
