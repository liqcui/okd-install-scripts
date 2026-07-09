#!/bin/bash
set -euo pipefail
# ====================== 全局配置 ======================
BASE_OUT="./okd-offline-images"
TAG_MAP_FILE="${BASE_OUT}/image-tag-map.lst"

# ====================== 帮助文档 ======================
usage() {
cat << EOF
OKD 4.22 SCOS 离线镜像导入脚本
用法：$0 [bootstrap|master|worker|all] [--verify]
参数：
  bootstrap  导入bootstrap全套渲染镜像
  master     导入控制平面master组件镜像
  worker     导入worker计算节点通用镜像
  all        一次性导入bootstrap+master+worker
  --verify   导入后验证每个镜像tag是否与映射文件一致
说明：
  镜像tar包已包含repo:tag信息，podman load后会自动恢复标签。
  可配合 --verify 参数验证导入结果是否完整。
EOF
exit 0
}

# ====================== 参数校验 ======================
VERIFY=0
ARG=""
for param in "$@"; do
    if [[ "$param" == "-h" || "$param" == "--help" ]]; then
        usage
    elif [[ "$param" == "--verify" ]]; then
        VERIFY=1
    elif [[ -z "$ARG" ]]; then
        ARG="$param"
    else
        echo "错误：仅支持单个角色参数，附加 --verify 可选"
        exit 1
    fi
done

if [[ -z "$ARG" ]]; then
    usage
fi
ALLOW_ARGS=("bootstrap" "master" "worker" "all")
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

# ====================== 导入单组镜像 ======================
load_single_group() {
    local group_name="$1"
    local pack_file="${BASE_OUT}/${group_name}-image.tar.gz"
    local out_dir="${BASE_OUT}/${group_name}-image"

    if [[ ! -f "$pack_file" ]]; then
        echo "错误：打包文件 $pack_file 不存在"
        echo "请先在联网机器上运行 save-okd-images.sh $group_name 导出镜像"
        return 1
    fi

    echo -e "\n===== 解压${group_name}镜像包 ===="
    tar -zxvf "$pack_file" -C "$BASE_OUT"

    echo -e "\n===== 导入${group_name}镜像 ===="
    local count=0
    local failed=0
    for tar_file in "${out_dir}"/*.tar; do
        [[ ! -f "$tar_file" ]] && continue
        count=$((count+1))
        echo ">>> 导入镜像 $count: $(basename "$tar_file")"
        if podman load -i "$tar_file"; then
            echo "导入成功"
        else
            echo "导入失败：$tar_file"
            failed=$((failed+1))
        fi
    done

    if [[ $count -eq 0 ]]; then
        echo "【${group_name}】未找到任何tar文件"
    else
        echo "【${group_name}】导入完成：成功${count}-${failed}，失败${failed}"
    fi

    # 验证模式：检查每个镜像的tag是否与映射文件一致
    if [[ "$VERIFY" -eq 1 ]] && [[ -f "${TAG_MAP_FILE}.${group_name}" ]]; then
        echo -e "\n===== 验证${group_name}镜像标签 ===="
        local verify_ok=0
        local verify_fail=0
        while IFS=' ' read -r digest_ref tagged_ref short_name; do
            if podman image exists "$tagged_ref" 2>/dev/null; then
                echo "  OK: $tagged_ref"
                verify_ok=$((verify_ok+1))
            else
                echo "  MISSING: $tagged_ref (digest: $digest_ref)"
                verify_fail=$((verify_fail+1))
            fi
        done < "${TAG_MAP_FILE}.${group_name}"
        echo "验证结果：${verify_ok} 通过，${verify_fail} 缺失"
    fi
}

# ====================== 分支执行 ======================
case "$ARG" in
bootstrap)
    load_single_group "bootstrap"
    ;;
master)
    load_single_group "master"
    ;;
worker)
    load_single_group "worker"
    ;;
all)
    load_single_group "bootstrap"
    load_single_group "master"
    load_single_group "worker"
    ;;
*)
    exit 1
    ;;
esac

echo -e "\n镜像导入完毕，可使用 podman images 查看本地镜像列表"
if [[ -f "${TAG_MAP_FILE}" ]]; then
    echo "映射文件：${TAG_MAP_FILE}，记录了 digest→tag 对应关系"
fi
