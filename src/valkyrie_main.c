/**
 * valkyrie_main.c — Valkyrie Linux Kernel Module
 * PCIe DMA driver: BAR mapping, MSI-X IRQ, zero-copy mmap ring buffers.
 * Build (Linux): make -C /lib/modules/$(uname -r)/build M=$PWD modules
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/pci.h>
#include <linux/interrupt.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/dma-mapping.h>
#include <linux/uaccess.h>
#include <linux/io.h>
#include <linux/version.h>
#include "valkyrie.h"

static int ring_count = VALKYRIE_RING_BUF_COUNT;
module_param(ring_count, int, 0644);
MODULE_PARM_DESC(ring_count, "Number of DMA ring buffers (default=4)");

struct valkyrie_dev {
    struct pci_dev        *pdev;
    struct cdev            cdev;
    struct device         *device;
    dev_t                  dev_num;
    int                    ring_cnt;

    /* BARs */
    void __iomem          *bar[VALKYRIE_BAR_COUNT];
    unsigned long          bar_len[VALKYRIE_BAR_COUNT];

    /* MSI-X */
    struct msix_entry      msix[VALKYRIE_MSIX_VECTORS];
    struct tasklet_struct  tasklet;
    int                    irqs;

    /* DMA Rings */
    struct {
        void              *cpu;
        dma_addr_t         dma;
        size_t             size;
    } rings[VALKYRIE_MAX_RING_BUFFERS];

    valkyrie_ring_desc_t   descs[VALKYRIE_MAX_RING_BUFFERS];
    valkyrie_stats_t       stats;
    spinlock_t             lock;
    atomic_t               active;
    wait_queue_head_t      wq;
};

static struct class *v_class;
static struct valkyrie_dev *v_dev;

/* ─── Forward declarations ─── */
static int  valk_probe(struct pci_dev*, const struct pci_device_id*);
static void valk_remove(struct pci_dev*);
static int  valk_open(struct inode*, struct file*);
static int  valk_release(struct inode*, struct file*);
static int  valk_mmap(struct file*, struct vm_area_struct*);
static long valk_ioctl(struct file*, unsigned int, unsigned long);
static irqreturn_t valk_irq(int, void*);
static void valk_tasklet(unsigned long);
/* ─── PCIe IDs ─── */
static const struct pci_device_id valk_ids[] = {
    { PCI_DEVICE(0x10EE, 0x903F) },
    { 0, }
};
MODULE_DEVICE_TABLE(pci, valk_ids);

static const struct file_operations valk_fops = {
    .owner          = THIS_MODULE,
    .open           = valk_open,
    .release        = valk_release,
    .mmap           = valk_mmap,
    .unlocked_ioctl = valk_ioctl,
};

static struct pci_driver valk_driver = {
    .name     = VALKYRIE_DEVICE_NAME,
    .id_table = valk_ids,
    .probe    = valk_probe,
    .remove   = valk_remove,
};

/* ═══ BARs ═══ */
static int valk_setup_bars(struct valkyrie_dev *vd)
{
    int i;
    for (i = 0; i < VALKYRIE_BAR_COUNT; i++) {
        if (!(pci_resource_flags(vd->pdev, i) & IORESOURCE_MEM))
            continue;
        vd->bar_len[i] = pci_resource_len(vd->pdev, i);
        vd->bar[i] = pci_ioremap_bar(vd->pdev, i);
        if (!vd->bar[i]) {
            dev_err(&vd->pdev->dev, "BAR %d remap failed\n", i);
            return -ENOMEM;
        }
        dev_info(&vd->pdev->dev, "BAR %d: %luB @ %p\n",
                 i, vd->bar_len[i], vd->bar[i]);
    }
    return 0;
}

/* ═══ MSI-X ═══ */
static int valk_setup_msix(struct valkyrie_dev *vd)
{
    int ret, i;
    for (i = 0; i < VALKYRIE_MSIX_VECTORS; i++)
        vd->msix[i].entry = i;

    ret = pci_enable_msix_range(vd->pdev, vd->msix,
                                 VALKYRIE_MSIX_VECTORS,
                                 VALKYRIE_MSIX_VECTORS);
    if (ret < 0) {
        dev_warn(&vd->pdev->dev, "MSI-X failed (%d), fallback MSI\n", ret);
        ret = pci_enable_msi(vd->pdev);
        if (ret) return ret;
        ret = request_irq(vd->pdev->irq, valk_irq, IRQF_SHARED,
                          VALKYRIE_DEVICE_NAME, vd);
        vd->irqs = 1;
        return ret;
    }
    for (i = 0; i < VALKYRIE_MSIX_VECTORS; i++) {
        ret = request_irq(vd->msix[i].vector, valk_irq, 0,
                          VALKYRIE_DEVICE_NAME, vd);
        if (ret) {
            while (i--) free_irq(vd->msix[i].vector, vd);
            return ret;
        }
    }
    vd->irqs = VALKYRIE_MSIX_VECTORS;
    dev_info(&vd->pdev->dev, "MSI-X with %d vectors\n", VALKYRIE_MSIX_VECTORS);
    return 0;
}
/* ═══ DMA Rings ═══ */
static int valk_alloc_rings(struct valkyrie_dev *vd)
{
    int i;
    size_t sz = VALKYRIE_RING_BUF_SIZE;
    vd->ring_cnt = min(ring_count, VALKYRIE_MAX_RING_BUFFERS);

    for (i = 0; i < vd->ring_cnt; i++) {
        vd->rings[i].cpu = dma_alloc_coherent(
            &vd->pdev->dev, sz, &vd->rings[i].dma, GFP_KERNEL);
        if (!vd->rings[i].cpu) {
            dev_err(&vd->pdev->dev, "Ring %d DMA alloc fail\n", i);
            while (i--) dma_free_coherent(&vd->pdev->dev, sz,
                            vd->rings[i].cpu, vd->rings[i].dma);
            return -ENOMEM;
        }
        memset(vd->rings[i].cpu, 0, sz);
        vd->rings[i].size = sz;
        vd->descs[i].head      = 0;
        vd->descs[i].tail      = 0;
        vd->descs[i].flags     = VALKYRIE_RING_ACTIVE;
        vd->descs[i].base_addr = vd->rings[i].dma;
        vd->descs[i].buf_size  = sz;
        vd->descs[i].packet_count = 0;
        /* Publish the ring to the FPGA using the canonical BAR0 map. */
        if (vd->bar[0]) {
            iowrite32(lower_32_bits(vd->rings[i].dma),
                      vd->bar[0] + VALKYRIE_REG_RING_BASE(i));
            iowrite32(upper_32_bits(vd->rings[i].dma),
                      vd->bar[0] + VALKYRIE_REG_RING_BASE(i) + 4);
            iowrite32((u32)sz, vd->bar[0] + VALKYRIE_REG_RING_SIZE(i));
        }
        dev_info(&vd->pdev->dev, "Ring %d: DMA=%pad CPU=%p\n",
                 i, &vd->rings[i].dma, vd->rings[i].cpu);
    }
    return 0;
}

/* ═══ Probe ═══ */
static int valk_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    struct valkyrie_dev *vd;
    int ret, i;

    vd = kzalloc(sizeof(*vd), GFP_KERNEL);
    if (!vd) return -ENOMEM;
    vd->pdev = pdev;
    spin_lock_init(&vd->lock);
    atomic_set(&vd->active, 0);
    init_waitqueue_head(&vd->wq);

    ret = pci_enable_device(pdev);
    if (ret) { dev_err(&pdev->dev, "pci_enable fail\n"); goto err_free; }
    pci_set_master(pdev);

    ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
    if (ret) {
        ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
        if (ret) { dev_err(&pdev->dev, "No DMA mask\n"); goto err_disable; }
    }

    ret = pci_request_regions(pdev, VALKYRIE_DEVICE_NAME);
    if (ret) { dev_err(&pdev->dev, "pci_request_regions fail\n"); goto err_disable; }

    ret = valk_setup_bars(vd);
    if (ret) goto err_regions;
    ret = valk_setup_msix(vd);
    if (ret) { dev_err(&pdev->dev, "IRQ setup fail\n"); goto err_unmap; }
    ret = valk_alloc_rings(vd);
    if (ret) goto err_irq;

    tasklet_init(&vd->tasklet, valk_tasklet, (unsigned long)vd);

    ret = alloc_chrdev_region(&vd->dev_num, 0, 1, VALKYRIE_DEVICE_NAME);
    if (ret) { dev_err(&pdev->dev, "chrdev alloc fail\n"); goto err_rings; }
    cdev_init(&vd->cdev, &valk_fops);
    vd->cdev.owner = THIS_MODULE;
    ret = cdev_add(&vd->cdev, vd->dev_num, 1);
    if (ret) { dev_err(&pdev->dev, "cdev_add fail\n"); goto err_chrdev; }
    vd->device = device_create(v_class, &pdev->dev, vd->dev_num,
                    NULL, VALKYRIE_DEVICE_NAME "%d", MINOR(vd->dev_num));
    if (IS_ERR(vd->device)) { ret = PTR_ERR(vd->device); goto err_cdev; }

    pci_set_drvdata(pdev, vd);
    v_dev = vd;
    atomic_set(&vd->active, 1);
    dev_info(&pdev->dev, "Valkyrie ready maj=%d min=%d rings=%d\n",
             MAJOR(vd->dev_num), MINOR(vd->dev_num), vd->ring_cnt);
    return 0;

err_cdev:    cdev_del(&vd->cdev);
err_chrdev:  unregister_chrdev_region(vd->dev_num, 1);
err_rings:   tasklet_kill(&vd->tasklet);
             for (i = 0; i < vd->ring_cnt; i++)
                 if (vd->rings[i].cpu)
                     dma_free_coherent(&pdev->dev, vd->rings[i].size,
                                       vd->rings[i].cpu, vd->rings[i].dma);
err_irq:     if (vd->irqs == 1) free_irq(pdev->irq, vd);
             else for (i = 0; i < vd->irqs; i++) free_irq(vd->msix[i].vector, vd);
err_unmap:   for (i = 0; i < VALKYRIE_BAR_COUNT; i++)
                 if (vd->bar[i]) iounmap(vd->bar[i]);
err_regions: pci_release_regions(pdev);
err_disable: pci_disable_device(pdev);
err_free:    kfree(vd);
    return ret;
}

/* ═══ Char ops ═══ */
static int valk_open(struct inode *inode, struct file *filp)
{
    struct valkyrie_dev *vd = v_dev;
    if (!vd || !atomic_read(&vd->active)) return -ENODEV;
    filp->private_data = vd;
    return 0;
}

static int valk_release(struct inode *inode, struct file *filp) { return 0; }

static int valk_mmap(struct file *filp, struct vm_area_struct *vma)
{
    struct valkyrie_dev *vd = filp->private_data;
    unsigned long off = vma->vm_pgoff << PAGE_SHIFT;
    unsigned long sz  = vma->vm_end - vma->vm_start;
    int idx;

    if (!vd || off % VALKYRIE_RING_BUF_SIZE) return -EINVAL;
    idx = off / VALKYRIE_RING_BUF_SIZE;
    if (idx >= vd->ring_cnt || sz > vd->rings[idx].size) return -EINVAL;

    vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
    vm_flags_set(vma, VM_IO | VM_DONTEXPAND | VM_DONTDUMP);
#else
    vma->vm_flags |= VM_IO | VM_DONTEXPAND | VM_DONTDUMP;
#endif

    if (dma_mmap_coherent(&vd->pdev->dev, vma, vd->rings[idx].cpu,
                           vd->rings[idx].dma, sz))
        return -EAGAIN;
    dev_info(&vd->pdev->dev, "mmap ring %d -> user\n", idx);
    return 0;
}

static long valk_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
    struct valkyrie_dev *vd = filp->private_data;
    void __user *u = (void __user*)arg;
    if (!vd) return -ENODEV;

    switch (cmd) {
    case VALKYRIE_IOCTL_GET_RING: {
        int idx;
        if (copy_from_user(&idx, u, sizeof(int))) return -EFAULT;
        if (idx < 0 || idx >= vd->ring_cnt) return -EINVAL;
        if (copy_to_user(u, &vd->descs[idx], sizeof(valkyrie_ring_desc_t)))
            return -EFAULT;
        return 0;
    }
    case VALKYRIE_IOCTL_START_DMA:
        if (vd->bar[0])
            iowrite32(VALKYRIE_DMA_CTRL_ENABLE,
                      vd->bar[0] + VALKYRIE_REG_DMA_CTRL);
        dev_info(&vd->pdev->dev, "DMA start\n"); return 0;
    case VALKYRIE_IOCTL_STOP_DMA:
        if (vd->bar[0]) iowrite32(0, vd->bar[0] + VALKYRIE_REG_DMA_CTRL);
        dev_info(&vd->pdev->dev, "DMA stop\n"); return 0;
    case VALKYRIE_IOCTL_GET_STATS:
        if (copy_to_user(u, &vd->stats, sizeof(vd->stats))) return -EFAULT;
        return 0;
    case VALKYRIE_IOCTL_GET_LATENCY: {
        valkyrie_latency_t lat;
        if (!vd->bar[0]) return -ENODEV;
        memset(&lat, 0, sizeof(lat));
        lat.timestamp_ns = ((__u64)ioread32(vd->bar[0] + VALKYRIE_REG_TS_HI) << 32)
                         |  (__u64)ioread32(vd->bar[0] + VALKYRIE_REG_TS_LO);
        lat.last_cycles  = ioread32(vd->bar[0] + VALKYRIE_REG_LAT_LAST);
        lat.min_cycles   = ioread32(vd->bar[0] + VALKYRIE_REG_LAT_MIN);
        lat.max_cycles   = ioread32(vd->bar[0] + VALKYRIE_REG_LAT_MAX);
        lat.packets      = ioread32(vd->bar[0] + VALKYRIE_REG_LAT_PKTS);
        lat.sum_cycles   = ((__u64)ioread32(vd->bar[0] + VALKYRIE_REG_LAT_SUM_HI) << 32)
                         |  (__u64)ioread32(vd->bar[0] + VALKYRIE_REG_LAT_SUM_LO);
        lat.ring_overflows = ioread32(vd->bar[0] + VALKYRIE_REG_RING_OVERFLOW);
        if (copy_to_user(u, &lat, sizeof(lat))) return -EFAULT;
        return 0;
    }
    case VALKYRIE_IOCTL_RESET:
        for (int i = 0; i < vd->ring_cnt; i++) {
            vd->descs[i].head = vd->descs[i].tail = 0;
            vd->descs[i].flags = VALKYRIE_RING_ACTIVE;
            vd->descs[i].packet_count = 0;
            memset(vd->rings[i].cpu, 0, vd->rings[i].size);
        }
        memset(&vd->stats, 0, sizeof(vd->stats)); return 0;
    default: return -ENOTTY;
    }
}

/* ═══ IRQ ═══ */
static irqreturn_t valk_irq(int irq, void *dev_id)
{
    struct valkyrie_dev *vd = dev_id;
    if (vd->bar[0]) {
        u32 s = ioread32(vd->bar[0] + VALKYRIE_REG_IRQ_STATUS);
        iowrite32(s, vd->bar[0] + VALKYRIE_REG_IRQ_STATUS);  /* W1C */
    }
    tasklet_schedule(&vd->tasklet);
    wake_up_interruptible(&vd->wq);
    return IRQ_HANDLED;
}

static void valk_tasklet(unsigned long data)
{
    struct valkyrie_dev *vd = (struct valkyrie_dev*)data;
    for (int i = 0; i < vd->ring_cnt; i++) {
        vd->descs[i].tail = vd->descs[i].head;
        vd->stats.dma_completions++;
        vd->stats.packets_received += vd->descs[i].packet_count;
    }
}

/* ═══ Module ═══ */
static int __init valkyrie_init(void)
{
    pr_info("Valkyrie DMA v1.0 loading...\n");
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 4, 0)
    v_class = class_create(VALKYRIE_CLASS_NAME);
#else
    v_class = class_create(THIS_MODULE, VALKYRIE_CLASS_NAME);
#endif
    if (IS_ERR(v_class)) return PTR_ERR(v_class);
    int ret = pci_register_driver(&valk_driver);
    if (ret) { class_destroy(v_class); return ret; }
    pr_info("Valkyrie DMA loaded\n");
    return 0;
}

static void __exit valkyrie_exit(void)
{
    pci_unregister_driver(&valk_driver);
    class_destroy(v_class);
    pr_info("Valkyrie DMA unloaded\n");
}

module_init(valkyrie_init);
module_exit(valkyrie_exit);

/* Dual MIT/GPL: the source is MIT, but the module links GPL-only symbols
 * (class_create/device_create/pci_ioremap_bar), so modpost requires a
 * GPL-compatible licence tag. "MIT" alone fails with:
 *   ERROR: modpost: GPL-incompatible module valkyrie.ko uses GPL-only symbol */
MODULE_LICENSE("Dual MIT/GPL");
MODULE_AUTHOR("Frankline Misango Oyolo");
MODULE_DESCRIPTION("Valkyrie — Ultra-Fast PCIe DMA Module for HFT");
MODULE_VERSION("1.0.0");

static void valk_remove(struct pci_dev *pdev)
{
    struct valkyrie_dev *vd = pci_get_drvdata(pdev);
    if (!vd) return;
    atomic_set(&vd->active, 0);
    device_destroy(v_class, vd->dev_num);
    cdev_del(&vd->cdev);
    unregister_chrdev_region(vd->dev_num, 1);
    tasklet_kill(&vd->tasklet);
    if (vd->irqs > 0) {
        if (vd->irqs == 1) free_irq(vd->pdev->irq, vd);
        else for (int i = 0; i < vd->irqs; i++)
            free_irq(vd->msix[i].vector, vd);
    }
    for (int i = 0; i < vd->ring_cnt; i++)
        if (vd->rings[i].cpu)
            dma_free_coherent(&vd->pdev->dev, vd->rings[i].size,
                              vd->rings[i].cpu, vd->rings[i].dma);
    for (int i = 0; i < VALKYRIE_BAR_COUNT; i++)
        if (vd->bar[i]) iounmap(vd->bar[i]);
    pci_release_regions(pdev);
    pci_disable_device(pdev);
    dev_info(&pdev->dev, "Valkyrie removed\n");
    kfree(vd);
    v_dev = NULL;
}