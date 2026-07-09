#!/bin/bash
set -euo pipefail
# ====================== 全局配置 ======================
RELEASE_IMG="quay.io/okd/scos-release:4.22.0-okd-scos.6"
FIXED_SCOS_RELEASE="quay.io/okd/scos-release@sha256:765b8a3547a0cd97152dfb2fe4e51d8c23da8a6de77f3a131f33ee016d357bf1"
CLOUD_FILTER=("aws" "gcp" "azure" "ibm" "powervs")
BASE_OUT="./okd-offline-images"
MAX_RETRY=3

# ====================== 帮助文档 ======================
usage() {
cat << EOF
OKD 4.22 SCOS 离线镜像导出脚本
用法：$0 [bootstrap|master|worker|ostree|all]
参数：
  bootstrap  导出bootstrap全套渲染镜像
  master     导出控制平面master组件镜像
  worker     导出worker计算节点通用镜像
  ostree     仅提示scos使用bootc预拉取
  all        一次性导出bootstrap+master+worker
内置修复：
  1. 启动自动清空旧导出目录，清除损坏tar包
  2. 拉取镜像前强制删除本地残缺镜像，规避layer not known
  3. 自动过滤纯短名镜像，消除podman短名解析报错
EOF
exit 0
}

# ====================== 参数校验 ======================
if [[ $# -eq 0 ]]; then
    usage
fi
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
fi
if [[ $# -gt 1 ]]; then
    echo "错误：仅支持单个参数，执行 $0 --help"
    exit 1
fi
ARG="$1"
ALLOW_ARGS=("bootstrap" "master" "worker" "ostree" "all")
VALID=0
for a in "${ALLOW_ARGS[@]}"; do
    if [[ "$ARG" == "$a" ]]; then
        VALID=1
        break
    fi
done
if [[ $VALID -eq 0 ]]; then
    echo "错误：无效参数 $ARG"
    echo "合法参数：${ALLOW_ARGS[*]}"
    exit 1
fi

# ====================== 前置清理：步骤4 清空旧导出目录 ======================
echo "===== 前置清理：删除历史损坏镜像导出文件 ====="
rm -rf "${BASE_OUT}"
mkdir -p "${BASE_OUT}"
echo "旧目录清理完成，新建输出目录：${BASE_OUT}"

# ====================== 工具：预拉release ======================
pull_release() {
    echo "预拉取release镜像: ${RELEASE_IMG}"
    local cnt=0
    # 拉取前先清理本地残留镜像
    podman rmi -f "${RELEASE_IMG}" 2>/dev/null || true
    while [[ $cnt -lt $MAX_RETRY ]]; do
        if podman pull "${RELEASE_IMG}"; then
            echo "release镜像拉取完成"
            return 0
        fi
        cnt=$((cnt+1))
        echo "拉取失败，等待10s重试..."
        sleep 10
    done
    echo "连续${MAX_RETRY}次拉取release失败，终止脚本"
    exit 1
}

# ====================== 过滤：云镜像、纯短名 ======================
filter_cloud_images() {
    local img_list=("$@")
    local res=()
    for img in "${img_list[@]}"; do
        # 1. 不含 / 纯短名直接丢弃
        if [[ "$img" != *"/"* ]]; then
            continue
        fi
        # 2. 跳过云厂商镜像
        local skip=0
        for cloud in "${CLOUD_FILTER[@]}"; do
            if [[ "$img" == *"$cloud"* ]]; then
                skip=1
                break
            fi
        done
        if [[ $skip -eq 0 ]]; then
            res+=("$img")
        fi
    done
    echo "${res[@]}"
}

# ====================== 按角色分组 ======================
split_images_by_role() {
    local all_raw=("$@")
    declare -A bootstrap_arr master_arr worker_arr
    bootstrap_arr["${FIXED_SCOS_RELEASE}"]=1

    for img in "${all_raw[@]}"; do
        if [[ "$img" == *"-render"* || "$img" == *cluster-version* || "$img" == *config-operator* || "$img" == *authentication* ]]; then
            bootstrap_arr["$img"]=1
        elif [[ "$img" == *kube-apiserver* || "$img" == *kube-controller* || "$img" == *kube-scheduler* || "$img" == *etcd* || "$img" == *machine-config* ]]; then
            master_arr["$img"]=1
        else
            worker_arr["$img"]=1
        fi
    done
    echo "BOOTSTRAP ${!bootstrap_arr[*]}"
    echo "MASTER ${!master_arr[*]}"
    echo "WORKER ${!worker_arr[*]}"
}

# ====================== 镜像拉取重试：内置步骤3 拉取前清残缺镜像 ======================
pull_with_retry() {
    local img="$1"
    local cnt=0
    # 关键：拉取前强制删除本地损坏/残留镜像，解决layer not known
    podman rmi -f "$img" 2>/dev/null || true
    while [[ $cnt -lt $MAX_RETRY ]]; do
        echo ">>> 拉取镜像 $img 第$((cnt+1))/$MAX_RETRY次"
        if podman pull "$img"; then
            return 0
        fi
        cnt=$((cnt+1))
        echo "拉取失败，等待10秒重试..."
        sleep 10
    done
    echo "镜像 $img 拉取全部失败，退出"
    exit 1
}

# ====================== 导出打包 ======================
export_single_group() {
    local group_name="$1"
    shift
    local img_raw_list=("$@")
    if [[ ${#img_raw_list[@]} -eq 0 ]]; then
        echo "【${group_name}】无可用镜像，直接跳过"
        return
    fi
    local out_dir="${BASE_OUT}/${group_name}-image"
    local pack_file="${BASE_OUT}/${group_name}-image.tar.gz"

    echo -e "\n===== 清理${group_name}旧文件 ===="
    rm -rf "$out_dir"
    rm -f "$pack_file"
    mkdir -p "$out_dir"

    echo "【${group_name}】待导出镜像总数：${#img_raw_list[@]}"
    for idx in "${!img_raw_list[@]}"; do
        echo "$((idx+1)). ${img_raw_list[$idx]}"
    done
    echo "===================================="

    for img in "${img_raw_list[@]}"; do
        tar_name=$(echo "$img" | sed 's/[@\/:]/_/g').tar
        tar_path="${out_dir}/${tar_name}"
        [[ -f "$tar_path" ]] && rm -f "$tar_path"
        echo "===== 处理镜像：$img ===="
        pull_with_retry "$img"
        podman save -o "$tar_path" "$img"
        echo "保存完成：$tar_path"
    done

    echo -e "\n打包压缩包：$pack_file"
    tar -zcvf "$pack_file" -C "$BASE_OUT" "${group_name}-image"
    echo "【${group_name}】打包完毕"
}

# ====================== 主流程 ======================
pull_release
echo "===== 从okd-images.lst读取完整镜像地址 ===="
# 文件格式：<组件短名> <完整镜像URL>，使用awk逐行提取第二列，避免大文件内存问题
IMAGE_LIST_FILE="okd-images.lst"
if [[ ! -f "${IMAGE_LIST_FILE}" ]]; then
    echo "错误：镜像列表文件 ${IMAGE_LIST_FILE} 不存在"
    exit 1
fi
# 使用awk流式读取，只提取第二列（镜像URL），sort -u去重
raw_images=($(awk '{print $2}' "${IMAGE_LIST_FILE}" | sort -u))
echo "原始镜像总数：${#raw_images[@]}"

# 过滤：短名/云镜像全部剔除
clean_images=($(filter_cloud_images "${raw_images[@]}"))
echo "过滤后有效完整镜像数量：${#clean_images[@]}"

# 分组
split_out=$(split_images_by_role "${clean_images[@]}")
BOOTSTRAP_IMGS=($(echo "$split_out" | grep ^BOOTSTRAP | sed 's/BOOTSTRAP //'))
MASTER_IMGS=($(echo "$split_out" | grep ^MASTER | sed 's/MASTER //'))
WORKER_IMGS=($(echo "$split_out" | grep ^WORKER | sed 's/WORKER //'))

# ====================== 分支执行 ======================
case "$ARG" in
bootstrap)
    export_single_group "bootstrap" "${BOOTSTRAP_IMGS[@]}"
    ;;
master)
    export_single_group "master" "${MASTER_IMGS[@]}"
    ;;
worker)
    export_single_group "worker" "${WORKER_IMGS[@]}"
    ;;
ostree)
    echo "===== ostree系统镜像说明 ===="
    echo "scos-content为系统分层镜像，使用bootc管理，不通过podman save导出"
    ;;
all)
    export_single_group "bootstrap" "${BOOTSTRAP_IMGS[@]}"
    export_single_group "master" "${MASTER_IMGS[@]}"
    export_single_group "worker" "${WORKER_IMGS[@]}"
    echo -e "\n全部组件镜像导出完成"
    echo "输出目录：$BASE_OUT"
    ;;
*)
    exit 1
    ;;
esac

