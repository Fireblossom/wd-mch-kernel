// SPDX-License-Identifier: GPL-2.0
/*
 * Realtek RTD129x PWM (ISO block, 0x980070d0), ported from the vendor
 * 4.9 pwm-rtk.c register contract.
 *
 * Three packed registers, four channels each:
 *   +0x0 OCD: output clock divider, 8 bits per channel (shift 8n)
 *   +0x4 CD:  duty compare,         8 bits per channel (shift 8n)
 *   +0x8 CSD: source clock divider, 4 bits per channel (shift 4n)
 *
 *   period = (2^(csd+1) * (ocd+1)) / clk
 *   duty   = (cd+1) / (ocd+1) of the period; cd = 0xff = always on
 *   channel disabled = all three fields zero (vendor semantics)
 *
 * On the WD My Cloud Home only channel 3 is wired: the front SYS LED.
 * The boot loader leaves it at ocd=255 cd=127 csd=1 (50 % at ~26 kHz);
 * the pin mux is inherited from the boot loader like the rest of the
 * port. Live register poking on the running box confirmed the duty
 * field tracks LED brightness before this driver was written.
 */

#include <linux/clk.h>
#include <linux/io.h>
#include <linux/math64.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pwm.h>

#define RTD_PWM_OCD	0x0
#define RTD_PWM_CD	0x4
#define RTD_PWM_CSD	0x8

#define RTD_PWM_NUM	4
#define OCD_MAX		255
#define CSD_MAX		15

struct rtd129x_pwm {
	void __iomem *base;
	unsigned long clkrate;
	spinlock_t lock;
};

static inline struct rtd129x_pwm *to_rtd129x_pwm(struct pwm_chip *chip)
{
	return pwmchip_get_drvdata(chip);
}

static void rtd129x_pwm_write_field(struct rtd129x_pwm *rp, unsigned int reg,
				    unsigned int shift, unsigned int mask,
				    unsigned int val)
{
	u32 v;

	v = readl(rp->base + reg);
	v = (v & ~(mask << shift)) | ((val & mask) << shift);
	writel(v, rp->base + reg);
}

static void rtd129x_pwm_set_channel(struct rtd129x_pwm *rp, unsigned int hwpwm,
				    unsigned int ocd, unsigned int cd,
				    unsigned int csd)
{
	unsigned long flags;

	spin_lock_irqsave(&rp->lock, flags);
	rtd129x_pwm_write_field(rp, RTD_PWM_OCD, hwpwm * 8, 0xff, ocd);
	rtd129x_pwm_write_field(rp, RTD_PWM_CD, hwpwm * 8, 0xff, cd);
	rtd129x_pwm_write_field(rp, RTD_PWM_CSD, hwpwm * 4, 0xf, csd);
	spin_unlock_irqrestore(&rp->lock, flags);
}

static int rtd129x_pwm_apply(struct pwm_chip *chip, struct pwm_device *pwm,
			     const struct pwm_state *state)
{
	struct rtd129x_pwm *rp = to_rtd129x_pwm(chip);
	unsigned int csd, cd;
	u64 div, ocd;

	if (state->polarity == PWM_POLARITY_INVERSED)
		return -EINVAL;

	if (!state->enabled || !state->duty_cycle) {
		rtd129x_pwm_set_channel(rp, pwm->hwpwm, 0, 0, 0);
		return 0;
	}

	/* total divider for the requested period, in clk cycles */
	div = mul_u64_u64_div_u64(rp->clkrate, state->period, NSEC_PER_SEC);
	if (!div)
		return -EINVAL;

	/* smallest csd that brings ocd into 8 bits */
	for (csd = 0; csd < CSD_MAX; csd++) {
		if ((div >> (csd + 1)) <= OCD_MAX + 1)
			break;
	}
	ocd = div >> (csd + 1);
	ocd = ocd ? ocd - 1 : 0;

	cd = div_u64(state->duty_cycle * (ocd + 1), state->period);
	cd = cd ? cd - 1 : 0;
	if (cd > ocd)
		cd = ocd;

	rtd129x_pwm_set_channel(rp, pwm->hwpwm, ocd, cd, csd);
	return 0;
}

static int rtd129x_pwm_get_state(struct pwm_chip *chip, struct pwm_device *pwm,
				 struct pwm_state *state)
{
	struct rtd129x_pwm *rp = to_rtd129x_pwm(chip);
	unsigned int ocd, cd, csd;
	u64 cycles;

	ocd = (readl(rp->base + RTD_PWM_OCD) >> (pwm->hwpwm * 8)) & 0xff;
	cd = (readl(rp->base + RTD_PWM_CD) >> (pwm->hwpwm * 8)) & 0xff;
	csd = (readl(rp->base + RTD_PWM_CSD) >> (pwm->hwpwm * 4)) & 0xf;

	state->polarity = PWM_POLARITY_NORMAL;
	state->enabled = !!(ocd | cd | csd);

	cycles = (u64)(ocd + 1) << (csd + 1);
	state->period = DIV64_U64_ROUND_UP(cycles * NSEC_PER_SEC, rp->clkrate);
	state->duty_cycle = DIV64_U64_ROUND_UP((cycles * (cd + 1) / (ocd + 1)) *
					       NSEC_PER_SEC, rp->clkrate);
	return 0;
}

static const struct pwm_ops rtd129x_pwm_ops = {
	.apply = rtd129x_pwm_apply,
	.get_state = rtd129x_pwm_get_state,
};

static int rtd129x_pwm_probe(struct platform_device *pdev)
{
	struct pwm_chip *chip;
	struct rtd129x_pwm *rp;
	struct clk *clk;

	chip = devm_pwmchip_alloc(&pdev->dev, RTD_PWM_NUM, sizeof(*rp));
	if (IS_ERR(chip))
		return PTR_ERR(chip);
	rp = pwmchip_get_drvdata(chip);

	rp->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(rp->base))
		return PTR_ERR(rp->base);

	clk = devm_clk_get_enabled(&pdev->dev, NULL);
	if (IS_ERR(clk))
		return dev_err_probe(&pdev->dev, PTR_ERR(clk), "no clock\n");

	rp->clkrate = clk_get_rate(clk);
	if (!rp->clkrate)
		return dev_err_probe(&pdev->dev, -EINVAL, "zero clock rate\n");

	spin_lock_init(&rp->lock);
	chip->ops = &rtd129x_pwm_ops;

	return devm_pwmchip_add(&pdev->dev, chip);
}

static const struct of_device_id rtd129x_pwm_dt_ids[] = {
	{ .compatible = "realtek,rtd129x-pwm" },
	{ }
};

static struct platform_driver rtd129x_pwm_driver = {
	.probe = rtd129x_pwm_probe,
	.driver = {
		.name = "pwm-rtd129x",
		.of_match_table = rtd129x_pwm_dt_ids,
	},
};
builtin_platform_driver(rtd129x_pwm_driver);
