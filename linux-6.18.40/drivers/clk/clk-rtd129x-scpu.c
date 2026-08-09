// SPDX-License-Identifier: GPL-2.0
/*
 * Realtek RTD129x SCPU core clock: PLL_SCPU with its post-divider.
 *
 * The PLL N/F code (CRT SSC1 register) is left exactly as the boot
 * loader programmed it (1201.5 MHz on the WD My Cloud Home); only the
 * post-divider in CRT 0x30 bits [8:7] is switched, so every selectable
 * rate stays at or below the operating point the board has run at
 * since power-on and the (software-invisible) cpudvs rail is never
 * exceeded.
 *
 * Divider encoding, from the vendor 4.9 clk driver and verified live
 * on this board: 0 = /1, 2 = /2, 3 = /4.  /1 is intentionally not
 * selectable: raising the core above the boot operating point must
 * wait until the real cpudvs voltage can be read back (G2227 PMIC on
 * i2c-0, driver not yet enabled).
 */

#include <linux/bitfield.h>
#include <linux/clk-provider.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>

#define CRT_SCPU_DIV		0x030
#define SCPU_DIV_MASK		GENMASK(8, 7)
#define CRT_PLL_SCPU_SSC1	0x504

struct rtd129x_scpu_clk {
	struct clk_hw hw;
	struct regmap *regmap;
};

#define to_scpu_clk(_hw) container_of(_hw, struct rtd129x_scpu_clk, hw)

static const struct {
	unsigned int field;
	unsigned int div;
} scpu_divs[] = {
	{ 2, 2 },
	{ 3, 4 },
};

static unsigned long scpu_pll_rate(struct rtd129x_scpu_clk *sc,
				   unsigned long parent_rate)
{
	unsigned int n, f;
	u32 v = 0;

	regmap_read(sc->regmap, CRT_PLL_SCPU_SSC1, &v);
	n = (v >> 11) & 0xff;
	f = v & 0x7ff;

	return parent_rate * (n + 3) + mult_frac(parent_rate, f, 2048);
}

static unsigned int scpu_cur_div(struct rtd129x_scpu_clk *sc)
{
	u32 v = 0;

	regmap_read(sc->regmap, CRT_SCPU_DIV, &v);

	switch (FIELD_GET(SCPU_DIV_MASK, v)) {
	case 0:
		return 1;
	case 3:
		return 4;
	default:
		return 2;
	}
}

static unsigned long scpu_recalc_rate(struct clk_hw *hw,
				      unsigned long parent_rate)
{
	struct rtd129x_scpu_clk *sc = to_scpu_clk(hw);

	return scpu_pll_rate(sc, parent_rate) / scpu_cur_div(sc);
}

static int scpu_best_div(struct rtd129x_scpu_clk *sc, unsigned long rate,
			 unsigned long parent_rate)
{
	unsigned long pll = scpu_pll_rate(sc, parent_rate);
	unsigned long best_delta = ULONG_MAX;
	int i, best = 0;

	for (i = 0; i < ARRAY_SIZE(scpu_divs); i++) {
		unsigned long r = pll / scpu_divs[i].div;
		unsigned long delta = (r > rate) ? r - rate : rate - r;

		if (delta < best_delta) {
			best_delta = delta;
			best = i;
		}
	}

	return best;
}

static long scpu_round_rate(struct clk_hw *hw, unsigned long rate,
			    unsigned long *parent_rate)
{
	struct rtd129x_scpu_clk *sc = to_scpu_clk(hw);
	int i = scpu_best_div(sc, rate, *parent_rate);

	return scpu_pll_rate(sc, *parent_rate) / scpu_divs[i].div;
}

static int scpu_set_rate(struct clk_hw *hw, unsigned long rate,
			 unsigned long parent_rate)
{
	struct rtd129x_scpu_clk *sc = to_scpu_clk(hw);
	int i = scpu_best_div(sc, rate, parent_rate);

	return regmap_update_bits(sc->regmap, CRT_SCPU_DIV, SCPU_DIV_MASK,
				  FIELD_PREP(SCPU_DIV_MASK,
					     scpu_divs[i].field));
}

static const struct clk_ops rtd129x_scpu_clk_ops = {
	.recalc_rate = scpu_recalc_rate,
	.round_rate  = scpu_round_rate,
	.set_rate    = scpu_set_rate,
};

static int rtd129x_scpu_clk_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *parent __free(device_node) =
		of_get_parent(dev->of_node);
	struct rtd129x_scpu_clk *sc;
	struct clk_init_data init = { };
	int ret;

	sc = devm_kzalloc(dev, sizeof(*sc), GFP_KERNEL);
	if (!sc)
		return -ENOMEM;

	sc->regmap = syscon_node_to_regmap(parent);
	if (IS_ERR(sc->regmap))
		return dev_err_probe(dev, PTR_ERR(sc->regmap),
				     "no parent syscon regmap\n");

	init.name = "scpu";
	init.ops = &rtd129x_scpu_clk_ops;
	init.parent_data = &(const struct clk_parent_data){ .index = 0 };
	init.num_parents = 1;
	init.flags = CLK_GET_RATE_NOCACHE;
	sc->hw.init = &init;

	ret = devm_clk_hw_register(dev, &sc->hw);
	if (ret)
		return dev_err_probe(dev, ret, "failed to register clk\n");

	return devm_of_clk_add_hw_provider(dev, of_clk_hw_simple_get, &sc->hw);
}

static const struct of_device_id rtd129x_scpu_clk_dt_ids[] = {
	{ .compatible = "realtek,rtd129x-scpu-clk" },
	{ }
};

static struct platform_driver rtd129x_scpu_clk_driver = {
	.probe = rtd129x_scpu_clk_probe,
	.driver = {
		.name = "rtd129x-scpu-clk",
		.of_match_table = rtd129x_scpu_clk_dt_ids,
	},
};
builtin_platform_driver(rtd129x_scpu_clk_driver);
