#!/bin/bash
set -euo pipefail

BASE_OUT="./okd-offline-images"
TAR_DIR="${BASE_OUT}/all-image"
TMP_REMOTE="/var/tmp/okd-img-tmp"

usage() {
cat << EOF
OKD 离线镜像上传加载工具（免密SSH/SCP，直接传tar不压缩）
用法：
  $0 <节点IP/主机名>

示例：
  ./load-okd-images.sh okd-bootstrap
  ./load-okd-images.sh 10-66-3-40
  ./load-okd-images.sh okd-worker-01

逻辑：
  1. SCP逐个上传镜像tar文件至远端 /var/tmp/okd-img-tmp
  2. 远端逐个 podman load 导入镜像，边传边导
  3. 执行完毕自动清理远端临时文件
优势：
  不再打包压缩/解压，省去tar.gz压缩和解压时间，边传边导节省总耗时
要求：本机到目标节点core用户已配置 SSH 免密登录
EOF
exit 0
}

# 参数校验
if [[ $# -ne 1 ]]; then
    echo "参数数量错误！"
    usage
fi

NODE="$1"

if [[ ! -d "$TAR_DIR" ]]; then
    echo "错误：本地镜像目录 ${TAR_DIR} 不存在"
    echo "请先执行 ./save-okd-images.sh 导出镜像"
    exit 1
fi

# 收集本地tar文件
tar_files=()
for f in "${TAR_DIR}"/*.tar; do
    [[ -f "$f" ]] && tar_files+=("$f")
done

if [[ ${#tar_files[@]} -eq 0 ]]; then
    echo "错误：${TAR_DIR} 目录下无任何tar文件"
    exit 1
fi

echo "============================================="
echo "目标节点：${NODE}"
echo "远端临时目录：${TMP_REMOTE}"
echo "待上传镜像数：${#tar_files[@]}"
echo "============================================="

# 1. 远端创建临时目录
echo "[准备] 初始化远端临时目录"
ssh core@"${NODE}" "rm -rf ${TMP_REMOTE}; mkdir -p ${TMP_REMOTE}"

# 2. 逐个 SCP + 远端 podman load（边传边导）
total=${#tar_files[@]}
idx=0
for tar_file in "${tar_files[@]}"; do
    idx=$((idx+1))
    tar_name=$(basename "$tar_file")
    echo -e "\n===== [${idx}/${total}] 处理镜像：${tar_name} ====="

    # SCP 上传单个tar
    echo "  [上传] SCP ${tar_name} -> ${NODE}:${TMP_REMOTE}/"
    scp -q "$tar_file" core@"${NODE}:${TMP_REMOTE}/"

    # 远端 podman load 该tar，完成后删除远端tar节省磁盘
    echo "  [导入] 远端 podman load ${tar_name}"
    ssh core@"${NODE}" bash -s "${TMP_REMOTE}" "${tar_name}" << 'REMOTE_CODE'
set -euo pipefail
TMP_DIR="$1"
TAR_NAME="$2"
podman load -i "${TMP_DIR}/${TAR_NAME}"
rm -f "${TMP_DIR}/${TAR_NAME}"
REMOTE_CODE

    echo "  [完成] ${tar_name} 已导入并清理"
done

# 清理远端临时目录（已为空，但确保干净）
ssh core@"${NODE}" "rm -rf ${TMP_REMOTE}"

echo -e "\n============================================="
echo "全部镜像上传导入任务完成！(${total}个)"
echo "节点 ${NODE} 镜像列表预览："
echo "============================================="
ssh core@"${NODE}" "podman images | head -30"
