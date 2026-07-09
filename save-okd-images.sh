#!/bin/bash
set -euo pipefail
# ====================== 全局配置 ======================
RELEASE_IMG="quay.io/okd/scos-release:4.22.0-okd-scos.6"
FIXED_SCOS_RELEASE="quay.io/okd/scos-release@sha256:765b8a3547a0cd97152dfb2fe4e51d8c23da8a6de77f3a131f33ee016d357bf1"
CLOUD_FILTER=("aws" "gcp" "azure" "ibm" "powervs")
BASE_OUT="./okd-offline-images"
MAX_RETRY=3
TAG_MAP_FILE="${BASE_OUT}/image-tag-map.lst"
IMAGE_LIST_FILE="okd-images.lst"

# ====================== 帮助文档 ======================
usage() {
cat << EOF
OKD 4.22 SCOS 离线镜像导出脚本（统一全量导出）
用法：$0
内置修复：
  1. 启动自动清空旧导出目录，清除损坏tar包
  2. 拉取镜像前强制删除本地残缺镜像，规避layer not known
  3. 自动过滤纯短名镜像与云厂商镜像，消除podman短名解析报错
  4. 保存digest镜像时自动补充repo:tag，确保podman load后镜像可按名称引用
  5. 生成image-tag-map.lst映射文件，记录digest与tag的对应关系
  6. 统一导出所有镜像至 all-image 目录，不打包压缩
EOF
exit 0
}

if [[ $# -ne 0 ]]; then
    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        usage
    fi
    echo "错误：本脚本无需参数，执行 $0 --help 查看说明"
    exit 1
fi

# ====================== 前置清理 ======================
echo "===== 前置清理：删除历史损坏镜像导出文件 ====="
rm -rf "${BASE_OUT}"
mkdir -p "${BASE_OUT}"
echo "旧目录清理完成，新建输出目录：${BASE_OUT}"

# ====================== 预拉release镜像 ======================
pull_release() {
    echo "预拉取release镜像: ${RELEASE_IMG}"
    local cnt=0
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
        # 不含 / 纯短名直接丢弃
        if [[ "$img" != *"/"* ]]; then
            continue
        fi
        # 跳过云厂商镜像
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
    # 通过返回值传递数组（空数组时返回空行，避免 unbound variable）
    if [[ ${#res[@]} -eq 0 ]]; then
        echo ""
    else
        echo "${res[@]}"
    fi
}

# ====================== 标签解析：确保digest镜像保存时携带repo:tag ======================
resolve_save_tag() {
    local digest_ref="$1"
    local short_name="$2"

    # FIXED_SCOS_RELEASE: 用已知 RELEASE_IMG tag
    if [[ "$digest_ref" == "${FIXED_SCOS_RELEASE}" ]]; then
        podman tag "$digest_ref" "${RELEASE_IMG}" 2>/dev/null || true
        echo "${RELEASE_IMG}"
        return 0
    fi

    # 检查镜像是否已有 RepoTags
    local existing_tags
    existing_tags=$(podman image inspect --format '{{.RepoTags}}' "$digest_ref" 2>/dev/null \
        | tr -d '[]"' | sed 's/^ *//;s/ *$//')

    if [[ -n "$existing_tags" ]]; then
        echo "$existing_tags" | awk '{print $1}'
        return 0
    fi

    # 无 tag: 用短名构造 repo:short_name
    local repo="${digest_ref%%@*}"
    local derived_tag="${repo}:${short_name}"
    podman tag "$digest_ref" "$derived_tag"
    echo "$derived_tag"
}

# ====================== 镜像拉取重试 ======================
pull_with_retry() {
    local img="$1"
    local cnt=0
    # 拉取前强制删除本地损坏/残留镜像，解决layer not known
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

# ====================== 主流程 ======================
pull_release

# 读取镜像列表
echo "===== 从 ${IMAGE_LIST_FILE} 读取完整镜像地址 ===="
if [[ ! -f "${IMAGE_LIST_FILE}" ]]; then
    echo "错误：镜像列表文件 ${IMAGE_LIST_FILE} 不存在"
    exit 1
fi

# 构建digest→短名映射表 + 提取镜像URL列表
declare -A DIGEST_TO_SHORTNAME
raw_images=()
while IFS=' ' read -r short_name full_ref; do
    DIGEST_TO_SHORTNAME["$full_ref"]="$short_name"
    raw_images+=("$full_ref")
done < "${IMAGE_LIST_FILE}"
# 附加 release 镜像
DIGEST_TO_SHORTNAME["${FIXED_SCOS_RELEASE}"]="scos-release"
raw_images+=("${FIXED_SCOS_RELEASE}")
# 去重
raw_images=($(echo "${raw_images[@]}" | tr ' ' '\n' | sort -u))
echo "原始镜像总数：${#raw_images[@]}"
echo "短名映射表构建完成，共${#DIGEST_TO_SHORTNAME[@]}条记录"

# 过滤：短名/云镜像剔除
filter_result=$(filter_cloud_images "${raw_images[@]}")
if [[ -z "$filter_result" ]]; then
    clean_images=()
else
    clean_images=($filter_result)
fi
echo "过滤后有效完整镜像数量：${#clean_images[@]}"

if [[ ${#clean_images[@]} -eq 0 ]]; then
    echo "错误：过滤后无可用镜像，终止执行"
    exit 1
fi

# ====================== 统一导出所有镜像 ======================
out_dir="${BASE_OUT}/all-image"
pack_file="${BASE_OUT}/all-image.tar.gz"

echo -e "\n===== 统一导出全部镜像 ===="
rm -rf "$out_dir"
rm -f "$pack_file"
mkdir -p "$out_dir"

echo "待导出镜像总数：${#clean_images[@]}"
for idx in "${!clean_images[@]}"; do
    echo "$((idx+1)). ${clean_images[$idx]}"
done
echo "===================================="

# 初始化映射文件
> "${TAG_MAP_FILE}"

for img in "${clean_images[@]}"; do
    tar_name=$(echo "$img" | sed 's/[@\/:]/_/g').tar
    tar_path="${out_dir}/${tar_name}"
    [[ -f "$tar_path" ]] && rm -f "$tar_path"
    echo "===== 处理镜像：$img ===="
    pull_with_retry "$img"

    # 解析保存引用：确保digest镜像带有repo:tag
    short_name="${DIGEST_TO_SHORTNAME[$img]:-unknown}"
    save_ref=$(resolve_save_tag "$img" "$short_name")

    echo "保存引用：$save_ref (原始digest: $img)"
    podman save -o "$tar_path" "$save_ref"

    # 记录映射：digest_ref tagged_ref short_name
    echo "$img $save_ref $short_name" >> "${TAG_MAP_FILE}"
    echo "保存完成：$tar_path (tag: $save_ref)"
done

echo "===== 全部镜像导出完毕 ====="
echo "输出目录：$out_dir"
echo "映射文件：${TAG_MAP_FILE}"
