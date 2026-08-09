// SPDX-License-Identifier: GPL-2.0
/*
 * Realtek RTD129x "coolboot" power-off.
 *
 * On this SoC the SCPU cannot cut its own power. The vendor 4.9 flow
 * (rtk_poweroff -> rtk_suspend_to_coolboot -> rtk_iso_suspend) writes a
 * suspend request into the IPC shared-memory block that lives at the
 * start of the RPC "common" DRAM region (base + 0xC4), and the ACPU
 * firmware - started by the unmodified vendor boot chain - performs the
 * actual power-down when it sees the flag. The vendor implementation
 * then simply spins; power disappears underneath it.
 *
 * Protocol (vendor rtd129x_suspend.c, suspend_version = 2 on this
 * firmware generation, values stored big-endian):
 *   suspend_mask (+0x10) = version << 16
 *   suspend_flag (+0x14) = AUTHOR_SCPU << 30 | NOTIFY_SUSPEND_TO_COOLBOOT
 * A version-1 fallback (mask 1 << 16, flag 0x000018ff) is issued if the
 * version-2 write has not cut power after a few seconds, so a device
 * with older ACPU firmware still turns off.
 *
 * No wake-up sources are configured: like the vendor product (which has
 * no power button), a powered-off unit is brought back by cycling AC.
 *
 * The region is declared no-map so it can be mapped uncached here,
 * matching the vendor's ioremap() access type; the boot chain also
 * memreserves it at runtime.
 */

#include <linux/io.h>
#include <linux/delay.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/platform_device.h>
#include <linux/reboot.h>

#define IPC_SHM_OFFSET		0xc4
#define IPC_SUSPEND_MASK	(IPC_SHM_OFFSET + 0x10)
#define IPC_SUSPEND_FLAG	(IPC_SHM_OFFSET + 0x14)
#define IPC_AUDIO_FW_ENTRY	(IPC_SHM_OFFSET + 0x1c)

#define COOLBOOT_V2_MASK	(2 << 16)
#define COOLBOOT_V2_FLAG	(BIT(30) | 0x02)	/* SCPU | COOLBOOT */
#define COOLBOOT_V1_MASK	(1 << 16)
#define COOLBOOT_V1_FLAG	0x000018ff

struct rtd129x_poweroff {
	void __iomem *shm;
};

static void coolboot_request(struct rtd129x_poweroff *po, u32 mask, u32 flag)
{
	writel((__force u32)cpu_to_be32(mask), po->shm + IPC_SUSPEND_MASK);
	writel((__force u32)cpu_to_be32(flag), po->shm + IPC_SUSPEND_FLAG);
}

static int rtd129x_coolboot_power_off(struct sys_off_data *data)
{
	struct rtd129x_poweroff *po = data->cb_data;

	coolboot_request(po, COOLBOOT_V2_MASK, COOLBOOT_V2_FLAG);
	mdelay(3000);

	/* still alive: retry with the version-1 encoding */
	coolboot_request(po, COOLBOOT_V1_MASK, COOLBOOT_V1_FLAG);
	mdelay(3000);

	pr_emerg("rtd129x-poweroff: ACPU did not cut power\n");
	return NOTIFY_DONE;
}

static int rtd129x_poweroff_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *rmem __free(device_node) =
		of_parse_phandle(dev->of_node, "memory-region", 0);
	struct rtd129x_poweroff *po;
	struct resource res;
	int ret;

	if (!rmem)
		return dev_err_probe(dev, -EINVAL, "no memory-region\n");

	ret = of_address_to_resource(rmem, 0, &res);
	if (ret)
		return dev_err_probe(dev, ret, "bad memory-region\n");

	po = devm_kzalloc(dev, sizeof(*po), GFP_KERNEL);
	if (!po)
		return -ENOMEM;

	po->shm = devm_ioremap(dev, res.start, resource_size(&res));
	if (!po->shm)
		return dev_err_probe(dev, -ENOMEM, "cannot map IPC region\n");

	dev_info(dev,
		 "IPC shm at %pa: suspend_mask=%08x flag=%08x audio_fw_entry=%08x\n",
		 &res.start,
		 be32_to_cpu((__force __be32)readl(po->shm + IPC_SUSPEND_MASK)),
		 be32_to_cpu((__force __be32)readl(po->shm + IPC_SUSPEND_FLAG)),
		 be32_to_cpu((__force __be32)readl(po->shm + IPC_AUDIO_FW_ENTRY)));

	return devm_register_sys_off_handler(dev, SYS_OFF_MODE_POWER_OFF,
					     SYS_OFF_PRIO_DEFAULT,
					     rtd129x_coolboot_power_off, po);
}

static const struct of_device_id rtd129x_poweroff_dt_ids[] = {
	{ .compatible = "realtek,rtd129x-coolboot-poweroff" },
	{ }
};

static struct platform_driver rtd129x_poweroff_driver = {
	.probe = rtd129x_poweroff_probe,
	.driver = {
		.name = "rtd129x-poweroff",
		.of_match_table = rtd129x_poweroff_dt_ids,
	},
};
builtin_platform_driver(rtd129x_poweroff_driver);
