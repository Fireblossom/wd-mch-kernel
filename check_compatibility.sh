#!/bin/bash
#
# 兼容性检查脚本
# 用于检查 extracted.dts 中的 compatible 字符串是否在 6.18 内核中支持
#

KERNEL_DIR="linux-6.18.2"
EXTRACTED_DTS="extracted.dts"

echo "=== 检查设备树兼容性 ==="
echo ""

# 提取所有 compatible 字符串
echo "从 extracted.dts 提取 compatible 字符串..."
grep -h "compatible" "$EXTRACTED_DTS" | sed 's/.*compatible.*=.*"\([^"]*\)".*/\1/' | sort -u > /tmp/compatibles.txt

echo "找到的 compatible 字符串:"
cat /tmp/compatibles.txt
echo ""

# 检查每个 compatible 字符串
echo "=== 检查内核支持情况 ==="
while IFS= read -r compat; do
    if [ -z "$compat" ]; then
        continue
    fi
    
    # 转义特殊字符用于 grep
    compat_escaped=$(echo "$compat" | sed 's/[[\.*^$()+?{|]/\\&/g')
    
    # 在驱动中搜索
    found=$(grep -r "$compat_escaped" "$KERNEL_DIR/drivers/" "$KERNEL_DIR/arch/" 2>/dev/null | wc -l)
    
    if [ "$found" -gt 0 ]; then
        echo "✅ $compat - 找到 $found 处引用"
    else
        echo "❌ $compat - 未找到支持"
    fi
done < /tmp/compatibles.txt

echo ""
echo "=== 检查完成 ==="


