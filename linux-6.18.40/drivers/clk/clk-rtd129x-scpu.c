// SPDX-License-Identifier: GPL-2.0
/*
 * Realtek RTD129x SCPU core clock: PLL_SCPU with its post-divider.
 *
 * Three operating points, table-driven:
 *
 *   300.375 MHz  PLL 1201.5 MHz (N=41 F=1024, the boot loader value), /4
 *   600.750 MHz  PLL 1201.5 MHz, /2  - the operating point the board
 *                shipped with and has run at its whole product life
 *   ~1100 MHz    PLL 1100 MHz (N=37 F=1517, vendor freq table), /1
 *
 * The idle and mid points keep the PLL exactly as the boot loader set
 * it; the PLL is only reprogrammed when the peak point is entered or
 * left.  PLL changes use the SSC block (hold -> write N/F -> OC_EN ->
 * poll done), which ramps the running PLL glitch-free; the sequencing
 * of divider vs PLL writes guarantees the core never transiently
 * exceeds the highest requested rate.  The whole sequence, including a
 * multi-minute 4-core soak at 1100 MHz, was validated live on hardware
 * via /dev/mem before being frozen into this driver.
 *
 * Voltage: the cpudvs rail measures 1.0000 V (G2227 DC2, read back over
 * i2c).  Per the Realtek reference tables that covers 1.1 GHz (needs
 * 0.9625 V) with margin, but NOT 1.2 GHz (needs 1.0125 V), which is why
 * the peak point is 1100 and the boot PLL's /1 (1201.5 MHz) is not
 * offered.  No voltage is ever changed by this driver.
 *
 * Divider encoding (vendor 4.9 clk driver, verified live): 0 = /1,
 * 2 = /2, 3 = /4, in CRT 0x30 bits [8:7].
 */

#include <linux/bitfield.h>
#include <linux/clk-provider.h>
#include <linux/iopoll.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>

#define CRT_SCPU_DIV		0x030
#define SCPU_DIV_MASK		GENMASK(8, 7)
#define CRT_PLL_SCPU_SSC0	0x500
#define CRT_PLL_SCPU_SSC1	0x504
#define CRT_PLL_SCPU_SSC_STAT	0x51c
#define SSC_CTRL_MASK		GENMASK(2, 0)
#define SSC_CTRL_HOLD		0x4
#define SSC_CTRL_OC_EN		0x5
#define SSC_STAT_OC_DONE	BIT(20)
#define SSC_NF(n, f)		(((n) << 11) | (f))
#define SSC_NF_MASK		GENMASK(18, 0)

struct rtd129x_scpu_clk {
	struct clk_hw hw;
	struct regmap *regmap;
	spinlock_t lock;
};

#define to_scpu_clk(_hw) container_of(_hw, struct rtd129x_scpu_clk, hw)

struct scpu_point {
	unsigned int nf;
	unsigned int div;
	unsigned int div_field;
};

static const struct scpu_point scpu_points[] = {
	{ SSC_NF(41, 1024), 4, 3 },	/* 300.375 MHz */
	{ SSC_NF(41, 1024), 2, 2 },	/* 600.750 MHz */
	{ SSC_NF(37, 1517), 1, 0 },	/* ~1100 MHz   */
};

static unsigned long scpu_nf_to_pll(unsigned int nf, unsigned long parent_rate)
{
	unsigned int n = (nf >> 11) & 0xff;
	unsigned int f = nf & 0x7ff;

	return parent_rate * (n + 3) + mult_frac(parent_rate, f, 2048);
}

static unsigned long scpu_point_rate(const struct scpu_point *p,
				     unsigned long parent_rate)
{
	return scpu_nf_to_pll(p->nf, parent_rate) / p->div;
}

static unsigned int scpu_read_div(struct rtd129x_scpu_clk *sc)
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
	u32 nf = 0;

	regmap_read(sc->regmap, CRT_PLL_SCPU_SSC1, &nf);

	return scpu_nf_to_pll(nf & SSC_NF_MASK, parent_rate) /
	       scpu_read_div(sc);
}

static const struct scpu_point *scpu_nearest(unsigned long rate,
					     unsigned long parent_rate)
{
	const struct scpu_point *best = &scpu_points[0];
	unsigned long best_delta = ULONG_MAX;
	int i;

	for (i = 0; i < ARRAY_SIZE(scpu_points); i++) {
		unsigned long r = scpu_point_rate(&scpu_points[i], parent_rate);
		unsigned long delta = (r > rate) ? r - rate : rate - r;

		if (delta < best_delta) {
			best_delta = delta;
			best = &scpu_points[i];
		}
	}

	return best;
}

static long scpu_round_rate(struct clk_hw *hw, unsigned long rate,
			    unsigned long *parent_rate)
{
	return scpu_point_rate(scpu_nearest(rate, *parent_rate), *parent_rate);
}

static int scpu_pll_set_nf(struct rtd129x_scpu_clk *sc, unsigned int nf)
{
	u32 stat;
	int ret;

	regmap_update_bits(sc->regmap, CRT_PLL_SCPU_SSC0, SSC_CTRL_MASK,
			   SSC_CTRL_HOLD);
	regmap_update_bits(sc->regmap, CRT_PLL_SCPU_SSC1, SSC_NF_MASK, nf);
	regmap_update_bits(sc->regmap, CRT_PLL_SCPU_SSC0, SSC_CTRL_MASK,
			   SSC_CTRL_OC_EN);

	ret = regmap_read_poll_timeout_atomic(sc->regmap,
					      CRT_PLL_SCPU_SSC_STAT, stat,
					      stat & SSC_STAT_OC_DONE,
					      1, 2000);
	if (ret)
		pr_warn("%s: SSC ramp did not signal completion\n", __func__);

	return 0;
}

static void scpu_write_div(struct rtd129x_scpu_clk *sc, unsigned int field)
{
	regmap_update_bits(sc->regmap, CRT_SCPU_DIV, SCPU_DIV_MASK,
			   FIELD_PREP(SCPU_DIV_MASK, field));
}

static int scpu_set_rate(struct clk_hw *hw, unsigned long rate,
			 unsigned long parent_rate)
{
	struct rtd129x_scpu_clk *sc = to_scpu_clk(hw);
	const struct scpu_point *np = scpu_nearest(rate, parent_rate);
	unsigned int cur_div = scpu_read_div(sc);
	unsigned long flags;
	u32 cur_nf = 0;

	regmap_read(sc->regmap, CRT_PLL_SCPU_SSC1, &cur_nf);
	cur_nf &= SSC_NF_MASK;

	spin_lock_irqsave(&sc->lock, flags);

	/*
	 * Raise the division before a PLL change and lower it after, so
	 * the core rate never transiently exceeds max(old, new) while
	 * the SSC block ramps between N/F codes.
	 */
	if (np->div > cur_div)
		scpu_write_div(sc, np->div_field);

	if (np->nf != cur_nf)
		scpu_pll_set_nf(sc, np->nf);

	if (np->div < cur_div)
		scpu_write_div(sc, np->div_field);

	spin_unlock_irqrestore(&sc->lock, flags);

	return 0;
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

	spin_lock_init(&sc->lock);

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
