#!/bin/bash
set -euo pipefail

BASE_OUT="./okd-offline-images"
TMP_REMOTE="/var/tmp/okd-img-tmp"
PACK_NAME="all-image.tar.gz"

usage() {
cat << EOF
OKD 离线镜像上传加载工具（免密SSH/SCP）
用法：
  $0 <节点IP/主机名>

示例：
  ./load-okd-images.sh okd-bootstrap
  ./load-okd-images.sh 10-66-3-40
  ./load-okd-images.sh okd-worker-01

逻辑：
  1. SCP上传压缩包至远端 /var/tmp/okd-img-tmp
  2. 远端自动解压，批量 podman load 导入镜像
  3. 执行完毕自动清理远端临时文件
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
LOCAL_PACK="${BASE_OUT}/${PACK_NAME}"

if [[ ! -f "$LOCAL_PACK" ]]; then
    echo "错误：本地缺失镜像包 ${LOCAL_PACK}"
    echo "请先执行 ./save-okd-images.sh 导出镜像"
    exit 1
fi

echo "============================================="
echo "目标节点：${NODE}"
echo "远端临时目录：${TMP_REMOTE}"
echo "待处理镜像包：${PACK_NAME}"
echo "============================================="

# 1. 远端创建临时目录
echo "[1/3] 初始化远端临时目录"
ssh core@"${NODE}" "rm -rf ${TMP_REMOTE}; mkdir -p ${TMP_REMOTE}"

# 2. SCP 上传压缩包
echo "[2/3] SCP 上传 ${LOCAL_PACK} -> ${NODE}:${TMP_REMOTE}/"
scp -q "${LOCAL_PACK}" core@"${NODE}:${TMP_REMOTE}/"

# 3. 远端执行解压 + podman load
echo "[3/3] 远端解压并导入所有镜像tar"
ssh core@"${NODE}" bash -s "${TMP_REMOTE}" "${PACK_NAME}" << 'REMOTE_CODE'
set -euo pipefail
TMP_DIR="$1"
PKG="$2"
cd "${TMP_DIR}"
tar -zxf "${PKG}"
UNPACK_DIR=$(basename "${PKG}" .tar.gz)
cd "${UNPACK_DIR}"
for tarfile in *.tar; do
    echo ">>> 导入镜像: ${tarfile}"
    podman load -i "${tarfile}"
done
echo "===== ${PKG} 镜像全部导入完成 ====="
REMOTE_CODE

# 清理远端临时文件
echo "[清理] 删除远端临时目录 ${TMP_REMOTE}"
ssh core@"${NODE}" "rm -rf ${TMP_REMOTE}"

echo -e "\n============================================="
echo "全部镜像上传导入任务完成！节点 ${NODE} 镜像列表预览："
echo "============================================="
ssh core@"${NODE}" "podman images | head -30"
