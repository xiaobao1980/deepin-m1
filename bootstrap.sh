#!/bin/bash
# scripts/bootstrap.sh - 构建 rootfs (适配 Rockchip)

set -e

# 参数解析
BOARD=${1:-generic}
VARIANT=${2:-desktop}  # base 或 desktop
OUTPUT=${3:-./build}
DEEPIN_VERSION=${4:-beige}  # V23

# 加载板级配置
BOARD_CONFIG="board/${BOARD}/board.json"
if [ ! -f "$BOARD_CONFIG" ]; then
    echo "错误: 未找到板级配置 $BOARD_CONFIG"
    exit 1
fi

# 解析 JSON (使用 jq)
SOC=$(jq -r '.metadata.soc' $BOARD_CONFIG)
GPU=$(jq -r '.hardware.gpu' $BOARD_CONFIG)

echo "=== 构建 Deepin ${DEEPIN_VERSION} for ${BOARD} (${SOC}) ==="

# 工作目录
WORK_DIR="${OUTPUT}/work/${BOARD}"
ROOTFS_DIR="${WORK_DIR}/rootfs"
mkdir -p $WORK_DIR

# === 第一阶段: 基础系统 (debootstrap) ===
setup_base_system() {
    echo ">>> 创建基础系统..."
    
    # 使用 deepin beige (V23)
    DEBOOTSTRAP_SUITE="beige"
    DEBOOTSTRAP_MIRROR="https://community-packages.deepin.com/beige"
    
    # 创建 debootstrap 脚本链接 (V23 兼容)
    if [ ! -f "/usr/share/debootstrap/scripts/${DEBOOTSTRAP_SUITE}" ]; then
        sudo ln -sf /usr/share/debootstrap/scripts/sid \
            "/usr/share/debootstrap/scripts/${DEBOOTSTRAP_SUITE}"
    fi
    
    # 运行 debootstrap
    sudo debootstrap \
        --arch=arm64 \
        --variant=minbase \
        --include=eatmydata,sudo,vim-tiny,net-tools,iputils-ping,wget,curl,ca-certificates,dbus,systemd \
        ${DEBOOTSTRAP_SUITE} \
        ${ROOTFS_DIR} \
        ${DEBOOTSTRAP_MIRROR}
    
    # 配置 APT
    sudo chroot ${ROOTFS_DIR} /bin/bash -c "
        cat > /etc/apt/sources.list << 'EOF'
deb [trusted=yes] https://community-packages.deepin.com/beige beige main commercial community
deb [trusted=yes] https://proposed-packages.deepin.com/beige-testing beige main commercial community
EOF
        apt update
        apt install -y deepin-keyring
    "
}

# === 第二阶段: 安装 Deepin 桌面 (修改自 deepin-m1) ===
install_deepin_desktop() {
    echo ">>> 安装 Deepin 桌面环境..."
    
    # 核心包列表 (源自 deepin-m1 经验)
    CORE_PACKAGES="
        dde-desktop-environment-core
        dde-desktop-environment-base
        dde-session-ui
        dde-session-shell
        dde-daemon
        startdde
        deepin-desktop-base
        deepin-wallpapers
        dde-api
        dde-clipboard
        dde-control-center
        dde-file-manager
        dde-launcher
        dde-dock
        deepin-terminal
        deepin-calculator
        deepin-editor
    "
    
    # 修复 libssl 问题 (deepin-m1 已知问题)
    sudo chroot ${ROOTFS_DIR} /bin/bash -c "
        apt install -y libssl3 || apt install -y libssl1.1
        ln -sf /usr/lib/aarch64-linux-gnu/libssl.so.3 /usr/lib/libssl.so 2>/dev/null || true
    "
    
    # 安装桌面
    sudo chroot ${ROOTFS_DIR} /bin/bash -c "
        DEBIAN_FRONTEND=noninteractive apt install -y $CORE_PACKAGES
        systemctl enable dde-session
    "
    
    # 创建首次启动用户配置 (源自 deepin-m1 改进)
    sudo chroot ${ROOTFS_DIR} /bin/bash -c "
        mkdir -p /etc/deepin
        cat > /etc/deepin/first-boot-setup.sh << 'SETUP'
#!/bin/bash
# 首次启动创建用户 (替代默认 hiweed/1)
if [ ! -f /var/lib/deepin/first-boot-done ]; then
    dpkg-reconfigure deepin-default-settings
    touch /var/lib/deepin/first-boot-done
fi
SETUP
        chmod +x /etc/deepin/first-boot-setup.sh
        
        # 添加到 systemd
        cat > /etc/systemd/system/deepin-first-boot.service << 'SERVICE'
[Unit]
Description=Deepin First Boot Setup
After=systemd-user-sessions.service

[Service]
Type=oneshot
ExecStart=/etc/deepin/first-boot-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE
        
        systemctl enable deepin-first-boot
    "
}

# === 第三阶段: Rockchip 硬件适配 (新增) ===
setup_rockchip_hardware() {
    echo ">>> 配置 Rockchip 硬件支持..."
    
    # 安装 vendor 内核
    KERNEL_VERSION="6.1.75-rk3588"
    sudo mkdir -p ${ROOTFS_DIR}/boot
    sudo cp ${OUTPUT}/kernel/${BOARD}/Image ${ROOTFS_DIR}/boot/
    sudo cp ${OUTPUT}/kernel/${BOARD}/dtb/* ${ROOTFS_DIR}/boot/
    
    # 安装内核模块
    sudo tar xzf ${OUTPUT}/kernel/${BOARD}/modules.tar.gz -C ${ROOTFS_DIR}
    
    # 创建 extlinux 配置
    sudo mkdir -p ${ROOTFS_DIR}/boot/extlinux
    sudo bash -c "cat > ${ROOTFS_DIR}/boot/extlinux/extlinux.conf << EOF
default deepin
label deepin
    kernel /Image
    fdt /dtb/rockchip/${SOC}-${BOARD}.dtb
    append console=ttyFIQ0,1500000n8 console=tty1 root=UUID=ROOT_UUID_PLACEHOLDER rw rootwait quiet splash
EOF"
    
    # GPU 驱动配置
    case $GPU in
        "mali-g610")
            setup_mali_g610
            ;;
        "mali-g52")
            setup_mali_g52
            ;;
    esac
    
    # SATA/NAS 特定配置
    if [ "$BOARD" == "cm3588-nas" ]; then
        setup_nas_features
    fi
    
    # PCIe 显卡支持 (ROCK 5 ITX)
    if [ "$BOARD" == "rock-5-itx" ]; then
        setup_pcie_gpu
    fi
}

# Mali G610 配置 (RK3588)
setup_mali_g610() {
    sudo chroot ${ROOTFS_DIR} /bin/bash -c "
        # 安装 Mesa Panfrost (推荐) 或 Vendor Mali
        apt install -y mesa-vulkan-drivers mesa-opencl-icd
        
        # 创建 GPU 权限规则
        cat > /etc/udev/rules.d/50-mali.rules << 'UDEV'
KERNEL==\"mali0\", MODE=\"0666\", GROUP=\"video\"
KERNEL==\"rga\", MODE=\"0666\", GROUP=\"video\"
KERNEL==\"mpp_service\", MODE=\"0666\", GROUP=\"video\"
UDEV
        
        # 添加到 video 组
        usermod -aG video deepin 2>/dev/null || true
    "
    
    # 复制固件
    sudo mkdir -p ${ROOTFS_DIR}/lib/firmware
    sudo cp firmware/mali/mali_csffw.bin ${ROOTFS_DIR}/lib/firmware/ 2>/dev/null || true
}

# NAS 特性配置
setup_nas_features() {
    echo ">>> 配置 NAS 特性..."
    
    sudo chroot ${ROOTFS_DIR} /bin/bash -c "
        # 安装 RAID 和监控工具
        apt install -y mdadm lvm2 smartmontools hdparm
        
        # SATA 热插拔支持
        echo 'options libata hotplug=1' > /etc/modprobe.d/sata-hotplug.conf
        
        # 固定 SATA 设备命名
        cat > /etc/udev/rules.d/50-sata-naming.rules << 'UDEV'
# CM3588-NAS SATA 端口固定命名
SUBSYSTEM==\"block\", KERNEL==\"sd*\", ATTRS{path}==\"*ata.1*\", SYMLINK+=\"sataa%n\", ENV{DEVTYPE}==\"disk\", SYMLINK+=\"sataa\"
SUBSYSTEM==\"block\", KERNEL==\"sd*\", ATTRS{path}==\"*ata.2*\", SYMLINK+=\"satab%n\", ENV{DEVTYPE}==\"disk\", SYMLINK+=\"satab\"
SUBSYSTEM==\"block\", KERNEL==\"sd*\", ATTRS{path}==\"*ata.3*\", SYMLINK+=\"satac%n\", ENV{DEVTYPE}==\"disk\", SYMLINK+=\"satac\"
SUBSYSTEM==\"block\", KERNEL==\"sd*\", ATTRS{path}==\"*ata.4*\", SYMLINK+=\"satad%n\", ENV{DEVTYPE}==\"disk\", SYMLINK+=\"satad\"
UDEV
        
        # 禁用桌面合成器以节省内存 (可选)
        mkdir -p /etc/deepin
        echo '{\"disable_compositor\": true}' > /etc/deepin/nas-mode.conf
    "
}

# PCIe 显卡支持 (ROCK 5 ITX)
setup_pcie_gpu() {
    echo ">>> 配置 PCIe 显卡支持..."
    
    sudo chroot ${ROOTFS_DIR} /bin/bash -c "
        # 安装 AMD GPU 驱动 (最可能的外接显卡)
        apt install -y xserver-xorg-video-amdgpu mesa-vulkan-drivers
        
        # 内核启动参数
        echo 'GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT amdgpu.ppfeaturemask=0xffffffff pcie_aspm=off\"' \
            > /etc/default/grub.d/99-pcie-gpu.cfg
    "
}

# === 第四阶段: 打包 ===
create_artifact() {
    echo ">>> 创建分发包..."
    
    # 创建 boot 包 (内核 + dtb + 配置)
    sudo tar czf ${OUTPUT}/installer-data/${BOARD}/boot.tar.gz -C ${ROOTFS_DIR} boot/
    
    # 创建 rootfs 包
    case $VARIANT in
        base)
            # 最小系统
            sudo rm -rf ${ROOTFS_DIR}/usr/share/deepin-wallpapers  # 节省空间
            sudo tar czf ${OUTPUT}/installer-data/${BOARD}/deepin-base.tar.gz -C ${ROOTFS_DIR} .
            ;;
        desktop)
            # 完整桌面
            sudo tar czf ${OUTPUT}/installer-data/${BOARD}/deepin-desktop.tar.gz -C ${ROOTFS_DIR} .
            ;;
    esac
    
    # 生成校验和
    cd ${OUTPUT}/installer-data/${BOARD}
    sha256sum *.tar.gz > SHA256SUMS
    cd -
}

# 执行流程
setup_base_system
[ "$VARIANT" == "desktop" ] && install_deepin_desktop
setup_rockchip_hardware
create_artifact

echo "=== 构建完成: ${OUTPUT}/installer-data/${BOARD}/ ==="
