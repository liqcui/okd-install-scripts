#!/bin/bash
set -euo pipefail

WORK_DIR="/opt/kubespray-offline"
TARGET_VERSIONS="${1:-v2.31.0 v2.30.0 v2.29.1}"

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"
mkdir -p kubespray-versions repository inventory/dummy

# ================= 1. 环境准备 =================
PY3_VER=$(python3 -c "import sys; print('%s.%s' % (sys.version_info.major, sys.version_info.minor))")
VENV_PKG="python${PY3_VER}-venv"

# ✅ 修复: 使用 dpkg-query 替代 dpkg -s，避免 set -e 下的语法解析异常
if ! dpkg-query -W "${VENV_PKG}" &>/dev/null; then
    echo "[INFO] 安装 ${VENV_PKG}..."
    apt-get update -qq && apt-get install -y -qq "${VENV_PKG}"
fi

# ================= 1.5 检查并安装 nerdctl + containerd =================
if ! command -v nerdctl &>/dev/null; then
    echo "[INFO] 未检测到 nerdctl，正在自动安装..."

    # ✅ 修复: 去掉反斜杠续行符后的空行，改为单行管道，避免 bash 解析 "unexpected token `|`"
    NERDCTL_VER=$(curl -fsSL https://api.github.com/repos/containerd/nerdctl/releases/latest | grep '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')

    if [ -z "${NERDCTL_VER}" ]; then
        echo "❌ 无法获取 nerdctl 最新版本号，请检查网络连接或手动指定版本"
        exit 1
    fi

    DOWNLOAD_URL="https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VER}/nerdctl-${NERDCTL_VER}-linux-amd64.tar.gz"
    echo "[INFO] 下载 nerdctl v${NERDCTL_VER} ..."
    echo "[INFO] URL: ${DOWNLOAD_URL}"

    TMPFILE=$(mktemp /tmp/nerdctl-XXXXXX.tar.gz)
    if ! wget -q --show-progress -O "${TMPFILE}" "${DOWNLOAD_URL}"; then
        echo "❌ 下载失败，请检查网络或手动下载: ${DOWNLOAD_URL}"
        rm -f "${TMPFILE}"
        exit 1
    fi

    tar xzf "${TMPFILE}" -C /usr/local/bin/ nerdctl
    rm -f "${TMPFILE}"
    chmod +x /usr/local/bin/nerdctl

    echo "[INFO] ✅ nerdctl 安装完成: $(nerdctl --version)"
else
    echo "[INFO] ✅ nerdctl 已存在: $(nerdctl --version)"
fi

# ================= 1.6 检查并安装 containerd（nerdctl 依赖它）=================
# 先明确检查是否已安装，不存在则安装
if ! command -v containerd &>/dev/null; then
    echo "[INFO] 未检测到 containerd，正在安装..."
    apt-get update -qq && apt-get install -y -qq containerd
    echo "[INFO] ✅ containerd 安装完成: $(containerd --version)"
else
    echo "[INFO] ✅ containerd 已存在: $(containerd --version)"
fi

# 再确保 containerd 服务正在运行
if ! systemctl is-active --quiet containerd 2>/dev/null; then
    echo "[INFO] containerd 未运行，正在启动..."
    systemctl enable --now containerd || {
        echo "❌ containerd 启动失败，请手动处理"
        exit 1
    }
    echo "[INFO] ✅ containerd 已就绪"
else
    echo "[INFO] ✅ containerd 已在运行"
fi

# ================= 1.7 确保 ctr CLI 可用（Kubespray 导出镜像依赖它）=================
# Kubespray 默认在 /usr/local/bin/ctr 查找 ctr；apt 装的 containerd 把它放在 /usr/bin/ctr
CTR_REAL=$(command -v ctr || true)
if [ -z "${CTR_REAL}" ]; then
    echo "[INFO] 未检测到 ctr，(重新)安装 containerd 以提供 ctr..."
    apt-get update -qq && apt-get install -y -qq containerd
    CTR_REAL=$(command -v ctr || true)
fi
if [ -z "${CTR_REAL}" ]; then
    echo "❌ ctr 仍不可用，请手动安装 containerd"
    exit 1
fi
# 软链到 Kubespray 默认的 bin_dir（/usr/local/bin），让 ansible 能找到
if [ "${CTR_REAL}" != "/usr/local/bin/ctr" ] && [ ! -e /usr/local/bin/ctr ]; then
    ln -s "${CTR_REAL}" /usr/local/bin/ctr
    echo "[INFO] ✅ 已软链 ctr -> ${CTR_REAL} (/usr/local/bin/ctr)"
else
    echo "[INFO] ✅ ctr 已可用: ${CTR_REAL}"
fi

# ================= 2. 创建安全的 INI Inventory =================
INV_FILE="${WORK_DIR}/inventory/dummy/hosts.ini"
if [ ! -f "${INV_FILE}" ]; then
    cat > "${INV_FILE}" <<'EOF'
[all]
localhost ansible_connection=local

[kube_control_plane]
localhost

[kube_node]
localhost

[etcd]
localhost

[k8s_cluster:children]
kube_control_plane
kube_node

[calico_rr]

[bastion]
EOF
    echo "[INFO] 已创建 INI 格式 dummy inventory"
fi

# ================= 3. 版本循环处理 =================
for VERSION in ${TARGET_VERSIONS}; do
    echo ""
    echo "=============================================="
    echo "🚀 Preparing Kubespray ${VERSION}"
    echo "=============================================="

    KS_DIR="${WORK_DIR}/kubespray-versions/${VERSION}"
    R    echo "=============================================="

    echo "=============================================="

    echo "=============================================="

    echo "=============================================="

    echo "=============================================="

    echo "=============================================="

    echo "=============================================="

    echo "=============================================="

EPO_DIR="${WORK_DIR}/repository/${VERSION}"

    # 3.1 克隆源码
    if [ ! -d "${KS_DIR}" ]; then
        echo "[${VERSION}] 克隆 tag..."
        git clone --depth=1 --branch="${VERSION}" \
            https://github.com/kubernetes-sigs/kubespray.git "${KS_DIR}"
    fi

    # 3.2 虚拟环境
    VENV="${KS_DIR}/.venv"
    if [ ! -f "${VENV}/bin/activate" ]; then
        rm -rf "${VENV}"
        python3 -m venv "${VENV}"
    fi
    source "${VENV}/bin/activate"
    pip install -q --upgrade pip
    pip install -q -r "${KS_DIR}/requirements.txt"

    cd "${KS_DIR}"

    # 3.3 🔍 智能搜索 Download Playbook
    PLAYBOOK=""
    SEARCH_PATHS=(
        "playbooks/offline/download.yml"
        "playbooks/offline/offline.yml"
        "playbooks/download.yml"
        "offline.yml"
        "download.yml"
    )

    for p in "${SEARCH_PATHS[@]}"; do
        if [ -f "${p}" ]; then
            PLAYBOOK="${p}"
            break
        fi
    done

    EXTRA_TAGS=""
    if [ -z "${PLAYBOOK}" ]; then
        if [ -f "playbooks/cluster.yml" ]; then
            PLAYBOOK="playbooks/cluster.yml"
            EXTRA_TAGS="--tags=download"
            echo "[${VERSION}] ⚠️ 未找到专用下载 playbook，回退: ${PLAYBOOK} ${EXTRA_TAGS}"
        else
            echo "❌ [${VERSION}] 找不到任何可用 playbook!"
            find . -name "*.yml" -path "*/playbooks/*" | head -10
            deactivate
            continue
        fi
    else
        echo "[${VERSION}] ✅ 使用专用下载 playbook: ${PLAYBOOK}"
    fi

    # 3.4 预创建集群目录
    if [[ "${PLAYBOOK}" == *"cluster.yml" ]]; then
        echo "[${VERSION}] 预创建 /etc/kubernetes 目录..."
        mkdir -p /etc/kubernetes
    fi


    # 3.4.5 清理 containerd 中不完整的镜像，避免 ctr image export 失败
    # 如果镜像之前被部分拉取（网络中断、进程被杀等），ctr image list 会显示
    # 该镜像存在，但 ctr image export 会因为缺少 content blob 而报错:
    #   "ctr: failed to get reader: content digest sha256:...: not found"
    # 仅用 ctr image rm 删除不完整镜像是不够的：元数据 blob（manifest）仍残留在
    # content store 中，后续 ctr image pull 会检查到这些元数据就跳过下载对应层，
    # 导致新拉取的镜像依然不完整。
    # 正确做法：删除镜像 -> 清理过时 content -> 用 nerdctl 重新拉取（nerdctl 会
    # 实际验证 blob 数据是否在磁盘上存在，而不仅检查元数据）。
    echo "[${VERSION}] 检查 containerd 中是否存在不完整镜像..."
    INCOMPLETE_IMAGES=$(ctr -n k8s.io image check 2>/dev/null | grep "incomplete" | awk '{print $1}' || true)
    if [ -n "${INCOMPLETE_IMAGES}" ]; then
        echo "[${VERSION}] ⚠️ 发现不完整镜像，正在彻底清理:"
        echo "${INCOMPLETE_IMAGES}" | while IFS= read -r img; do
            [ -n "${img}" ] || continue
            echo "  - 删除镜像: ${img}"
            # 提取仓库名用于清理 content（如 kube-apiserver）
            REPO_NAME=$(echo "${img}" | sed 's|.*/||; s|:.*||')
            # 先删除镜像引用
            ctr -n k8s.io image rm "${img}" 2>/dev/null || true
            # 清理该仓库的过时 content blob，避免后续 pull 被残留元数据干扰
            STALE_CONTENT=$(ctr -n k8s.io content ls 2>/dev/null | grep "distribution.source.*=${REPO_NAME}" | awk '{print $1}' || true)
            if [ -n "${STALE_CONTENT}" ]; then
                cnt=$(echo "${STALE_CONTENT}" | wc -l)
                echo "    - 清理 ${cnt} 个过时 content blob"
                echo "${STALE_CONTENT}" | xargs -r ctr -n k8s.io content rm 2>/dev/null || true
            fi
        done
        # 使用 nerdctl 重新拉取，nerdctl 会验证 blob 实际存在于磁盘，缺失则重新下载
        echo "[${VERSION}] 使用 nerdctl 重新拉取清理后的镜像..."
        echo "${INCOMPLETE_IMAGES}" | while IFS= read -r img; do
            [ -n "${img}" ] || continue
            echo "  - nerdctl pull ${img}"
            if nerdctl -n k8s.io pull --platform linux/amd64 "${img}" 2>/dev/null; then
                echo "    ✅ 拉取成功"
            else
                echo "    ⚠️ nerdctl 拉取失败，将交由 ansible 处理"
            fi
        done
        echo "[${VERSION}] ✅ 不完整镜像已彻底清理并重新拉取"
    else
        echo "[${VERSION}] ✅ 所有镜像完整，无需清理"
    fi

    # 3.4.6 清理 ${REPO_DIR}/images/ 中的残缺 tar 文件
    # kubespray 的 "Save and compress image" 任务会先检查 tar 是否已存在，
    # 如果存在则跳过导出（即使 download_force_cache: true 也不会覆盖）。
    # 上次失败留下的残缺 tar（通常只有几 KB）会导致 nerdctl load 报错:
    #   "failed to ingest ...: short read: expected N bytes but got 0"
    # 主动删除这些残缺文件，让 kubespray 完整地重新导出镜像。
    IMG_DIR="${REPO_DIR}/images"
    if [ -d "${IMG_DIR}" ]; then
        # 容器镜像 tar 至少几百 KB，< 1MB 一定是残缺的
        # (find -size 使用 M 后缀会向上取整，须用字节数 -1048576c)
        CORRUPT_TARS=$(find "${IMG_DIR}" -maxdepth 1 -name "*.tar" -type f -size -1048576c 2>/dev/null || true)
        if [ -n "${CORRUPT_TARS}" ]; then
            echo "[${VERSION}] ⚠️ 发现残缺镜像 tar 文件，正在清理以允许重新导出:"
            echo "${CORRUPT_TARS}" | while IFS= read -r f; do
                [ -n "${f}" ] || continue
                echo "  - 删除: ${f} ($(stat -c%s "${f}" 2>/dev/null || echo 0) bytes)"
            done
            echo "${CORRUPT_TARS}" | xargs -r rm -f
            echo "[${VERSION}] ✅ 残缺 tar 已清理"
        else
            echo "[${VERSION}] ✅ 镜像 tar 文件完整，无需清理"
        fi
    fi

    # 3.5 执行下载
    # 关键: 通过 download_cache_dir 把 Kubespray 的下载缓存(二进制+镜像tar)
    # 指向 ${REPO_DIR}，否则会默认落到 /tmp/kubespray_cache，
    # 导致后续离线迁移和完整性校验找不到文件。
    mkdir -p "${REPO_DIR}"
    OUTPUT_LOG=$(mktemp)

    set +e
    ansible-playbook "${PLAYBOOK}" \
        -i "${INV_FILE}" \
        -e '{"download_run_once": true}' \
        -e '{"download_localhost": true}' \
        -e "{\"local_release_dir\": \"${REPO_DIR}\"}" \
        -e "{\"download_cache_dir\": \"${REPO_DIR}\"}" \
        -e '{"download_container": true}' \
        -e '{"download_force_cache": true}' \
        -e '{"container_manager": "containerd"}' \
        ${EXTRA_TAGS} \
        --become 2>&1 | tee "${OUTPUT_LOG}"
    ANSIBLE_RC=$?
    set -e

    # 3.6 Ansible 执行结果校验
    SKIPPED_PLAYS=$(grep -c "skipping: no hosts matched" "${OUTPUT_LOG}" || true)
    CHANGED_TASKS=$(grep -cE "changed=|ok=" "${OUTPUT_LOG}" || true)

    if [ "${ANSIBLE_RC}" -ne 0 ]; then
        echo "❌ [${VERSION}] Ansible 执行失败 (exit code: ${ANSIBLE_RC})"
        deactivate; rm -f "${OUTPUT_LOG}"; continue
    fi

    if [ "${SKIPPED_PLAYS}" -gt 5 ] && [ "${CHANGED_TASKS}" -lt 3 ]; then
        echo "❌ [${VERSION}] 检测到无效执行：大量 Play 被跳过且无实际任务运行"
        deactivate; rm -f "${OUTPUT_LOG}"; continue
    fi
    rm -f "${OUTPUT_LOG}"

    # =====================================================
    # 3.7 ✅ 深度完整性校验
    # =====================================================
    echo "[${VERSION}] 🔍 开始离线包完整性校验..."
    VERIFY_PASS=true

    # 校验1: 二进制文件 / 核心组件
    # 注意1: 用 `find -print -quit` 替代 `find | head -1`，
    #         避免 set -o pipefail 下 head 提前关闭管道导致 find 收到 SIGPIPE (exit 141)
    #         进而触发 set -e 让整个脚本异常退出。
    # 注意2: Kubespray 把所有下载产物(含二进制、压缩包、镜像 tar)平铺在
    #         ${download_cache_dir}(= ${REPO_DIR}) 根目录下，文件名带版本后缀，
    #         如 kubelet-1.35.4-amd64、cni-plugins-linux-amd64-1.9.1.tgz。
    #         因此在整个 ${REPO_DIR} 范围内按名称前缀匹配即可。
    EXPECTED_BINS=("kubectl" "kubeadm" "kubelet" "crictl" "cni-plugins" "etcd" "calicoctl" "containerd" "runc" "nerdctl")
    MISSING_BINS=()
    for bin in "${EXPECTED_BINS[@]}"; do
        found=$(find "${REPO_DIR}" -maxdepth 2 -name "${bin}*" -type f -print -quit 2>/dev/null || true)
        if [ -z "${found}" ]; then
            MISSING_BINS+=("${bin}")
        fi
    done
    if [ ${#MISSING_BINS[@]} -gt 0 ]; then
        echo "  ❌ 缺失二进制/组件: ${MISSING_BINS[*]}"
        VERIFY_PASS=false
    else
        echo "  ✅ 二进制/组件完整 (${#EXPECTED_BINS[@]}/${#EXPECTED_BINS[@]})"
    fi

    # 校验2: 镜像 tar 文件 (Kubespray 默认缓存到 ${download_cache_dir}/images/)
    IMAGE_TARS=$(find "${REPO_DIR}" \( -name "*.tar" -o -name "*.tar.gz" \) -type f 2>/dev/null)
    TAR_COUNT=$(echo "${IMAGE_TARS}" | grep -c . || true)
    if [ "${TAR_COUNT}" -eq 0 ]; then
        echo "  ❌ 未检测到任何镜像 tar 文件"
        VERIFY_PASS=false
    else
        TOTAL_SIZE=$(du -sh "${REPO_DIR}" 2>/dev/null | cut -f1)
        echo "  ✅ 镜像文件: ${TAR_COUNT} 个, 总大小: ${TOTAL_SIZE}"
    fi

    # 校验3: 核心镜像清单比对
    DOWNLOAD_DEFAULTS="${KS_DIR}/roles/download/defaults/main.yml"
    if [ -f "${DOWNLOAD_DEFAULTS}" ]; then
        EXPECTED_IMAGES=$(grep -cE '^\s+tag:\s+' "${DOWNLOAD_DEFAULTS}" 2>/dev/null || echo "0")
        if [ "${EXPECTED_IMAGES}" -gt 0 ] && [ "${TAR_COUNT}" -lt "$((EXPECTED_IMAGES / 2))" ]; then
            echo "  ⚠️ 镜像数量偏少: 实际 ${TAR_COUNT}, 预期约 ${EXPECTED_IMAGES} 个组件"
            echo "     可能原因: 部分镜像使用了默认跳过策略或架构不匹配"
            VERIFY_PASS=false
        fi
    fi

    # 校验4: 空文件检测
    EMPTY_FILES=$(find "${REPO_DIR}" -type f -empty 2>/dev/null | wc -l || true)
    if [ "${EMPTY_FILES}" -gt 0 ]; then
        echo "  ❌ 发现 ${EMPTY_FILES} 个空文件（下载不完整）:"
        # 用 while read + 计数替代 head -5，避免 pipefail + SIGPIPE 退出
        n=0
        while IFS= read -r f; do
            [ -n "${f}" ] || continue
            echo "     - ${f}"
            n=$((n+1))
            [ "${n}" -ge 5 ] && break
        done < <(find "${REPO_DIR}" -type f -empty 2>/dev/null || true)
        VERIFY_PASS=false
    else
        echo "  ✅ 无空文件"
    fi

    # 校验结果汇总
    if [ "${VERIFY_PASS}" = true ]; then
        echo "  🎉 [${VERSION}] 离线包完整性校验通过！"
    else
        echo "  ⚠️ [${VERSION}] 离线包存在缺陷，请勿直接用于生产部署！"
        echo "     建议重新执行本脚本或手动补全缺失文件"
    fi

    deactivate
done

# ================= 4. 📋 离线迁移操作指引 =================
echo ""
echo "============================================================"
echo "📦 离线包迁移到目标部署服务器的操作步骤"
echo "============================================================"
echo ""
echo "【步骤 1】打包离线资源（在当前机器上执行）"
echo "─────────────────────────────────────────"
echo "  cd ${WORK_DIR}"
echo "  tar czf kubespray-offline-bundle.tar.gz \\"
echo "      repository/ \\"
echo "      kubespray-versions/ \\"
echo "      inventory/"
echo ""
echo "  # 查看包大小"
echo "  ls -lh kubespray-offline-bundle.tar.gz"
echo ""
echo "【步骤 2】传输到目标服务器（U盘/光盘/内网文件服务器）"
echo "─────────────────────────────────────────"
echo "  scp kubespray-offline-bundle.tar.gz user@target-server:/opt/"
echo "  # 或通过 U 盘拷贝后在目标服务器执行:"
echo "  cp /media/usb/kubespray-offline-bundle.tar.gz /opt/"
echo ""
echo "【步骤 3】在目标服务器上解压并部署"
echo "─────────────────────────────────────────"
echo "  cd /opt"
echo "  tar xzf kubespray-offline-bundle.tar.gz"
echo ""
echo "  # 进入对应版本的 kubespray 目录"
echo "  cd /opt/kubespray-offline/kubespray-versions/v2.31.0"
echo "  source .venv/bin/activate"
echo ""
echo "  # ⚠️ 修改 inventory 为实际集群配置"
echo "  cp -r /opt/kubespray-offline/inventory/dummy /opt/kubespray-offline/inventory/my-cluster"
echo "  vi /opt/kubespray-offline/inventory/my-cluster/hosts.ini"
echo ""
echo "  # 执行离线部署（关键参数指向本地缓存）"
echo "  ansible-playbook playbooks/cluster.yml \\"
echo "      -i /opt/kubespray-offline/inventory/my-cluster/hosts.ini \\"
echo "      -e '{\"local_release_dir\": \"/opt/kubespray-offline/repository/v2.31.0\"}' \\"
echo "      -e '{\"download_run_once\": false}' \\"
echo "      -e '{\"download_localhost\": false}' \\"
echo "      --become"
echo ""
echo "============================================================"
echo "💡 提示: 目标服务器无需联网，所有镜像和二进制均从 local_release_dir 加载"
echo "============================================================"

