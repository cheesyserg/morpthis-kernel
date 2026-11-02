// SPDX-License-Identifier: GPL-2.0
/*
 * morpthis_led -- the TempoTec V1 status light (SGM31324 RGB controller on
 * I2C bus 0, address 0x30) driven from the kernel.
 *
 * This is the player's own LED engine (src/system/device/led.c and
 * led_i2c.c), moved under the kernel. The register map, the level ladder,
 * the cross-fade, the quadratic fade-out, the blink and the hardware breathing
 * are exactly what the player did over /dev/i2c-0; see
 * docs/sgm31324-led-control.md. What moving it here buys:
 *
 *   - a fade is ten-millisecond kernel work instead of a userspace thread
 *     doing four write() syscalls per step and sleeping in between, so its
 *     steps keep their spacing however busy the interface thread is;
 *   - a register shadow: a step that leaves a register where it was does not
 *     put it on the bus again, which in a cross-fade between two colours that
 *     share a channel is most of the writes;
 *   - the blink runs with no process waking up every half second;
 *   - the light goes out at reboot and power-off even when the player is not
 *     the one that asked for it (a crash, a watchdog reboot, `reboot` from a
 *     shell), and the shadow is thrown away across a suspend, so the first
 *     write after the wake is a real one.
 *
 * The controller is reached with raw transfers on the adapter rather than
 * through a bound i2c client: the device tree already declares a client at
 * 0x30 for the vendor driver (leds_sgm31324_add.ko), which the firmware packer
 * removes, and a second client at the same address would be refused. The
 * vendor module must not be loaded at the same time; the player unloads it
 * before it loads this one.
 *
 * Interface: /sys/devices/platform/morpthis-led/
 *
 *   render   (w)  "MODE R G B PERIOD DUTY FADE TRANSITION_MS STEP_MS"
 *                 MODE 0 steady (cross-fade to R G B), 1 hardware breathing,
 *                 2 blink, 3 off (quadratic fade-out). R G B are the
 *                 controller's 0-79 levels; PERIOD DUTY FADE are the raw
 *                 breathing registers. A new render cuts the one running,
 *                 from wherever it had got to.
 *   busy     (r)  1 while a fade is running, else 0
 *   wait     (r)  waits up to 50 ms for the running fade to end, then
 *                 reads as busy does
 *   regs     (r)  the register shadow, "--" for a register not known
 *   resync   (w)  forget the shadow (someone else wrote to the chip)
 */

#include <linux/delay.h>
#include <linux/device.h>
#include <linux/err.h>
#include <linux/i2c.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/pm.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/sysfs.h>
#include <linux/wait.h>
#include <linux/workqueue.h>

#define DRV_NAME "morpthis-led"
#define DRV_VERSION "1"

static int bus;
module_param(bus, int, 0444);
MODULE_PARM_DESC(bus, "I2C adapter number of the SGM31324 (default 0)");

static ushort addr = 0x30;
module_param(addr, ushort, 0444);
MODULE_PARM_DESC(addr, "I2C address of the SGM31324 (default 0x30)");

/* The register map (docs/sgm31324-led-control.md). */
#define REG_COUNT 10
#define REG_PERIOD 0x01
#define REG_DUTY 0x02
#define REG_MAP 0x04
#define REG_FADE 0x05
#define REG_R 0x06
#define REG_G 0x07
#define REG_B 0x08
#define REG_MODE 0x09

#define DEV_EN 0x40
#define CH_R 0x01
#define CH_G 0x04
#define CH_B 0x10
#define BREATHE_R 0x02
#define BREATHE_G 0x08
#define BREATHE_B 0x20

#define LEVEL_MAX 79
#define BLINK_MS 500

enum { MODE_STEADY, MODE_BREATHE, MODE_BLINK, MODE_OFF, MODE_COUNT };

struct target {
	int mode;
	int r, g, b;
	int period, duty, fade;
	int transition_ms;
	int step_ms;
};

struct sgm {
	struct i2c_adapter *adap;
	struct mutex lock;		/* everything below */
	struct delayed_work work;
	wait_queue_head_t idle_wq;

	u8 shadow[REG_COUNT];
	bool shadow_ok[REG_COUNT];
	bool i2c_warned;

	struct target t;		/* what was asked for last */
	bool fresh;			/* t has not been started yet */
	bool busy;			/* a ramp is running */
	bool suspended;
	unsigned int gen;		/* bumped by every render */

	/* What the light is showing, as the player's worker kept it. */
	int cur_r, cur_g, cur_b;
	unsigned int cur_ch;

	/* The running ramp or blink. */
	int sr, sg, sb;
	int tr, tg, tb;
	unsigned int tch, ramp_ch;
	int step, steps;
	bool blink_lit;
};

static struct sgm *g_sgm;
static struct platform_device *g_pdev;

/* --- the bus ------------------------------------------------------------ */

static void write_reg(struct sgm *s, u8 reg, u8 val)
{
	u8 buf[2] = { reg, val };
	struct i2c_msg msg = {
		.addr = addr,
		.flags = 0,
		.len = sizeof(buf),
		.buf = buf,
	};
	int ret;

	if (reg < REG_COUNT && s->shadow_ok[reg] && s->shadow[reg] == val)
		return;

	ret = i2c_transfer(s->adap, &msg, 1);
	if (ret != 1) {
		if (!s->i2c_warned) {
			pr_warn(DRV_NAME ": write of reg 0x%02x failed (%d)\n", reg, ret);
			s->i2c_warned = true;
		}
		if (reg < REG_COUNT)
			s->shadow_ok[reg] = false;
		return;
	}
	if (reg < REG_COUNT) {
		s->shadow[reg] = val;
		s->shadow_ok[reg] = true;
	}
}

static void forget_shadow(struct sgm *s)
{
	memset(s->shadow_ok, 0, sizeof(s->shadow_ok));
}

static unsigned int ch_mask(int r, int g, int b)
{
	unsigned int m = 0;

	if (r > 0)
		m |= CH_R;
	if (g > 0)
		m |= CH_G;
	if (b > 0)
		m |= CH_B;
	return m;
}

/* led_i2c_levels(): the enable map, then the three levels. */
static void hw_levels(struct sgm *s, int r, int g, int b, unsigned int ch)
{
	write_reg(s, REG_MAP, DEV_EN | (ch & (CH_R | CH_G | CH_B)));
	write_reg(s, REG_R, (u8)r);
	write_reg(s, REG_G, (u8)g);
	write_reg(s, REG_B, (u8)b);
}

/* led_i2c_steady() */
static void hw_steady(struct sgm *s)
{
	write_reg(s, REG_MODE, 0x00);
}

/* led_i2c_breathe(): every register the engine depends on, in this order. */
static void hw_breathe(struct sgm *s, const struct target *t)
{
	u8 map = DEV_EN;

	if (t->r > 0)
		map |= BREATHE_R;
	if (t->g > 0)
		map |= BREATHE_G;
	if (t->b > 0)
		map |= BREATHE_B;
	write_reg(s, 0x00, 0x00);
	write_reg(s, REG_PERIOD, (u8)t->period);
	write_reg(s, REG_DUTY, (u8)t->duty);
	write_reg(s, 0x03, 0x00);
	write_reg(s, REG_MAP, map);
	write_reg(s, REG_FADE, (u8)t->fade);
	write_reg(s, REG_R, (u8)t->r);
	write_reg(s, REG_G, (u8)t->g);
	write_reg(s, REG_B, (u8)t->b);
	write_reg(s, REG_MODE, 0x06);
}

/* led_i2c_off(): DEV_EN too, so the controller draws nothing. */
static void hw_off(struct sgm *s)
{
	write_reg(s, REG_MAP, 0x00);
	write_reg(s, REG_R, 0x00);
	write_reg(s, REG_G, 0x00);
	write_reg(s, REG_B, 0x00);
	write_reg(s, REG_MODE, 0x00);
}

/* --- the engine --------------------------------------------------------- */

static void set_idle(struct sgm *s)
{
	if (s->busy) {
		s->busy = false;
		wake_up_all(&s->idle_wq);
	}
}

static void schedule_next(struct sgm *s, int ms)
{
	/* queue_ rather than mod_: a render that has just queued the work at
	 * zero delay must not be pushed back by the step it is cutting. */
	queue_delayed_work(system_freezable_wq, &s->work, msecs_to_jiffies(ms));
}

/* One step of the ramp: the player worker's loop body, i is s->step. */
static void ramp_step(struct sgm *s)
{
	int i = s->step, steps = s->steps;
	int r, g, b;

	if (s->t.mode == MODE_OFF) {
		int k = steps - i;

		r = s->sr * k * k / (steps * steps);
		g = s->sg * k * k / (steps * steps);
		b = s->sb * k * k / (steps * steps);
	} else {
		r = s->sr + (s->tr - s->sr) * i / steps;
		g = s->sg + (s->tg - s->sg) * i / steps;
		b = s->sb + (s->tb - s->sb) * i / steps;
	}
	hw_levels(s, r, g, b, s->ramp_ch);
	s->cur_r = r;
	s->cur_g = g;
	s->cur_b = b;

	if (i < steps) {
		/* Until the last step lands, a cut leaves every channel of the
		 * ramp enabled, as the player's worker did. */
		s->cur_ch = s->ramp_ch;
		s->step++;
		schedule_next(s, s->t.step_ms);
		return;
	}

	if (s->t.mode == MODE_OFF)
		hw_off(s);
	s->cur_r = s->tr;
	s->cur_g = s->tg;
	s->cur_b = s->tb;
	s->cur_ch = s->tch;
	set_idle(s);
}

static void start_target(struct sgm *s)
{
	const struct target *t = &s->t;

	s->fresh = false;

	switch (t->mode) {
	case MODE_BREATHE:
		hw_breathe(s, t);
		s->cur_r = t->r;
		s->cur_g = t->g;
		s->cur_b = t->b;
		s->cur_ch = ch_mask(t->r, t->g, t->b);
		set_idle(s);
		return;

	case MODE_BLINK:
		/* The blink is only ever left by a cut, and the player's worker
		 * left it with the light counted as dark on the blink's channels. */
		s->tch = ch_mask(t->r, t->g, t->b);
		s->cur_r = 0;
		s->cur_g = 0;
		s->cur_b = 0;
		s->cur_ch = s->tch;
		hw_steady(s);
		hw_levels(s, t->r, t->g, t->b, s->tch);
		s->blink_lit = true;
		set_idle(s);
		schedule_next(s, BLINK_MS);
		return;

	default:
		/* Steady or off: a walk from what is on now to the target. */
		s->tr = t->mode == MODE_OFF ? 0 : t->r;
		s->tg = t->mode == MODE_OFF ? 0 : t->g;
		s->tb = t->mode == MODE_OFF ? 0 : t->b;
		s->tch = t->mode == MODE_OFF ? 0 : ch_mask(s->tr, s->tg, s->tb);
		s->ramp_ch = s->cur_ch | s->tch;
		s->steps = t->transition_ms / t->step_ms;
		if (s->steps < 1)
			s->steps = 1;
		s->sr = s->cur_r;
		s->sg = s->cur_g;
		s->sb = s->cur_b;
		s->step = 1;
		hw_steady(s);
		ramp_step(s);
		return;
	}
}

static void sgm_work(struct work_struct *work)
{
	struct sgm *s = container_of(to_delayed_work(work), struct sgm, work);

	mutex_lock(&s->lock);
	if (s->suspended) {
		mutex_unlock(&s->lock);
		return;
	}
	if (s->fresh) {
		start_target(s);
	} else if (s->t.mode == MODE_BLINK) {
		s->blink_lit = !s->blink_lit;
		if (s->blink_lit)
			hw_levels(s, s->t.r, s->t.g, s->t.b, s->tch);
		else
			hw_levels(s, 0, 0, 0, s->tch);
		schedule_next(s, BLINK_MS);
	} else if (s->busy) {
		ramp_step(s);
	}
	mutex_unlock(&s->lock);
}

/* --- sysfs -------------------------------------------------------------- */

static int clamp_level(int v)
{
	return clamp(v, 0, LEVEL_MAX);
}

static ssize_t render_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	struct sgm *s = g_sgm;
	struct target t;
	int n;

	n = sscanf(buf, "%d %d %d %d %d %d %d %d %d", &t.mode, &t.r, &t.g, &t.b, &t.period, &t.duty, &t.fade,
		   &t.transition_ms, &t.step_ms);
	if (n < 4)
		return -EINVAL;
	if (n < 7)
		t.period = t.duty = t.fade = 0;
	if (n < 8)
		t.transition_ms = 500;
	if (n < 9)
		t.step_ms = 10;
	if (t.mode < 0 || t.mode >= MODE_COUNT)
		return -EINVAL;

	t.r = clamp_level(t.r);
	t.g = clamp_level(t.g);
	t.b = clamp_level(t.b);
	t.period = clamp(t.period, 0, 255);
	t.duty = clamp(t.duty, 0, 255);
	t.fade = clamp(t.fade, 0, 255);
	t.transition_ms = clamp(t.transition_ms, 1, 10000);
	t.step_ms = clamp(t.step_ms, 1, 1000);

	mutex_lock(&s->lock);
	s->t = t;
	s->fresh = true;
	s->gen++;
	/* Busy from now until the walk lands, so a reader of `wait` right
	 * after this write never sees the gap before the work has run. */
	s->busy = t.mode == MODE_STEADY || t.mode == MODE_OFF;
	wake_up_all(&s->idle_wq);
	mutex_unlock(&s->lock);

	mod_delayed_work(system_freezable_wq, &s->work, 0);
	return count;
}
static DEVICE_ATTR_WO(render);

static ssize_t busy_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sprintf(buf, "%d\n", READ_ONCE(g_sgm->busy) ? 1 : 0);
}
static DEVICE_ATTR_RO(busy);

static ssize_t wait_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct sgm *s = g_sgm;
	unsigned int gen = READ_ONCE(s->gen);

	wait_event_interruptible_timeout(s->idle_wq, !READ_ONCE(s->busy) || READ_ONCE(s->gen) != gen,
					 msecs_to_jiffies(50));
	return sprintf(buf, "%d\n", READ_ONCE(s->busy) ? 1 : 0);
}
static DEVICE_ATTR_RO(wait);

static ssize_t regs_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct sgm *s = g_sgm;
	ssize_t len = 0;
	int i;

	mutex_lock(&s->lock);
	for (i = 0; i < REG_COUNT; i++) {
		if (s->shadow_ok[i])
			len += scnprintf(buf + len, PAGE_SIZE - len, "%02x%c", s->shadow[i], i + 1 < REG_COUNT ? ' ' : '\n');
		else
			len += scnprintf(buf + len, PAGE_SIZE - len, "--%c", i + 1 < REG_COUNT ? ' ' : '\n');
	}
	mutex_unlock(&s->lock);
	return len;
}
static DEVICE_ATTR_RO(regs);

static ssize_t resync_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	mutex_lock(&g_sgm->lock);
	forget_shadow(g_sgm);
	mutex_unlock(&g_sgm->lock);
	return count;
}
static DEVICE_ATTR_WO(resync);

static ssize_t version_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return sprintf(buf, "%s\n", DRV_VERSION);
}
static DEVICE_ATTR_RO(version);

static struct attribute *sgm_attrs[] = {
	&dev_attr_render.attr,
	&dev_attr_busy.attr,
	&dev_attr_wait.attr,
	&dev_attr_regs.attr,
	&dev_attr_resync.attr,
	&dev_attr_version.attr,
	NULL,
};

static const struct attribute_group sgm_group = {
	.attrs = sgm_attrs,
};

/* --- the platform driver ------------------------------------------------- */

/* Stops whatever is running and puts the light out, now. */
static void sgm_quiesce(struct sgm *s, bool dark)
{
	cancel_delayed_work_sync(&s->work);
	mutex_lock(&s->lock);
	s->fresh = false;
	if (dark) {
		forget_shadow(s);	/* written for certain, whatever the shadow says */
		hw_off(s);
		s->cur_r = s->cur_g = s->cur_b = 0;
		s->cur_ch = 0;
	}
	set_idle(s);
	mutex_unlock(&s->lock);
}

static int sgm_probe(struct platform_device *pdev)
{
	struct sgm *s;
	int ret;

	s = devm_kzalloc(&pdev->dev, sizeof(*s), GFP_KERNEL);
	if (!s)
		return -ENOMEM;

	s->adap = i2c_get_adapter(bus);
	if (!s->adap) {
		dev_err(&pdev->dev, "no I2C adapter %d\n", bus);
		return -ENODEV;
	}

	mutex_init(&s->lock);
	INIT_DELAYED_WORK(&s->work, sgm_work);
	init_waitqueue_head(&s->idle_wq);
	g_sgm = s;
	platform_set_drvdata(pdev, s);

	ret = sysfs_create_group(&pdev->dev.kobj, &sgm_group);
	if (ret) {
		g_sgm = NULL;
		i2c_put_adapter(s->adap);
		return ret;
	}

	/* Nothing is assumed about what the chip was left showing: it keeps
	 * running on its last registers when its driver goes away, so the
	 * shadow starts empty and the first render writes for real. */
	dev_info(&pdev->dev, "SGM31324 on i2c-%d at 0x%02x\n", bus, addr);
	return 0;
}

static int sgm_remove(struct platform_device *pdev)
{
	struct sgm *s = platform_get_drvdata(pdev);

	sysfs_remove_group(&pdev->dev.kobj, &sgm_group);
	/* Left as it is: the player hands the chip back to its own I2C path
	 * on the colour it shows, and unloading must not flash the light. */
	sgm_quiesce(s, false);
	g_sgm = NULL;
	i2c_put_adapter(s->adap);
	return 0;
}

/* Reboot and power-off: the light goes with the system, whoever asked. */
static void sgm_shutdown(struct platform_device *pdev)
{
	struct sgm *s = platform_get_drvdata(pdev);

	if (s)
		sgm_quiesce(s, true);
}

#ifdef CONFIG_PM_SLEEP
static int sgm_suspend(struct device *dev)
{
	struct sgm *s = dev_get_drvdata(dev);

	/* The player fades the light out before it writes `mem`; this only
	 * stops a ramp or a blink that was still going. */
	cancel_delayed_work_sync(&s->work);
	mutex_lock(&s->lock);
	s->suspended = true;
	set_idle(s);
	mutex_unlock(&s->lock);
	return 0;
}

static int sgm_resume(struct device *dev)
{
	struct sgm *s = dev_get_drvdata(dev);

	mutex_lock(&s->lock);
	s->suspended = false;
	/* Whatever the rail did through the sleep, the next write is real. */
	forget_shadow(s);
	if (s->fresh || s->t.mode == MODE_BLINK)
		schedule_next(s, 0);
	mutex_unlock(&s->lock);
	return 0;
}
#endif

static SIMPLE_DEV_PM_OPS(sgm_pm_ops, sgm_suspend, sgm_resume);

static struct platform_driver sgm_driver = {
	.probe = sgm_probe,
	.remove = sgm_remove,
	.shutdown = sgm_shutdown,
	.driver = {
		.name = DRV_NAME,
		.pm = &sgm_pm_ops,
	},
};

static int __init sgm_init(void)
{
	int ret;

	ret = platform_driver_register(&sgm_driver);
	if (ret)
		return ret;

	g_pdev = platform_device_register_simple(DRV_NAME, -1, NULL, 0);
	if (IS_ERR(g_pdev)) {
		platform_driver_unregister(&sgm_driver);
		return PTR_ERR(g_pdev);
	}
	if (!g_sgm) {
		/* The probe refused (no adapter): fail the load, so the player
		 * keeps its own I2C path instead of a node that does nothing. */
		platform_device_unregister(g_pdev);
		platform_driver_unregister(&sgm_driver);
		return -ENODEV;
	}
	return 0;
}

static void __exit sgm_exit(void)
{
	platform_device_unregister(g_pdev);
	platform_driver_unregister(&sgm_driver);
}

module_init(sgm_init);
module_exit(sgm_exit);

MODULE_DESCRIPTION("TempoTec V1 SGM31324 status light, the Morpthis LED engine");
MODULE_AUTHOR("Morpthis");
MODULE_LICENSE("GPL");
MODULE_VERSION(DRV_VERSION);
