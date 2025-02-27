#!/bin/bash

# 用来恢复 blogs 环境

set -x

WD=$(pwd)

if [ -d "themes/archer" ] && [ ! "$(ls -A themes/archer)" ]; then
    git clone https://github.com/fi3ework/hexo-theme-archer.git themes/archer --depth=1
    mv themes/archer/_config.yml themes/archer/_config.yml.template
    if [ -d "backup" ]; then
        rm -r themes/archer/source/assets
        cp -r backup/assets themes/archer/source/assets
        rm -r themes/archer/source/avatar
        cp -r backup/avatar themes/archer/source/avatar
        rm -r themes/archer/source/intro
        cp -r backup/intro themes/archer/source/intro
    fi
fi

# https://github.com/fi3ework/hexo-theme-archer?tab=readme-ov-file#%E5%BF%AB%E9%80%9F%E5%AE%89%E8%A3%85
# archer 官方要求的依赖
npm install hexo-generator-json-content
npm install hexo-wordcount

# latex 数学公式依赖
# 安装 pandox
PANDOX_V=3.6.3
PANDOX_ARCH=
if [ "$(uname -m)" == "aarch64" ]; then
    PANDOX_ARCH=arm64
elif [ "$(uname -m)" == "x86_64" ]; then
    PANDOX_ARCH=amd64
else
    echo "Unsupported architecture: $(uname -m)"
    exit 1
fi
INSTALLED=1
if dpkg-query -l | grep -q "pandoc"; then
    # 如果已经安装，检查版本号
    installed_version=$(dpkg-query -l | grep "pandoc" | awk '{print $3}')
    if [ "$installed_version" != "$PANDOX_V-1" ]; then
        INSTALLED=0
    fi
else
    INSTALLED=0
fi
if [ "$INSTALLED" == 0 ]; then
    cd /home
    wget https://github.com/jgm/pandoc/releases/download/$PANDOX_V/pandoc-$PANDOX_V-1-$PANDOX_ARCH.deb
    dpkg -i pandoc-$PANDOX_V-1-$PANDOX_ARCH.deb
    cd $WD
fi
npm un hexo-renderer-marked --save
npm install hexo-renderer-pandoc --save

# emoji 依赖
npm un hexo-renderer-marked --save
npm install markdown-it-emoji --save

set +x
